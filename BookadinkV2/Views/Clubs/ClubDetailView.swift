import CoreLocation
import SwiftUI
import UIKit
import os

// MARK: - Content Tab Kind

enum ContentTabKind: String, CaseIterable { case games = "Games", chat = "Chat" }

// MARK: - Club Hero View

struct ClubHeroView: View {
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
        let heroHeight: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 320 : 280
        let imageName = Self.heroImageName(for: club.heroImageKey)

        GeometryReader { geo in
            Image(imageName)
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: heroHeight)
                .clipped()
        }
        .frame(height: heroHeight)
            // Fades hero bottom into the page background. Paired with .padding(.bottom, -65)
            // at the call site so content starts at the original position and total
            // page length is unchanged.
            .overlay(
                LinearGradient(
                    colors: [.clear, Color(.systemBackground).opacity(0.5)],
                    startPoint: UnitPoint(x: 0.5, y: 0.75),
                    endPoint: .bottom
                )
            )
            .ignoresSafeArea(edges: .top)
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

    @EnvironmentObject private var appState: AppState
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let club: Club

    @State private var selectedTab: ClubDetailTab = .games
    @State private var searchText = ""

    @State private var isShowingInviteSheet = false
    @State private var ownerToolSheet: OwnerToolSheet?
    @State private var editingOwnerGame: Game?
    @State private var ownerDeleteGameCandidate: Game?
    @State private var duplicatingGame: Game?
    @State private var membersSortByDUPRDescending = false

    @State private var aboutExpanded = false
    @State private var membersPreviewExpanded = false
    @State private var membersPreviewLoaded = false
    @State private var showBookGame = false
    @State private var reviewsExpanded = false
    @State private var shakeBookGame = false
    @State private var navigateToChat = false
    @State private var showLeaveClubConfirm = false
    @State private var showConductSheet = false
    @State private var now = Date()
    private let minuteTick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// Always reads the latest in-memory version of this club so fields like
    /// codeOfConduct reflect the most recent fetch, not the navigation-time snapshot.
    private var liveClub: Club {
        appState.clubs.first(where: { $0.id == club.id }) ?? club
    }

    private var displayedMembers: [ClubMember] {
        guard !searchText.isEmpty else { return club.topMembers }
        return club.topMembers.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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

    private var safeDescription: String {
        cappedDisplayText(club.description, maxLength: Self.maxDescriptionLength)
    }

    private var safeContactEmail: String {
        cappedDisplayText(club.contactEmail, maxLength: Self.maxContactLength)
    }

    private var safeWebsite: String? {
        trimmedOptional(cappedDisplayText(club.website ?? "", maxLength: Self.maxWebsiteLength))
    }

    private var safeManagerName: String? {
        trimmedOptional(cappedDisplayText(club.managerName ?? "", maxLength: Self.maxManagerLength))
    }

    private var safeLocationDisplay: String {
        cappedDisplayText(club.locationDisplay, maxLength: Self.maxAddressLength)
    }

    private var filteredClubGames: [Game] {
        allClubGames
            .filter { $0.dateTime >= now }
            .filter { isClubAdminUser || ($0.publishAt == nil || $0.publishAt! <= now) }
            .sorted { $0.dateTime < $1.dateTime }
    }

    private var isClubAdminUser: Bool {
        appState.isClubAdmin(for: club)
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 0) {
                    ClubHeroView(club: club)
                        .environmentObject(appState)
                        .padding(.bottom, -15)

                    // Membership feedback banner
                    if let msg = membershipFeedbackMessage {
                        HStack(spacing: 10) {
                            Image(systemName: msg.isError ? "exclamationmark.circle" : "checkmark.circle.fill")
                                .foregroundStyle(msg.isError ? Brand.errorRed : Brand.emeraldAction)
                            Text(msg.isError ? AppCopy.friendlyError(msg.text) : msg.text)
                                .font(.footnote.weight(msg.isError ? .regular : .semibold))
                                .foregroundStyle(msg.isError ? Brand.errorRed : Brand.primaryText)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(msg.isError ? Brand.errorRed.opacity(0.08) : Brand.secondarySurface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(msg.isError ? Brand.errorRed.opacity(0.22) : Brand.softOutline, lineWidth: 1)
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .background(Color(.systemBackground))
                    }

                    clubInfoSection
                    let reviewsData = appState.reviewsByClubID[club.id] ?? []
                    let reviewsLoading = appState.loadingReviewsClubIDs.contains(club.id)
                    if !reviewsData.isEmpty || reviewsLoading {
                        Divider().padding(.horizontal, 20).background(Color(.systemBackground))
                        reviewsSection
                    }
                    Divider().padding(.horizontal, 20).background(Color(.systemBackground))
                    aboutSection
                    Divider().padding(.horizontal, 20).background(Color(.systemBackground))
                    contactSection
                    Divider().padding(.horizontal, 20).background(Color(.systemBackground))
                    membersPreviewSection

                    Divider().background(Color(.systemBackground))
                    contentTabsSection
                }
                .padding(.bottom, 100)
            }
            .refreshable {
                await appState.refreshMemberships()
                await appState.refreshClubAdminRole(for: club)
                await appState.refreshGames(for: club)
                await appState.refreshClubs()
                await appState.fetchReviews(for: club.id)
            }
            .ignoresSafeArea(edges: .top)
            .background(Color(.systemBackground))

            floatingCTABar
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .navigationTitle("")
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if isClubAdminUser {
                ToolbarItem(placement: .topBarTrailing) {
                    let pendingCount = appState.ownerJoinRequests(for: club).count
                    Menu {
                        Button { ownerToolSheet = .manageGames } label: {
                            Label("View/Edit Games", systemImage: "calendar.badge.clock")
                        }
                        Button { ownerToolSheet = .createGame } label: {
                            Label("Create Game", systemImage: "calendar.badge.plus")
                        }
                        Divider()
                        Button { ownerToolSheet = .editClub } label: {
                            Label("Club Settings", systemImage: "slider.horizontal.3")
                        }
                        Divider()
                        Button { ownerToolSheet = .joinRequests } label: {
                            Label(
                                pendingCount > 0 ? "Join Requests (\(pendingCount))" : "Join Requests",
                                systemImage: "person.badge.plus"
                            )
                        }
                        Button { ownerToolSheet = .members } label: {
                            Label("Manage Members", systemImage: "person.2")
                        }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Brand.ink)
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Capsule())
                            if pendingCount > 0 {
                                Circle()
                                    .fill(Brand.errorRed)
                                    .frame(width: 9, height: 9)
                                    .padding(.top, 3)
                                    .padding(.trailing, 3)
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $ownerToolSheet) { sheet in
            switch sheet {
            case .manageGames:  OwnerManageGamesView(club: club).environmentObject(appState)
            case .joinRequests: OwnerJoinRequestsSheet(club: club).environmentObject(appState)
            case .createGame:   OwnerCreateGameSheet(club: club).environmentObject(appState)
            case .editClub:     OwnerEditClubSheet(club: club).environmentObject(appState)
            case .members:      OwnerMembersSheet(club: club).environmentObject(appState)
            }
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
        .onAppear {
            Self.logger.info("open_club_detail club_id=\(club.id.uuidString, privacy: .public) name=\(safeClubName, privacy: .public)")
            Task { await appState.refreshMemberships() }
            Task { await appState.refreshClubAdminRole(for: club) }
            Task { await appState.refreshGames(for: club) }
            Task { await appState.fetchReviews(for: club.id) }
            // If we already know the user is an admin (cached from a prior session), fetch requests now.
            if appState.isClubAdmin(for: club) {
                Task { await appState.refreshOwnerJoinRequests(for: club) }
            }
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
        .navigationDestination(for: Game.self) { game in
            GameDetailView(game: game)
        }
        .navigationDestination(isPresented: $navigateToChat) {
            ClubNewsView(club: club, isClubModerator: appState.isClubAdmin(for: club))
                .environmentObject(appState)
                .navigationBarBackButtonHidden(true)
                .navigationTitle("Member Chat")
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

    // MARK: - Club Info Section

    private var clubInfoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text(safeClubName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Brand.ink)
                Spacer()
                heroButtonRow
            }
            .padding(.top, 20)
            .padding(.horizontal, 20)

            if !club.addressLine1.isEmpty {
                Button {
                    if let url = MapNavigationURL.directions(to: safeAddress) {
                        openURL(url)
                    }
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "mappin")
                            .font(.subheadline)
                            .foregroundStyle(Brand.mutedText)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(club.addressLine1)
                                .font(.subheadline)
                                .foregroundStyle(Brand.mutedText)
                            if let line2 = club.addressLine2 {
                                Text(line2)
                                    .font(.subheadline)
                                    .foregroundStyle(Brand.mutedText)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
                .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
    }

    // MARK: - Reviews Section

    private var reviewsSection: some View {
        let reviews = appState.reviewsByClubID[club.id] ?? []
        let isLoading = appState.loadingReviewsClubIDs.contains(club.id)

        // Compute average rating
        let avgRating: Double? = reviews.isEmpty ? nil : Double(reviews.reduce(0) { $0 + $1.rating }) / Double(reviews.count)
        let displayed = reviewsExpanded ? reviews : Array(reviews.prefix(2))

        return Group {
            if isLoading && reviews.isEmpty {
                HStack {
                    ProgressView()
                        .tint(Brand.secondaryText)
                    Text("Loading reviews…")
                        .font(.subheadline)
                        .foregroundStyle(Brand.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                .background(Color(.systemBackground))
            } else if reviews.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Reviews")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Brand.ink)
                        Spacer()
                        if let avg = avgRating {
                            HStack(spacing: 4) {
                                HStack(spacing: 2) {
                                    ForEach(1...5, id: \.self) { star in
                                        Image(systemName: starImageName(star: star, avg: avg))
                                            .font(.caption2)
                                            .foregroundStyle(Color(hex: "FFB800"))
                                    }
                                }
                                Text(String(format: "%.1f", avg))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Brand.mutedText)
                                Text("(\(reviews.count))")
                                    .font(.caption)
                                    .foregroundStyle(Brand.mutedText.opacity(0.7))
                            }
                        }
                    }

                    ForEach(displayed) { review in
                        HStack(alignment: .top, spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Brand.secondarySurface)
                                    .frame(width: 42, height: 42)
                                Text(review.initials)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Brand.secondaryText)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 2) {
                                    ForEach(1...5, id: \.self) { star in
                                        Image(systemName: star <= review.rating ? "star.fill" : "star")
                                            .font(.caption)
                                            .foregroundStyle(star <= review.rating ? Color(hex: "FFB800") : Brand.softOutline)
                                    }
                                }
                                if let gameTitle = review.gameTitle {
                                    Text(gameTitle)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Brand.mutedText)
                                }
                                if let comment = review.comment, !comment.isEmpty {
                                    Text(comment)
                                        .font(.subheadline)
                                        .foregroundStyle(Brand.ink.opacity(0.85))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    if reviews.count > 2 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { reviewsExpanded.toggle() }
                        } label: {
                            Text(reviewsExpanded ? "Show less" : "Show \(reviews.count - 2) more review\(reviews.count - 2 == 1 ? "" : "s")")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Brand.primaryText)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(20)
                .background(Color(.systemBackground))
            }
        }
    }

    private func starImageName(star: Int, avg: Double) -> String {
        if Double(star) <= avg { return "star.fill" }
        if Double(star) - avg < 1.0 { return "star.leadinghalf.filled" }
        return "star"
    }

    // MARK: - About Section

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About the Club")
                .font(.title3.weight(.bold))
                .foregroundStyle(Brand.ink)

            ZStack(alignment: .bottomTrailing) {
                Text(safeDescription)
                    .font(.subheadline)
                    .foregroundStyle(Brand.ink.opacity(0.8))
                    .lineLimit(aboutExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if safeDescription.count > 150 && !aboutExpanded {
                    LinearGradient(
                        colors: [.clear, Color(.systemBackground)],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 120, height: 20)
                    .offset(y: -2)
                }
            }

            if safeDescription.count > 150 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { aboutExpanded.toggle() }
                } label: {
                    Text(aboutExpanded ? "Show less" : "Read more")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.primaryText)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(20)
        .background(Color(.systemBackground))
    }

    // MARK: - Contact Section

    private var contactSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Contact Information")
                .font(.title3.weight(.bold))
                .foregroundStyle(Brand.ink)

            // Manager
            if let manager = safeManagerName, !manager.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Club Manager")
                        .font(.caption)
                        .foregroundStyle(Brand.mutedText)
                    Text(manager)
                        .font(.subheadline)
                        .foregroundStyle(Brand.ink)
                }
            }

            // Phone — label + circular call button on trailing
            if !safeContactEmail.isEmpty && safeContactEmail != "No contact email listed" {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Email")
                            .font(.caption)
                            .foregroundStyle(Brand.mutedText)
                        Text(safeContactEmail)
                            .font(.subheadline)
                            .foregroundStyle(Brand.ink)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        if let url = URL(string: "mailto:\(safeContactEmail)") {
                            openURL(url)
                        }
                    } label: {
                        Image(systemName: "envelope")
                            .font(.system(size: 17))
                            .foregroundStyle(Brand.primaryText)
                            .frame(width: 40, height: 40)
                            .background(Brand.primaryText.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Website
            if let website = safeWebsite, !website.isEmpty {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Website")
                            .font(.caption)
                            .foregroundStyle(Brand.mutedText)
                        Text(website)
                            .font(.subheadline)
                            .foregroundStyle(Brand.ink)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        if let url = URL(string: website) { openURL(url) }
                    } label: {
                        Image(systemName: "globe")
                            .font(.system(size: 17))
                            .foregroundStyle(Brand.primaryText)
                            .frame(width: 40, height: 40)
                            .background(Brand.primaryText.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Venue — primary ClubVenue name and address
            if let venue = primaryVenueForContact {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Venue")
                        .font(.caption)
                        .foregroundStyle(Brand.mutedText)
                    Text(venue.venueName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Brand.ink)
                }

                if let address = LocationService.formattedAddress(for: venue) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Address")
                            .font(.caption)
                            .foregroundStyle(Brand.mutedText)
                        Text(address)
                            .font(.subheadline)
                            .foregroundStyle(Brand.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(20)
        .background(Color(.systemBackground))
        .task {
            // Ensure venue data is loaded for the primary venue display.
            // Skipped if already cached in clubVenuesByClubID.
            if appState.clubVenuesByClubID[club.id] == nil {
                await appState.refreshVenues(for: club)
            }
        }
    }

    // MARK: - Members Preview Section

    private var membersPreviewSection: some View {
        guard isMemberOrAdmin else {
            return AnyView(
                VStack(alignment: .leading, spacing: 10) {
                    Text("Members")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Brand.ink)
                    HStack(spacing: 10) {
                        Image(systemName: "lock.fill")
                            .font(.subheadline)
                            .foregroundStyle(Brand.secondaryText)
                        Text("Join the club to see the member list.")
                            .font(.subheadline)
                            .foregroundStyle(Brand.secondaryText)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(20)
                .background(Color(.systemBackground))
            )
        }
        let allMembers = appState.clubDirectoryMembers(for: club)
        let previewCount = 4
        let displayed = membersPreviewExpanded ? allMembers : Array(allMembers.prefix(previewCount))

        return AnyView(VStack(alignment: .leading, spacing: 14) {
            Text("Members")
                .font(.title3.weight(.bold))
                .foregroundStyle(Brand.ink)

            if appState.isLoadingClubDirectory(for: club) && allMembers.isEmpty {
                ProgressView()
                    .tint(Brand.primaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else if allMembers.isEmpty {
                Text("No members loaded yet.")
                    .font(.subheadline)
                    .foregroundStyle(Brand.mutedText)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(displayed) { member in
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Brand.secondarySurface)
                                    .frame(width: 34, height: 34)
                                Text(memberInitials(member.name))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Brand.secondaryText)
                            }
                            Text(member.name)
                                .font(.subheadline)
                                .foregroundStyle(Brand.ink)
                                .lineLimit(1)
                            Spacer()
                            if let dupr = member.duprRating {
                                Text(String(format: "%.3f", dupr))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Brand.pineTeal)
                            }
                        }
                        .padding(.vertical, 9)
                        if member.id != displayed.last?.id {
                            Divider()
                        }
                    }
                }
            }

            if allMembers.count > previewCount {
                Button {
                    if !membersPreviewLoaded {
                        membersPreviewLoaded = true
                        Task { await appState.refreshClubDirectoryMembers(for: club) }
                    }
                    withAnimation(.easeInOut(duration: 0.2)) { membersPreviewExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(membersPreviewExpanded ? "Show less" : "View all members")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.primaryText)
                        Image(systemName: membersPreviewExpanded ? "chevron.up" : "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Brand.primaryText)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
            } else if allMembers.isEmpty {
                Button {
                    Task { await appState.refreshClubDirectoryMembers(for: club) }
                } label: {
                    Text("Load members")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.primaryText)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(20)
        .background(Color(.systemBackground))
        .onAppear {
            if appState.clubDirectoryMembers(for: club).isEmpty && !appState.isLoadingClubDirectory(for: club) {
                Task { await appState.refreshClubDirectoryMembers(for: club) }
            }
        })
    }

    private func memberInitials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap(\.first).map(String.init).joined()
    }

    // MARK: - Content Tabs Section (Games only — Chat moved to push nav)

    private var contentTabsSection: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                gamesContent.padding(16)
            }
            .background(Color(.systemBackground))
        }
        .onAppear {
            if appState.games(for: club).isEmpty {
                Task { await appState.refreshGames(for: club) }
            }
        }
    }

    // MARK: - Floating CTA Bar

    private var floatingCTABar: some View {
        HStack(spacing: 12) {
            Button {
                navigateToChat = true
            } label: {
                Text("Member Chat")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Brand.primaryText, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button {
                showBookGame = true
            } label: {
                Text("Book Game")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        isMemberOrAdmin ? Brand.primaryText : Brand.softOutline,
                        in: Capsule()
                    )
                    .foregroundStyle(.white)
                    .modifier(ShakeEffect(animatableData: shakeBookGame ? 1 : 0))
            }
            .buttonStyle(.plain)
            .disabled(!isMemberOrAdmin)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .background(
            LinearGradient(
                colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 80)
            .allowsHitTesting(false),
            alignment: .top
        )
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

    // MARK: - Hero Button Row

    private var isMemberOrAdmin: Bool {
        if isClubAdminUser { return true }
        switch appState.membershipState(for: club) {
        case .approved, .unknown: return true
        default: return false
        }
    }

    @ViewBuilder
    private var heroButtonRow: some View {
        let state = appState.membershipState(for: club)
        let isBusy = appState.isRequestingMembership(for: club) || appState.isRemovingMembership(for: club)

        HStack(spacing: 8) {
            if isClubAdminUser {
                // Show "Owner" or "Admin" depending on role
                let isOwner = appState.isClubOwner(for: club)
                statusCapsule(icon: isOwner ? "crown.fill" : "shield.checkered",
                              label: isOwner ? "Owner" : "Admin")
            } else if case .pending = state {
                // Pending — tap to cancel request
                Button {
                    showLeaveClubConfirm = true
                } label: {
                    statusCapsule(icon: "clock", label: "Pending")
                }
                .buttonStyle(.plain)
                .confirmationDialog("Cancel membership request?", isPresented: $showLeaveClubConfirm, titleVisibility: .visible) {
                    Button("Cancel Request", role: .destructive) {
                        Task { await appState.removeMembership(for: club) }
                    }
                    Button("Keep", role: .cancel) {}
                }
            } else if case .approved = state {
                // Member — tap to leave
                Button {
                    showLeaveClubConfirm = true
                } label: {
                    statusCapsule(icon: isBusy ? nil : "checkmark.circle.fill",
                                  label: isBusy ? "Updating..." : "Member",
                                  isBusy: isBusy)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .confirmationDialog("Leave club?", isPresented: $showLeaveClubConfirm, titleVisibility: .visible) {
                    Button("Leave Club", role: .destructive) {
                        Task { await appState.removeMembership(for: club) }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            } else if case .unknown = state {
                // Club owner edge case — treat as member
                statusCapsule(icon: "checkmark.circle.fill", label: "Member")
            } else {
                // Not a member — tap to join (may show conduct sheet first)
                Button {
                    if liveClub.codeOfConduct?.isEmpty == false {
                        showConductSheet = true
                    } else {
                        Task { await appState.requestMembership(for: club) }
                    }
                } label: {
                    statusCapsule(icon: isBusy ? nil : "person.badge.plus",
                                  label: isBusy ? "Joining..." : "Join Club",
                                  isBusy: isBusy)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .sheet(isPresented: $showConductSheet) {
                    ConductAcceptanceSheet(club: liveClub) {
                        Task { await appState.requestMembership(for: club, conductAcceptedAt: Date()) }
                    }
                    .environmentObject(appState)
                }
            }

            heroInviteButton
        }
    }

    private func statusCapsule(icon: String?, label: String, isBusy: Bool = false) -> some View {
        HStack(spacing: 6) {
            if isBusy {
                ProgressView().tint(.white).controlSize(.small)
            } else if let icon {
                Image(systemName: icon)
            }
            Text(label).fontWeight(.bold)
        }
        .font(.subheadline)
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(Brand.primaryText, in: Capsule())
        .fixedSize()
    }

    private var heroInviteButton: some View {
        Group {
            if let shareURL = URL(string: "https://bookadink.com/club/\(club.id.uuidString.lowercased())") {
                ShareLink(item: shareURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18))
                        .foregroundStyle(Brand.primaryText)
                        .frame(width: 40, height: 40)
                        .background(Brand.secondarySurface, in: Circle())
                        .overlay(Circle().stroke(Brand.softOutline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share club")
            }
        }
    }

    private func statusTitle(for state: ClubMembershipState, isBusy: Bool) -> String {
        if isBusy {
            if appState.isRequestingMembership(for: club) { return "Updating..." }
            if appState.isRemovingMembership(for: club) { return "Updating..." }
        }
        switch state {
        case .approved: return "Member"
        case .pending: return "Pending"
        case .none: return "Join to Book"
        case .rejected: return "Join to Book"
        case .unknown: return "Member"
        }
    }

    // MARK: - Members Content (full directory)

    private var membersContent: some View {
        let loadedMembers = appState.clubDirectoryMembers(for: club)
        let members = membersSortByDUPRDescending
            ? loadedMembers.sorted { lhs, rhs in
                let l = lhs.duprRating ?? -1
                let r = rhs.duprRating ?? -1
                if l == r {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return l > r
            }
            : loadedMembers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Members")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Brand.ink)
                    Spacer()
                    membersSortToggle
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Members")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Brand.ink)
                    membersSortToggle
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = appState.clubDirectoryError(for: club), !error.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(AppCopy.friendlyError(error))
                }
                .font(.footnote)
                .foregroundStyle(Brand.errorRed)
                .appErrorCardStyle(cornerRadius: 12)
            }

            if appState.isLoadingClubDirectory(for: club), members.isEmpty {
                ProgressView("Loading members...")
                    .tint(Brand.pineTeal)
            } else if members.isEmpty {
                Text("No approved members yet.")
                    .font(.subheadline)
                    .foregroundStyle(Brand.mutedText)
            } else {
                ForEach(members) { member in
                    HStack(spacing: 12) {
                        Text(member.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.ink)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        Text(member.duprRating.map { String(format: "%.3f", $0) } ?? "No DUPR")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(member.duprRating == nil ? Brand.mutedText : Brand.pineTeal)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    // MARK: - Games Content

    private var gamesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Upcoming Games")
                .font(.title3.weight(.bold))
                .foregroundStyle(Brand.ink)

            if let error = appState.clubGamesError(for: club) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(AppCopy.friendlyError(error))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Retry") {
                        Task { await appState.refreshGames(for: club) }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.errorRed)
                }
                .appErrorCardStyle(cornerRadius: 12)
            }

            if filteredClubGames.isEmpty, !appState.isLoadingGames(for: club) {
                Text("No upcoming games scheduled.")
                    .foregroundStyle(Brand.mutedText)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(filteredClubGames) { game in
                        let venues        = appState.clubVenuesByClubID[game.clubID] ?? []
                        let resolvedVenue = LocationService.resolvedVenue(for: game, venues: venues)
                        VStack(alignment: .leading, spacing: 0) {
                            NavigationLink {
                                GameDetailView(game: game)
                            } label: {
                                UnifiedGameCard(
                                    game: game,
                                    clubName: club.name,
                                    isBooked: appState.bookingState(for: game) == .confirmed,
                                    isWaitlisted: {
                                        if case .waitlisted = appState.bookingState(for: game) { return true }
                                        return false
                                    }(),
                                    resolvedVenue: resolvedVenue
                                )
                            }
                            .buttonStyle(.plain)
                            .opacity(game.isScheduled ? 0.55 : 1)

                            if isClubAdminUser, let pa = game.publishAt, pa > now {
                                scheduledGameBanner(publishAt: pa)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Scheduled Game Banner (admin only)

    private func scheduledGameBanner(publishAt: Date) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash")
                .font(.caption2.weight(.semibold))
            Text("Not visible to the public")
                .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
            Text("Goes live in \(goesLiveCountdown(publishAt))")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .padding(.top, 4)
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

    // MARK: - Ranking Content

    private var rankingContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Doubles Ranking")
                .font(.title3.weight(.bold))
                .foregroundStyle(Brand.ink)

            searchBar

            ForEach(displayedMembers) { member in
                HStack(spacing: 12) {
                    Text("\(member.rank)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Brand.spicyOrange)
                        .frame(width: 28)

                    Circle()
                        .fill(Brand.dividerColor)
                        .overlay(
                            Text(initials(member.name))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Brand.primaryText)
                        )
                        .frame(width: 34, height: 34)

                    Text(member.name)
                        .font(.headline)
                        .foregroundStyle(Brand.ink)

                    Spacer(minLength: 8)

                    reliabilityRing(member.reliability)

                    Text(String(format: "%.3f", member.rating))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Brand.pineTeal)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Brand.rosyTaupe.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Members Sort Toggle

    private var membersSortToggle: some View {
        Button {
            membersSortByDUPRDescending.toggle()
        } label: {
            Text(membersSortByDUPRDescending ? "A-Z" : "Highest DUPR")
                .font(.caption.weight(.semibold))
                .foregroundStyle(membersSortByDUPRDescending ? .white : Brand.pineTeal)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    (membersSortByDUPRDescending ? Brand.slateBlue : Brand.secondarySurface),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .actionBorder(
            cornerRadius: 12,
            color: Brand.softOutline
        )
    }

    // MARK: - Games Refresh Control

    private var gamesRefreshControl: some View {
        Group {
            if appState.isLoadingGames(for: club) {
                ProgressView()
            } else {
                Button {
                    Task { await appState.refreshGames(for: club) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(Brand.primaryText)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Brand.cardBackground)
                    )
                }
                .buttonStyle(.plain)
                .actionBorder(cornerRadius: 12, color: Brand.softOutline)
            }
        }
    }

    // MARK: - Admin Owner Panel

    private var ownerToolsPanel: some View {
        let pendingCount = appState.ownerJoinRequests(for: club).count

        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    adminToolsHeaderLabel
                    Spacer(minLength: 8)
                    adminToolsRolePill
                }

                VStack(alignment: .leading, spacing: 8) {
                    adminToolsHeaderLabel
                    adminToolsRolePill
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Manage your club with quick tools for admins and owners.")
                .font(.footnote)
                .foregroundStyle(Brand.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            ownerOnboardingChecklist

            if let info = appState.ownerToolsInfoMessage, !info.isEmpty {
                Text(verbatim: softWrappedDisplayText(info))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = appState.ownerToolsErrorMessage, !error.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                        Text(verbatim: softWrappedDisplayText(AppCopy.friendlyError(error)))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .font(.footnote)
                    .foregroundStyle(Brand.errorRed)
                    .appErrorCardStyle(cornerRadius: 12)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle")
                            Text(verbatim: softWrappedDisplayText(AppCopy.friendlyError(error)))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(Brand.errorRed)
                    .appErrorCardStyle(cornerRadius: 12)
                }
            }

            VStack(spacing: 6) {
                Button {
                    ownerToolSheet = .manageGames
                } label: {
                    ownerToolRow(
                        title: "View/Edit Games",
                        subtitle: "View, edit, duplicate, or delete upcoming and past games.",
                        icon: "calendar.badge.clock"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    ownerToolSheet = .createGame
                } label: {
                    ownerToolRow(
                        title: "Create Game",
                        subtitle: "Publish a new session with time, capacity, fee, and notes.",
                        icon: "calendar.badge.plus"
                    )
                }
                .buttonStyle(.plain)

                Divider()
                    .padding(.vertical, 2)

                Button {
                    ownerToolSheet = .editClub
                } label: {
                    ownerToolRow(
                        title: "Club Settings",
                        subtitle: "Update contact info, join approval settings, and club details.",
                        icon: "slider.horizontal.3"
                    )
                }
                .buttonStyle(.plain)

                Divider()
                    .padding(.vertical, 2)

                Button {
                    ownerToolSheet = .joinRequests
                } label: {
                    ownerToolRow(
                        title: "Join Requests",
                        subtitle: pendingCount == 0 ? "Review pending membership requests and approvals." : "\(pendingCount) pending request\(pendingCount == 1 ? "" : "s") ready for review.",
                        icon: "person.badge.plus",
                        hasBadge: pendingCount > 0
                    )
                }
                .buttonStyle(.plain)

                Button {
                    ownerToolSheet = .members
                } label: {
                    ownerToolRow(
                        title: "Manage Members",
                        subtitle: "View approved members and manage admin access.",
                        icon: "person.3.sequence.fill"
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(cornerRadius: 20, tint: Brand.frostedSurfaceSoft)
    }

    private var ownerOnboardingChecklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Club launch checklist")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.primaryText)

            ownerChecklistRow(
                title: "Set club profile picture",
                isComplete: ClubProfileImagePresets.presetID(from: club.imageURL) != nil
            )
            ownerChecklistRow(
                title: "Publish first game",
                isComplete: !appState.games(for: club).isEmpty
            )
            ownerChecklistRow(
                title: "Post first Club Chat update",
                isComplete: !appState.clubNewsPosts(for: club).isEmpty
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Brand.softOutline, lineWidth: 1)
        )
    }

    private func ownerChecklistRow(title: String, isComplete: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isComplete ? Brand.accentGreen : Brand.softOutline)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.primaryText)
            Spacer(minLength: 0)
        }
    }

    private var adminToolsHeaderLabel: some View {
        Label("Admin Tools", systemImage: "crown.fill")
            .font(.headline.weight(.semibold))
            .foregroundStyle(Brand.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    private var adminToolsRolePill: some View {
        Text("Admins")
            .font(.caption2.weight(.bold))
            .foregroundStyle(Brand.primaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Brand.secondarySurface, in: Capsule())
    }

    // MARK: - Owner Game Quick Actions

    private func ownerGameQuickActions(_ game: Game) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                editGameButton(game)
                duplicateGameButton(game)
                deleteGameButton(game)
            }

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    editGameButton(game)
                    duplicateGameButton(game)
                }
                deleteGameButton(game)
            }
        }
    }

    private func nextWeekDraft(from game: Game) -> ClubOwnerGameDraft {
        var draft = ClubOwnerGameDraft(game: game)
        draft.startDate = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: game.dateTime) ?? game.dateTime
        draft.repeatWeekly = false
        draft.repeatCount = 1
        return draft
    }

    private func editGameButton(_ game: Game) -> some View {
        Button {
            editingOwnerGame = game
        } label: {
            HStack(spacing: 6) {
                if appState.isOwnerSavingGame(game) {
                    ProgressView().tint(Brand.pineTeal)
                } else {
                    Image(systemName: "square.and.pencil")
                }
                Text("Edit Game")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Brand.pineTeal)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(appState.isOwnerDeletingGame(game))
        .actionBorder(cornerRadius: 12, color: Brand.softOutline)
    }

    private func duplicateGameButton(_ game: Game) -> some View {
        Button {
            duplicatingGame = game
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc")
                Text("Duplicate")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Brand.slateBlue)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(appState.isOwnerSavingGame(game) || appState.isOwnerDeletingGame(game))
        .actionBorder(cornerRadius: 12, color: Brand.softOutline)
    }

    private func deleteGameButton(_ game: Game) -> some View {
        Button {
            ownerDeleteGameCandidate = game
        } label: {
            HStack(spacing: 6) {
                if appState.isOwnerDeletingGame(game) {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "trash")
                }
                Text(appState.isOwnerDeletingGame(game) ? "Deleting..." : "Delete")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(Brand.coralBlaze, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(appState.isOwnerSavingGame(game))
        .actionBorder(cornerRadius: 12, color: Brand.softOutline)
    }

    // MARK: - Owner Tool Row

    private func ownerToolRow(title: String, subtitle: String, icon: String, hasBadge: Bool = false) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ownerToolIcon(icon, hasBadge: hasBadge)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Brand.primaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(softWrappedDisplayText(subtitle))
                        .font(.caption)
                        .foregroundStyle(Brand.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ownerToolChevron
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Brand.softOutline, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    ownerToolIcon(icon, hasBadge: hasBadge)
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Brand.primaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ownerToolChevron
                }
                Text(softWrappedDisplayText(subtitle))
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 44)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Brand.softOutline, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ownerToolIcon(_ icon: String, hasBadge: Bool = false) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Brand.primaryText)
                .frame(width: 34, height: 34)
                .background(Brand.dividerColor, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            if hasBadge {
                Circle()
                    .fill(Brand.errorRed)
                    .frame(width: 9, height: 9)
                    .offset(x: 3, y: -3)
            }
        }
    }

    private var ownerToolChevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(Brand.softOutline)
            .padding(.top, 2)
            .fixedSize()
    }

    // MARK: - Helper Views

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Brand.secondaryText)
            TextField("Search members", text: $searchText)
        }
        .padding()
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Brand.softOutline, lineWidth: 1)
        )
    }

    private func reliabilityRing(_ value: Int) -> some View {
        ZStack {
            Circle()
                .stroke(Brand.rosyTaupe.opacity(0.35), lineWidth: 4)
            Circle()
                .trim(from: 0, to: CGFloat(value) / 100)
                .stroke(Brand.spicyOrange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(value)")
                .font(.caption2.bold())
                .foregroundStyle(Brand.pineTeal)
        }
        .frame(width: 34, height: 34)
    }

    private func infoSection(_ title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Brand.ink)
            Text(verbatim: softWrappedDisplayText(body))
                .foregroundStyle(Brand.mutedText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func locationInfoSection(_ title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Brand.ink)

            if let url = MapNavigationURL.directions(to: body) {
                Button {
                    openURL(url)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "location.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.top, 3)
                        Text(verbatim: softWrappedDisplayText(body))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Brand.pineTeal)
                }
                .buttonStyle(.plain)
            } else {
                Text(verbatim: softWrappedDisplayText(body))
                    .foregroundStyle(Brand.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filterMenuLabel(title: String, value: String, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(value)
                .font(.caption)
                .foregroundStyle(Brand.secondaryText)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
        }
        .filterChipStyle(selected: isSelected, cornerRadius: 12)
    }

    private func prettify(_ raw: String) -> String {
        if raw.caseInsensitiveCompare("ladder") == .orderedSame ||
            raw.caseInsensitiveCompare("king_of_court") == .orderedSame {
            return "King of the Court"
        }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    // MARK: - Hero Artwork

    private var heroArtwork: some View {
        ZStack {
            if let preset = ClubProfileImagePresets.preset(for: club.imageURL) {
                ProfileAvatarArtwork(preset: preset, variant: .club)
            } else if let url = club.imageURL, isRemoteImageURL(url) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Brand.pineTeal.opacity(0.95))
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure, .empty:
                        fallbackHeroIcon
                    @unknown default:
                        fallbackHeroIcon
                    }
                }
            } else {
                fallbackHeroIcon
            }
        }
    }

    private var fallbackHeroIcon: some View {
        Image(systemName: club.imageSystemName)
            .font(.system(size: 34))
            .foregroundStyle(Brand.rosyTaupe.opacity(0.95))
    }

    private func isRemoteImageURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func iconName(for state: ClubMembershipState, isRequesting: Bool) -> String {
        if isRequesting { return "hourglass" }
        switch state {
        case .none, .rejected:
            return "plus.circle.fill"
        case .pending:
            return "clock.badge.checkmark.fill"
        case .approved, .unknown:
            return "checkmark.circle.fill"
        }
    }

    // MARK: - Text Helpers

    private func softWrappedDisplayText(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        let cappedRaw: String
        if raw.count > Self.maxRenderableDetailTextLength {
            cappedRaw = String(raw.prefix(Self.maxRenderableDetailTextLength)) + "..."
        } else {
            cappedRaw = raw
        }

        let breakAfter = CharacterSet(charactersIn: "/._-?&=:@,")
        let whitespace = CharacterSet.whitespacesAndNewlines
        var output = String.UnicodeScalarView()
        var runLength = 0

        for scalar in cappedRaw.unicodeScalars {
            output.append(scalar)

            if whitespace.contains(scalar) {
                runLength = 0
                continue
            }

            runLength += 1

            if breakAfter.contains(scalar) || runLength >= 18 {
                output.append(UnicodeScalar(0x200B)!)
                runLength = 0
            }
        }

        return String(output)
    }

    private func cappedDisplayText(_ raw: String, maxLength: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)) + "..."
    }

    private func trimmedOptional(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        let chars = parts.prefix(2).compactMap { $0.first }
        return String(chars)
    }

    // MARK: - Load Data If Needed

    private func loadDataIfNeeded(for tab: ClubDetailTab) async {
        if tab == .games, appState.games(for: club).isEmpty {
            await appState.refreshGames(for: club)
        }
        if tab == .members, appState.clubDirectoryMembers(for: club).isEmpty {
            await appState.refreshClubDirectoryMembers(for: club)
        }
        if tab == .clubNews, appState.clubNewsPosts(for: club).isEmpty {
            await appState.refreshClubNews(for: club)
        }
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
