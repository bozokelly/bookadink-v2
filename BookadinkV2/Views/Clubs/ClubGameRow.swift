import SwiftUI
import os

struct ClubGameRow: View {
    let game: Game
    let bookingState: BookingState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            gameHeader

            gameMeta

            capacitySection
        }
        .padding(12)
        .background(Color.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Brand.slateBlue.opacity(0.12), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gameHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                gameTitleBlock
                Spacer(minLength: 8)
                gameBadgesBlock
            }

            VStack(alignment: .leading, spacing: 8) {
                gameTitleBlock
                HStack {
                    Spacer(minLength: 0)
                    gameBadgesBlock
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var gameTitleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(game.title)
                .font(.headline)
                .foregroundStyle(Brand.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(game.dateTime.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.pineTeal)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gameBadgesBlock: some View {
        VStack(alignment: .trailing, spacing: 6) {
            statusBadge
            dateBadge
            if game.recurrenceGroupID != nil {
                Text("Recurring")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Brand.slateBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Brand.slateBlue.opacity(0.1), in: Capsule())
            }
        }
    }

    private var gameMeta: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Label(game.displayLocation, systemImage: "mappin.and.ellipse")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Label("\(game.durationMinutes)m", systemImage: "clock")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                gameFeeText
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label(game.displayLocation, systemImage: "mappin.and.ellipse")
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Label("\(game.durationMinutes)m", systemImage: "clock")
                        .lineLimit(1)
                    gameFeeText
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(Brand.mutedText)
    }

    private var gameFeeText: Text {
        if let fee = game.feeAmount, fee > 0 {
            return Text("$\(fee, specifier: "%.2f")")
        }
        return Text("Free")
    }

    private var waitlistSuffix: String {
        guard let waitlist = game.waitlistCount, waitlist > 0 else { return "" }
        return " • \(waitlist) waitlisted"
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch bookingState {
        case .none:
            EmptyView()
        case .confirmed:
            badge("Booked", fill: Brand.pineTeal, text: .white)
        case let .waitlisted(position):
            badge(position.map { "Waitlist #\($0)" } ?? "Waitlisted", fill: Color.white.opacity(0.92), text: Brand.pineTeal)
        case .cancelled:
            badge("Cancelled", fill: Color.white.opacity(0.92), text: Brand.pineTeal)
        case .unknown:
            badge("Joined", fill: Color.white.opacity(0.92), text: Brand.pineTeal)
        }
    }

    private var dateBadge: some View {
        let style = dateBadgeStyle()

        return Text(style.label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(style.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(style.fill, in: Capsule())
    }

    private var capacitySection: some View {
        Group {
            if let confirmed = game.confirmedCount {
                capacityContent(confirmed: confirmed)
            }
        }
    }

    private func capacityContent(confirmed: Int) -> some View {
        let maxSpots = max(game.maxSpots, 1)
        let ratio = min(max(Double(confirmed) / Double(maxSpots), 0), 1)
        let fillColor = game.isFull ? Brand.spicyOrange : Brand.pineTeal

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(confirmed)/\(game.maxSpots) spots")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Brand.mutedText)
                Spacer()
                if let spotsLeft = game.spotsLeft {
                    Text(game.isFull ? "Full\(waitlistSuffix)" : "\(spotsLeft) left")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(game.isFull ? Brand.spicyOrange : Brand.pineTeal)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Brand.rosyTaupe.opacity(0.22))
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fillColor)
                        .frame(width: max(proxy.size.width, 1) * ratio)
                }
            }
            .frame(height: 8)

            if let waitlist = game.waitlistCount, waitlist > 0 {
                Text("\(waitlist) on waitlist")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Brand.spicyOrange)
            }
        }
    }

    private func dateBadgeStyle() -> (label: String, fill: Color, text: Color) {
        let calendar = Calendar.current
        if calendar.isDateInToday(game.dateTime) {
            return ("Today", Brand.spicyOrange, .white)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()),
           calendar.isDate(game.dateTime, inSameDayAs: tomorrow) {
            return ("Tomorrow", Color.white.opacity(0.92), Brand.pineTeal)
        }
        if calendar.isDateInWeekend(game.dateTime) {
            return ("Weekend", Color.white.opacity(0.92), Brand.pineTeal)
        }
        return ("Upcoming", Color.white.opacity(0.92), Brand.pineTeal)
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
