import CoreLocation
import MapKit
import SwiftUI
import UIKit
import os

// MARK: - Content Tab Kind

enum ContentTabKind: String, CaseIterable { case games = "Games", chat = "Chat" }

// MARK: - Club Hero View
//
// Renders the club banner image (custom upload, then preset). Sized via the
// shared `bannerAspectRatio` so the crop preview in ClubOwnerSheets matches
// the rendered banner here exactly. The dark gradient/scrim/stripes and all
// overlay chrome live in ClubDetailView's `clubHero` view — this struct is
// only the underlying image layer.

struct ClubHeroView: View {
    /// Single source of truth: banner width ÷ height.
    /// This ratio is shared with ImageCropSheet so the crop preview
    /// matches exactly what renders in the club header (WYSIWYG).
    static let bannerAspectRatio: CGFloat = 1.5

    let club: Club

    private static func heroImageName(for key: String?) -> String {
        switch key {
        case "hero_1": return "vine_concept"
        case "hero_2": return "red_topdown"
        case "hero_3": return "blue_collage"
        case "hero_4": return "blue_closeup"
        case "hero_5": return "red_aerial"
        case "hero_6": return "dark_aerial"
        default:       return "club_hero_default"
        }
    }

    var body: some View {
        GeometryReader { geo in
            if let customURL = club.customBannerURL {
                AsyncImage(url: customURL) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(Self.heroImageName(for: club.heroImageKey))
                            .resizable().scaledToFill()
                    default:
                        Color.black.opacity(0.6)
                    }
                }
                // Force AsyncImage to rebuild when the URL changes so the old
                // cached image does not flash briefly before the new one loads.
                .id(customURL)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            } else {
                Image(Self.heroImageName(for: club.heroImageKey))
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        }
    }
}

// MARK: - Club Detail View

struct ClubDetailView: View {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BookadinkV2", category: "ClubDetailView")
    private static let maxRenderableDetailTextLength = 1600
    private static let maxDisplayNameLength = 120
    private static let maxAddressLength = 260
    private static let maxDescriptionLength = 2000
    private static let maxContactLength = 320
    private static let maxWebsiteLength = 260
    private static let maxManagerLength = 160
    private static let maxTagLength = 40

    /// Hero block height — anchors the dark gradient overlay layout.
    private static let heroHeight: CGFloat = 340

    @EnvironmentObject private var appState: AppState
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let club: Club

    @State private var isShowingInviteSheet = false
    @State private var isDashboardPresented = false
    @State private var editingOwnerGame: Game?
    @State private var ownerDeleteGameCandidate: Game?
    @State private var duplicatingGame: Game?

    @State private var aboutExpanded = false
    @State private var showBookGame = false
    @State private var reviewsExpanded = false
    @State private var shakeBookGame = false
    @State private var navigateToChat = false
    @State private var showLeaveClubConfirm = false
    @State private var showCancelRequestConfirm = false
    @State private var showPinCapAlert = false
    @State private var showConductSheet = false
    @State private var showCancellationPolicySheet = false
    @State private var pendingConductDate: Date? = nil
    @State private var now = Date()
    private let minuteTick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// Always reads the latest in-memory version of this club so fields like
    /// codeOfConduct reflect the most recent fetch, not the navigation-time snapshot.
    private var liveClub: Club {
        appState.clubs.first(where: { $0.id == club.id }) ?? club
    }

    private var allClubGames: [Game] {
        appState.games(for: club)
    }

    private var safeClubName: String {
        cappedDisplayText(club.name, maxLength: Self.maxDisplayNameLength)
    }

    private var safeAddress: String {
        let full = club.formattedAddressFull
        return cappedDisplayText(full.isEmpty ? club.address : full, maxLength: Self.maxAddressLength)
    }

    /// Primary ClubVenue for the contact section — used for venue name, structured address, and map navigation.
    private var primaryVenueForContact: ClubVenue? {
        appState.clubVenuesByClubID[club.id]?.first(where: { $0.isPrimary })
    }

    /// Best available coordinate for map navigation: primary venue → club → nil.
    private var clubMapCoordinate: CLLocationCoordinate2D? {
        if let v = primaryVenueForContact, let lat = v.latitude, let lng = v.longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        if let lat = club.latitude, let lng = club.longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        return nil
    }

    /// Apple Maps URL: coordinate-based when available, string-address fallback.
    private var clubMapURL: URL? {
        if let coord = clubMapCoordinate {
            return MapNavigationURL.directions(to: coord)
        }
        return MapNavigationURL.directions(to: safeAddress)
    }

    private var safeDescription: String {
        cappedDisplayText(club.description, maxLength: Self.maxDescriptionLength)
    }

    private var safeContactEmail: String {
        cappedDisplayText(club.contactEmail, maxLength: Self.maxContactLength)
    }

    private var safeContactPhone: String? {
        trimmedOptional(cappedDisplayText(club.contactPhone ?? "", maxLength: 30))
    }

    private var safeManagerName: String? {
        trimmedOptional(cappedDisplayText(club.managerName ?? "", maxLength: Self.maxManagerLength))
    }

    private var filteredClubGames: [Game] {
        allClubGames
            .filter { $0.status != "cancelled" }
            .filter { $0.dateTime >= now }
            .filter { isClubAdminUser || ($0.publishAt == nil || $0.publishAt! <= now) }
            .sorted { $0.dateTime < $1.dateTime }
    }

    private var isClubAdminUser: Bool {
        appState.isClubAdmin(for: club)
    }

    private var isMemberOrAdmin: Bool {
        if isClubAdminUser { return true }
        switch appState.membershipState(for: club) {
        case .approved, .unknown: return true
        default: return false
        }
    }

    /// Hero descriptor: prefer the primary venue's suburb, then club's suburb /
    /// city, then the legacy display string. Returns "" when nothing is set so
    /// the row hides cleanly.
    private var heroDescriptor: String {
        if let venue = primaryVenueForContact {
            if let suburb = venue.suburb?.trimmingCharacters(in: .whitespacesAndNewlines), !suburb.isEmpty {
                return suburb
            }
        }
        if let suburb = club.suburb?.trimmingCharacters(in: .whitespacesAndNewlines), !suburb.isEmpty {
            return suburb
        }
        let city = club.city.trimmingCharacters(in: .whitespacesAndNewlines)
        if !city.isEmpty { return city }
        let region = club.region.trimmingCharacters(in: .whitespacesAndNewlines)
        return region
    }

    /// Reviews sorted with highest-rated first (most recent breaks ties).
    private var sortedReviews: [GameReview] {
        let reviews = appState.reviewsByClubID[club.id] ?? []
        return reviews.sorted { lhs, rhs in
            if lhs.rating != rhs.rating { return lhs.rating > rhs.rating }
            let l = lhs.createdAt ?? .distantPast
            let r = rhs.createdAt ?? .distantPast
            return l > r
        }
    }

    private var avgRating: Double? {
        let reviews = appState.reviewsByClubID[club.id] ?? []
        guard !reviews.isEmpty else { return nil }
        return Double(reviews.reduce(0) { $0 + $1.rating }) / Double(reviews.count)
    }

    /// Stable per-club hue 0...360 used for the gradient fallback when the
    /// club has no custom banner. Derived deterministically from the UUID so
    /// the same club always paints the same colour across launches.
    private var clubHue: Double {
        let bytes = withUnsafeBytes(of: club.id.uuid) { Array($0) }
        let seed = bytes.reduce(0) { Int($0) &+ Int($1) }
        return Double(seed % 360)
    }

    private var pendingJoinRequestCount: Int {
        appState.ownerJoinRequests(for: club).count
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 0) {
                    clubHero
                        .padding(.bottom, -1)

                    // Membership feedback banner — real state, kept above the fold.
                    if let msg = membershipFeedbackMessage {
                        membershipBanner(msg: msg)
                    }

                    // Credit balance banner — only when the user holds credits at this club.
                    let clubCredit = appState.creditBalance(for: club.id)
                    if clubCredit > 0 {
                        creditBanner(amountCents: clubCredit)
                    }

                    upcomingGamesSection
                    aboutCardSection
                    reviewsCardSection
                    locationCardSection

                    Color.clear.frame(height: 24)
                }
                .padding(.bottom, 130)
            }
            .refreshable {
                await appState.refreshMemberships()
                await appState.refreshClubAdminRole(for: club)
                await appState.refreshGames(for: club)
                await appState.refreshClubs()
                await appState.fetchReviews(for: club.id)
                await appState.refreshCreditBalance(for: club.id)
            }
            .ignoresSafeArea(edges: .top)
            .background(Brand.appBackground)

            floatingCTABar
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .fullScreenCover(isPresented: $isDashboardPresented) {
            ClubDashboardView(club: club)
                .environmentObject(appState)
        }
        .sheet(item: $editingOwnerGame) { game in
            OwnerEditGameSheet(club: club, game: game, initialVenues: appState.venues(for: club)).environmentObject(appState)
        }
        .sheet(item: $duplicatingGame) { game in
            OwnerCreateGameSheet(club: club, initialDraft: nextWeekDraft(from: game)).environmentObject(appState)
        }
        .sheet(isPresented: $showBookGame) {
            ClubBookGameView(club: club).environmentObject(appState)
        }
        .sheet(isPresented: $showConductSheet) {
            ConductAcceptanceSheet(club: liveClub) {
                let conductDate = Date()
                if liveClub.cancellationPolicy?.isEmpty == false {
                    pendingConductDate = conductDate
                    showCancellationPolicySheet = true
                } else {
                    Task { await appState.requestMembership(for: club, conductAcceptedAt: conductDate) }
                }
            }
            .environmentObject(appState)
        }
        .sheet(isPresented: $showCancellationPolicySheet) {
            CancellationPolicyAcceptanceSheet(club: liveClub) {
                let conductDate = pendingConductDate
                pendingConductDate = nil
                Task { await appState.requestMembership(for: club, conductAcceptedAt: conductDate, cancellationPolicyAcceptedAt: Date()) }
            }
            .environmentObject(appState)
        }
        .confirmationDialog(
            "Delete Game?",
            isPresented: Binding(
                get: { ownerDeleteGameCandidate != nil },
                set: { if !$0 { ownerDeleteGameCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let game = ownerDeleteGameCandidate {
                if game.recurrenceGroupID != nil {
                    Button("Delete This Event", role: .destructive) {
                        Task {
                            let deleted = await appState.deleteGameForClub(club, game: game, scope: .singleEvent)
                            if deleted { ownerDeleteGameCandidate = nil }
                        }
                    }
                    Button("Delete This & Future", role: .destructive) {
                        Task {
                            let deleted = await appState.deleteGameForClub(club, game: game, scope: .thisAndFuture)
                            if deleted { ownerDeleteGameCandidate = nil }
                        }
                    }
                    Button("Delete Entire Series", role: .destructive) {
                        Task {
                            let deleted = await appState.deleteGameForClub(club, game: game, scope: .entireSeries)
                            if deleted { ownerDeleteGameCandidate = nil }
                        }
                    }
                } else {
                    Button("Delete Game", role: .destructive) {
                        Task {
                            let deleted = await appState.deleteGameForClub(club, game: game, scope: .singleEvent)
                            if deleted { ownerDeleteGameCandidate = nil }
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { ownerDeleteGameCandidate = nil }
        } message: {
            Text(ownerDeleteGameCandidate?.title ?? "This cannot be undone.")
        }
        .confirmationDialog("Leave club?", isPresented: $showLeaveClubConfirm, titleVisibility: .visible) {
            Button("Leave Club", role: .destructive) {
                Task { await appState.removeMembership(for: club) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Cancel membership request?", isPresented: $showCancelRequestConfirm, titleVisibility: .visible) {
            Button("Cancel Request", role: .destructive) {
                Task { await appState.removeMembership(for: club) }
            }
            Button("Keep", role: .cancel) {}
        }
        .alert("Pinned Clubs Full", isPresented: $showPinCapAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You can pin up to 3 clubs. Unpin one to add this club.")
        }
        .onAppear {
            Self.logger.info("open_club_detail club_id=\(club.id.uuidString, privacy: .public) name=\(safeClubName, privacy: .public)")
            Task { await appState.refreshMemberships() }
            Task { await appState.refreshClubAdminRole(for: club) }
            Task { await appState.refreshGames(for: club) }
            Task { await appState.fetchReviews(for: club.id) }
            Task { await appState.refreshCreditBalance(for: club.id) }
            // If we already know the user is an admin (cached from a prior session), fetch requests now.
            if appState.isClubAdmin(for: club) {
                Task { await appState.refreshOwnerJoinRequests(for: club) }
            }
        }
        .onChange(of: appState.lastCancellationCredit) { _, result in
            // When a credit is issued for this club, refresh the balance immediately
            // so the banner updates without the user having to pull-to-refresh.
            guard result?.clubID == club.id else { return }
            Task { await appState.refreshCreditBalance(for: club.id) }
        }
        .onChange(of: isClubAdminUser) { _, newValue in
            // Fires when the admin role resolves asynchronously on first open.
            if newValue {
                Task { await appState.refreshOwnerJoinRequests(for: club) }
            }
        }
        .onReceive(minuteTick) { now = $0 }
        .onDisappear {
            Self.logger.info("close_club_detail club_id=\(club.id.uuidString, privacy: .public)")
        }
        .onChange(of: appState.clubs) { _, newClubs in
            if !newClubs.contains(where: { $0.id == club.id }) { dismiss() }
        }
        // Game push destinations are resolved centrally in MainTabView's
        // `.navigationDestination(for: AppRoute.self)`. Pushing here is done
        // via `appState.navigate(to: .game(...))`, never via a per-view
        // navigationDestination — that's how the Game ↔ Club ping-pong loop
        // used to form (each ClubDetailView added another destination handler
        // and each push grew the implicit stack).
        .navigationDestination(isPresented: $navigateToChat) {
            ClubNewsView(club: club, isClubModerator: appState.isClubAdmin(for: club))
                .environmentObject(appState)
                .navigationBarBackButtonHidden(true)
                .navigationTitle("Chat")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { navigateToChat = false } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Brand.ink)
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
        }
    }

    // MARK: - Hero

    private var clubHero: some View {
        ZStack(alignment: .bottomLeading) {
            // Background: banner image (when uploaded) or hue-derived dark gradient.
            heroBackground

            // Diagonal stripes — design's signature texture.
            heroStripes

            // Bottom-fade legibility scrim (over both image and gradient).
            LinearGradient(
                colors: [
                    Color.black.opacity(0.0),
                    Color.black.opacity(0.55),
                    Color.black.opacity(0.78)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(maxHeight: .infinity)

            // Top chrome — back button + settings menu.
            VStack {
                HStack {
                    glassNavButton(systemName: "chevron.left", action: { dismiss() })
                        .accessibilityLabel("Back")
                    Spacer()
                    settingsMenu
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                Spacer()
            }
            .padding(.top, safeAreaTopPad)

            // Owner / Admin chip — bottom-right.
            if let roleLabel = roleBadgeLabel {
                roleBadge(label: roleLabel)
                    .padding(.trailing, 16)
                    .padding(.bottom, 22)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            // Bottom block: name, descriptor, ★ rating · members.
            VStack(alignment: .leading, spacing: 8) {
                Text(safeClubName)
                    .font(.system(size: 32, weight: .heavy))
                    .kerning(-0.5)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 2)
                    .padding(.trailing, roleBadgeLabel != nil ? 80 : 0)

                if !heroDescriptor.isEmpty {
                    Text(heroDescriptor.uppercased())
                        .font(.system(size: 11.5, weight: .heavy))
                        .kerning(1.2)
                        .foregroundStyle(Color.white.opacity(0.72))
                        .lineLimit(1)
                }

                heroMetaRow
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 22)
        }
        .frame(height: Self.heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private var heroBackground: some View {
        if club.customBannerURL != nil {
            ClubHeroView(club: club)
                .overlay(Color.black.opacity(0.30))
        } else {
            // Hue-derived deep gradient (per-club deterministic).
            let h = clubHue / 360
            let a = Color(hue: h, saturation: 0.28, brightness: 0.28)
            let b = Color(hue: h, saturation: 0.30, brightness: 0.14)
            let c = Color(hue: h, saturation: 0.35, brightness: 0.08)
            ZStack {
                LinearGradient(
                    colors: [a, b, c],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                // Soft radial glow from top-right.
                RadialGradient(
                    colors: [
                        Color(hue: h, saturation: 0.55, brightness: 0.45).opacity(0.45),
                        .clear
                    ],
                    center: .init(x: 0.85, y: 0.05),
                    startRadius: 10,
                    endRadius: 280
                )
            }
        }
    }

    private var heroStripes: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let gap: CGFloat = 14
                ctx.translateBy(x: 0, y: 0)
                let count = Int((size.width + size.height) / gap) + 2
                for i in 0..<count {
                    let x = CGFloat(i) * gap - size.height
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    ctx.stroke(path, with: .color(Color.white.opacity(0.045)), lineWidth: 1)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .blendMode(.screen)
            .allowsHitTesting(false)
        }
    }

    private var heroMetaRow: some View {
        HStack(spacing: 8) {
            if let avg = avgRating {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: "F5B70A"))
                    Text(String(format: "%.1f", avg))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                    let count = appState.reviewsByClubID[club.id]?.count ?? 0
                    Text("(\(count))")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                Text("·")
                    .foregroundStyle(Color.white.opacity(0.4))
            }

            HStack(spacing: 5) {
                Text("\(club.memberCount)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Text(club.memberCount == 1 ? "member" : "members")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.78))
            }

            if appState.isClubPinned(club) {
                Text("·").foregroundStyle(Color.white.opacity(0.4))
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Pinned")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color.white.opacity(0.78))
            }
        }
    }

    private func glassNavButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.black.opacity(0.45), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func roleBadge(label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "crown.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Brand.sportPop)
            Text(label.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .kerning(0.4)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
    }

    private var roleBadgeLabel: String? {
        guard isClubAdminUser else { return nil }
        return appState.isClubOwner(for: club) ? "Owner" : "Admin"
    }

    private var safeAreaTopPad: CGFloat {
        // Bring the back/menu chrome below the status bar without using a
        // GeometryReader — the hero ignores safe area, so we offset manually.
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }
            .first ?? 44
    }

    // MARK: - Settings Menu

    @ViewBuilder
    private var settingsMenu: some View {
        let pinned = appState.isClubPinned(club)
        let state = appState.membershipState(for: club)

        Menu {
            if isClubAdminUser {
                Button {
                    isDashboardPresented = true
                } label: {
                    Label("Manage Club", systemImage: "square.grid.2x2")
                }
                Divider()
            }

            if let shareURL = clubShareURL {
                ShareLink(item: shareURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }

            Button {
                let success = appState.togglePinClub(club)
                if !success { showPinCapAlert = true }
            } label: {
                Label(pinned ? "Unpin from Home" : "Pin to Home",
                      systemImage: pinned ? "pin.slash" : "pin")
            }

            switch state {
            case .approved:
                Divider()
                Button(role: .destructive) {
                    showLeaveClubConfirm = true
                } label: {
                    Label("Leave Club", systemImage: "rectangle.portrait.and.arrow.right")
                }
            case .pending:
                Divider()
                Button(role: .destructive) {
                    showCancelRequestConfirm = true
                } label: {
                    Label("Cancel Request", systemImage: "xmark.circle")
                }
            default:
                EmptyView()
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.45), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
                if isClubAdminUser, pendingJoinRequestCount > 0 {
                    Circle()
                        .fill(Brand.errorRed)
                        .frame(width: 9, height: 9)
                        .padding(.top, 2)
                        .padding(.trailing, 2)
                }
            }
        }
        .accessibilityLabel("Club options")
    }

    private var clubShareURL: URL? {
        URL(string: "https://bookadink.com/club/\(club.id.uuidString.lowercased())")
    }

    // MARK: - Banners (membership feedback / credit)

    private func membershipBanner(msg: (text: String, isError: Bool)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: msg.isError ? "exclamationmark.circle" : "checkmark.circle.fill")
                .foregroundStyle(msg.isError ? Brand.errorRed : Brand.emeraldAction)
            Text(msg.isError ? AppCopy.friendlyError(msg.text) : msg.text)
                .font(.footnote.weight(msg.isError ? .regular : .semibold))
                .foregroundStyle(msg.isError ? Brand.errorRed : Brand.primaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(msg.isError ? Brand.errorRed.opacity(0.08) : Brand.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(msg.isError ? Brand.errorRed.opacity(0.22) : Brand.softOutline, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private func creditBanner(amountCents: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Brand.primaryText)
            HStack(spacing: 4) {
                Text(String(format: "$%.2f", Double(amountCents) / 100))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Brand.primaryText)
                Text("credit available")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Brand.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Brand.softOutline, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: - Section helpers

    private func sectionLabel(_ text: String, accent: Bool = false) -> some View {
        HStack(spacing: 7) {
            if accent {
                Circle()
                    .fill(Brand.sportPop)
                    .frame(width: 5, height: 5)
                    .shadow(color: Brand.sportPop.opacity(0.8), radius: 6)
            }
            Text(text.uppercased())
                .font(.system(size: 11.5, weight: .heavy))
                .kerning(1.4)
                .foregroundStyle(Brand.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Brand.softOutline, lineWidth: 1)
            )
            .padding(.horizontal, 16)
    }

    // MARK: - Upcoming Games

    private var upcomingGamesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Upcoming games", accent: true)
                .padding(.top, 22)

            if let error = appState.clubGamesError(for: club) {
                cardContainer {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(Brand.errorRed)
                        Text(AppCopy.friendlyError(error))
                            .font(.footnote)
                            .foregroundStyle(Brand.errorRed)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Button("Retry") {
                            Task { await appState.refreshGames(for: club) }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.errorRed)
                    }
                    .padding(14)
                }
            } else if filteredClubGames.isEmpty {
                if appState.isLoadingGames(for: club) {
                    cardContainer {
                        HStack {
                            ProgressView().tint(Brand.secondaryText)
                            Text("Loading games…")
                                .font(.subheadline)
                                .foregroundStyle(Brand.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(18)
                    }
                } else {
                    cardContainer {
                        Text("No upcoming games scheduled.")
                            .font(.subheadline)
                            .foregroundStyle(Brand.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(filteredClubGames) { game in
                            let venues = appState.clubVenuesByClubID[game.clubID] ?? []
                            let resolvedVenue = LocationService.resolvedVenue(for: game, venues: venues)
                            Button {
                                appState.navigate(to: .game(game.id))
                            } label: {
                                UpcomingGameCarouselCard(
                                    game: game,
                                    resolvedVenue: resolvedVenue,
                                    isBooked: appState.bookingState(for: game) == .confirmed,
                                    isScheduled: game.isScheduled
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 16)
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    // MARK: - About Card

    private var aboutCardSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("About")
                .padding(.top, 22)

            cardContainer {
                VStack(alignment: .leading, spacing: 8) {
                    if safeDescription.isEmpty {
                        Text("This club hasn't added a description yet.")
                            .font(.subheadline)
                            .foregroundStyle(Brand.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(safeDescription)
                            .font(.system(size: 14))
                            .foregroundStyle(Brand.ink.opacity(0.92))
                            .lineSpacing(2)
                            .lineLimit(aboutExpanded ? nil : 3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if safeDescription.count > 150 || aboutExpanded {
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) { aboutExpanded.toggle() }
                            } label: {
                                Text(aboutExpanded ? "Show less" : "Show more")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .underline(true, pattern: .solid)
                                    .foregroundStyle(Brand.secondaryText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }

    // MARK: - Reviews Card

    private var reviewsCardSection: some View {
        let reviews = sortedReviews
        let isLoading = appState.loadingReviewsClubIDs.contains(club.id)

        return Group {
            if isLoading && reviews.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    sectionLabel("Reviews").padding(.top, 22)
                    cardContainer {
                        HStack {
                            ProgressView().tint(Brand.secondaryText)
                            Text("Loading reviews…")
                                .font(.subheadline)
                                .foregroundStyle(Brand.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(18)
                    }
                }
            } else if reviews.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    sectionLabel("Reviews").padding(.top, 22)
                    cardContainer {
                        VStack(alignment: .leading, spacing: 0) {
                            // Header — average rating block.
                            HStack {
                                Text("Reviews")
                                    .font(.system(size: 11.5, weight: .heavy))
                                    .kerning(1.4)
                                    .foregroundStyle(Brand.tertiaryText)
                                Spacer()
                                if let avg = avgRating {
                                    HStack(spacing: 4) {
                                        starRow(value: avg, size: 12)
                                        Text(String(format: "%.1f", avg))
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(Brand.ink)
                                        Text("(\(reviews.count))")
                                            .font(.system(size: 12, weight: .regular))
                                            .foregroundStyle(Brand.tertiaryText)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 10)

                            ForEach(reviewsExpanded ? reviews : Array(reviews.prefix(1))) { review in
                                reviewRow(review)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 14)
                                if review.id != (reviewsExpanded ? reviews.last?.id : reviews.first?.id) {
                                    Divider().overlay(Brand.softOutline)
                                        .padding(.horizontal, 16)
                                        .padding(.bottom, 14)
                                }
                            }

                            if reviews.count > 1 {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) { reviewsExpanded.toggle() }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(reviewsExpanded ? "Show less" : "Show all \(reviews.count) reviews")
                                            .font(.system(size: 13.5, weight: .bold))
                                            .foregroundStyle(Brand.ink)
                                        Image(systemName: reviewsExpanded ? "chevron.up" : "chevron.right")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(Brand.ink)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        Rectangle()
                                            .fill(Brand.softOutline)
                                            .frame(height: 1),
                                        alignment: .top
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private func reviewRow(_ review: GameReview) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(AvatarGradients.resolveGradient(forKey: review.avatarColorKey))
                    .frame(width: 32, height: 32)
                Text(review.initials)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let name = review.reviewerName, !name.isEmpty {
                        Text(name)
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(Brand.ink)
                    }
                    Spacer(minLength: 0)
                    if let date = review.createdAt {
                        Text(relativeReviewDate(date))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Brand.tertiaryText)
                    }
                }
                HStack(spacing: 6) {
                    starRow(value: Double(review.rating), size: 11)
                    if let title = review.gameTitle, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Brand.tertiaryText)
                            .lineLimit(1)
                    }
                }
                if let comment = review.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Brand.ink.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func starRow(value: Double, size: CGFloat) -> some View {
        HStack(spacing: 1.5) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: starImageName(star: star, avg: value))
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(Color(hex: "F5B70A"))
            }
        }
    }

    private func starImageName(star: Int, avg: Double) -> String {
        if Double(star) <= avg { return "star.fill" }
        if Double(star) - avg < 1.0 { return "star.leadinghalf.filled" }
        return "star"
    }

    private func relativeReviewDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    // MARK: - Location Card (Venue + Contact + Map)

    private var locationCardSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Location").padding(.top, 22)

            // Resolve display fields. Hide rows whose data is missing.
            let venueName: String? = {
                if let v = primaryVenueForContact { return v.venueName }
                return club.venueName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }()
            let venueAddress: String? = {
                if let v = primaryVenueForContact, let a = LocationService.formattedAddress(for: v) { return a }
                let trimmed = club.formattedAddressFull.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }()

            cardContainer {
                VStack(alignment: .leading, spacing: 0) {
                    if let coord = clubMapCoordinate {
                        Button {
                            if let url = clubMapURL { openURL(url) }
                        } label: {
                            ZStack(alignment: .bottomTrailing) {
                                Map(position: .constant(MapCameraPosition.region(
                                    MKCoordinateRegion(center: coord, latitudinalMeters: 600, longitudinalMeters: 600)
                                ))) {
                                    Marker("", coordinate: coord)
                                }
                                .frame(height: 150)
                                .allowsHitTesting(false)

                                openInMapsChip
                                    .padding(10)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        if let name = venueName {
                            locationFieldHeader("Venue")
                            Text(name)
                                .font(.system(size: 15.5, weight: .bold))
                                .foregroundStyle(Brand.ink)
                                .lineLimit(2)
                        }

                        if let addr = venueAddress {
                            Text(addr)
                                .font(.system(size: 13))
                                .foregroundStyle(Brand.secondaryText)
                                .padding(.top, 3)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // Contact divider — only when we have any contact info to show.
                        let hasContact = (safeManagerName?.isEmpty == false)
                            || (safeContactPhone?.isEmpty == false)
                            || !safeContactEmail.isEmpty

                        if hasContact, venueName != nil || venueAddress != nil {
                            Divider().overlay(Brand.softOutline)
                                .padding(.vertical, 12)
                        }

                        if hasContact {
                            locationFieldHeader("Contact")
                        }

                        if let manager = safeManagerName, !manager.isEmpty {
                            Text(manager)
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(Brand.ink)
                                .padding(.top, 1)
                        }

                        if let phone = safeContactPhone, !phone.isEmpty {
                            contactRow(value: phone, action: {
                                let digits = phone.filter { $0.isNumber || $0 == "+" }
                                if let url = URL(string: "tel:\(digits)") { openURL(url) }
                            })
                            .padding(.top, 4)
                        }

                        if !safeContactEmail.isEmpty {
                            contactRow(value: safeContactEmail, action: {
                                if let url = URL(string: "mailto:\(safeContactEmail)") { openURL(url) }
                            })
                            .padding(.top, 1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
        }
        .task {
            // Load primary venue rows so the address/coordinates resolve.
            if appState.clubVenuesByClubID[club.id] == nil {
                await appState.refreshVenues(for: club)
            }
        }
    }

    private func locationFieldHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .heavy))
            .kerning(1.2)
            .foregroundStyle(Brand.tertiaryText)
            .padding(.bottom, 4)
    }

    private func contactRow(value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(Brand.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var openInMapsChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "map")
                .font(.system(size: 11, weight: .semibold))
            Text("Open in Maps")
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(Brand.ink)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.95), in: Capsule())
        .overlay(Capsule().stroke(Color.black.opacity(0.06), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
    }

    // MARK: - Floating CTA Bar

    private var floatingCTABar: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    Brand.appBackground.opacity(0),
                    Brand.appBackground.opacity(0.92),
                    Brand.appBackground
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 28)
            .allowsHitTesting(false)

            HStack(spacing: 10) {
                Button {
                    navigateToChat = true
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Brand.secondaryText)
                        .frame(width: 48, height: 48)
                        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Brand.softOutline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open club chat")

                primaryCTAButton
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
            .padding(.top, 6)
            .background(Brand.appBackground)
        }
    }

    @ViewBuilder
    private var primaryCTAButton: some View {
        let state = appState.membershipState(for: club)
        let isBusy = appState.isRequestingMembership(for: club) || appState.isRemovingMembership(for: club)

        if isMemberOrAdmin {
            Button {
                showBookGame = true
            } label: {
                ctaPill(label: "Book a game",
                        systemIcon: "bolt.fill",
                        background: Brand.sportPop,
                        foreground: Brand.ink,
                        iconTint: Brand.ink)
            }
            .buttonStyle(.plain)
            .modifier(ShakeEffect(animatableData: shakeBookGame ? 1 : 0))
        } else if case .pending = state {
            Button {
                showCancelRequestConfirm = true
            } label: {
                ctaPill(label: isBusy ? "Updating…" : "Request Pending",
                        systemIcon: "clock.fill",
                        background: Brand.secondarySurface,
                        foreground: Brand.secondaryText,
                        iconTint: Brand.secondaryText)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        } else {
            Button {
                let hasConduct = liveClub.codeOfConduct?.isEmpty == false
                let hasPolicy  = liveClub.cancellationPolicy?.isEmpty == false
                if hasConduct {
                    showConductSheet = true
                } else if hasPolicy {
                    showCancellationPolicySheet = true
                } else {
                    Task { await appState.requestMembership(for: club) }
                }
            } label: {
                ctaPill(label: isBusy ? "Joining…" : "Join Club",
                        systemIcon: "person.badge.plus",
                        background: Brand.primaryText,
                        foreground: .white,
                        iconTint: Brand.sportPop)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
    }

    private func ctaPill(label: String, systemIcon: String, background: Color, foreground: Color, iconTint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemIcon)
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(iconTint)
            Text(label)
                .font(.system(size: 16, weight: .heavy))
                .kerning(-0.1)
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: background.opacity(0.45), radius: 10, x: 0, y: 6)
    }

    // MARK: - Membership Feedback

    private var membershipFeedbackMessage: (text: String, isError: Bool)? {
        if let error = appState.membershipErrorMessage, !error.isEmpty {
            return (error, true)
        }
        if let info = appState.membershipInfoMessage, !info.isEmpty {
            return (info, false)
        }
        return nil
    }

    // MARK: - Game Helpers

    private func nextWeekDraft(from game: Game) -> ClubOwnerGameDraft {
        var draft = ClubOwnerGameDraft(game: game)
        draft.startDate = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: game.dateTime) ?? game.dateTime
        draft.repeatWeekly = false
        draft.repeatCount = 1
        return draft
    }

    private func goesLiveCountdown(_ publishAt: Date) -> String {
        let diff = max(publishAt.timeIntervalSince(now), 0)
        let totalMinutes = Int(diff / 60)
        let days  = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let mins  = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    // MARK: - Text Helpers

    private func cappedDisplayText(_ raw: String, maxLength: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)) + "..."
    }

    private func trimmedOptional(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Optional helpers

private extension String {
    var nilIfEmpty: String? { self.isEmpty ? nil : self }
}

// MARK: - Upcoming Game Carousel Card
//
// Compact 212pt-wide card for the horizontal Upcoming Games carousel on the
// club detail screen. Distinct from `UnifiedGameCard` (which is the full-width
// row used in Bookings / Game Detail / Home). This card is screen-specific
// and intentionally narrower so multiple games show at once with snap-paging.

private struct UpcomingGameCarouselCard: View {
    let game: Game
    let resolvedVenue: ClubVenue?
    let isBooked: Bool
    let isScheduled: Bool

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private var hue: Double {
        let bytes = withUnsafeBytes(of: game.id.uuid) { Array($0) }
        let seed = bytes.reduce(0) { Int($0) &+ Int($1) }
        return Double(seed % 360)
    }
    private var dateLabel: String { Self.dateFormatter.string(from: game.dateTime).uppercased() }
    private var timeLabel: String { Self.timeFormatter.string(from: game.dateTime).uppercased() }
    private var confirmed: Int { game.confirmedCount ?? 0 }
    private var pct: Double {
        guard game.maxSpots > 0 else { return 0 }
        return min(1, Double(confirmed) / Double(game.maxSpots))
    }
    private var isFull: Bool { confirmed >= game.maxSpots && game.maxSpots > 0 }
    private var venueLabel: String? {
        if let v = resolvedVenue { return v.venueName }
        let trimmed = game.venueName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return nil
    }
    private var costLabel: String {
        guard let fee = game.feeAmount, fee > 0 else { return "Free" }
        if fee.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "$%.0f", fee)
        }
        return String(format: "$%.2f", fee)
    }
    private var capacityColor: Color {
        if isFull { return Color(hex: "FF6B6B") }
        if pct >= 0.75 { return Color(hex: "FFC23A") }
        return Brand.sportPop
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroBlock
            bodyBlock
        }
        .frame(width: 212)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Brand.softOutline, lineWidth: 1)
        )
        .opacity(isScheduled ? 0.55 : 1)
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    private var heroBlock: some View {
        let h = hue / 360
        let topColor = Color(hue: h, saturation: 0.32, brightness: 0.24)
        let botColor = Color(hue: h, saturation: 0.38, brightness: 0.10)

        return ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [topColor, botColor],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            stripesOverlay

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(dateLabel)
                        .font(.system(size: 10.5, weight: .heavy))
                        .kerning(1)
                    Text("·")
                        .font(.system(size: 10.5, weight: .heavy))
                        .opacity(0.4)
                    Text(timeLabel)
                        .font(.system(size: 10.5, weight: .heavy))
                        .kerning(1)
                }
                .foregroundStyle(Color.white.opacity(0.85))

                Spacer(minLength: 0)

                Text(game.title)
                    .font(.system(size: 16, weight: .heavy))
                    .kerning(-0.3)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.2), radius: 1.5, x: 0, y: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if isBooked {
                ZStack {
                    Circle()
                        .fill(Brand.sportPop)
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Brand.ink)
                }
                .padding(8)
                .accessibilityLabel("You're in")
            }
        }
        .frame(height: 96)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var bodyBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let venue = venueLabel {
                HStack(spacing: 5) {
                    Image(systemName: "map")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.tertiaryText)
                    Text(venue)
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(1)
                }
            }

            // Capacity bar — single GeometryReader sized track + fill.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 99, style: .continuous)
                        .fill(Brand.softOutline)
                    RoundedRectangle(cornerRadius: 99, style: .continuous)
                        .fill(capacityColor)
                        .frame(width: max(0, geo.size.width * pct))
                }
            }
            .frame(height: 4)

            HStack {
                Text(isFull ? "Full" : "\(confirmed)/\(game.maxSpots) players")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isFull ? Color(hex: "E04848") : Brand.secondaryText)
                Spacer(minLength: 0)
                Text(costLabel)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Brand.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var stripesOverlay: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 12
            let count = Int((size.width + size.height) / gap) + 2
            for i in 0..<count {
                let x = CGFloat(i) * gap - size.height
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                ctx.stroke(path, with: .color(Color.white.opacity(0.05)), lineWidth: 1)
            }
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
    }
}

// MARK: - Share Sheet

/// Wraps UIActivityViewController so sheets present correctly on iPad
/// (avoids the detached floating popover that ShareLink renders on iPad).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}

// MARK: - Shake Effect

struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        let angle = sin(animatableData * .pi * 4) * 8
        return ProjectionTransform(CGAffineTransform(translationX: angle, y: 0))
    }
}


#Preview {
    NavigationStack {
        ClubDetailView(club: MockData.clubs[0])
            .environmentObject({
                let state = AppState()
                state.signInPreview()
                let previewID = state.authUserID ?? UUID()
                state.profile = UserProfile(
                    id: previewID,
                    fullName: "Brayden Kelly",
                    email: "preview@bookadink.app",
                    favoriteClubName: nil,
                    skillLevel: .intermediate
                )
                return state
            }())
    }
}
