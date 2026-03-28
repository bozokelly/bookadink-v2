import CoreLocation
import SwiftUI
import StripePaymentSheet

struct GameDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let game: Game

    @State private var showDUPRBookingSheet = false
    @State private var showScheduleSheet = false
    @State private var showAddPlayerSheet = false
    @State private var isEditingGame = false
    @State private var addPlayerSearch = ""
    @State private var duprIDDraft = ""
    @State private var duprDoublesRatingText = ""
    @State private var duprSinglesRatingText = ""
    @State private var duprBookingConfirmed = false
    @State private var duprSheetErrorMessage: String? = nil
    @State private var isPlayersExpanded = false
    @State private var showCancelGameConfirmation = false

    // Stripe PaymentSheet
    @State private var paymentSheet: PaymentSheet = PaymentSheet(paymentIntentClientSecret: "", configuration: .init())
    @State private var isShowingPaymentSheet = false
    @State private var isPreparingPayment = false
    @State private var paymentErrorMessage: String?
    @State private var pendingStripePaymentIntentID: String?

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

    private var priceText: String {
        if let fee = currentGame.feeAmount, fee > 0 {
            return "$\(String(format: "%.2f", fee))"
        }
        return "Free"
    }

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
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {

                // ── Header ────────────────────────────────────────
                gameInfoHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 24)

                // ── Primary CTA (single, full-width) ──────────────
                primaryCTASection
                    .padding(.horizontal, 20)

                // ── Payment error ─────────────────────────────────
                if let paymentError = paymentErrorMessage, !paymentError.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                        Text(paymentError)
                    }
                    .font(.footnote)
                    .foregroundStyle(Brand.errorRed)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }

                // ── Inline booking messages ───────────────────────
                if let info = appState.bookingInfoMessage, !info.isEmpty {
                    Text(info)
                        .font(.footnote)
                        .foregroundStyle(Brand.pineTeal)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }
                if let error = appState.bookingsErrorMessage, !error.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                        Text(AppCopy.friendlyError(error))
                    }
                    .font(.footnote)
                    .foregroundStyle(Brand.errorRed)
                    .appErrorCardStyle(cornerRadius: 12)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }

                // ── Venue section ─────────────────────────────────
                sectionHeader("Venue")
                    .padding(.horizontal, 20)
                    .padding(.top, 32)
                    .padding(.bottom, 12)
                venueInfoCard
                    .padding(.horizontal, 20)

                // ── DUPR requirement card ─────────────────────────
                if currentGame.requiresDUPR {
                    duprRequirementCard
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }

                // ── About This Event ──────────────────────────────
                // Shows format description + optional user Information
                // in a single card. Visible whenever there is either a
                // displayable format or user-entered information.
                let userInfo = currentGame.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if hasDisplayableFormat || !userInfo.isEmpty {
                    sectionHeader("About This Event")
                        .padding(.horizontal, 20)
                        .padding(.top, 32)
                        .padding(.bottom, 12)
                    aboutEventCard
                        .padding(.horizontal, 20)
                }

                // ── Attendance (past games, admin only) ──────────
                if currentGame.startsInPast && isClubAdminUser {
                    sectionHeader("Attendance")
                        .padding(.horizontal, 20)
                        .padding(.top, 32)
                        .padding(.bottom, 12)
                    attendanceSummaryCard
                        .padding(.horizontal, 20)
                }

                // ── Players ───────────────────────────────────────
                if canViewAttendees {
                    sectionHeader(currentGame.startsInPast && isClubAdminUser ? "Player Records" : "Players Registered (\(confirmedAttendees.count))")
                        .padding(.horizontal, 20)
                        .padding(.top, currentGame.startsInPast && isClubAdminUser ? 20 : 32)
                        .padding(.bottom, 12)
                    playersCard
                        .padding(.horizontal, 20)
                }

                // ── Cancellation policy ───────────────────────────
                cancellationCard
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                Spacer().frame(height: 48)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .background(Brand.pageGradient.ignoresSafeArea())
        .navigationTitle("Event Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                moreMenu
            }
        }
        .task(id: game.id) {
            // Clear any stale booking messages from a previous game before loading this one.
            appState.bookingsErrorMessage = nil
            appState.bookingInfoMessage = nil

            if canViewAttendees {
                await appState.refreshAttendees(for: game)
            }
            if let club = clubForGame, appState.authState == .signedIn {
                await appState.refreshClubAdminRole(for: club)
                if appState.isClubAdmin(for: club) {
                    await appState.refreshOwnerMembers(for: club)
                    if appState.venues(for: club).isEmpty {
                        await appState.refreshVenues(for: club)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookADinkWaitlistPromoted)) { note in
            guard let gameIDString = note.object as? String,
                  gameIDString == game.id.uuidString else { return }
            Task {
                await appState.refreshBookings(silent: true)
                await appState.refreshAttendees(for: game)
            }
        }
        .sheet(isPresented: $showDUPRBookingSheet) { duprBookingSheet }
        .sheet(isPresented: $showAddPlayerSheet) { addPlayerSheet }
        .sheet(isPresented: Binding(
            get: { showScheduleSheet && UIDevice.current.userInterfaceIdiom != .pad },
            set: { showScheduleSheet = $0 }
        )) {
            GameScheduleSheet(game: currentGame, confirmedPlayers: confirmedAttendees)
        }
        .fullScreenCover(isPresented: Binding(
            get: { showScheduleSheet && UIDevice.current.userInterfaceIdiom == .pad },
            set: { showScheduleSheet = $0 }
        )) {
            GameScheduleSheet(game: currentGame, confirmedPlayers: confirmedAttendees)
        }
        .sheet(isPresented: $isEditingGame) {
            if let club = clubForGame {
                OwnerEditGameSheet(club: club, game: currentGame, initialVenues: appState.venues(for: club))
                    .environmentObject(appState)
            }
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
            Text("This will cancel the game and notify all booked players.")
        }
        .onChange(of: currentGame.status) { _, newStatus in
            if newStatus == "cancelled" {
                dismiss()
            }
        }
    }

    // MARK: - Game Info Header (flat, no card background)

    private var gameInfoHeader: some View {
        VStack(alignment: .leading, spacing: 6) {

            // Title — dominant element
            Text(currentGame.title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Brand.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if let name = clubName {
                Text(name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Brand.pineTeal)
                    .lineLimit(1)
            }

            // Date + time with calendar icon
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.mutedText)
                Text(currentGame.dateTime.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()))
                    .font(.system(size: 14))
                    .foregroundStyle(Brand.mutedText)
                    .lineLimit(1)
            }

            // Inline tags: "Intermediate • King of the Court • DUPR Required"
            if let tags = tagLine {
                Text(tags)
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.mutedText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Primary CTA Section

    private var primaryCTASection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if currentGame.status == "cancelled" {
                // Game-level cancellation banner — replaces all booking UI
                HStack(spacing: 10) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Brand.errorRed)
                    Text("This game has been cancelled")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Brand.errorRed)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .padding(.horizontal, 16)
                .background(Brand.errorRed.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Brand.errorRed.opacity(0.25), lineWidth: 1)
                )
            } else {
                // Membership gate message
                if let msg = bookingMembershipRequirementMessage {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(Brand.spicyOrange)
                }

                ctaButton
            }
        }
    }

    @ViewBuilder
    private var ctaButton: some View {
        let state = currentBookingState
        let isRequesting = appState.isRequestingBooking(for: game)
        let isCancelling = appState.isCancellingBooking(for: game)
        let enabled = state.canBook && canBookGameByClubMembership && !currentGame.startsInPast

        if state.canBook && !currentGame.startsInPast {
            // "Book Your Spot • $15.00" or "Join Waitlist"
            let isBusy = isRequesting || isPreparingPayment
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
                                return " • \(String(format: "$%.2f", fee))"
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
            .paymentSheet(
                isPresented: $isShowingPaymentSheet,
                paymentSheet: paymentSheet,
                onCompletion: { result in
                    switch result {
                    case .completed:
                        let piID = pendingStripePaymentIntentID
                        pendingStripePaymentIntentID = nil
                        Task { await appState.requestBooking(for: game, stripePaymentIntentID: piID) }
                    case .canceled:
                        pendingStripePaymentIntentID = nil
                    case .failed(let error):
                        pendingStripePaymentIntentID = nil
                        paymentErrorMessage = error.localizedDescription
                    }
                }
            )

        } else if case .confirmed = state {
            // Subtle "You're In" — premium, not loud
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color(hex: "80FF00"))
                Text("You're In")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Brand.ink)
                Spacer()
                if isCancelling {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .padding(.horizontal, 16)
            .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(hex: "80FF00").opacity(0.4), lineWidth: 1.5)
            )

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
        }
    }

    // MARK: - More Menu (toolbar)
    // Absorbs: Cancel Booking, Add to Calendar, Set Reminder, and all admin actions.

    private var moreMenu: some View {
        let hasReminder = appState.hasReminder(for: game)
        let hasCalendarExport = appState.hasCalendarExport(for: game)
        let isExportingCalendar = appState.isExportingCalendar(for: game)
        let isCancelling = appState.isCancellingBooking(for: game)
        let isCancellingGame = appState.isCancellingGame(game)
        let state = currentBookingState

        return Menu {
            // Admin actions
            if isClubAdminUser {
                if confirmedAttendees.count >= 4 {
                    Button {
                        showScheduleSheet = true
                    } label: {
                        Label("Generate Play", systemImage: "shuffle")
                    }
                }
                Button {
                    addPlayerSearch = ""
                    showAddPlayerSheet = true
                } label: {
                    Label("Add Player", systemImage: "person.badge.plus")
                }
                Button {
                    isEditingGame = true
                } label: {
                    Label("Edit Game", systemImage: "pencil")
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
                Divider()
            }

            // Booked user actions
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
                        Task { await appState.cancelBooking(for: game) }
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

    // MARK: - Players Card

    private var playersCard: some View {
        let isOverCapacity = !waitlistedAttendees.isEmpty
        let spotsRemaining = max(0, currentGame.maxSpots - confirmedAttendees.count)
        let waitingCount = waitlistedAttendees.count
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

                    // Summary + chevron
                    HStack {
                        if !isLoading {
                            Text("\(confirmedAttendees.count) player\(confirmedAttendees.count == 1 ? "" : "s") confirmed")
                                .font(.system(size: 13))
                                .foregroundStyle(Brand.mutedText)
                            Text("•")
                                .font(.system(size: 13))
                                .foregroundStyle(Brand.mutedText)
                            Text(isOverCapacity
                                 ? "\(waitingCount) waiting"
                                 : "\(spotsRemaining) spot\(spotsRemaining == 1 ? "" : "s") remaining")
                                .font(.system(size: 13))
                                .foregroundStyle(isOverCapacity ? Brand.spicyOrange : Brand.mutedText)
                        }
                        Spacer()
                        if isClubAdminUser || waitingCount > 0 {
                            Image(systemName: isPlayersExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Brand.mutedText)
                        }
                    }
                }
                .padding(16)
            }
            .buttonStyle(.plain)

            // ── Expanded: full attendee list (admin + detail view) ────
            if isPlayersExpanded {
                Divider()

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
                            Divider().padding(.leading, 64)
                        }
                    }
                }

                // Waitlist section
                if !waitlistedAttendees.isEmpty {
                    Divider().padding(.top, 4)

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

                    ForEach(Array(waitlistedAttendees.enumerated()), id: \.element.id) { index, attendee in
                        attendeeRow(attendee, displayPosition: index + 1)
                        if index < waitlistedAttendees.count - 1 {
                            Divider().padding(.leading, 64)
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
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isOverCapacity ? Brand.spicyOrange.opacity(0.3) : Brand.softOutline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        .clipped()
    }

    // MARK: - Attendance Summary Card (past games, admin only)

    private var attendanceSummaryCard: some View {
        let checkedInCount  = confirmedAttendees.filter { appState.isCheckedIn(bookingID: $0.booking.id) }.count
        let noShowCount     = confirmedAttendees.count - checkedInCount
        let unpaidCount     = confirmedAttendees.filter {
            appState.isCheckedIn(bookingID: $0.booking.id) &&
            appState.paymentStatus(for: $0.booking.id) == "unpaid"
        }.count
        let cashCount       = confirmedAttendees.filter { appState.paymentStatus(for: $0.booking.id) == "cash" }.count
        let stripeCount     = confirmedAttendees.filter { appState.paymentStatus(for: $0.booking.id) == "stripe" }.count

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                attendanceStat(value: "\(checkedInCount)/\(confirmedAttendees.count)", label: "Attended",
                               color: Brand.pineTeal)
                Divider().frame(height: 40)
                attendanceStat(value: "\(noShowCount)", label: "No Show",
                               color: noShowCount > 0 ? Brand.errorRed : Brand.mutedText)
                Divider().frame(height: 40)
                attendanceStat(value: "\(unpaidCount)", label: "Unpaid",
                               color: unpaidCount > 0 ? Brand.spicyOrange : Brand.mutedText)
            }
            .padding(.vertical, 16)

            if cashCount > 0 || stripeCount > 0 {
                Divider()
                HStack(spacing: 16) {
                    if cashCount > 0 {
                        Label("\(cashCount) cash", systemImage: "banknote")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.mutedText)
                    }
                    if stripeCount > 0 {
                        Label("\(stripeCount) card", systemImage: "creditcard")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.mutedText)
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Brand.softOutline, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }

    private func attendanceStat(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(Brand.mutedText)
        }
        .frame(maxWidth: .infinity)
    }

    /// Large avatar circles (44pt) shown in the collapsed players card, up to 6.
    private var largeAvatarRow: some View {
        let preview = Array(confirmedAttendees.prefix(6))
        let overflow = max(0, confirmedAttendees.count - 6)
        return HStack(spacing: 8) {
            ForEach(preview, id: \.id) { attendee in
                Circle()
                    .fill(Brand.secondarySurface)
                    .overlay(
                        Text(initials(attendee.userName))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Brand.ink)
                    )
                    .frame(width: 44, height: 44)
            }
            if overflow > 0 {
                Circle()
                    .fill(Brand.secondarySurface)
                    .overlay(
                        Text("+\(overflow)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Brand.mutedText)
                    )
                    .frame(width: 44, height: 44)
            }
        }
    }

    // MARK: - Attendee Row

    @ViewBuilder
    private func paymentStatusBadge(_ status: String) -> some View {
        switch status {
        case "cash":
            attendeeBadge("Cash", fill: Brand.pineTeal.opacity(0.12), text: Brand.pineTeal)
        case "stripe":
            attendeeBadge("Card", fill: Brand.slateBlue.opacity(0.12), text: Brand.slateBlue)
        default:
            attendeeBadge("Unpaid", fill: Brand.spicyOrange.opacity(0.12), text: Brand.spicyOrange)
        }
    }

    /// Payment badge for upcoming games — derived from the booking record itself (not game_attendance).
    @ViewBuilder
    private func bookingPaymentBadge(_ booking: BookingRecord) -> some View {
        switch booking.paymentMethod {
        case "stripe":
            attendeeBadge("Card", fill: Brand.slateBlue.opacity(0.12), text: Brand.slateBlue)
        case "admin":
            attendeeBadge("Comp", fill: Brand.secondarySurface, text: Brand.mutedText)
        default:
            attendeeBadge("Unpaid", fill: Brand.spicyOrange.opacity(0.12), text: Brand.spicyOrange)
        }
    }

    private func attendeeRow(_ attendee: GameAttendee, displayPosition: Int? = nil) -> some View {
        let isChecked = appState.isCheckedIn(bookingID: attendee.booking.id)
        let isBusy = appState.isUpdatingOwnerBooking(attendee.booking.id)
        let waitlisted = isWaitlisted(attendee.booking.state)

        return HStack(alignment: .center, spacing: 12) {
            // Avatar — neutral styling for all players
            Circle()
                .fill(Brand.secondarySurface)
                .overlay(
                    Text(initials(attendee.userName))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Brand.ink)
                )
                .frame(width: 36, height: 36)

            // Name + metadata
            VStack(alignment: .leading, spacing: 2) {
                Text(attendee.userName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)
                if attendee.booking.userID == appState.authUserID,
                   let doubles = appState.duprDoublesRating {
                    Text("DUPR \(String(format: "%g", doubles))")
                        .font(.caption)
                        .foregroundStyle(Brand.mutedText)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                // Waitlist position badge — always use dynamic index position
                if waitlisted {
                    let label = displayPosition.map { "#\($0)" } ?? "Waitlisted"
                    attendeeBadge(label, fill: Brand.spicyOrange.opacity(0.12), text: Brand.spicyOrange)
                }

                if isClubAdminUser {
                    // Upcoming paid game: show payment status from booking record
                    if !currentGame.startsInPast, let fee = currentGame.feeAmount, fee > 0 {
                        bookingPaymentBadge(attendee.booking)
                    }

                    // Circular check-in button with confetti
                    CheckInConfettiButton(isCheckedIn: isChecked, isBusy: isBusy) {
                        Task { await appState.toggleCheckIn(for: game, attendee: attendee) }
                    }

                    if currentGame.startsInPast && isChecked {
                        // Past game: tappable payment status pill
                        let pStatus = appState.paymentStatus(for: attendee.booking.id)
                        Menu {
                            Button {
                                Task { await appState.updatePaymentStatus(for: game, attendee: attendee, status: "unpaid") }
                            } label: { Label("Unpaid", systemImage: "xmark.circle") }
                            Button {
                                Task { await appState.updatePaymentStatus(for: game, attendee: attendee, status: "cash") }
                            } label: { Label("Cash", systemImage: "banknote") }
                            Button {
                                Task { await appState.updatePaymentStatus(for: game, attendee: attendee, status: "stripe") }
                            } label: { Label("Card / Stripe", systemImage: "creditcard") }
                        } label: {
                            paymentStatusBadge(pStatus)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                    } else if !currentGame.startsInPast {
                        // Live game: full admin overflow menu
                        Menu {
                            if attendee.booking.state != .confirmed {
                                Button {
                                    Task { await appState.ownerSetBookingState(for: game, attendee: attendee, targetState: .confirmed) }
                                } label: {
                                    Label("Confirm", systemImage: "checkmark.circle.fill")
                                }
                            }
                            if !isWaitlisted(attendee.booking.state) {
                                Button {
                                    Task { await appState.ownerSetBookingState(for: game, attendee: attendee, targetState: .waitlisted(position: nil)) }
                                } label: {
                                    Label("Move to Waitlist", systemImage: "clock.badge")
                                }
                            }
                            if isWaitlisted(attendee.booking.state) {
                                Button {
                                    Task { await appState.ownerMoveWaitlistAttendee(for: game, attendee: attendee, directionUp: true) }
                                } label: { Label("Move Up", systemImage: "arrow.up") }
                                Button {
                                    Task { await appState.ownerMoveWaitlistAttendee(for: game, attendee: attendee, directionUp: false) }
                                } label: { Label("Move Down", systemImage: "arrow.down") }
                            }
                            Divider()
                            Button(role: .destructive) {
                                Task { await appState.ownerSetBookingState(for: game, attendee: attendee, targetState: .cancelled) }
                            } label: {
                                Label("Cancel Booking", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Brand.mutedText)
                                .frame(width: 32, height: 32)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                    }
                } else {
                    // Non-admin: status badge only
                    if isChecked {
                        attendeeBadge("Checked In", fill: Color(hex: "80FF00"), text: .black)
                    } else if case .confirmed = attendee.booking.state {
                        attendeeBadge("Confirmed", fill: Brand.primaryText, text: .white)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func attendeeBadge(_ title: String, fill: Color, text: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(text)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(fill, in: Capsule())
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 18, weight: .bold))
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
            // ── Venue header ──────────────────────────────────────────
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
                Divider()
            }

            // ── Info rows ─────────────────────────────────────────────
            detailInfoRow(icon: "clock", label: "Duration", value: durationText)
            Divider().padding(.leading, 52)
            detailInfoRow(icon: "dollarsign.circle", label: "Price", value: priceText)
            Divider().padding(.leading, 52)
            detailInfoRow(icon: "person.2", label: "Spots Available", value: spotsText, valueColor: spotsColor)
        }
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
                .font(.system(size: 22))
                .foregroundStyle(Brand.errorRed)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(2)
                if let address {
                    Text(address)
                        .font(.system(size: 13))
                        .foregroundStyle(Brand.mutedText)
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
                .fill(Color(hex: "80FF00").opacity(0.55))
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(Brand.secondaryText)
                    Text("DUPR Rating Required")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                }
                Text("This event requires a verified DUPR rating. Make sure your profile is up to date before booking.")
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
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

        VStack(alignment: .leading, spacing: 12) {
            // Format block — only shown for non-open-play formats
            if hasDisplayableFormat {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Format: \(formatName)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                    if let formatDesc {
                        Text(formatDesc)
                            .font(.system(size: 14))
                            .foregroundStyle(Brand.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // Divider between format and user info — only when both are present
            if hasDisplayableFormat && !userInfo.isEmpty {
                Divider()
            }

            // User-entered Information
            if !userInfo.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Information")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.ink)
                    Text(userInfo)
                        .font(.system(size: 14))
                        .foregroundStyle(Brand.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Brand.softOutline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }

    // MARK: - Cancellation Policy Card

    private var cancellationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CANCELLATION POLICY")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Brand.mutedText)
                .tracking(0.8)
            Text("Free cancellation up to 24 hours before the event. Late cancellations or no-shows may be charged the full session amount.")
                .font(.system(size: 14))
                .foregroundStyle(Brand.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Brand.softOutline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
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
                        Text("Doubles")
                        Spacer()
                        TextField("e.g. 2.928", text: $duprDoublesRatingText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                    }
                    HStack {
                        Text("Singles")
                        Spacer()
                        TextField("Optional", text: $duprSinglesRatingText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                            .foregroundStyle(.secondary)
                    }
                } header: { Text("DUPR Ratings") } footer: {
                    Text("Doubles rating is required (1.0–8.0). Singles is optional.").font(.caption)
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
                        duprDoublesRatingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        !duprBookingConfirmed ||
                        appState.isRequestingBooking(for: game)
                    )
                }
            }
            .onAppear {
                duprIDDraft = appState.duprID ?? ""
                if let d = appState.duprDoublesRating { duprDoublesRatingText = String(d) } else { duprDoublesRatingText = "" }
                if let s = appState.duprSinglesRating { duprSinglesRatingText = String(s) } else { duprSinglesRatingText = "" }
                duprBookingConfirmed = false
                duprSheetErrorMessage = nil
            }
        }
    }

    // MARK: - Add Player Sheet

    private var addPlayerSheet: some View {
        NavigationStack {
            let club = clubForGame
            let allMembers = club.map { appState.ownerMembers(for: $0) } ?? []
            let existingUserIDs: Set<UUID> = Set(
                appState.gameAttendees(for: game)
                    .filter {
                        switch $0.booking.state {
                        case .confirmed, .waitlisted: return true
                        default: return false
                        }
                    }
                    .compactMap { $0.booking.userID }
            )
            let bookableMembers = allMembers.filter {
                $0.membershipStatus == .approved && !existingUserIDs.contains($0.userID)
            }
            let filtered = addPlayerSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? bookableMembers
                : bookableMembers.filter {
                    $0.memberName.localizedCaseInsensitiveContains(addPlayerSearch) ||
                    ($0.memberEmail?.localizedCaseInsensitiveContains(addPlayerSearch) ?? false)
                }

            VStack(spacing: 0) {
                if let info = appState.gameOwnerInfoByID[game.id], !info.isEmpty {
                    Text(info)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Brand.pineTeal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Brand.pineTeal.opacity(0.08))
                }
                if let error = appState.gameOwnerErrorByID[game.id], !error.isEmpty {
                    Text(error)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Brand.errorRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Brand.errorRed.opacity(0.08))
                }
                List {
                    if filtered.isEmpty {
                        Text(bookableMembers.isEmpty ? "All club members are already in this game." : "No members match your search.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(filtered) { member in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(member.memberName).font(.subheadline.weight(.semibold))
                                    if let email = member.memberEmail {
                                        Text(email).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button {
                                    Task { await appState.ownerAddPlayerToGame(member, game: game) }
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(Brand.emeraldAction)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $addPlayerSearch, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search members")
            }
            .navigationTitle("Add Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showAddPlayerSheet = false }
                        .fontWeight(.semibold)
                }
            }
            .task { await appState.refreshAttendees(for: game) }
        }
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
        case "king_of_court", "ladder":
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
        case "ladder", "king_of_court": return "King of the Court"
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

    private func initials(_ name: String) -> String {
        let pieces = name.split(separator: " ")
        let chars = pieces.prefix(2).compactMap(\.first)
        return chars.isEmpty ? "M" : String(chars)
    }

    private func isWaitlisted(_ state: BookingState) -> Bool {
        if case .waitlisted = state { return true }
        return false
    }

    private func handlePrimaryBookingTap(state: BookingState) {
        if currentGame.requiresDUPR && state.canBook && canBookGameByClubMembership {
            duprIDDraft = appState.duprID ?? ""
            if let d = appState.duprDoublesRating { duprDoublesRatingText = String(d) } else { duprDoublesRatingText = "" }
            if let s = appState.duprSinglesRating { duprSinglesRatingText = String(s) } else { duprSinglesRatingText = "" }
            duprBookingConfirmed = false
            duprSheetErrorMessage = nil
            showDUPRBookingSheet = true
            return
        }

        // Paid game — collect payment before confirming booking
        if let fee = currentGame.feeAmount, fee > 0 {
            Task { await preparePaymentSheet(fee: fee, currency: currentGame.feeCurrency ?? "aud") }
            return
        }

        Task { await appState.requestBooking(for: game) }
    }

    private func preparePaymentSheet(fee: Double, currency: String) async {
        isPreparingPayment = true
        paymentErrorMessage = nil
        defer { isPreparingPayment = false }

        let amountCents = Int((fee * 100).rounded())

        do {
            let clientSecret = try await appState.createPaymentIntent(
                amountCents: amountCents,
                currency: currency.lowercased(),
                metadata: ["game_id": game.id.uuidString, "game_title": currentGame.title]
            )

            var config = PaymentSheet.Configuration()
            config.merchantDisplayName = "Book A Dink"
            config.applePay = .init(
                merchantId: "merchant.com.bookadink",
                merchantCountryCode: "AU"
            )

            // Extract payment intent ID from client secret ("pi_xxx_secret_yyy" → "pi_xxx")
            pendingStripePaymentIntentID = clientSecret.components(separatedBy: "_secret_").first
            paymentSheet = PaymentSheet(paymentIntentClientSecret: clientSecret, configuration: config)
            isShowingPaymentSheet = true
        } catch {
            print("[Payment] createPaymentIntent failed: \(error)")
            paymentErrorMessage = error.localizedDescription
        }
    }

    private func confirmDUPRAndBook() async {
        if let error = appState.saveCurrentUserDUPRID(duprIDDraft) {
            duprSheetErrorMessage = error; return
        }
        let doublesText = duprDoublesRatingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let doublesRating = Double(doublesText) else {
            duprSheetErrorMessage = "Enter a valid Doubles rating (e.g. 2.928)."; return
        }
        let singlesText = duprSinglesRatingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let singlesRating: Double? = singlesText.isEmpty ? nil : Double(singlesText)
        if !singlesText.isEmpty && singlesRating == nil {
            duprSheetErrorMessage = "Enter a valid Singles rating or leave it blank."; return
        }
        if let error = appState.saveDUPRRatings(doubles: doublesRating, singles: singlesRating) {
            duprSheetErrorMessage = error; return
        }
        guard duprBookingConfirmed else {
            duprSheetErrorMessage = "Please confirm this is your DUPR profile."; return
        }
        duprSheetErrorMessage = nil
        showDUPRBookingSheet = false
        // Persist doubles rating to profile so Edit Profile shows the same value.
        await appState.saveProfilePersonalInfo(
            fullName: appState.profile?.fullName ?? "",
            phone: appState.profile?.phone,
            dateOfBirth: appState.profile?.dateOfBirth,
            duprRating: doublesRating
        )
        await appState.requestBooking(for: game)
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
