import SwiftUI

// MARK: - BookingsListView

struct BookingsListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: Int = 0
    @State private var selectedGame: Game? = nil
    @State private var localUpcomingBookings: [BookingWithGame] = []
    @State private var removingBookingIDs: Set<UUID> = []
    /// Phase 2A.2: mirror of GameDetailView — when AppState publishes a
    /// cancellation result, capture it locally and present the half-sheet so
    /// users cancelling from this list see the same outcome explanation they
    /// would see if they'd cancelled from GameDetailView.
    @State private var showCancellationResultSheet = false
    @State private var displayedCancellationResult: CancellationCreditResult? = nil

    // MARK: - Filtered Lists

    private var upcomingBookings: [BookingWithGame] {
        let now = Date()
        return appState.bookings
            .filter { item in
                guard let date = item.game?.dateTime else { return false }
                guard date >= now else { return false }
                if case .cancelled = item.booking.state { return false }
                return true
            }
            .sorted { ($0.game?.dateTime ?? .distantFuture) < ($1.game?.dateTime ?? .distantFuture) }
    }

    private var pastBookings: [BookingWithGame] {
        let now = Date()
        return appState.bookings
            .filter { item in
                guard let date = item.game?.dateTime else { return false }
                guard date < now else { return false }
                if case .confirmed = item.booking.state { return true }
                return false
            }
            .sorted { ($0.game?.dateTime ?? .distantPast) > ($1.game?.dateTime ?? .distantPast) }
    }

    private var displayedBookings: [BookingWithGame] {
        selectedTab == 0 ? upcomingBookings : pastBookings
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Brand.pageGradient.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    pageHeader

                    if let error = appState.bookingsErrorMessage, !error.isEmpty {
                        errorBanner(error)
                            .padding(.top, 16)
                    }
                    if let info = appState.bookingInfoMessage, !info.isEmpty {
                        Text(info)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Brand.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.top, 8)
                    }

                    segmentedControl
                        .padding(.top, 20)

                    let visibleUpcoming = localUpcomingBookings.filter { !removingBookingIDs.contains($0.id) }
                    let currentSource: [BookingWithGame] = selectedTab == 0 ? visibleUpcoming : pastBookings

                    if appState.isLoadingBookings && localUpcomingBookings.isEmpty && pastBookings.isEmpty {
                        ProgressView("Loading bookings...")
                            .tint(Brand.secondaryText)
                            .foregroundStyle(Brand.secondaryText)
                            .padding(.top, 32)
                            .frame(maxWidth: .infinity)
                    } else if currentSource.isEmpty {
                        emptyState
                            .padding(.top, 24)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(currentSource) { item in
                                if let game = item.game {
                                    let club = appState.clubs.first { $0.id == game.clubID }
                                    let venues = appState.clubVenuesByClubID[game.clubID] ?? []
                                    let resolvedVenue = LocationService.resolvedVenue(for: game, venues: venues)

                                    BookingCompactCard(
                                        item: item,
                                        club: club,
                                        resolvedVenue: resolvedVenue,
                                        isPast: selectedTab == 1,
                                        onCardTap: { selectedGame = game }
                                    )
                                    .transition(.asymmetric(
                                        insertion: .opacity,
                                        removal: .opacity.combined(with: .scale(scale: 0.96))
                                    ))
                                }
                            }
                        }
                        .padding(.top, 16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .refreshable { await appState.refreshBookings() }
            .onAppear {
                localUpcomingBookings = upcomingBookings
            }
            .onChange(of: upcomingBookings) { _, new in
                let newIDs = Set(new.map(\.id))
                let removedIDs = Set(localUpcomingBookings.map(\.id)).subtracting(newIDs)

                if !removedIDs.isEmpty {
                    // Animate only the departing cards; leave the rest untouched.
                    withAnimation(.easeOut(duration: 0.26)) {
                        removingBookingIDs.formUnion(removedIDs)
                    }
                    // After the transition plays, commit the pruned list and clear the removing set.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        localUpcomingBookings = new
                        removingBookingIDs.subtract(removedIDs)
                    }
                } else {
                    // No removals — silently update in place so surviving cards don't flash.
                    localUpcomingBookings = new
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { EmptyView() }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await appState.refreshBookings() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
        .navigationDestination(item: $selectedGame) { game in
            GameDetailView(game: game)
        }
        .task {
            if appState.bookings.isEmpty && appState.authState == .signedIn {
                await appState.refreshBookings(silent: true)
            }
            let clubIDs = Set(appState.bookings.compactMap { $0.game?.clubID })
            await withTaskGroup(of: Void.self) { group in
                for clubID in clubIDs {
                    group.addTask { await appState.refreshCreditBalance(for: clubID) }
                }
            }
        }
        .onChange(of: appState.lastCancellationCredit) { _, result in
            guard let result else { return }
            // Refresh the credit balance for the affected club, then present the
            // outcome sheet. AppState's value is consumed (set back to nil) so
            // only the first observer to fire wins — preventing dual-presentation
            // when both BookingsListView and an active GameDetailView observe.
            Task { await appState.refreshCreditBalance(for: result.clubID) }
            displayedCancellationResult = result
            showCancellationResultSheet = true
            appState.lastCancellationCredit = nil
        }
        .sheet(isPresented: $showCancellationResultSheet) {
            if let result = displayedCancellationResult {
                CancellationResultSheet(
                    result: result,
                    club: appState.clubs.first(where: { $0.id == result.clubID }),
                    onDismiss: { showCancellationResultSheet = false }
                )
            }
        }
    }

    // MARK: - Page Header

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BOOKINGS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Brand.secondaryText)
                .tracking(1.2)

            Text("Your court time.")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Brand.primaryText)

            Text("Cancel free up to 6h before. Credits return instantly.")
                .font(.subheadline)
                .foregroundStyle(Brand.secondaryText)
        }
        .padding(.top, 4)
    }

    // MARK: - Segmented Control

    private var segmentedControl: some View {
        Picker("", selection: $selectedTab) {
            Text("Upcoming (\(upcomingBookings.count))").tag(0)
            Text("Past").tag(1)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Error Banner

    @ViewBuilder
    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
            Text(AppCopy.friendlyError(error))
            Spacer(minLength: 0)
            Button("Retry") {
                Task { await appState.refreshBookings() }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Brand.errorRed)
        }
        .foregroundStyle(Brand.errorRed)
        .appErrorCardStyle(cornerRadius: 12)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 38))
                .foregroundStyle(Brand.secondaryText)
            Text(selectedTab == 0 ? "No upcoming bookings" : "No past bookings")
                .font(.headline)
                .foregroundStyle(Brand.primaryText)
            Text(selectedTab == 0
                 ? "Open a club, browse the Games tab, and join your first session."
                 : "Your completed sessions will appear here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .glassCard(cornerRadius: 22, tint: Brand.secondarySurface)
    }
}

// MARK: - BookingCompactCard

private struct BookingCompactCard: View {
    @EnvironmentObject private var appState: AppState
    let item: BookingWithGame
    let club: Club?
    let resolvedVenue: ClubVenue?
    let isPast: Bool
    var onCardTap: (() -> Void)? = nil

    @State private var showCancelConfirm:   Bool = false
    @State private var showCalendarConfirm: Bool = false
    @State private var showReminderConfirm: Bool = false

    // MARK: - Date Formatters

    private static let weekdayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d"; return f
    }()
    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM"; return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    // MARK: - Derived

    // Resolved display status. Game cancellation takes absolute priority over booking state —
    // a confirmed booking on a cancelled game must never read as "Confirmed".
    private var isGameCancelled: Bool {
        item.game?.status == "cancelled"
    }

    private var statusColor: Color {
        if isGameCancelled { return Brand.errorRed }
        switch item.booking.state {
        case .confirmed:      return .green
        case .waitlisted:     return .orange
        case .pendingPayment: return Color(hex: "3B82F6")
        case .cancelled:      return Brand.secondaryText
        default:              return Brand.secondaryText
        }
    }

    private var statusLabel: String {
        if isGameCancelled { return "Cancelled" }
        switch item.booking.state {
        case .confirmed:              return "Confirmed"
        case .waitlisted(let pos):
            if let pos { return "Waitlisted #\(pos)" }
            return "Waitlisted"
        case .pendingPayment:         return "Awaiting Payment"
        case .cancelled:              return "Cancelled"
        case .none:                   return "—"
        case .unknown(let s):         return s.capitalized
        }
    }

    private var venueName: String? {
        if let v = resolvedVenue?.venueName, !v.isEmpty { return v }
        if let v = club?.venueName, !v.isEmpty { return v }
        return club?.name
    }

    private var suburb: String? {
        if let s = resolvedVenue?.suburb, !s.isEmpty { return s }
        return club?.suburb
    }

    private func timeRange(for game: Game) -> String {
        let start = Self.timeFmt.string(from: game.dateTime)
        let endDate = game.dateTime.addingTimeInterval(Double(game.durationMinutes) * 60)
        let end = Self.timeFmt.string(from: endDate)
        return "\(start) – \(end)"
    }

    // MARK: - Body

    var body: some View {
        guard let game = item.game else { return AnyView(EmptyView()) }

        let state = item.booking.state
        let canCancel   = state.canCancel && !game.startsInPast
        let hasCalendar = appState.hasCalendarExport(for: game)
        let hasReminder = appState.hasReminder(for: game)

        return AnyView(
            Button { onCardTap?() } label: {
                HStack(spacing: 0) {
                    // Date block
                    dateBlock(for: game)

                    // Content
                    VStack(alignment: .leading, spacing: 3) {
                        // Status line
                        HStack(spacing: 4) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 7, height: 7)
                            Text(statusLabel)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(statusColor)
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(1)
                            if let venue = venueName {
                                Text("·")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Brand.secondaryText)
                                    .fixedSize()
                                    .layoutPriority(1)
                                Text(venue)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Brand.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .layoutPriority(0)
                            }
                        }
                        .padding(.trailing, 36)

                        // Game title
                        Text(game.title)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Brand.primaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.trailing, 36)

                        // Time + suburb
                        let timeLine: String = {
                            var parts = [timeRange(for: game)]
                            if let sub = suburb, !sub.isEmpty { parts.append(sub) }
                            return parts.joined(separator: " · ")
                        }()
                        Text(timeLine)
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.secondaryText)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 14)
                    .padding(.leading, 14)
                    .padding(.trailing, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Brand.softOutline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
                .opacity(isPast ? 0.72 : 1)
                .overlay(alignment: .topTrailing) {
                    Menu {
                        Button {
                            showCalendarConfirm = true
                        } label: {
                            Label(
                                hasCalendar ? "Remove from Calendar" : "Add to Calendar",
                                systemImage: hasCalendar ? "calendar.badge.minus" : "calendar.badge.plus"
                            )
                        }
                        Button {
                            showReminderConfirm = true
                        } label: {
                            Label(
                                hasReminder ? "Remove Reminder" : "Set Reminder",
                                systemImage: hasReminder ? "bell.slash" : "bell"
                            )
                        }
                        if canCancel {
                            Divider()
                            Button(role: .destructive) {
                                showCancelConfirm = true
                            } label: {
                                Label("Cancel Booking", systemImage: "xmark.circle")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Brand.mutedText)
                            .padding(12)
                            .contentShape(Rectangle())
                    }
                }
            }
            .buttonStyle(.plain)
            .confirmationDialog(
                "Cancel Booking",
                isPresented: $showCancelConfirm,
                titleVisibility: .visible
            ) {
                Button("Cancel Booking", role: .destructive) {
                    Task { await appState.cancelBooking(for: game) }
                }
                Button("Keep Booking", role: .cancel) { }
            } message: {
                Text("This will remove you from \(game.title). You may not be able to rebook if the session fills up.")
            }
            .confirmationDialog(
                hasCalendar ? "Remove from Calendar?" : "Add to Calendar?",
                isPresented: $showCalendarConfirm,
                titleVisibility: .visible
            ) {
                Button(hasCalendar ? "Remove from Calendar" : "Add to Calendar") {
                    Task { await appState.toggleCalendarExport(for: game) }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(hasCalendar
                     ? "This will remove \(game.title) from your calendar."
                     : "This will add \(game.title) to your calendar.")
            }
            .confirmationDialog(
                hasReminder ? "Remove Reminder?" : "Set a Reminder?",
                isPresented: $showReminderConfirm,
                titleVisibility: .visible
            ) {
                Button(hasReminder ? "Remove Reminder" : "Set Reminder") {
                    Task { await appState.toggleReminder(for: game) }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(hasReminder
                     ? "Your reminder for \(game.title) will be removed."
                     : "You'll get a reminder before \(game.title) starts.")
            }
        )
    }

    // MARK: - Date Block

    private func dateBlock(for game: Game) -> some View {
        ZStack {
            // Canonical HeroSurface — pinned palette/pattern when the
            // admin selected them, deterministic auto rotation seeded
            // from `game.id` otherwise. Same surface as ClubGameRow's
            // date block so a booking and the source club row match.
            HeroSurface.forGame(
                game,
                lighting: .none,
                vignette: .none,
                direction: .vertical
            )

            VStack(spacing: 1) {
                Text(Self.weekdayFmt.string(from: game.dateTime).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .tracking(0.5)

                Text(Self.dayFmt.string(from: game.dateTime))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(Self.monthFmt.string(from: game.dateTime).uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .tracking(0.5)
            }
        }
        .frame(width: 62)
        .frame(maxHeight: .infinity)
        .clipShape(.rect(
            topLeadingRadius: 14,
            bottomLeadingRadius: 14,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        ))
    }
}

// MARK: - Cancellation Result Sheet (Phase 2A.2)

/// Post-cancellation half-sheet that surfaces the credit/refund outcome.
/// Renders one of four states depending on the published `CancellationCreditResult`:
///   - Free game             → no credit ever applies.
///   - Club-managed policy   → refunds handled off-platform.
///   - Credit issued         → exact amount and new club balance.
///   - Inside cutoff, no credit yet → eligible if a replacement player books.
///
/// Used by both `BookingsListView` and `GameDetailView` to keep the user-facing
/// explanation identical regardless of where the cancellation originates.
struct CancellationResultSheet: View {
    let result: CancellationCreditResult
    let club: Club?
    let onDismiss: () -> Void

    private enum Outcome {
        case freeGame
        case clubManaged
        case creditIssued
        case pendingReplacement
        case cancelled
    }

    private var outcome: Outcome {
        if result.gameWasFree { return .freeGame }
        if club?.cancellationPolicyType == .clubManaged { return .clubManaged }
        if result.creditedCents > 0 { return .creditIssued }
        if !result.wasEligible { return .pendingReplacement }
        return .cancelled
    }

    private var iconName: String {
        switch outcome {
        case .freeGame:            return "checkmark.circle.fill"
        case .clubManaged:         return "envelope.fill"
        case .creditIssued:        return "creditcard.fill"
        case .pendingReplacement:  return "clock.badge.checkmark.fill"
        case .cancelled:           return "checkmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch outcome {
        case .creditIssued:        return Brand.slateBlue
        case .pendingReplacement:  return Brand.softOrangeAccent
        default:                   return Brand.emeraldAction
        }
    }

    private var clubLabel: String { result.clubName ?? club?.name ?? "this club" }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.14))
                        .frame(width: 72, height: 72)
                    Image(systemName: iconName)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(iconColor)
                }

                VStack(spacing: 8) {
                    Text("Booking Cancelled")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Brand.primaryText)

                    Group {
                        switch outcome {
                        case .freeGame:
                            Text("Free game — no credit applies.")
                                .font(.system(size: 15))
                                .foregroundStyle(Brand.secondaryText)
                                .multilineTextAlignment(.center)
                        case .clubManaged:
                            Text("\(clubLabel) handles refunds off-platform. Contact the club if you have any questions.")
                                .font(.system(size: 15))
                                .foregroundStyle(Brand.secondaryText)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        case .creditIssued:
                            let credited = String(format: "$%.2f", Double(result.creditedCents) / 100)
                            let newBal   = String(format: "$%.2f", Double(result.newBalanceCents) / 100)
                            Text("\(credited) credit added at \(clubLabel)")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Brand.slateBlue)
                                .multilineTextAlignment(.center)
                            Text("Your credit balance at \(clubLabel) is now **\(newBal)**. Credits can only be used at the club that issued them.")
                                .font(.system(size: 14))
                                .foregroundStyle(Brand.secondaryText)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        case .pendingReplacement:
                            Text("If a replacement player books your spot, we'll credit you automatically.")
                                .font(.system(size: 15))
                                .foregroundStyle(Brand.secondaryText)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("You'll get a notification if that happens.")
                                .font(.system(size: 13))
                                .foregroundStyle(Brand.tertiaryText)
                                .multilineTextAlignment(.center)
                        case .cancelled:
                            Text("Your booking has been cancelled.")
                                .font(.system(size: 15))
                                .foregroundStyle(Brand.secondaryText)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .padding(.horizontal, 24)

                // Balance pill — only when credit was actually issued.
                if outcome == .creditIssued {
                    HStack(spacing: 10) {
                        Image(systemName: "creditcard.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Brand.slateBlue)
                        Text("Balance: \(String(format: "$%.2f", Double(result.newBalanceCents) / 100))")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Brand.primaryText)
                        Text("· \(clubLabel)")
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.secondaryText)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Brand.softOutline, lineWidth: 1))
                    .padding(.horizontal, 24)
                }

                Button(action: onDismiss) {
                    Text("Got it")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Brand.primaryText, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 28)
            .background(Brand.appBackground)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 0)
            Spacer().frame(height: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDetents([.height(420)])
        .presentationBackground(Brand.appBackground)
        .presentationCornerRadius(28)
        .presentationDragIndicator(.hidden)
    }
}
