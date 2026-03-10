import SwiftUI

struct BookingsListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showPastBookings = false

    private var displayedBookings: [BookingWithGame] {
        let now = Date()
        let filtered = appState.bookings.filter { item in
            guard let gameDate = item.game?.dateTime else { return true }
            return showPastBookings || gameDate >= now
        }
        return filtered.sorted { lhs, rhs in
            let lDate = lhs.game?.dateTime ?? lhs.booking.createdAt ?? .distantFuture
            let rDate = rhs.game?.dateTime ?? rhs.booking.createdAt ?? .distantFuture
            return lDate < rDate
        }
    }

    var body: some View {
        ZStack {
            Brand.pageGradient.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center) {
                        Text("Bookings")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Spacer()
                        Button {
                            Task { await appState.refreshBookings() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 4)

                    if let error = appState.bookingsErrorMessage, !error.isEmpty {
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
                    
                    if let info = appState.bookingInfoMessage, !info.isEmpty {
                        Text(info)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .padding(.horizontal, 6)
                    }

                    historyToggle

                    if appState.isLoadingBookings {
                        ProgressView("Loading bookings...")
                            .tint(.white)
                            .foregroundStyle(.white)
                            .padding(.top, 6)
                    } else if displayedBookings.isEmpty {
                        emptyState
                    } else {
                        ForEach(displayedBookings) { item in
                            if let game = item.game {
                                VStack(alignment: .leading, spacing: 6) {
                                    NavigationLink(value: game) {
                                        BookingRowCard(item: item)
                                    }
                                    .buttonStyle(.plain)

                                    BookingRowQuickActions(item: item)
                                }
                            } else {
                                BookingRowCard(item: item)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .clipped()
            .refreshable {
                await appState.refreshBookings()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: Game.self) { game in
            GameDetailView(game: game)
        }
        .task {
            if appState.bookings.isEmpty && appState.authState == .signedIn {
                await appState.refreshBookings()
            }
        }
    }


    private var historyToggle: some View {
        Button {
            showPastBookings.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: showPastBookings ? "clock.arrow.circlepath" : "clock")
                Text(showPastBookings ? "Showing Past + Future" : "Show Past Bookings")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !showPastBookings {
                    Text("Upcoming Only")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.pineTeal)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.85), in: Capsule())
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(showPastBookings ? Color.white.opacity(0.14) : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .actionBorder(cornerRadius: 16, color: Color.white.opacity(0.18))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 38))
                .foregroundStyle(.white)
            Text(showPastBookings ? "No bookings found" : "No upcoming bookings")
                .font(.headline)
                .foregroundStyle(.white)
            Text(showPastBookings ? "You don't have any bookings in this view yet." : "Open a club, browse the Games tab, and join your first session.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.white.opacity(0.88))
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .glassCard(cornerRadius: 22, tint: Color.white.opacity(0.1))
    }
}

private struct BookingRowCard: View {
    let item: BookingWithGame

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.game?.title ?? "Game")
                        .font(.headline)
                        .foregroundStyle(Brand.ink)
                    if let date = item.game?.dateTime {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.pineTeal)
                    }
                }
                Spacer()
                statusBadge
            }

            HStack(spacing: 10) {
                Label(item.game?.displayLocation ?? "Club venue", systemImage: "mappin.and.ellipse")
                if let game = item.game {
                    Label("\(game.durationMinutes)m", systemImage: "clock")
                }
            }
            .font(.caption)
            .foregroundStyle(Brand.mutedText)

            HStack(spacing: 8) {
                Text(statusReasonText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.pineTeal)
                    .lineLimit(2)

                Spacer(minLength: 8)

                paymentBadge
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 20, tint: Color.white.opacity(0.65))
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch item.booking.state {
        case .confirmed:
            badge("Booked", fill: Brand.pineTeal, text: .white)
        case let .waitlisted(position):
            badge(position.map { "Waitlist #\($0)" } ?? "Waitlisted", fill: Color.white.opacity(0.9), text: Brand.pineTeal)
        case .cancelled:
            badge("Cancelled", fill: Color.white.opacity(0.9), text: Brand.pineTeal)
        case .unknown:
            badge("Joined", fill: Color.white.opacity(0.9), text: Brand.pineTeal)
        case .none:
            EmptyView()
        }
    }

    private var statusReasonText: String {
        switch item.booking.state {
        case .confirmed:
            return "Booking confirmed"
        case let .waitlisted(position):
            if let position {
                return "Waitlisted at #\(position)"
            }
            return "Waitlisted for next available spot"
        case .cancelled:
            return "Booking cancelled"
        case .unknown:
            return "Booking status updated"
        case .none:
            return "No booking"
        }
    }

    @ViewBuilder
    private var paymentBadge: some View {
        if let label = paymentStatusLabel {
            let isPaid = label == "Paid"
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(isPaid ? .white : Brand.pineTeal)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    isPaid ? AnyShapeStyle(Brand.pineTeal) : AnyShapeStyle(Color.white.opacity(0.9)),
                    in: Capsule()
                )
        }
    }

    private var paymentStatusLabel: String? {
        guard let game = item.game else { return item.booking.feePaid ? "Paid" : nil }
        let fee = game.feeAmount ?? 0
        if fee <= 0 { return "Free" }
        if item.booking.feePaid || item.booking.paidAt != nil { return "Paid" }
        switch item.booking.state {
        case .confirmed, .waitlisted:
            return "Payment Due"
        case .cancelled, .unknown, .none:
            return "Unpaid"
        }
    }

    private func badge(_ title: String, fill: Color, text: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(text)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(fill, in: Capsule())
    }
}

private struct BookingRowQuickActions: View {
    @EnvironmentObject private var appState: AppState
    let item: BookingWithGame

    var body: some View {
        guard let game = item.game else { return AnyView(EmptyView()) }

        let canCancel = item.booking.state.canCancel
        let isCancelling = appState.isCancellingBooking(for: game)
        let isExporting = appState.isExportingCalendar(for: game)
        let hasCalendar = appState.hasCalendarExport(for: game)

        return AnyView(
            HStack(spacing: 10) {
                if canCancel {
                    Button {
                        Task { await appState.cancelBooking(for: game) }
                    } label: {
                        HStack(spacing: 6) {
                            if isCancelling {
                                ProgressView().tint(Brand.pineTeal)
                            } else {
                                Image(systemName: "xmark.circle")
                            }
                            Text(isCancelling ? "Cancelling..." : "Cancel")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.pineTeal)
                    .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .disabled(isCancelling || isExporting)
                    .actionBorder(cornerRadius: 14, color: Brand.slateBlue.opacity(0.22))
                }

                Button {
                    Task { await appState.toggleCalendarExport(for: game) }
                } label: {
                    HStack(spacing: 6) {
                        if isExporting {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: hasCalendar ? "calendar.badge.minus" : "calendar.badge.plus")
                        }
                        Text(hasCalendar ? "Remove Calendar" : "Add to Calendar")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(
                    (hasCalendar ? Brand.slateBlue : Brand.spicyOrange),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .disabled(isCancelling || isExporting || (!canCancel && !hasCalendar))
                .opacity((!canCancel && !hasCalendar) ? 0.7 : 1)
                .actionBorder(cornerRadius: 14, color: Brand.lightCyan.opacity(0.5))

            }
        )
    }
}
