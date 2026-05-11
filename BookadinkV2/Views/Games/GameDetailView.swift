import CoreLocation
import MapKit
import SwiftUI
import StripePaymentSheet

struct GameDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let game: Game

    @State private var showDUPRBookingSheet = false
    @State private var isEditingGame = false
    @State private var duprIDDraft = ""
    @State private var duprRatingText = ""
    @State private var duprBookingConfirmed = false
    @State private var duprSheetErrorMessage: String? = nil

    // In-flow DUPR recovery sheet — fires when AppState signals a booking attempt
    // failed because the user lacks a valid DUPR ID. Distinct from the proactive
    // duprBookingSheet above (which captures DUPR ID + rating + a confirmation
    // toggle and auto-books). This recovery sheet is intentionally minimal:
    // a single field, server-min length validation, no auto-book — the user
    // taps Book again so the server-authoritative path runs unchanged.
    @State private var showDUPRRecoverySheet = false
    @State private var duprRecoveryDraft = ""
    @State private var duprRecoveryError: String? = nil
    @State private var isSavingDUPRRecovery = false
    @State private var isPlayersExpanded = false
    @State private var showCancelGameConfirmation = false
    /// Phase 2A.2: secondary confirmation before firing `appState.cancelBooking`.
    /// Both player-side Cancel CTAs in this view route through this flag instead
    /// of calling cancel directly — matches the existing pattern used by
    /// `BookingsListView` and the admin "Cancel this game?" dialog above.
    @State private var showCancelBookingConfirmation = false

    // Stripe PaymentSheet
    @State private var paymentSheet: PaymentSheet = PaymentSheet(paymentIntentClientSecret: "", configuration: .init())
    @State private var isShowingPaymentSheet = false
    @State private var isPreparingPayment = false
    @State private var isConfirmingPayment = false
    @State private var paymentErrorMessage: String?
    @State private var pendingStripePaymentIntentID: String?
    @State private var pendingPlatformFeeCents: Int? = nil
    @State private var pendingClubPayoutCents: Int? = nil
    @State private var pendingCreditsApplied: Int? = nil
    @State private var useCredits: Bool = true
    // Phase 3: promoted waitlist payment completion
    @State private var isPendingPaymentCompletion: Bool = false
    @State private var pendingBookingIDForConfirm: UUID? = nil
    @State private var holdCountdown: String = ""
    // Cancellation credit result sheet
    @State private var showCancellationCreditSheet = false
    @State private var displayedCancellationCredit: CancellationCreditResult? = nil
    @State private var cancellationPolicyExpanded = false
    @State private var showBookingSuccess = false

    /// Drives the "Open in Apple Maps / Google Maps" confirmation dialog
    /// triggered by tapping the VENUE info card.
    @State private var showOpenInMapsPrompt = false

    /// Positive distance the user has pulled the ScrollView down past
    /// rest. Drives the fixed HeroSurface's height so the hero paint
    /// stretches with the pull instead of detaching from the top of
    /// the screen — matches the `ClubDetailView` morphing feel.
    @State private var pullDownAmount: CGFloat = 0

    /// Vertical offset applied to the fixed HeroSurface as the user
    /// scrolls upward (content rising). Without this, the painted hero
    /// stays pinned at y=0 even after the in-scroll heroSection has
    /// scrolled past, so subsequent content (price pills, info cards)
    /// would render *on top of* the dark hero painting. Tracks scroll
    /// 1:1 so the hero scrolls out of view together with the in-scroll
    /// `heroSection` placeholder. (ClubDetailView gets to use a 30%
    /// parallax because its content sheet has a solid background that
    /// masks the hero behind it; GameDetailView's content is a
    /// transparent VStack of individual cards, so any partially-visible
    /// hero would bleed through the gaps. 1:1 keeps the seam clean.)
    @State private var heroParallaxOffset: CGFloat = 0

    /// Baseline hero height. The fixed background is at least this
    /// tall, plus `pullDownAmount` while the user is pulling down.
    /// **Must stay in sync with `ClubDetailView.heroHeight`** so the
    /// hero region is the same pixel height when the user navigates
    /// between Club ↔ Game — the seam between the painted hero and
    /// the content sheet sits at the same Y in both views, which
    /// keeps the transition feeling continuous rather than jumpy.
    private static let heroHeight: CGFloat = 280

    // MARK: - Adaptive Layout

    /// Two-column iPad layout intentionally disabled — design feedback
    /// preferred the single-column layout even at page-sized sheet
    /// presentation. The supporting scaffolding (`iPadWideContentLayer`,
    /// `iPadBookingSidebar`, `iPadContentMaxWidth`, etc.) is kept in
    /// place so a future re-enable is a one-line revert here.
    /// `hSizeClass` is still read so the rest of the body keeps reacting
    /// to size class for the iPad payment-sheet backdrop dim and any
    /// future iPad-specific tweaks.
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var isWideLayout: Bool {
        false
    }

    /// True when running on iPad regular-width, used for selective iPad
    /// affordances that should keep firing (e.g. PaymentSheet backdrop
    /// dim) even though the two-column content layout is disabled.
    private var isIPadRegular: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && hSizeClass == .regular
    }

    /// Adaptive booking-panel width range. Computed from container width
    /// (~28% of total, clamped to [320, 400]) so the panel feels docked
    /// without dominating a 13" canvas. Tighter ratio + lower ceiling
    /// (vs the previous 0.30 / 420pt) gives the left content more room.
    private static let iPadBookingPanelMinWidth: CGFloat = 320
    private static let iPadBookingPanelMaxWidth: CGFloat = 400
    private static let iPadBookingPanelRatio: CGFloat = 0.28

    private static func iPadBookingPanelWidth(for containerWidth: CGFloat) -> CGFloat {
        min(iPadBookingPanelMaxWidth, max(iPadBookingPanelMinWidth, containerWidth * iPadBookingPanelRatio))
    }

    /// Reading-width cap for the left content column on iPad. 840pt
    /// (vs the previous 760pt) lets section cards fill more of the
    /// available space so the page no longer reads as a narrow phone
    /// column floating in a large canvas.
    private static let iPadContentMaxWidth: CGFloat = 840

    // MARK: - Computed Properties

    private var clubName: String? {
        appState.clubs.first(where: { $0.id == game.clubID })?.name
    }

    private var clubForGame: Club? {
        appState.clubs.first(where: { $0.id == game.clubID })
    }

    /// The ClubVenue that matches `currentGame.venueName` (case-insensitive).
    /// Single source of truth for address display, map navigation, and distance.
    private var resolvedVenueForGame: ClubVenue? {
        let venues = appState.clubVenuesByClubID[currentGame.clubID] ?? []
        return LocationService.resolvedVenue(for: currentGame, venues: venues)
    }

    private var isClubAdminUser: Bool {
        guard let club = clubForGame else { return false }
        return appState.isClubAdmin(for: club)
    }

    private var canViewAttendees: Bool {
        guard let club = clubForGame else { return false }
        if isClubAdminUser { return true }
        if appState.bookingState(for: game).canCancel { return true }
        let membership = appState.membershipState(for: club)
        switch membership {
        case .approved, .unknown: return true
        case .none, .pending, .rejected: return false
        }
    }

    private var canBookGameByClubMembership: Bool {
        guard let club = clubForGame else { return true }
        if appState.isClubAdmin(for: club) { return true }
        switch appState.membershipState(for: club) {
        case .approved, .unknown: return true
        case .none, .pending, .rejected: return false
        }
    }

    private var bookingMembershipRequirementMessage: String? {
        guard let club = clubForGame else { return nil }
        let state = appState.membershipState(for: club)
        guard appState.bookingState(for: game).canBook, !canBookGameByClubMembership else { return nil }
        switch state {
        case .pending: return "Your club join request is pending. You can book after approval."
        case .none, .rejected: return "Join the club to book this game."
        case .approved, .unknown: return nil
        }
    }

    /// Always returns the latest in-memory version of this game.
    /// After an owner edit, `updateGameForClub` patches `gamesByClubID` immediately
    /// (before `dismiss()` is called), so this computed var reflects the edit
    /// as soon as the edit sheet closes — no extra network call needed.
    private var currentGame: Game {
        appState.gamesByClubID[game.clubID]?.first(where: { $0.id == game.id }) ?? game
    }

    /// String search query for Maps when coordinate-based navigation is unavailable.
    /// Only called when `resolvedVenueForGame` exists but has no coordinates.
    private var gameLocationNavigationQuery: String {
        guard let venue = resolvedVenueForGame else { return "" }
        let parts = [venue.venueName, LocationService.formattedAddress(for: venue)]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.joined(separator: ", ")
    }

    private var confirmedAttendees: [GameAttendee] {
        appState.gameAttendees(for: game)
            .filter { if case .confirmed = $0.booking.state { return true } else { return false } }
            .sorted { ($0.booking.createdAt ?? .distantFuture) < ($1.booking.createdAt ?? .distantFuture) }
    }

    private var waitlistedAttendees: [GameAttendee] {
        appState.gameAttendees(for: game)
            .filter { if case .waitlisted = $0.booking.state { return true } else { return false } }
            .sorted { lhs, rhs in
                func waitlistPos(_ a: GameAttendee) -> Int {
                    if case let .waitlisted(p) = a.booking.state { return p ?? Int.max }
                    return Int.max
                }
                let p0 = waitlistPos(lhs), p1 = waitlistPos(rhs)
                if p0 != p1 { return p0 < p1 }
                return (lhs.booking.createdAt ?? .distantFuture) < (rhs.booking.createdAt ?? .distantFuture)
            }
    }

    /// Players promoted from waitlist who haven't completed payment yet.
    /// Shown in the owner's waitlist section with an "Awaiting Payment" badge.
    private var pendingPaymentAttendees: [GameAttendee] {
        appState.gameAttendees(for: game)
            .filter { if case .pendingPayment = $0.booking.state { return true } else { return false } }
            .sorted { ($0.booking.createdAt ?? .distantFuture) < ($1.booking.createdAt ?? .distantFuture) }
    }

    private var currentBookingState: BookingState {
        appState.bookingState(for: game)
    }

    private var durationText: String {
        let m = currentGame.durationMinutes
        if m >= 60 && m % 60 == 0 {
            let h = m / 60
            return "\(h) hour\(h > 1 ? "s" : "")"
        } else if m >= 60 {
            return "\(m / 60)h \(m % 60)m"
        }
        return "\(m) min"
    }

    private var priceText: String { currentGame.priceLabel }

    private var spotsLeft: Int {
        // Prefer live attendee count (updated after refreshAttendees) over the
        // confirmedCount baked into the game model at fetch time, which can be stale.
        let attendees = appState.gameAttendees(for: game)
        let confirmed = !attendees.isEmpty
            ? confirmedAttendees.count
            : (currentGame.confirmedCount ?? 0)
        return max(0, currentGame.maxSpots - confirmed)
    }

    /// Whether the game is full based on live attendee data (more accurate than game.isFull).
    private var isGameFull: Bool {
        spotsLeft == 0
    }

    // True only when entitlements are loaded and confirm the club cannot accept payments.
    // Fail-open while loading (nil entitlements) — the server blocks at payment time regardless.
    private var clubPaymentBlocked: Bool {
        guard let fee = currentGame.feeAmount, fee > 0, !isGameFull else { return false }
        guard let entitlements = appState.entitlementsByClubID[game.clubID] else { return false }
        return !entitlements.canAcceptPayments
    }

    private var spotsText: String {
        switch spotsLeft {
        case 0:        return "Full"
        case 1:        return "1 spot left"
        default:       return "\(spotsLeft) spots left"
        }
    }

    private var spotsColor: Color {
        switch spotsLeft {
        case 0, 1:     return .red
        case 2...5:    return .orange
        default:       return Brand.mutedText
        }
    }

    /// Inline tag string: "Intermediate • King of the Court • DUPR Required"
    private var tagLine: String? {
        var parts: [String] = []
        let skill = prettify(currentGame.skillLevel)
        if !skill.isEmpty { parts.append(skill) }
        let format = prettify(currentGame.gameFormat)
        if !format.isEmpty && format.lowercased() != "open play" { parts.append(format) }
        if currentGame.requiresDUPR { parts.append("DUPR Required") }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            Brand.appBackground.ignoresSafeArea()

            // Fixed HeroSurface background — pinned to the top of the
            // screen behind the ScrollView. Stretches downward by
            // `pullDownAmount` so the hero paint follows the title
            // block as the user pulls the page down (no gap at the top
            // edge during pull-to-refresh).
            HeroSurface.forGame(
                currentGame,
                lighting: .topRight,
                vignette: .bottomStrong,
                direction: .diagonal
            )
            .frame(height: Self.heroHeight + pullDownAmount)
            // Drift upward with scroll so the hero scrolls out of view
            // alongside the in-scroll heroSection placeholder. Without
            // this offset, content that scrolls into the hero's y-zone
            // would render on top of the dark painting (price pills on
            // navy background, etc.).
            .offset(y: heroParallaxOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)

            // Adaptive content layer — single column on iPhone (sticky
            // footer), two-column on iPad with a persistent right-side
            // booking panel. The fixed HeroSurface above is shared by
            // both, so the painted hero stays continuous across the
            // iPhone ↔ iPad transition (e.g. Slide Over → full screen).
            if isWideLayout {
                iPadWideContentLayer
            } else {
                iPhoneContentLayer
            }
        }
        // Stripe PaymentSheet presentation lives at the body root so it
        // is attached regardless of which content layer is active. The
        // previous attachment on `stickyFooter` would have been gone on
        // iPad two-column where the footer is suppressed.
        .paymentSheet(
            isPresented: $isShowingPaymentSheet,
            paymentSheet: paymentSheet,
            onCompletion: handlePaymentCompletion
        )
        // iPad: dim the app behind the Stripe PaymentSheet. Stripe
        // presents its sheet as a centered modal card on iPad so the
        // underlying two-column layout stays highly readable through
        // Stripe's own backdrop. This overlay sits under the Stripe
        // modal (Stripe is a UIKit window-level presentation) and only
        // fires while the sheet is up. iPhone is unaffected — Stripe's
        // own backdrop already covers most of the screen there.
        .overlay {
            Color.black
                .opacity(isShowingPaymentSheet && isIPadRegular ? 0.35 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.2), value: isShowingPaymentSheet)
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task(id: game.id) {
            appState.bookingsErrorMessage = nil
            appState.bookingInfoMessage = nil
            await appState.refreshBookings(silent: true)
            if canViewAttendees { await appState.refreshAttendees(for: game) }
            if let club = clubForGame, appState.authState == .signedIn {
                if appState.gamesByClubID[club.id]?.contains(where: { $0.id == game.id }) != true {
                    await appState.refreshGames(for: club)
                }
                await appState.refreshClubAdminRole(for: club)
                if appState.isClubAdmin(for: club) {
                    await appState.refreshOwnerMembers(for: club)
                    if appState.venues(for: club).isEmpty {
                        await appState.refreshVenues(for: club)
                    }
                }
            }
            if let fee = currentGame.feeAmount, fee > 0 {
                await appState.refreshCreditBalance(for: game.clubID)
                if appState.entitlementsByClubID[game.clubID] == nil {
                    await appState.fetchClubEntitlements(for: game.clubID)
                }
            }
            updateHoldCountdown()
        }
        .onChange(of: currentGame.feeAmount) { oldFee, newFee in
            guard let fee = newFee, fee > 0, (oldFee == nil || oldFee == 0) else { return }
            Task { await appState.refreshCreditBalance(for: game.clubID) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookADinkWaitlistPromoted)) { note in
            guard let gameIDString = note.object as? String,
                  gameIDString == game.id.uuidString else { return }
            Task {
                await appState.refreshBookings(silent: true)
                await appState.refreshAttendees(for: game)
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            updateHoldCountdown()
        }
        .sheet(isPresented: $showDUPRBookingSheet) { duprBookingSheet }
        .sheet(isPresented: $showDUPRRecoverySheet) { duprRecoverySheet }
        .onChange(of: appState.bookingDUPRRequiredForGameID) { _, newValue in
            guard newValue == currentGame.id else { return }
            duprRecoveryDraft = appState.duprID ?? ""
            duprRecoveryError = nil
            showDUPRRecoverySheet = true
            // Clear immediately so re-renders / scenePhase changes don't refire the sheet.
            appState.clearBookingDUPRRequired()
        }
        .sheet(isPresented: $isEditingGame) {
            if let club = clubForGame {
                OwnerEditGameSheet(club: club, game: currentGame, initialVenues: appState.venues(for: club))
                    .environmentObject(appState)
            }
        }
        .confirmationDialog(
            "Open directions in Maps?",
            isPresented: $showOpenInMapsPrompt,
            titleVisibility: .visible
        ) {
            if let url = venueAppleMapsURL {
                Button("Open in Apple Maps") { openURL(url) }
            }
            if let url = venueGoogleMapsURL {
                Button("Open in Google Maps") { openURL(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let v = resolvedVenueForGame {
                Text("Get directions to \(v.venueName).")
            } else {
                Text("Get directions to this game's venue.")
            }
        }
        .confirmationDialog(
            "Cancel Booking",
            isPresented: $showCancelBookingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel Booking", role: .destructive) {
                Task { await appState.cancelBooking(for: game) }
            }
            Button("Keep Booking", role: .cancel) {}
        } message: {
            Text("This will remove you from \(currentGame.title). You may not be able to rebook if the session fills up.")
        }
        .confirmationDialog(
            "Cancel this game?",
            isPresented: $showCancelGameConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel Game", role: .destructive) {
                Task { await appState.cancelGame(for: game) }
            }
            Button("Keep Game", role: .cancel) {}
        } message: {
            // Append the credit warning when paid bookings exist on this game.
            // Attendees were loaded by GameDetailView's own .task so the cache
            // is reliable by the time the admin reaches this dialog.
            let paid = (appState.attendeesByGameID[game.id] ?? []).filter { attendee in
                guard case .confirmed = attendee.booking.state else { return false }
                return attendee.booking.feePaid && attendee.booking.paymentMethod == "stripe"
            }.count
            if paid > 0 {
                Text("This will cancel the game and notify all booked players.\nPaid players will be issued club credit.")
            } else {
                Text("This will cancel the game and notify all booked players.")
            }
        }
        .onChange(of: currentGame.status) { _, newStatus in
            if newStatus == "cancelled" { dismiss() }
        }
        .onChange(of: appState.lastCancellationCredit) { _, result in
            guard let result, result.clubID == game.clubID else { return }
            displayedCancellationCredit = result
            showCancellationCreditSheet = true
            appState.lastCancellationCredit = nil
        }
        .sheet(isPresented: $showCancellationCreditSheet) { cancellationCreditSheet }
        .onChange(of: currentBookingState) { old, new in
            guard case .confirmed = new else { return }
            switch old {
            case .none, .cancelled, .pendingPayment:
                showBookingSuccess = true
            default:
                break
            }
        }
        .sheet(isPresented: $showBookingSuccess) { bookingSuccessSheet }
        .blur(radius: showBookingSuccess ? 22 : 0)
        .overlay(
            Color.black
                .opacity(showBookingSuccess ? 0.55 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
        .animation(.easeInOut(duration: 0.32), value: showBookingSuccess)
        // iPad: when presented as a `.sheet` from HomeView / NearbyGamesView /
        // BookingsListView / NotificationsView, present at page size (iOS 18+)
        // so the game card fills the iPad canvas — matches the page-sized
        // OwnerEditGameSheet and lets the Phase B two-column iPad layout
        // fire (form-sheet presentation reports compact hSizeClass and
        // would otherwise force the iPhone single-column layout). iPhone is
        // unaffected; `.page` is the default full sheet there.
        .modifier(IPadPagePresentationSizing())
    }

    // MARK: - Hero Helpers

    private var startsInText: String {
        let secs = currentGame.dateTime.timeIntervalSinceNow
        guard secs > 0 else { return "" }
        let totalMins = Int(secs / 60)
        if totalMins < 60 { return "Starts in \(totalMins)m" }
        let days  = totalMins / 1440
        let hours = (totalMins % 1440) / 60
        let mins  = totalMins % 60
        if days > 0 {
            return mins > 0 ? "Starts in \(days)d \(hours)h \(mins)m" : "Starts in \(days)d \(hours)h"
        }
        return mins > 0 ? "Starts in \(hours)h \(mins)m" : "Starts in \(hours)h"
    }

    // MARK: - Hero Section

    /// Top safe-area inset, sourced the same way as `ClubDetailView`.
    /// Used to push the hero's chrome row (back button + admin/more
    /// menus) below the status bar now that the ScrollView extends
    /// through the safe area so the HeroSurface paints all the way to
    /// the top of the screen.
    private var safeAreaTopPad: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }
            .first ?? 44
    }

    private var heroChipText: String {
        (clubName ?? "").uppercased()
    }

    private static let heroDateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_AU")
        f.dateFormat = "EEE d MMM"; return f
    }()
    private static let heroTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"; f.amSymbol = "AM"; f.pmSymbol = "PM"; return f
    }()
    private static let scheduledPublishFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_AU")
        f.dateFormat = "EEE d MMM 'at' h:mm a"
        f.amSymbol = "AM"; f.pmSymbol = "PM"
        return f
    }()

    private var heroDateText: String {
        "\(Self.heroDateFmt.string(from: currentGame.dateTime).uppercased()) · \(Self.heroTimeFmt.string(from: currentGame.dateTime))"
    }

    private var heroSection: some View {
        ZStack(alignment: .bottom) {
            // Transparent placeholder — the actual HeroSurface is
            // rendered as a fixed background layer in `body` so it
            // stays pinned to the top of the screen and stretches with
            // pull-to-refresh. This in-scroll layer just reserves the
            // hero's vertical space and carries the chrome + title
            // content on top of the fixed paint behind it.
            Color.clear
            // Content
            VStack(alignment: .leading, spacing: 0) {
                // Top bar
                HStack(spacing: 10) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.black.opacity(0.28), in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if isClubAdminUser {
                        heroAdminMenu
                    }
                    heroMoreMenu
                }
                .padding(.horizontal, 16)
                // ScrollView ignores top safe area so the HeroSurface
                // paints behind the status bar — the chrome row needs
                // an explicit safe-area inset added back to keep the
                // back button + menus clear of the status bar.
                .padding(.top, safeAreaTopPad + 10)

                Spacer(minLength: 12)

                // Club chip — tappable link to club page.
                // Routes through `appState.navigate(to:)` so the path is
                // idempotent: tapping back to a club already in the stack
                // pops to it instead of pushing a duplicate (eliminates the
                // Game ↔ Club ping-pong loop).
                Button {
                    appState.navigate(to: .club(currentGame.clubID))
                } label: {
                    HStack(spacing: 4) {
                        Text(heroChipText)
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(0.8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                // Date · time
                Text(heroDateText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.80))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)

                // Title
                Text(currentGame.title)
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
            }
        }
        // Locked to the same baseline as the fixed HeroSurface in
        // `body`, so at rest the in-scroll placeholder and the fixed
        // paint behind it occupy exactly the same vertical region.
        // (Was `minHeight: 260` previously; `.frame(minHeight:)` lets
        // long titles push the hero taller than the fixed background,
        // which would expose `appBackground` below the paint.)
        .frame(minHeight: Self.heroHeight)
        .frame(maxWidth: .infinity)
    }

    private func heroActionButton(systemImage: String) -> some View {
        Button { } label: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.28), in: Circle())
        }
        .buttonStyle(.plain)
    }

    // Hero-context admin menu (white icons)
    private var heroAdminMenu: some View {
        let isCancellingGame = appState.isCancellingGame(game)
        return Menu {
            if !currentGame.startsInPast {
                Button { isEditingGame = true } label: {
                    Label("Edit Game", systemImage: "pencil")
                }
            }
            if currentGame.status != "cancelled" {
                Divider()
                Button(role: .destructive) {
                    showCancelGameConfirmation = true
                } label: {
                    Label(isCancellingGame ? "Cancelling…" : "Cancel Game", systemImage: "xmark.circle")
                }
                .disabled(isCancellingGame)
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.28), in: Circle())
        }
    }

    // Hero-context more menu (white icons)
    private var heroMoreMenu: some View {
        let hasCalendarExport = appState.hasCalendarExport(for: game)
        let hasReminder = appState.hasReminder(for: game)
        let isExportingCalendar = appState.isExportingCalendar(for: game)
        let isCancelling = appState.isCancellingBooking(for: game)
        let state = currentBookingState
        return Menu {
            if state.canCancel {
                Button {
                    Task { await appState.toggleCalendarExport(for: game) }
                } label: {
                    Label(hasCalendarExport ? "Remove from Calendar" : "Add to Calendar",
                          systemImage: hasCalendarExport ? "calendar.badge.minus" : "calendar.badge.plus")
                }
                .disabled(isExportingCalendar)
                if !currentGame.startsInPast {
                    Button {
                        Task { await appState.toggleReminder(for: game) }
                    } label: {
                        Label(hasReminder ? "Remove Reminder" : "Set Reminder",
                              systemImage: hasReminder ? "bell.slash" : "bell.badge")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showCancelBookingConfirmation = true
                    } label: {
                        Label(isCancelling ? "Cancelling…" : "Cancel Booking", systemImage: "xmark.circle")
                    }
                    .disabled(isCancelling)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.28), in: Circle())
        }
    }

    // MARK: - Tags Row

    @ViewBuilder
    private var tagsRowSection: some View {
        let state = currentBookingState
        let costValue: String = currentGame.priceLabel
        let creditCents = appState.creditBalance(for: game.clubID)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 1. Cost — neutral, data badge (always first)
                costBadge(value: costValue)

                // 2. Status — semantic colour. "You're in" is the only solid-filled badge.
                if currentGame.status == "cancelled" {
                    tagPill("Cancelled", bg: Brand.errorRed.opacity(0.12), fg: Brand.errorRed)
                } else if case .confirmed = state {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        Text("You're in")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.primaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Brand.accentGreen, in: Capsule())
                } else if case let .waitlisted(pos) = state {
                    tagPill(pos.map { "Waitlist #\($0)" } ?? "Waitlisted",
                            bg: Brand.spicyOrange.opacity(0.12), fg: Brand.spicyOrange)
                } else if case .pendingPayment = state {
                    tagPill("Payment due", bg: Brand.spicyOrange.opacity(0.12), fg: Brand.spicyOrange)
                }

                // 3. Credits — neutral, data badge, lowest emphasis
                if creditCents > 0 {
                    let balanceText: String = {
                        let dollars = Double(creditCents) / 100
                        if dollars == dollars.rounded() { return "$\(Int(dollars))" }
                        return String(format: "$%.2f", dollars)
                    }()
                    creditsBadge(value: balanceText)
                }
            }
            .padding(.horizontal, 0)
        }
        .padding(.horizontal, -16)
        .padding(.leading, 16)
    }

    private func tagPill(_ label: String, bg: Color, fg: Color) -> some View {
        Text(label)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(fg)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(bg, in: Capsule())
            .overlay(Capsule().stroke(Brand.softOutline, lineWidth: 1))
    }

    /// Cost · $X / Cost · Free. Neutral data badge — slightly larger than standard chips,
    /// bold value for emphasis, no semantic colour (colour is reserved for state).
    private func costBadge(value: String) -> some View {
        HStack(spacing: 5) {
            Text("Cost")
                .fontWeight(.semibold)
                .foregroundStyle(Brand.secondaryText)
            Text("·")
                .foregroundStyle(Brand.secondaryText)
            Text(value)
                .fontWeight(.bold)
                .foregroundStyle(Brand.primaryText)
        }
        .font(.system(size: 14))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(Brand.secondarySurface, in: Capsule())
        .overlay(Capsule().stroke(Brand.softOutline, lineWidth: 1))
    }

    /// Credits · $X. Same shape as cost, lower contrast — lowest emphasis.
    private func creditsBadge(value: String) -> some View {
        HStack(spacing: 5) {
            Text("Credits")
            Text("·")
            Text(value)
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(Brand.secondarySurface, in: Capsule())
        .overlay(Capsule().stroke(Brand.softOutline, lineWidth: 1))
    }

    // MARK: - 2×2 Info Grid

    private var infoGridSection: some View {
        let venue = resolvedVenueForGame
        let address = venue.flatMap { LocationService.formattedAddress(for: $0) }
        let venueName = venue?.venueName ?? currentGame.venueName ?? (clubName ?? "TBC")
        let venueSubLine = [venue?.suburb, address].compactMap { $0 }.first ?? address

        let endTime = Calendar.current.date(byAdding: .minute, value: currentGame.durationMinutes, to: currentGame.dateTime) ?? currentGame.dateTime
        let dateMain = Self.heroDateFmt.string(from: currentGame.dateTime)
        let timeSub = "\(Self.heroTimeFmt.string(from: currentGame.dateTime)) – \(Self.heroTimeFmt.string(from: endTime))"

        let confirmedCount = !confirmedAttendees.isEmpty ? confirmedAttendees.count : (currentGame.confirmedCount ?? 0)
        let venueIsTappable = canOpenVenueInMaps

        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            Group {
                if venueIsTappable {
                    Button {
                        showOpenInMapsPrompt = true
                    } label: {
                        infoCard(icon: "mappin.and.ellipse", label: "VENUE",
                                 main: venueName, sub: venueSubLine,
                                 trailingChevron: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens directions to the venue")
                } else {
                    infoCard(icon: "mappin.and.ellipse", label: "VENUE",
                             main: venueName, sub: venueSubLine)
                }
            }
            infoCard(icon: "calendar", label: "WHEN",
                     main: dateMain, sub: timeSub)
            infoCard(icon: "person.2", label: "FORMAT",
                     main: compactFormatLabel(currentGame.gameFormat, type: currentGame.gameType).isEmpty
                        ? "Open Play"
                        : compactFormatLabel(currentGame.gameFormat, type: currentGame.gameType),
                     sub: "\(confirmedCount)/\(currentGame.maxSpots) players")
            infoCard(icon: "star.circle", label: "SKILL",
                     main: compactSkillLabel(currentGame.skillLevel).isEmpty ? "All Levels" : compactSkillLabel(currentGame.skillLevel),
                     sub: currentGame.requiresDUPR ? "DUPR required" : nil)
        }
    }

    /// True when we have either resolved coordinates or a non-empty
    /// search query for the venue — enough to hand off to a maps app.
    private var canOpenVenueInMaps: Bool {
        if let v = resolvedVenueForGame, v.latitude != nil, v.longitude != nil {
            return true
        }
        return !gameLocationNavigationQuery.isEmpty
    }

    /// Apple Maps URL for the resolved venue, or nil when nothing routable.
    private var venueAppleMapsURL: URL? {
        if let v = resolvedVenueForGame, let lat = v.latitude, let lng = v.longitude {
            return MapNavigationURL.directions(
                to: CLLocationCoordinate2D(latitude: lat, longitude: lng))
        }
        return MapNavigationURL.directions(to: gameLocationNavigationQuery)
    }

    /// Google Maps URL for the resolved venue, or nil when nothing routable.
    private var venueGoogleMapsURL: URL? {
        if let v = resolvedVenueForGame, let lat = v.latitude, let lng = v.longitude {
            return MapNavigationURL.googleDirections(
                to: CLLocationCoordinate2D(latitude: lat, longitude: lng))
        }
        return MapNavigationURL.googleDirections(to: gameLocationNavigationQuery)
    }

    private func infoCard(icon: String, label: String, main: String, sub: String?, trailingChevron: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Brand.secondaryText)
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Brand.secondaryText)
                if trailingChevron {
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.secondaryText)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(main)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let sub {
                    Text(sub)
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Brand.softOutline, lineWidth: 1))
    }

    // MARK: - About Section

    @ViewBuilder
    private var aboutSection: some View {
        let userInfo = currentGame.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = !userInfo.isEmpty ? userInfo : (formatDescription(currentGame.gameFormat) ?? "")
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("ABOUT THIS GAME")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Brand.secondaryText)
                Text(text)
                    .font(.system(size: 15))
                    .foregroundStyle(Brand.primaryText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Price Summary Section

    @ViewBuilder
    private func priceSummarySection(fee: Double) -> some View {
        let totalCents = Int((fee * 100).rounded())
        let creditBalance = appState.creditBalance(for: game.clubID)
        let creditsApplicable = useCredits && creditBalance > 0
        let creditsToApply = creditsApplicable ? min(creditBalance, totalCents) : 0
        let netCents = totalCents - creditsToApply

        let feeText = String(format: "$%.2f", fee)
        let creditText = String(format: "$%.2f", Double(creditBalance) / 100)
        let creditDeductText = String(format: "–$%.2f", Double(creditsToApply) / 100)
        let dueText = netCents == 0 ? "$0.00" : String(format: "$%.2f", Double(netCents) / 100)

        VStack(spacing: 0) {
            // Game price row
            HStack {
                Text("Game price")
                    .font(.system(size: 15))
                    .foregroundStyle(Brand.primaryText)
                Spacer()
                Text(feeText)
                    .font(.system(size: 15))
                    .foregroundStyle(Brand.primaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if creditBalance > 0 && currentBookingState.canBook {
                Divider().padding(.horizontal, 16)
                // Credits toggle row
                Button {
                    useCredits.toggle()
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(creditsApplicable ? Brand.accentGreen : Brand.secondarySurface)
                                .frame(width: 18, height: 18)
                            if creditsApplicable {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Brand.primaryText)
                            }
                        }
                        Text("Apply credits (\(creditText) available)")
                            .font(.system(size: 15))
                            .foregroundStyle(Brand.primaryText)
                        Spacer()
                        if creditsApplicable {
                            Text(creditDeductText)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Brand.primaryText)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }

            Divider()
            // Due today
            HStack {
                Text("Due today")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Brand.primaryText)
                Spacer()
                Text(dueText)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Brand.primaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Brand.softOutline, lineWidth: 1))
    }

    // MARK: - Admin players expanded section

    @ViewBuilder
    private var adminPlayersSection: some View {
        if canViewAttendees {
            let liveConfirmed = !confirmedAttendees.isEmpty
                ? confirmedAttendees.count
                : (currentGame.confirmedCount ?? 0)
            let maxSpots = currentGame.maxSpots
            let remaining = max(0, maxSpots - liveConfirmed)
            let fillFraction = maxSpots > 0 ? min(1, Double(liveConfirmed) / Double(maxSpots)) : 0
            let isFull = liveConfirmed >= maxSpots

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("PLAYERS REGISTERED (\(liveConfirmed))")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Brand.secondaryText)
                    Spacer()
                    Text("\(liveConfirmed)/\(maxSpots)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.primaryText)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Brand.secondarySurface)
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Brand.accentGreen)
                            .frame(width: geo.size.width * fillFraction, height: 6)
                    }
                }
                .frame(height: 6)

                Text(isFull ? "Game is full" : "\(remaining) spot\(remaining == 1 ? "" : "s") remaining")
                    .font(.system(size: 13))
                    .foregroundStyle(isFull || remaining <= 2 ? Brand.errorRed : Brand.secondaryText)

                playersCard
            }
        }
    }

    // MARK: - Sticky Footer

    private var stickyFooter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Brand.softOutline)
                .frame(height: 0.5)
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.primaryText)
                        .frame(width: 52, height: 52)
                        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Brand.softOutline, lineWidth: 1))
                }
                .buttonStyle(.plain)

                footerCTAArea
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .background(.regularMaterial)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 0) }
        // `.paymentSheet(...)` lives on the body's outer ZStack so the
        // Stripe sheet binding is attached on both iPhone (sticky footer)
        // and iPad (two-column / no sticky footer) layouts.
    }

    // MARK: - Adaptive Content Layers

    /// iPhone single-column layout: full-width ScrollView with the
    /// existing sticky bottom footer overlay. Behaviour is unchanged from
    /// before iPad support was added — same paddings, same scroll probe,
    /// same content order.
    private var iPhoneContentLayer: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.vertical) {
                scrollOffsetProbe

                VStack(spacing: 0) {
                    heroSection

                    VStack(alignment: .leading, spacing: 20) {
                        gameDetailContent
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 110)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)

            stickyFooter
        }
    }

    /// iPad two-column layout: scrolling content on the left, persistent
    /// booking panel on the right. The painted HeroSurface in the parent
    /// ZStack remains full-width behind both columns; the right panel
    /// sits below the hero baseline so the hero stays visually intact
    /// across the full screen width above it. The sticky bottom footer
    /// is not rendered here — `iPadBookingSidebar` is its replacement.
    ///
    /// Sidebar width is computed from container width via
    /// `iPadBookingPanelWidth(for:)` so 11" iPad portrait gets the floor
    /// (320pt), 13" landscape gets the ceiling (420pt), and split-screen
    /// cases land somewhere in between. Left content is capped at
    /// `iPadContentMaxWidth` so cards don't sprawl across a 13" canvas.
    private var iPadWideContentLayer: some View {
        GeometryReader { geo in
            let sidebarWidth = Self.iPadBookingPanelWidth(for: geo.size.width)
            HStack(alignment: .top, spacing: 0) {
                ScrollView(.vertical) {
                    scrollOffsetProbe

                    VStack(spacing: 0) {
                        heroSection

                        VStack(alignment: .leading, spacing: 20) {
                            gameDetailContent
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        // No sticky footer to clear on iPad — bottom padding
                        // is just breathing room.
                        .padding(.bottom, 32)
                        // Cap reading width so section cards stay
                        // comfortable on a 13" canvas. Centered within the
                        // remaining left-column space so the empty margins
                        // read as intentional balance, not abandonment.
                        .frame(maxWidth: Self.iPadContentMaxWidth)
                        .frame(maxWidth: .infinity)
                    }
                }
                .scrollIndicators(.hidden)
                .ignoresSafeArea(edges: .top)
                .frame(maxWidth: .infinity)

                iPadBookingSidebar
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// Live scroll-offset probe that drives `pullDownAmount` and
    /// `heroParallaxOffset`. Extracted so iPhone and iPad layers share
    /// the same parallax / pull-to-refresh feel without duplication.
    private var scrollOffsetProbe: some View {
        ScrollOffsetReader { offset in
            pullDownAmount = max(-offset, 0)
            let upward = max(offset, 0)
            heroParallaxOffset = -min(upward, Self.heroHeight)
        }
        .frame(height: 0)
    }

    /// The shared inner content sequence below the hero. Used by both
    /// iPhone and iPad layers — only the surrounding paddings differ.
    @ViewBuilder
    private var gameDetailContent: some View {
        tagsRowSection
        infoGridSection

        if shouldShowAboutSection {
            aboutSection
        }

        if currentGame.requiresDUPR {
            duprRequirementCard
        }

        if canViewAttendees {
            adminPlayersSection
        }

        if let club = clubForGame {
            clubCancellationPolicyCard(club: club)
        }

        if let fee = currentGame.feeAmount, fee > 0 {
            priceSummarySection(fee: fee)
        }

        if let err = paymentErrorMessage, !err.isEmpty {
            inlineBanner(err, color: Brand.errorRed)
        }
        if let info = appState.bookingInfoMessage, !info.isEmpty {
            inlineBanner(info, color: Brand.pineTeal)
        }
        if let err = appState.bookingsErrorMessage, !err.isEmpty {
            inlineBanner(AppCopy.friendlyError(err), color: Brand.errorRed)
        }
    }

    private var trimmedUserInfo: String {
        currentGame.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var shouldShowAboutSection: Bool {
        !trimmedUserInfo.isEmpty || hasDisplayableFormat
    }

    /// Persistent right-side booking panel for iPad. Wraps the same
    /// `footerCTAArea` used by `stickyFooter` on iPhone — same booking
    /// states, same payment flow, no duplicated logic. The panel sits
    /// below the hero so the painted HeroSurface above it stays intact.
    private var iPadBookingSidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Text("Book this game")
                        .font(.headline)
                        .foregroundStyle(Brand.primaryText)
                    Spacer(minLength: 0)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Brand.secondaryText)
                            .frame(width: 30, height: 30)
                            .background(Brand.secondarySurface, in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                footerCTAArea
            }
            .padding(16)
            .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Brand.softOutline, lineWidth: 1)
            )
            // Subtle elevation reads as "anchored deliberately" rather
            // than "floating in empty space". Soft + small offset keeps
            // it premium without competing with the hero's vignette.
            .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 4)
            // Asymmetric horizontal padding "docks" the card to the right
            // edge — 20pt leading separates it from the left scroll
            // column, 12pt trailing pulls it close to the screen edge so
            // it reads as a structural rail rather than a floating card.
            .padding(.leading, 20)
            .padding(.trailing, 12)
            // Lower the panel another step (~90pt vs heroHeight) so its
            // top edge sits at the metadata info-grid row in the left
            // column, not the tags row. Reads as anchored to the content
            // hierarchy rather than the hero. `safeAreaTopPad` cancels
            // the status-bar inset since the hero ignores safe area; the
            // floor (310) keeps the panel visible if the safe-area
            // lookup ever returns 0.
            .padding(.top, max(Self.heroHeight - safeAreaTopPad + 90, 310))
            .padding(.bottom, 24)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var footerCTAArea: some View {
        let state = currentBookingState
        let isRequesting = appState.isRequestingBooking(for: game)
        let isBusy = isRequesting || isPreparingPayment || isShowingPaymentSheet || isConfirmingPayment

        if currentGame.status == "cancelled" {
            Text("This game is cancelled")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Brand.secondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

        } else if case .confirmed = state {
            let hasCalendarExport = appState.hasCalendarExport(for: game)
            let isExporting = appState.isExportingCalendar(for: game)
            Button {
                Task { await appState.toggleCalendarExport(for: game) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: hasCalendarExport ? "calendar.badge.checkmark" : "calendar.badge.plus")
                        .font(.system(size: 14, weight: .semibold))
                    Text(hasCalendarExport ? "In Calendar" : "Add to Calendar")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .foregroundStyle(Brand.primaryText)
                .background(Brand.accentGreen, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(isExporting)
            .buttonStyle(.plain)

        } else if case let .waitlisted(pos) = state {
            Text(pos.map { "Waitlisted — #\($0) in queue" } ?? "On the Waitlist")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Brand.spicyOrange)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Brand.spicyOrange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Brand.spicyOrange.opacity(0.3), lineWidth: 1))

        } else if case .pendingPayment = state, let booking = appState.existingBooking(for: game) {
            if booking.hasActiveHold {
                VStack(spacing: 4) {
                    Button {
                        guard let fee = currentGame.feeAmount, fee > 0 else { return }
                        isPendingPaymentCompletion = true
                        pendingBookingIDForConfirm = booking.id
                        Task { await preparePaymentSheet(fee: fee, currency: currentGame.feeCurrency ?? "aud") }
                    } label: {
                        HStack(spacing: 8) {
                            if isPreparingPayment { ProgressView().tint(.white) }
                            Text(isPreparingPayment ? "Please wait…" : "Complete Booking →")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundStyle(.white)
                        .background(Brand.spicyOrange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(isPreparingPayment)
                    .buttonStyle(.plain)
                    if !holdCountdown.isEmpty {
                        Text(holdCountdown)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Brand.spicyOrange)
                    }
                }
            } else {
                Button { Task { await appState.refreshBookings(silent: true) } } label: {
                    Text("Hold expired — tap to refresh")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Brand.secondaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }

        } else if currentGame.isScheduled && !currentGame.startsInPast {
            // Delayed-publish: bookings open at publish_at. Server-side gates in
            // book_game() and create-payment-intent enforce this; the disabled
            // CTA + caption surface the same rule in the UI so the user sees
            // why their action is blocked without having to attempt it first.
            VStack(spacing: 6) {
                Text("Bookings open soon")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.secondaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                if let pa = currentGame.publishAt {
                    Text("Publishes \(Self.scheduledPublishFmt.string(from: pa))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.secondaryText)
                }
            }

        } else if state.canBook && !currentGame.startsInPast {
            let enabled = canBookGameByClubMembership && !clubPaymentBlocked
            Button {
                handlePrimaryBookingTap(state: state)
            } label: {
                HStack(spacing: 8) {
                    if isBusy { ProgressView().tint(Brand.primaryText) }
                    let label: String = {
                        if isBusy { return "Please wait…" }
                        if isGameFull { return "Join Waitlist →" }
                        return "Confirm booking →"
                    }()
                    Text(label)
                        .font(.system(size: 16, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .foregroundStyle(Brand.primaryText)
                .background(
                    enabled ? Brand.accentGreen : Brand.secondarySurface,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            .disabled(isBusy || !enabled)
            .buttonStyle(.plain)
        }
    }

    private func handlePaymentCompletion(_ result: PaymentSheetResult) {
        switch result {
        case .completed:
            let piID = pendingStripePaymentIntentID
            let feeCents = pendingPlatformFeeCents
            let payoutCents = pendingClubPayoutCents
            let credits = pendingCreditsApplied
            let isDeferred = isPendingPaymentCompletion
            let deferredBookingID = pendingBookingIDForConfirm
            pendingStripePaymentIntentID = nil
            pendingPlatformFeeCents = nil
            pendingClubPayoutCents = nil
            pendingCreditsApplied = nil
            isPendingPaymentCompletion = false
            pendingBookingIDForConfirm = nil
            isConfirmingPayment = true
            Task {
                if isDeferred, let bookingID = deferredBookingID {
                    await appState.confirmPendingBooking(
                        bookingID: bookingID,
                        stripePaymentIntentID: piID,
                        platformFeeCents: feeCents,
                        clubPayoutCents: payoutCents,
                        creditsAppliedCents: credits,
                        clubID: game.clubID
                    )
                } else {
                    await appState.requestBooking(
                        for: game,
                        stripePaymentIntentID: piID,
                        platformFeeCents: feeCents,
                        clubPayoutCents: payoutCents,
                        creditsAppliedCents: credits
                    )
                }
                isConfirmingPayment = false
            }
        case .canceled:
            let bookingIDToRelease = pendingBookingIDForConfirm
            pendingStripePaymentIntentID = nil
            pendingPlatformFeeCents = nil
            pendingClubPayoutCents = nil
            pendingCreditsApplied = nil
            isPendingPaymentCompletion = false
            pendingBookingIDForConfirm = nil
            if let bookingID = bookingIDToRelease {
                Task { await appState.releasePendingPaymentBooking(bookingID: bookingID, game: game) }
            }
        case .failed(let error):
            pendingStripePaymentIntentID = nil
            pendingPlatformFeeCents = nil
            pendingClubPayoutCents = nil
            pendingCreditsApplied = nil
            isPendingPaymentCompletion = false
            pendingBookingIDForConfirm = nil
            paymentErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Booking Success Sheet

    private var bookingSuccessSheet: some View {
        let venueName = resolvedVenueForGame?.venueName ?? currentGame.venueName
        let dateTimeText = "\(Self.heroDateFmt.string(from: currentGame.dateTime)) · \(Self.heroTimeFmt.string(from: currentGame.dateTime))"
        return BookingSuccessSheetContent(
            title: currentGame.title,
            dateTimeText: dateTimeText,
            venueText: venueName,
            onAddToCalendar: {
                Task { await appState.toggleCalendarExport(for: game) }
                showBookingSuccess = false
            },
            onDone: { showBookingSuccess = false }
        )
    }

    // MARK: - Inline Banner

    private func inlineBanner(_ message: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 14))
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Tag Helpers

    private func compactSkillLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "beginner":     return "2.0 – 3.0"
        case "intermediate": return "3.0 – 4.0"
        case "advanced":     return "4.0+"
        case "all", "":      return "All Levels"
        default:             return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func compactFormatLabel(_ format: String, type: String) -> String {
        let fmt: String
        switch format.lowercased() {
        case "open_play", "": fmt = "Open play"
        case "round_robin":   fmt = "Round-robin"
        case "king_of_court":           fmt = "King of Court"
        case "random":        fmt = "Random"
        default:              fmt = format.replacingOccurrences(of: "_", with: " ").capitalized
        }
        let typeLabel: String
        switch type.lowercased() {
        case "doubles": typeLabel = "doubles"
        case "singles": typeLabel = "singles"
        case "mixed":   typeLabel = "mixed"
        default:        typeLabel = ""
        }
        if typeLabel.isEmpty { return fmt }
        return "\(fmt) \(typeLabel)"
    }

    // MARK: - Primary CTA Section (preserved for legacy callers)

    private var primaryCTASection: some View {
        EmptyView()
    }

    // Inline "Add to Calendar" / "Set Reminder" buttons shown in booked state
    private var bookedInlineActions: some View {
        let hasCalendarExport = appState.hasCalendarExport(for: game)
        let hasReminder = appState.hasReminder(for: game)
        let isExportingCalendar = appState.isExportingCalendar(for: game)
        return HStack(spacing: 12) {
            Button {
                Task { await appState.toggleCalendarExport(for: game) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: hasCalendarExport ? "calendar.badge.minus" : "calendar.badge.plus")
                        .font(.system(size: 13))
                    Text(hasCalendarExport ? "Remove from Calendar" : "Add to Calendar")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .foregroundStyle(Brand.secondaryText)
                .background(Brand.secondarySurface.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Brand.softOutline.opacity(0.6), lineWidth: 0.75)
                )
            }
            .disabled(isExportingCalendar)
            .buttonStyle(.plain)

            Button {
                Task { await appState.toggleReminder(for: game) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: hasReminder ? "bell.slash" : "bell.badge")
                        .font(.system(size: 13))
                    Text(hasReminder ? "Remove Reminder" : "Set Reminder")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .foregroundStyle(Brand.secondaryText)
                .background(Brand.secondarySurface.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Brand.softOutline.opacity(0.6), lineWidth: 0.75)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var creditToggleRow: some View {
        let balanceDollars = String(format: "$%.2f", Double(appState.creditBalance(for: game.clubID)) / 100)
        return HStack(spacing: 10) {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 14))
                .foregroundStyle(Brand.pineTeal)
            VStack(alignment: .leading, spacing: 1) {
                Text("Use credits (\(balanceDollars) available)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.primaryText)
            }
            Spacer()
            Toggle("", isOn: $useCredits)
                .labelsHidden()
                .tint(Brand.pineTeal)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Brand.softOutline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var paymentBlockedCTAView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Payment Unavailable")
                    .font(.system(size: 16, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(.white)
            .background(Brand.ink.opacity(0.25), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("Bookings for this game are currently unavailable.")
                .font(.footnote)
                .foregroundStyle(Brand.mutedText)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var ctaButton: some View {
        let state = currentBookingState
        let isRequesting = appState.isRequestingBooking(for: game)
        let isCancelling = appState.isCancellingBooking(for: game)
        let enabled = state.canBook && canBookGameByClubMembership && !currentGame.startsInPast

        if (state.canBook || isPreparingPayment || isShowingPaymentSheet || isConfirmingPayment) && !currentGame.startsInPast {
            // "Book Your Spot • $15.00" or "Join Waitlist"
            // isPreparingPayment/isShowingPaymentSheet/isConfirmingPayment keep this block
            // visible through the full payment flow so the pendingPayment (orange) UI never
            // flashes during a fresh booking.
            let isBusy = isRequesting || isPreparingPayment || isShowingPaymentSheet || isConfirmingPayment
            Button {
                handlePrimaryBookingTap(state: state)
            } label: {
                HStack(spacing: 8) {
                    if isBusy { ProgressView().tint(.white) }
                    if isGameFull {
                        Text(isBusy ? "Please wait..." : "Join Waitlist")
                            .font(.system(size: 16, weight: .bold))
                    } else {
                        let priceLabel: String = {
                            if let fee = currentGame.feeAmount, fee > 0 {
                                let totalCents = Int((fee * 100).rounded())
                                let creditsToApply = useCredits ? min(appState.creditBalance(for: game.clubID), totalCents) : 0
                                let netCents = totalCents - creditsToApply
                                if netCents == 0 {
                                    return " • Free (credits)"
                                }
                                return " • \(String(format: "$%.2f", Double(netCents) / 100))"
                            }
                            return ""
                        }()
                        Text(isBusy ? "Please wait..." : "Book Your Spot\(priceLabel)")
                            .font(.system(size: 16, weight: .bold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .foregroundStyle(.white)
                .background(
                    enabled ? Brand.ink : Brand.ink.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            .disabled(isBusy || isCancelling || !enabled)
            .buttonStyle(.plain)

        } else if case .confirmed = state {
            // Compact booked status with countdown + inline actions
            VStack(alignment: .leading, spacing: 10) {
                // Status badge row
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(hex: "80FF00"))
                        .frame(width: 7, height: 7)
                    Text("Booked")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                    if !currentGame.startsInPast, !startsInText.isEmpty {
                        Text("·")
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.mutedText.opacity(0.6))
                        Text(startsInText)
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.mutedText.opacity(0.7))
                    }
                    Spacer()
                    if isCancelling {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(hex: "80FF00").opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(hex: "80FF00").opacity(0.22), lineWidth: 1)
                )

                // Inline actions: Add to Calendar + Set Reminder
                if !currentGame.startsInPast {
                    bookedInlineActions
                }
            }

        } else if case let .waitlisted(position) = state {
            // Waitlisted state
            HStack(spacing: 10) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Brand.spicyOrange)
                Text(position.map { "Waitlist #\($0)" } ?? "On the Waitlist")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Brand.ink)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .padding(.horizontal, 16)
            .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Brand.spicyOrange.opacity(0.35), lineWidth: 1)
            )

        } else if case .pendingPayment = state, let booking = appState.existingBooking(for: game) {
            // Phase 3: promoted waitlist player — timed payment hold
            if booking.hasActiveHold {
                VStack(spacing: 8) {
                    // Credit toggle for promoted player (same as normal paid booking)
                    if let fee = currentGame.feeAmount, fee > 0, appState.creditBalance(for: game.clubID) > 0 {
                        creditToggleRow
                    }
                    // Complete Booking CTA
                    let netLabel: String = {
                        if let fee = currentGame.feeAmount, fee > 0 {
                            let totalCents = Int((fee * 100).rounded())
                            let creditsToApply = useCredits ? min(appState.creditBalance(for: game.clubID), totalCents) : 0
                            let netCents = totalCents - creditsToApply
                            return netCents == 0 ? " • Free (credits)" : " • \(String(format: "$%.2f", Double(netCents) / 100))"
                        }
                        return ""
                    }()
                    Button {
                        guard let fee = currentGame.feeAmount, fee > 0 else { return }
                        isPendingPaymentCompletion = true
                        pendingBookingIDForConfirm = booking.id
                        Task { await preparePaymentSheet(fee: fee, currency: currentGame.feeCurrency ?? "aud") }
                    } label: {
                        HStack(spacing: 8) {
                            if isPreparingPayment { ProgressView().tint(.white) }
                            Text(isPreparingPayment ? "Please wait..." : "Complete Booking\(netLabel)")
                                .font(.system(size: 16, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundStyle(.white)
                        .background(Brand.spicyOrange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(isPreparingPayment)
                    .buttonStyle(.plain)
                    // Countdown
                    if !holdCountdown.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.caption)
                            Text(holdCountdown)
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                        }
                        .foregroundStyle(Brand.spicyOrange)
                    }
                }
            } else {
                // Hold has expired client-side — show passive state with refresh prompt
                HStack(spacing: 10) {
                    Image(systemName: "clock.badge.xmark")
                        .font(.system(size: 16))
                        .foregroundStyle(Brand.mutedText)
                    Text("Spot hold expired")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.secondaryText)
                    Spacer()
                    Button("Refresh") {
                        Task { await appState.refreshBookings(silent: true) }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.pineTeal)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .padding(.horizontal, 16)
                .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Brand.softOutline, lineWidth: 1)
                )
            }
        }
    }

    private func updateHoldCountdown() {
        guard let booking = appState.existingBooking(for: game),
              let expires = booking.holdExpiresAt,
              expires > Date() else {
            holdCountdown = ""
            return
        }
        let remaining = Int(expires.timeIntervalSinceNow)
        let minutes = remaining / 60
        let seconds = remaining % 60
        holdCountdown = minutes > 0
            ? "\(minutes)m \(seconds)s remaining"
            : "\(seconds)s remaining"
    }

    // MARK: - Menus (toolbar)

    // Player-only actions: booking management, calendar, reminder.
    private var moreMenu: some View {
        let hasReminder = appState.hasReminder(for: game)
        let hasCalendarExport = appState.hasCalendarExport(for: game)
        let isExportingCalendar = appState.isExportingCalendar(for: game)
        let isCancelling = appState.isCancellingBooking(for: game)
        let state = currentBookingState

        return Menu {
            if state.canCancel {
                Button {
                    Task { await appState.toggleCalendarExport(for: game) }
                } label: {
                    Label(
                        hasCalendarExport ? "Remove from Calendar" : "Add to Calendar",
                        systemImage: hasCalendarExport ? "calendar.badge.minus" : "calendar.badge.plus"
                    )
                }
                .disabled(isExportingCalendar)

                if !currentGame.startsInPast {
                    Button {
                        Task { await appState.toggleReminder(for: game) }
                    } label: {
                        Label(
                            hasReminder ? "Remove Reminder" : "Set Reminder",
                            systemImage: hasReminder ? "bell.slash" : "bell.badge"
                        )
                    }
                }

                if !currentGame.startsInPast {
                    Divider()

                    Button(role: .destructive) {
                        showCancelBookingConfirmation = true
                    } label: {
                        Label(
                            isCancelling ? "Cancelling…" : "Cancel Booking",
                            systemImage: "xmark.circle"
                        )
                    }
                    .disabled(isCancelling)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Brand.primaryText)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    // Admin-only actions: game lifecycle and player management.
    // Only rendered when isClubAdminUser — see toolbar.
    private var adminMenu: some View {
        let isCancellingGame = appState.isCancellingGame(game)

        return Menu {
            if !currentGame.startsInPast {
                Button {
                    isEditingGame = true
                } label: {
                    Label("Edit Game", systemImage: "pencil")
                }
            }
            if currentGame.status != "cancelled" {
                Divider()
                Button(role: .destructive) {
                    showCancelGameConfirmation = true
                } label: {
                    Label(
                        isCancellingGame ? "Cancelling…" : "Cancel Game",
                        systemImage: "xmark.circle"
                    )
                }
                .disabled(isCancellingGame)
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Brand.primaryText)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    // MARK: - Players Card

    private var playersCard: some View {
        let isOverCapacity = !waitlistedAttendees.isEmpty || !pendingPaymentAttendees.isEmpty
        let spotsRemaining = max(0, currentGame.maxSpots - confirmedAttendees.count)
        let waitingCount = waitlistedAttendees.count + pendingPaymentAttendees.count
        let isLoading = appState.isLoadingAttendees(for: game)

        return VStack(alignment: .leading, spacing: 0) {
            // ── Collapsed view: always visible ────────────────────────
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    isPlayersExpanded.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    // Avatar row (up to 6 large circles)
                    if isLoading {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if confirmedAttendees.isEmpty {
                        Text("No players registered yet.")
                            .font(.subheadline)
                            .foregroundStyle(Brand.mutedText)
                    } else {
                        largeAvatarRow
                    }

                    // Waitlist summary + chevron (capacity moved to section header above)
                    HStack {
                        if !isLoading && isOverCapacity {
                            Text("\(waitingCount) waiting")
                                .font(.system(size: 13))
                                .foregroundStyle(Brand.spicyOrange.opacity(0.85))
                        }
                        Spacer()
                        Image(systemName: isPlayersExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Brand.mutedText.opacity(0.7))
                    }
                }
                .padding(16)
            }
            .buttonStyle(.plain)

            // ── Expanded: full attendee list (admin + detail view) ────
            if isPlayersExpanded {
                Divider().overlay(Color(hex: "E5E5E5"))

                // Confirmed section
                HStack {
                    Text("BOOKED")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Brand.mutedText)
                        .tracking(0.6)
                    Spacer()
                    Text("\(confirmedAttendees.count) of \(currentGame.maxSpots)")
                        .font(.caption)
                        .foregroundStyle(Brand.mutedText)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)

                if confirmedAttendees.isEmpty {
                    Text("No confirmed players yet.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.mutedText)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                } else {
                    ForEach(Array(confirmedAttendees.enumerated()), id: \.element.id) { index, attendee in
                        attendeeRow(attendee)
                        if index < confirmedAttendees.count - 1 {
                            Divider().overlay(Color(hex: "E5E5E5")).padding(.leading, 64)
                        }
                    }
                }

                // Waitlist section
                if !waitlistedAttendees.isEmpty || !pendingPaymentAttendees.isEmpty {
                    Divider().overlay(Color(hex: "E5E5E5")).padding(.top, 4)

                    HStack {
                        Text("WAITLIST")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Brand.spicyOrange)
                            .tracking(0.6)
                        Spacer()
                        Text("\(waitingCount) waiting")
                            .font(.caption)
                            .foregroundStyle(Brand.spicyOrange)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 6)

                    // Promoted players awaiting payment — shown first, above queued waitlisters
                    ForEach(Array(pendingPaymentAttendees.enumerated()), id: \.element.id) { index, attendee in
                        attendeeRow(attendee)
                        Divider().overlay(Color(hex: "E5E5E5")).padding(.leading, 64)
                    }

                    ForEach(Array(waitlistedAttendees.enumerated()), id: \.element.id) { index, attendee in
                        attendeeRow(attendee, displayPosition: index + 1)
                        if index < waitlistedAttendees.count - 1 {
                            Divider().overlay(Color(hex: "E5E5E5")).padding(.leading, 64)
                        }
                    }
                }

                // Status messages
                if let info = appState.gameOwnerInfoByID[game.id], !info.isEmpty {
                    Text(info)
                        .font(.footnote)
                        .foregroundStyle(Brand.pineTeal)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                if let error = appState.gameOwnerErrorByID[game.id], !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Brand.spicyOrange)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                }

                HStack {
                    Spacer()
                    Button {
                        Task { await appState.refreshAttendees(for: game) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(Brand.mutedText)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isOverCapacity ? Brand.spicyOrange.opacity(0.3) : Brand.softOutline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        .clipped()
    }

    /// Large avatar circles (44pt) shown in the collapsed players card, up to 4.
    /// Capped at 4 (not 6) so max 5 items (4 circles + overflow badge) = 5×44 + 4×8 = 252pt,
    /// which fits inside the card on all devices including iPhone SE (303pt available).
    private var largeAvatarRow: some View {
        let preview = Array(confirmedAttendees.prefix(4))
        let overflow = max(0, confirmedAttendees.count - 4)
        return HStack(spacing: 7) {
            ForEach(preview, id: \.id) { attendee in
                // Avatar colour is identity data. Do not derive per-view.
                Circle()
                    .fill(AvatarGradients.resolveGradient(forKey: attendee.avatarColorKey))
                    .overlay(
                        Text(initials(attendee.userName))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .frame(width: 38, height: 38)
            }
            if overflow > 0 {
                Circle()
                    .fill(Brand.secondarySurface.opacity(0.7))
                    .overlay(
                        Text("+\(overflow)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Brand.mutedText)
                    )
                    .frame(width: 38, height: 38)
            }
        }
    }

    // MARK: - Attendee Row

    private func attendeeRow(_ attendee: GameAttendee, displayPosition: Int? = nil) -> some View {
        let isChecked = appState.isCheckedIn(bookingID: attendee.booking.id)
        let waitlisted = isWaitlisted(attendee.booking.state)
        let isPendingPayment: Bool = {
            if case .pendingPayment = attendee.booking.state { return true }
            return false
        }()

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shortName(attendee.userName))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)
                if let doubles = attendee.duprRating {
                    Text("DUPR \(String(format: "%.3f", doubles))")
                        .font(.caption)
                        .foregroundStyle(Brand.mutedText)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                if isPendingPayment {
                    attendeeBadge("Awaiting Payment",
                                  fill: Brand.spicyOrange.opacity(0.1),
                                  text: Brand.spicyOrange)
                } else if waitlisted {
                    let label = displayPosition.map { "#\($0)" } ?? "Waitlisted"
                    attendeeBadge(label, fill: Brand.secondarySurface, text: Brand.mutedText)
                } else if isChecked {
                    attendeeBadge("Checked In", fill: Color(hex: "80FF00"), text: .black)
                } else if case .confirmed = attendee.booking.state {
                    attendeeBadge("Confirmed", fill: Brand.primaryText, text: .white)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func attendeeBadge(_ title: String, fill: Color, text: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(fill, in: Capsule())
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline.weight(.semibold))
            .foregroundStyle(Brand.ink)
    }

    // MARK: - Venue + Info Card (unified)

    /// Single card: venue name + address at top, divider, then Duration / Price / Spots rows.
    private var venueInfoCard: some View {
        let venue = resolvedVenueForGame
        let address = venue.flatMap { LocationService.formattedAddress(for: $0) }
        let mapURL: URL? = {
            guard let v = venue else { return nil }
            if let lat = v.latitude, let lng = v.longitude {
                return MapNavigationURL.directions(
                    to: CLLocationCoordinate2D(latitude: lat, longitude: lng)
                )
            }
            let query = gameLocationNavigationQuery
            return query.isEmpty ? nil : MapNavigationURL.directions(to: query)
        }()

        return VStack(alignment: .leading, spacing: 0) {
            // ── Venue header ────────────────────────────────────────
            if let v = venue {
                Group {
                    if let url = mapURL {
                        Button { openURL(url) } label: {
                            venueHeaderRow(name: v.venueName, address: address, tappable: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        venueHeaderRow(name: v.venueName, address: address, tappable: false)
                    }
                }
                Divider().overlay(Color(hex: "E5E5E5"))

                // ── Map preview ───────────────────────────────────────
                if let lat = v.latitude, let lng = v.longitude {
                    let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                    Button {
                        if let url = mapURL { openURL(url) }
                    } label: {
                        Map(position: .constant(MapCameraPosition.region(
                            MKCoordinateRegion(center: coord, latitudinalMeters: 500, longitudinalMeters: 500)
                        ))) {
                            Marker("", coordinate: coord)
                        }
                        .frame(height: 82)
                        .allowsHitTesting(false)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Color(hex: "E5E5E5"))
                }
            }

            // ── Info rows ─────────────────────────────────────────────
            // Duration + Price combined into one row
            durationPriceRow
            Divider().overlay(Color(hex: "E5E5E5")).padding(.leading, 52)
            // Capacity progress row
            capacityProgressRow
        }
        .frame(maxWidth: .infinity)
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Brand.softOutline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }

    private func venueHeaderRow(name: String, address: String?, tappable: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 20))
                .foregroundStyle(Brand.mutedText.opacity(0.8))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(2)
                if let address {
                    Text(address)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.mutedText.opacity(0.8))
                        .lineLimit(2)
                }
            }

            Spacer()

            if tappable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.mutedText)
                    .padding(.top, 3)
            }
        }
        .padding(16)
    }

    // Capacity progress row — replaces plain "Spots Available" text
    private var capacityProgressRow: some View {
        let liveConfirmed = !confirmedAttendees.isEmpty
            ? confirmedAttendees.count
            : (currentGame.confirmedCount ?? 0)
        return HStack(spacing: 14) {
            Image(systemName: "person.2")
                .font(.system(size: 15))
                .foregroundStyle(Brand.mutedText)
                .frame(width: 20)
            CapacityProgressBar(
                confirmed: liveConfirmed,
                maxSpots: currentGame.maxSpots,
                height: 5
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // Combined Duration + Price row
    private var durationPriceRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock")
                .font(.system(size: 15))
                .foregroundStyle(Brand.mutedText)
                .frame(width: 20)
            Text(durationText)
                .font(.system(size: 15))
                .foregroundStyle(Brand.ink)
            Spacer()
            Text(priceText)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Brand.mutedText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func detailInfoRow(icon: String, label: String, value: String, valueColor: Color = Brand.mutedText) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Brand.mutedText)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(Brand.ink)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(valueColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - DUPR Requirement Card (left green accent)

    private var duprRequirementCard: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left accent bar — clipped to card corners via clipShape below
            Rectangle()
                .fill(Brand.spicyOrange)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(Brand.spicyOrange)
                    Text("DUPR Rating Required")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("This is a DUPR-rated game. DUPR (Dynamic Universal Pickleball Rating) is a global rating system that tracks your skill level based on match results, no matter where you play.")
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Getting started")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Brand.ink)
                        Text({
                            var str = AttributedString("To participate and have your results recorded, you'll need a free DUPR account. Create one in minutes at https://www.dupr.com and start tracking your rating.")
                            if let range = str.range(of: "https://www.dupr.com") {
                                str[range].link = URL(string: "https://www.dupr.com")
                            }
                            return str
                        }())
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(Brand.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Brand.softOutline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }

    // MARK: - About This Event Card

    @ViewBuilder
    private var aboutEventCard: some View {
        let formatName = prettify(currentGame.gameFormat)
        let formatDesc = formatDescription(currentGame.gameFormat)
        let userInfo   = currentGame.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        VStack(alignment: .leading, spacing: 14) {
            // Format block — only shown for non-open-play formats
            if hasDisplayableFormat {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text("Format")
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.mutedText)
                        Text(formatName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Brand.ink)
                    }
                    if let formatDesc {
                        Text(formatDesc)
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.mutedText)
                            .lineSpacing(2.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // Skill Level block
            let skill = skillLevelLabel(currentGame.skillLevel)
            if !skill.isEmpty {
                HStack(spacing: 4) {
                    Text("Skill Level")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.mutedText)
                    Text(skill)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                }
            }

            // Divider between format/skill and user info — only when both are present
            if (hasDisplayableFormat || !skill.isEmpty) && !userInfo.isEmpty {
                Divider().overlay(Color(hex: "E5E5E5"))
            }

            // User-entered Information
            if !userInfo.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Information")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.mutedText)
                    Text(userInfo)
                        .font(.system(size: 14))
                        .foregroundStyle(Brand.ink.opacity(0.85))
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.secondarySurface.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Brand.softOutline.opacity(0.7), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.03), radius: 4, y: 1)
    }

    /// Body text shown inside the expandable "Club Cancellation Policy" card.
    /// Display-only — the actual refund eligibility is decided server-side by
    /// `cancel_booking_with_credit` and the deferred-credit trigger.
    private func cancellationPolicyBody(for club: Club) -> String {
        switch club.cancellationPolicyType {
        case .managed:
            return "Cancel at least \(club.cancellationCutoffHours) hours before the game to receive club credit. If you cancel after that, you’ll only receive credit if your spot is filled by another confirmed paid player."
        case .clubManaged:
            let manual = (club.cancellationPolicy ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !manual.isEmpty { return manual }
            return "This club manages cancellations manually. Please contact the club for their cancellation policy."
        }
    }

    @ViewBuilder
    private func clubCancellationPolicyCard(club: Club) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    cancellationPolicyExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("CLUB CANCELLATION POLICY")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Brand.mutedText)
                        .tracking(0.8)
                    Spacer()
                    Image(systemName: cancellationPolicyExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Brand.mutedText)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if cancellationPolicyExpanded {
                Divider()
                    .padding(.horizontal, 16)
                Text(cancellationPolicyBody(for: club))
                    .font(.system(size: 14))
                    .foregroundStyle(Brand.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
            }
        }
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Brand.softOutline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }

    // MARK: - Cancellation Credit Sheet

    /// Routes through the shared `CancellationResultSheet` so the user sees the
    /// same explanatory copy regardless of where the cancellation originated
    /// (this view OR `BookingsListView`). Outcome branching lives in the shared
    /// view, not here.
    @ViewBuilder
    private var cancellationCreditSheet: some View {
        if let result = displayedCancellationCredit {
            CancellationResultSheet(
                result: result,
                club: appState.clubs.first(where: { $0.id == result.clubID }),
                onDismiss: { showCancellationCreditSheet = false }
            )
        }
    }

    // MARK: - DUPR Booking Sheet

    private var duprBookingSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This game requires a verified DUPR profile before booking.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        if let appURL = URL(string: "dupr://"), UIApplication.shared.canOpenURL(appURL) {
                            openURL(appURL)
                        } else if let webURL = URL(string: "https://mydupr.com") {
                            openURL(webURL)
                        }
                    } label: {
                        Label("Open DUPR", systemImage: "arrow.up.right.square")
                            .font(.subheadline.weight(.medium))
                    }
                } header: { Text("DUPR Profile") }

                Section {
                    TextField("DUPR ID (e.g. XKXR74)", text: $duprIDDraft)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: { Text("DUPR ID") } footer: {
                    Text("6-character alphanumeric code found in your DUPR profile.").font(.caption)
                }

                Section {
                    HStack {
                        Text("DUPR Rating")
                        Spacer()
                        TextField("e.g. 3.524", text: $duprRatingText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                    }
                } header: { Text("DUPR Rating") } footer: {
                    Text("Your DUPR rating (2.000–8.000), exactly 3 decimal places.").font(.caption)
                }

                Section {
                    Toggle("I confirm this is my DUPR profile.", isOn: $duprBookingConfirmed)
                }

                if let error = duprSheetErrorMessage, !error.isEmpty {
                    Section { Text(error).foregroundStyle(Brand.errorRed) }
                }
            }
            .navigationTitle("Confirm DUPR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showDUPRBookingSheet = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await confirmDUPRAndBook() }
                    } label: {
                        if appState.isRequestingBooking(for: game) {
                            ProgressView()
                        } else {
                            Text("Confirm").fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        duprIDDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        duprRatingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        !duprBookingConfirmed ||
                        appState.isRequestingBooking(for: game)
                    )
                }
            }
            .onAppear {
                duprIDDraft = appState.duprID ?? ""
                duprRatingText = appState.duprDoublesRating.map { String(format: "%.3f", $0) } ?? ""
                duprBookingConfirmed = false
                duprSheetErrorMessage = nil
            }
        }
    }

    // MARK: - DUPR Recovery Sheet

    /// In-flow recovery sheet shown when a booking attempt failed because the
    /// user lacks a valid DUPR ID. Single-field, server-min length validation,
    /// no auto-book — the user dismisses, then re-taps Book so the
    /// server-authoritative `book_game` gate runs unchanged.
    private var duprRecoverySheet: some View {
        NavigationStack {
            VStack(spacing: Brand.Spacing.s24) {
                ZStack {
                    Circle()
                        .fill(Brand.pineTeal.opacity(0.12))
                        .frame(width: 72, height: 72)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(Brand.pineTeal)
                }
                .padding(.top, Brand.Spacing.s8)

                VStack(spacing: Brand.Spacing.s8) {
                    Text("DUPR ID required")
                        .font(Brand.Typography.title)
                        .foregroundStyle(Brand.primaryText)
                    Text("This game requires a DUPR ID. Add yours to book — you can update it any time in your profile.")
                        .font(Brand.Typography.body)
                        .foregroundStyle(Brand.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: Brand.Spacing.s8) {
                    Text("DUPR ID")
                        .font(Brand.Typography.caption)
                        .foregroundStyle(Brand.secondaryText)
                    HStack(spacing: Brand.Spacing.s12) {
                        Image(systemName: "person.text.rectangle")
                            .foregroundStyle(Brand.pineTeal)
                        TextField("e.g. XKXR74", text: $duprRecoveryDraft)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit {
                                guard isDUPRRecoveryValid && !isSavingDUPRRecovery else { return }
                                Task { await saveDUPRRecovery() }
                            }
                    }
                    .padding(Brand.Spacing.s12)
                    .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: Brand.Radius.r14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Brand.Radius.r14, style: .continuous)
                            .strokeBorder(Brand.softOutline, lineWidth: 1)
                    )
                    if let error = duprRecoveryError, !error.isEmpty {
                        HStack(spacing: Brand.Spacing.s4) {
                            Image(systemName: "exclamationmark.circle")
                            Text(error)
                        }
                        .font(.footnote)
                        .foregroundStyle(Brand.errorRed)
                    }
                }

                Spacer(minLength: 0)

                OnboardingPrimaryButton(
                    "Save DUPR ID",
                    isLoading: isSavingDUPRRecovery,
                    isDisabled: !isDUPRRecoveryValid
                ) {
                    Task { await saveDUPRRecovery() }
                }
            }
            .onboardingContentShell()
            .navigationTitle("DUPR ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showDUPRRecoverySheet = false }
                }
            }
        }
        .presentationDetents([.height(420)])
        .onboardingSheetShell()
    }

    private var isDUPRRecoveryValid: Bool {
        duprRecoveryDraft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 6
    }

    private func saveDUPRRecovery() async {
        guard isDUPRRecoveryValid else { return }
        isSavingDUPRRecovery = true
        defer { isSavingDUPRRecovery = false }
        let trimmed = duprRecoveryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = appState.saveCurrentUserDUPRID(trimmed) {
            duprRecoveryError = error
            return
        }
        duprRecoveryError = nil
        // Clear the dead-end banner so the user can retry Book without stale guidance.
        appState.bookingsErrorMessage = nil
        showDUPRRecoverySheet = false
    }

    // MARK: - Helper Functions

    /// True when the game has a format worth surfacing in "About This Event"
    /// (i.e. anything other than Open Play, which is the implicit default).
    /// True when the game format has a description to display.
    private var hasDisplayableFormat: Bool {
        formatDescription(currentGame.gameFormat) != nil
    }

    /// Built-in description for each game format, shown in "About This Event".
    private func formatDescription(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "open_play":
            return "Rock up and play! Players organise their own groups, or use the paddle rack system — put your paddle in the queue and the next four players up take the next free court. Sometimes the winning team stays on. Fast, social, and fun."
        case "round_robin":
            return "All players rotate courts and partners each round, so everyone plays with and against everyone else."
        case "king_of_court":
            return "Winners stay on the feature court and challengers rotate in each round. Last team standing on court 1 is crowned King of the Court."
        case "dupr_king_of_court":
            return "DUPR-rated King of the Court format. Points are tracked each round and submitted to your DUPR profile after the game."
        case "random":
            return "Partners and courts are randomly assigned each round for a relaxed, social session."
        default:
            return nil
        }
    }

    private func prettify(_ raw: String) -> String {
        switch raw.lowercased() {
        case "king_of_court":           return "King of the Court"
        case "dupr_king_of_court":      return "DUPR King of the Court"
        case "round_robin":             return "Round Robin"
        case "open_play":               return "Open Play"
        case "beginner":                return "Beginner"
        case "intermediate":            return "Intermediate"
        case "advanced":                return "Advanced"
        case "all", "":                 return ""
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func skillLevelLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "all":          return "All Levels"
        case "beginner":     return "Beginner (2.0 – <3.0)"
        case "intermediate": return "Intermediate (3.0 – <4.0)"
        case "advanced":     return "Advanced (4.0+)"
        case "":             return ""
        default:             return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func initials(_ name: String) -> String {
        let pieces = name.split(separator: " ")
        let chars = pieces.prefix(2).compactMap(\.first)
        return chars.isEmpty ? "M" : String(chars)
    }

    /// "Brayden Kelly" → "Brayden. K"  |  single-word names returned as-is
    private func shortName(_ name: String) -> String {
        let pieces = name.split(separator: " ")
        guard pieces.count >= 2, let lastInitial = pieces.last?.first else { return name }
        return "\(pieces[0]). \(lastInitial)"
    }

    private func isWaitlisted(_ state: BookingState) -> Bool {
        if case .waitlisted = state { return true }
        return false
    }

    private func handlePrimaryBookingTap(state: BookingState) {
        if currentGame.requiresDUPR && state.canBook && canBookGameByClubMembership {
            duprIDDraft = appState.duprID ?? ""
            duprRatingText = appState.duprDoublesRating.map { String(format: "%.3f", $0) } ?? ""
            duprBookingConfirmed = false
            duprSheetErrorMessage = nil
            showDUPRBookingSheet = true
            return
        }

        // Paid game with spots available — collect payment before confirming booking.
        // isGameFull guard is non-negotiable: waitlisted users must NEVER pay upfront.
        if let fee = currentGame.feeAmount, fee > 0, !isGameFull {
            Task { await preparePaymentSheet(fee: fee, currency: currentGame.feeCurrency ?? "aud") }
            return
        }

        Task { await appState.requestBooking(for: game) }
    }

    private func preparePaymentSheet(fee: Double, currency: String) async {
        isPreparingPayment = true
        paymentErrorMessage = nil
        defer { isPreparingPayment = false }

        // Pre-flight: club entitlement check (defense-in-depth; server is authoritative).
        // Fetch entitlements if not yet cached so the gate is never silently skipped.
        if appState.entitlementsByClubID[game.clubID] == nil {
            await appState.fetchClubEntitlements(for: game.clubID)
        }
        if let entitlements = appState.entitlementsByClubID[game.clubID] {
            if case .blocked = FeatureGateService.canAcceptPayments(entitlements) {
                paymentErrorMessage = "Bookings for this game are currently unavailable."
                return
            }
        }

        // Refresh before calculating offset so the balance isn't stale from .task load
        await appState.refreshCreditBalance(for: game.clubID)
        let totalCents = Int((fee * 100).rounded())

        // Step 1: Calculate credit offset BEFORE creating a PaymentIntent.
        let (creditsToApply, remainingCents) = await appState.creditOffset(for: totalCents, clubID: game.clubID, applyCredits: useCredits)

        // Step 2: If credits cover the full amount, take the free booking path — no Stripe needed.
        if remainingCents == 0 {
            if isPendingPaymentCompletion, let bookingID = pendingBookingIDForConfirm {
                // Phase 3: credits fully cover a promoted waitlist booking — confirm in-place.
                isPendingPaymentCompletion = false
                pendingBookingIDForConfirm = nil
                await appState.confirmPendingBooking(
                    bookingID: bookingID,
                    stripePaymentIntentID: nil,
                    platformFeeCents: nil,
                    clubPayoutCents: nil,
                    creditsAppliedCents: creditsToApply > 0 ? creditsToApply : nil,
                    clubID: game.clubID
                )
            } else {
                await appState.requestBooking(
                    for: game,
                    creditsAppliedCents: creditsToApply > 0 ? creditsToApply : nil
                )
            }
            return
        }

        // Step 3: Reserve a booking BEFORE creating the Stripe PI so the idempotency key
        // is scoped to this specific booking (pi-{booking_id}-{amount}).  Gate 0.5 in
        // create-payment-intent finds the pending_payment booking and uses that key,
        // preventing paymentIntentInTerminalState on any future rebook by the same user.
        //
        // Skip when isPendingPaymentCompletion is already true — the caller (waitlist
        // "Complete Booking" button or a retry after PaymentSheet cancel) already holds
        // a valid pending_payment booking_id in pendingBookingIDForConfirm.
        if !isPendingPaymentCompletion {
            do {
                let reserved = try await appState.reservePaidBooking(
                    for: game,
                    creditsAppliedCents: creditsToApply > 0 ? creditsToApply : nil
                )
                if case .waitlisted = reserved.state {
                    // Game became full server-side between client check and lock acquisition.
                    // The waitlisted booking was created — refresh and surface the waitlist state.
                    await appState.refreshBookings(silent: true)
                    if let club = appState.clubs.first(where: { $0.id == game.clubID }) {
                        await appState.refreshGames(for: club)
                    }
                    appState.bookingInfoMessage = "The game just filled up. You've been added to the waitlist."
                    return
                }
                isPendingPaymentCompletion = true
                pendingBookingIDForConfirm = reserved.id
            } catch SupabaseServiceError.duplicateMembership {
                // A pending_payment booking already exists (e.g. user cancelled PaymentSheet
                // then navigated back before the hold expired).  Find it in the local cache
                // and reuse its booking_id — no new DB row needed.
                await appState.refreshBookings(silent: true)
                if let existing = appState.bookings.first(where: {
                    $0.booking.gameID == game.id && $0.booking.state == .pendingPayment
                })?.booking {
                    isPendingPaymentCompletion = true
                    pendingBookingIDForConfirm = existing.id
                } else {
                    paymentErrorMessage = "You already have a booking for this game."
                    return
                }
            } catch SupabaseServiceError.authenticationRequired {
                paymentErrorMessage = "Your session has expired. Please sign out and sign back in, then try again."
                return
            } catch SupabaseServiceError.notYetPublished {
                // Server rejected the reserve because publish_at is still in the future
                // (e.g. an admin moved publish forward after the user opened this view).
                // Refresh games so the cached publishAt updates and the scheduled-game
                // CTA renders on the next layout pass.
                paymentErrorMessage = "This game isn't open for bookings yet."
                if let club = appState.clubs.first(where: { $0.id == game.clubID }) {
                    await appState.refreshGames(for: club)
                }
                return
            } catch {
                paymentErrorMessage = "Could not reserve your spot. Please try again."
                return
            }
        }

        // Step 4: Create PaymentIntent — Gate 0.5 finds the pending_payment booking above
        // and scopes the idempotency key to pi-{booking_id}-{amount}.
        // Always use "aud" — the backend rejects any other currency.
        do {
            let result = try await appState.createPaymentIntent(
                amountCents: remainingCents,
                currency: "aud",
                clubID: game.clubID,
                metadata: [
                    "game_id": game.id.uuidString.lowercased(),
                    "game_title": currentGame.title,
                    "credits_applied": String(creditsToApply)
                ]
            )

            var config = PaymentSheet.Configuration()
            config.merchantDisplayName = "Book A Dink"
            config.applePay = .init(
                merchantId: "merchant.com.bookadink",
                merchantCountryCode: "AU"
            )

            pendingPlatformFeeCents = result.platformFeeCents > 0 ? result.platformFeeCents : nil
            pendingClubPayoutCents  = result.clubPayoutCents  > 0 ? result.clubPayoutCents  : nil
            pendingCreditsApplied   = creditsToApply          > 0 ? creditsToApply          : nil
            pendingStripePaymentIntentID = result.clientSecret.components(separatedBy: "_secret_").first
            paymentSheet = PaymentSheet(paymentIntentClientSecret: result.clientSecret, configuration: config)
            isShowingPaymentSheet = true
        } catch SupabaseServiceError.authenticationRequired {
            paymentErrorMessage = "Your session has expired. Please sign out and sign back in, then try again."
        } catch let SupabaseServiceError.httpStatus(code, message) {
            switch code {
            case 401:
                paymentErrorMessage = "Your session has expired. Please sign out and sign back in, then try again."
            case 403:
                paymentErrorMessage = "Bookings for this game are currently unavailable."
            case 409:
                isPendingPaymentCompletion = false
                pendingBookingIDForConfirm = nil
                paymentErrorMessage = message.isEmpty ? "Your spot hold has expired. Please refresh." : message
                Task { await appState.refreshBookings(silent: false) }
            case 429:
                paymentErrorMessage = "Too many requests. Please try again shortly."
            case 500, 502, 503:
                paymentErrorMessage = "Payment service is temporarily unavailable. Please try again."
            default:
                paymentErrorMessage = message.isEmpty ? "Could not start payment. Please try again." : message
            }
        } catch {
            paymentErrorMessage = "Could not start payment. Please try again."
        }
    }

    private func confirmDUPRAndBook() async {
        if let error = appState.saveCurrentUserDUPRID(duprIDDraft) {
            duprSheetErrorMessage = error; return
        }
        let ratingText = duprRatingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let ratingParts = ratingText.split(separator: ".", omittingEmptySubsequences: false)
        guard ratingParts.count == 2, ratingParts[1].count == 3 else {
            duprSheetErrorMessage = "Enter your DUPR rating with exactly 3 decimal places (e.g. 3.524)."; return
        }
        guard let rating = Double(ratingText) else {
            duprSheetErrorMessage = "Enter a valid DUPR rating (e.g. 3.524)."; return
        }
        if let error = appState.saveDUPRRatings(doubles: rating) {
            duprSheetErrorMessage = error; return
        }
        guard duprBookingConfirmed else {
            duprSheetErrorMessage = "Please confirm this is your DUPR profile."; return
        }
        duprSheetErrorMessage = nil
        showDUPRBookingSheet = false
        // Persist to profile so Edit Profile and all other displays show the same value.
        await appState.saveProfilePersonalInfo(
            fullName: appState.profile?.fullName ?? "",
            phone: appState.profile?.phone,
            dateOfBirth: appState.profile?.dateOfBirth,
            duprRating: rating
        )
        // If the game has a fee and spots are available, collect payment before confirming.
        // isGameFull guard: waitlisted users must never pay — join waitlist directly.
        if let fee = currentGame.feeAmount, fee > 0, !isGameFull {
            await preparePaymentSheet(fee: fee, currency: currentGame.feeCurrency ?? "aud")
        } else {
            await appState.requestBooking(for: game)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        GameDetailView(
            game: Game(
                id: UUID(),
                clubID: UUID(),
                title: "Tuesday Open Play",
                description: "Casual social session with mixed levels.",
                dateTime: .now.addingTimeInterval(3600 * 24),
                durationMinutes: 120,
                skillLevel: "all",
                gameFormat: "open_play",
                gameType: "doubles",
                maxSpots: 16,
                feeAmount: nil,
                feeCurrency: "AUD",
                location: "Downtown Courts",
                status: "upcoming",
                notes: "Bring indoor shoes.",
                requiresDUPR: false,
                confirmedCount: 8,
                waitlistCount: 2
            )
        )
        .environmentObject(AppState())
    }
}

// MARK: - Check-In Confetti Button

struct CheckInConfettiButton: View {
    let isCheckedIn: Bool
    let isBusy: Bool
    let onTap: () -> Void

    @State private var showConfetti = false
    @State private var buttonScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            if showConfetti {
                ConfettiBurst()
                    .allowsHitTesting(false)
            }

            Button {
                if isCheckedIn {
                    // Unchecking — no confetti
                    onTap()
                    return
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                // Pop animation
                withAnimation(.spring(response: 0.18, dampingFraction: 0.4)) {
                    buttonScale = 1.35
                }
                withAnimation(.spring(response: 0.2, dampingFraction: 0.55).delay(0.13)) {
                    buttonScale = 1.0
                }
                // Confetti burst
                showConfetti = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                    showConfetti = false
                }
                onTap()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isCheckedIn ? Color.black : Color(UIColor.tertiaryLabel))
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(isCheckedIn ? Color(hex: "80FF00") : Color(UIColor.tertiarySystemFill))
                    )
                    .overlay(
                        Circle().stroke(
                            isCheckedIn ? Color(hex: "80FF00") : Color(UIColor.separator),
                            lineWidth: 1
                        )
                    )
            }
            .buttonStyle(.plain)
            .scaleEffect(buttonScale)
            .disabled(isBusy)
        }
    }
}

// MARK: - Confetti Burst

private struct ConfettiBurst: View {
    // Generate once at creation time so particles are stable per burst
    private let particles: [ConfettiParticle] = (0..<16).map { _ in ConfettiParticle() }

    var body: some View {
        ZStack {
            ForEach(particles) { particle in
                ConfettiParticleView(particle: particle)
            }
        }
    }
}

private struct ConfettiParticle: Identifiable {
    let id = UUID()
    let angle: Double = .random(in: 0..<360)
    let distance: CGFloat = .random(in: 20...52)
    let size: CGFloat = .random(in: 4...7)
    let aspectRatio: CGFloat = Bool.random() ? 1.0 : CGFloat.random(in: 1.4...1.9)
    let cornerRadius: CGFloat = Bool.random() ? 100 : 2 // circle vs rect
    let spin: Double = .random(in: -180...180)
    let color: Color = [
        Color(hex: "80FF00"),
        Color(hex: "80FF00").opacity(0.75),
        Color(red: 0.62, green: 0.96, blue: 0.35),
        Color(UIColor.systemGray5),
        Color.white,
    ].randomElement()!
}

private struct ConfettiParticleView: View {
    let particle: ConfettiParticle

    @State private var offsetX: CGFloat = 0
    @State private var offsetY: CGFloat = 0
    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.1
    @State private var rotation: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: particle.cornerRadius)
            .fill(particle.color)
            .frame(width: particle.size, height: particle.size * particle.aspectRatio)
            .rotationEffect(.degrees(rotation))
            .scaleEffect(scale)
            .opacity(opacity)
            .offset(x: offsetX, y: offsetY)
            .onAppear {
                let rad = particle.angle * .pi / 180
                // Burst outward
                withAnimation(.easeOut(duration: 0.32)) {
                    offsetX = cos(rad) * particle.distance
                    offsetY = sin(rad) * particle.distance
                    scale = 1.0
                    opacity = 1.0
                    rotation = particle.spin
                }
                // Fade and shrink
                withAnimation(.easeIn(duration: 0.22).delay(0.28)) {
                    opacity = 0
                    scale = 0.3
                }
            }
    }
}

// MARK: - Clean Detail Line (kept for compatibility)

struct CleanDetailLine: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Brand.mutedText)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Brand.ink)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Booking Success Sheet Content

private struct BookingSuccessSheetContent: View {
    let title: String
    let dateTimeText: String
    let venueText: String?
    let onAddToCalendar: () -> Void
    let onDone: () -> Void

    @State private var iconShown = false
    @State private var textShown = false
    @State private var cardShown = false
    @State private var actionsShown = false
    @State private var didFireHaptic = false

    var body: some View {
        VStack(spacing: 18) {
            successIcon
                .padding(.top, 22)

            VStack(spacing: 4) {
                Text("You're in.")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Brand.primaryText)
                    .minimumScaleFactor(0.85)
                    .lineLimit(1)
                Text("See you on court.")
                    .font(.system(size: 16))
                    .foregroundStyle(Brand.secondaryText)
                    .minimumScaleFactor(0.9)
                    .lineLimit(1)
            }
            .multilineTextAlignment(.center)
            .opacity(textShown ? 1 : 0)
            .offset(y: textShown ? 0 : 6)

            ticketCard
                .opacity(cardShown ? 1 : 0)
                .offset(y: cardShown ? 0 : 8)

            actionRow
                .opacity(actionsShown ? 1 : 0)
                .offset(y: actionsShown ? 0 : 8)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(400)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Brand.appBackground)
        .presentationCornerRadius(28)
        .onAppear { runEntranceSequence() }
    }

    private var successIcon: some View {
        ZStack {
            Circle()
                .fill(Brand.accentGreen.opacity(0.32))
                .frame(width: 110, height: 110)
                .blur(radius: 20)
                .opacity(iconShown ? 1 : 0)
                .allowsHitTesting(false)
            Circle()
                .fill(Brand.accentGreen)
                .frame(width: 76, height: 76)
            Image(systemName: "checkmark")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Brand.primaryText)
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Brand.primaryText)
                .offset(x: 34, y: -30)
                .opacity(iconShown ? 0.85 : 0)
                .allowsHitTesting(false)
        }
        .frame(width: 76, height: 76)
        .scaleEffect(iconShown ? 1.0 : 0.55)
        .opacity(iconShown ? 1 : 0)
    }

    private var ticketCard: some View {
        VStack(spacing: 6) {
            Text(dateTimeText.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Brand.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Brand.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
            if let venueText, !venueText.isEmpty {
                Text(venueText)
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.9)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Brand.secondarySurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Brand.softOutline, lineWidth: 1)
        )
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button(action: onAddToCalendar) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 14, weight: .medium))
                    Text("Add to Calendar")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(Brand.secondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Brand.softOutline, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Button(action: onDone) {
                Text("Done")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Brand.primaryText, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func runEntranceSequence() {
        if !didFireHaptic {
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)
            didFireHaptic = true
        }
        withAnimation(.spring(response: 0.46, dampingFraction: 0.62)) {
            iconShown = true
        }
        withAnimation(.easeOut(duration: 0.28).delay(0.10)) {
            textShown = true
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85).delay(0.18)) {
            cardShown = true
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.85).delay(0.26)) {
            actionsShown = true
        }
    }
}
