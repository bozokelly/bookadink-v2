import SwiftUI

// MARK: - BookingsListView

struct BookingsListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showPastBookings = false
    @State private var selectedClub: Club? = nil
    /// This Week is open by default; other sections start collapsed.
    @State private var expandedGroups: Set<BookingGroup> = [.thisWeek]

    // MARK: - Grouping

    private enum BookingGroup: Int, Hashable, CaseIterable {
        case thisWeek, nextTwoWeeks, laterThisMonth, past

        var title: String {
            switch self {
            case .thisWeek:       return "This Week"
            case .nextTwoWeeks:   return "Next Two Weeks"
            case .laterThisMonth: return "Later This Month"
            case .past:           return "Past"
            }
        }
    }

    private struct GroupedSection: Identifiable {
        let id: BookingGroup
        let items: [BookingWithGame]
    }

    /// Calendar-aware bucketing.
    /// - thisWeek: same ISO week as now (includes today)
    /// - nextTwoWeeks: after this week, within 14 days from now
    /// - laterThisMonth: beyond 14 days
    /// - past: before now
    private func bucket(for date: Date, now: Date) -> BookingGroup {
        let cal = Calendar.current
        if date < now { return .past }
        if cal.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
        let twoWeeksOut = cal.date(byAdding: .day, value: 14, to: now) ?? now
        if date <= twoWeeksOut { return .nextTwoWeeks }
        return .laterThisMonth
    }

    private var sections: [GroupedSection] {
        let now = Date()
        var buckets: [BookingGroup: [BookingWithGame]] = [:]

        for item in appState.bookings {
            let date = item.game?.dateTime ?? item.booking.createdAt ?? now
            let g    = bucket(for: date, now: now)

            if g == .past {
                // Only show past bookings when toggled on, and only confirmed ones
                // (confirmed at game time = assumed attendance)
                guard showPastBookings else { continue }
                guard case .confirmed = item.booking.state else { continue }
            } else {
                // Hide cancelled bookings from upcoming sections — they look like game cancellations
                if case .cancelled = item.booking.state { continue }
            }

            buckets[g, default: []].append(item)
        }

        // Sort within each bucket: future ascending, past descending (most-recent first)
        for key in buckets.keys {
            buckets[key]?.sort {
                let l = $0.game?.dateTime ?? $0.booking.createdAt ?? .distantFuture
                let r = $1.game?.dateTime ?? $1.booking.createdAt ?? .distantFuture
                return key == .past ? (l > r) : (l < r)
            }
        }

        return BookingGroup.allCases.compactMap { g in
            guard let items = buckets[g], !items.isEmpty else { return nil }
            return GroupedSection(id: g, items: items)
        }
    }

    /// ID of the earliest confirmed upcoming booking — used for the subtle
    /// "next up" lime accent applied regardless of which section it falls in.
    private var nextBookingID: UUID? {
        let now = Date()
        return appState.bookings
            .filter {
                guard let d = $0.game?.dateTime else { return false }
                if case .confirmed = $0.booking.state { return d >= now }
                return false
            }
            .min { ($0.game?.dateTime ?? .distantFuture) < ($1.game?.dateTime ?? .distantFuture) }?
            .booking.id
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Brand.pageGradient.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerRow

                    if let error = appState.bookingsErrorMessage, !error.isEmpty {
                        errorBanner(error)
                    }
                    if let info = appState.bookingInfoMessage, !info.isEmpty {
                        Text(info)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Brand.secondaryText)
                            .padding(.horizontal, 6)
                    }

                    historyToggle

                    if appState.isLoadingBookings {
                        ProgressView("Loading bookings...")
                            .tint(Brand.secondaryText)
                            .foregroundStyle(Brand.secondaryText)
                            .padding(.top, 8)
                    } else if sections.isEmpty {
                        emptyState
                    } else {
                        ForEach(sections) { section in
                            sectionView(section)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .refreshable { await appState.refreshBookings() }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: Game.self) { game in
            GameDetailView(game: game)
        }
        .navigationDestination(item: $selectedClub) { club in
            ClubDetailView(club: club)
        }
        .task {
            if appState.bookings.isEmpty && appState.authState == .signedIn {
                await appState.refreshBookings(silent: true)
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center) {
            Text("Bookings")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.primaryText)
            Spacer()
            Button {
                Task { await appState.refreshBookings() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Brand.secondaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Section View

    @ViewBuilder
    private func sectionView(_ section: GroupedSection) -> some View {
        let isExpanded = expandedGroups.contains(section.id)

        VStack(alignment: .leading, spacing: 8) {
            // Collapsible section header
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    if isExpanded {
                        expandedGroups.remove(section.id)
                    } else {
                        expandedGroups.insert(section.id)
                    }
                }
            } label: {
                HStack(spacing: 0) {
                    HStack(spacing: 5) {
                        Text(section.id.title.uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Brand.secondaryText)
                            .tracking(0.6)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(Brand.secondaryText.opacity(0.4))
                        Text("\(section.items.count)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Brand.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.secondaryText.opacity(0.6))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
                }
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(section.items) { item in
                        if let game = item.game {
                            let club     = appState.clubs.first { $0.id == game.clubID }
                            let clubName = club?.name ?? ""
                            let isNext   = item.booking.id == nextBookingID

                            NavigationLink(value: game) {
                                BookingCard(
                                    item: item,
                                    clubName: clubName,
                                    isNext: isNext,
                                    onClubTap: club.map { c in { selectedClub = c } }
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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

    // MARK: - History Toggle

    private var historyToggle: some View {
        Button {
            showPastBookings.toggle()
            if showPastBookings {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    expandedGroups.insert(.past)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: showPastBookings ? "clock.arrow.circlepath" : "clock")
                Text(showPastBookings ? "Showing Past + Future" : "Show Past Bookings")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !showPastBookings {
                    Text("Upcoming Only")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Brand.secondarySurface, in: Capsule())
                }
            }
            .foregroundStyle(Brand.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(showPastBookings ? Brand.secondarySurface : Brand.cardBackground)
            )
        }
        .buttonStyle(.plain)
        .actionBorder(cornerRadius: 16, color: Brand.softOutline)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 38))
                .foregroundStyle(Brand.secondaryText)
            Text(showPastBookings ? "No bookings found" : "No upcoming bookings")
                .font(.headline)
                .foregroundStyle(Brand.primaryText)
            Text(showPastBookings
                 ? "You don't have any bookings in this view yet."
                 : "Open a club, browse the Games tab, and join your first session.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .glassCard(cornerRadius: 22, tint: Brand.secondarySurface)
    }
}

// MARK: - BookingCard

/// Thin wrapper around UnifiedGameCard for the Bookings list.
/// Adds the `···` manage button overlay (calendar / reminder / cancel booking).
private struct BookingCard: View {
    @EnvironmentObject private var appState: AppState
    let item: BookingWithGame
    let clubName: String
    /// Drives lime left-edge sliver + lime border on the card.
    let isNext: Bool
    var onClubTap: (() -> Void)? = nil

    @State private var showManageActions = false

    var body: some View {
        guard let game = item.game else { return AnyView(EmptyView()) }
        return AnyView(content(game: game))
    }

    private func content(game: Game) -> some View {
        let state        = item.booking.state
        let isBooked:    Bool = { if case .confirmed  = state { return true }; return false }()
        let isWaitlisted:Bool = { if case .waitlisted = state { return true }; return false }()
        let canCancel    = state.canCancel && !game.startsInPast
        let hasCalendar  = appState.hasCalendarExport(for: game)
        let hasReminder  = appState.hasReminder(for: game)
        let isCancelling = appState.isCancellingBooking(for: game)
        let isExporting  = appState.isExportingCalendar(for: game)
        let showManage   = canCancel || hasCalendar || hasReminder
        let venues       = appState.clubVenuesByClubID[game.clubID] ?? []
        let resolvedVenue = LocationService.resolvedVenue(for: game, venues: venues)

        return UnifiedGameCard(
            game: game,
            clubName: clubName,
            isBooked: isBooked,
            isWaitlisted: isWaitlisted,
            resolvedVenue: resolvedVenue,
            isNextBooking: isNext,
            onClubTap: onClubTap
        )
        .overlay(alignment: .topTrailing) {
            if showManage {
                Button { showManageActions = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.secondaryText.opacity(0.55))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isCancelling || isExporting)
            }
        }
        .confirmationDialog("Manage Booking", isPresented: $showManageActions) {
            Button(hasCalendar ? "Remove from Calendar" : "Add to Calendar") {
                Task { await appState.toggleCalendarExport(for: game) }
            }
            Button(hasReminder ? "Remove Reminder" : "Set Reminder") {
                Task { await appState.toggleReminder(for: game) }
            }
            if canCancel {
                Button("Cancel Booking", role: .destructive) {
                    Task { await appState.cancelBooking(for: game) }
                }
            }
        }
    }
}
