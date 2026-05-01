import CoreLocation
import SwiftUI

// MARK: - CapacityProgressBar

/// Thin horizontal capacity indicator — used in game detail rows and booking cards.
struct CapacityProgressBar: View {
    let confirmed: Int
    let maxSpots: Int
    var height: CGFloat = 7
    var labelFont: Font = .system(size: 13, weight: .medium)

    @State private var animatedFraction: Double = 0

    private var fraction: Double {
        guard maxSpots > 0 else { return 0 }
        return min(Double(confirmed) / Double(maxSpots), 1.0)
    }

    private var isFull: Bool { confirmed >= maxSpots }
    private var isNearFull: Bool { !isFull && (maxSpots - confirmed) <= 2 }

    private var fillColor: Color {
        if isFull { return Brand.errorRed }
        if isNearFull { return Color(hex: "80FF00") }
        return Color(.systemGray3)
    }

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.systemGray5))
                        .frame(height: height)
                    Capsule()
                        .fill(fillColor)
                        .frame(width: max(0, geo.size.width * animatedFraction), height: height)
                }
            }
            .frame(height: height)

            Text(isFull ? "Full" : "\(confirmed)/\(maxSpots)")
                .font(labelFont)
                .foregroundStyle(isFull ? Brand.errorRed : Brand.mutedText)
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.3)) {
                animatedFraction = fraction
            }
        }
        .onChange(of: confirmed) { _, _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                animatedFraction = fraction
            }
        }
    }
}

/// Standard game card used across the entire app: Club, Bookings, and Nearby.
///
/// Layout:
///   Left  — gradient date block (weekday · large day · month) with diagonal stripe
///   Right — status/venue row · title · time/skill/price · format · capacity bar
struct UnifiedGameCard: View {
    let game: Game
    let clubName: String
    var isBooked: Bool = false
    var isWaitlisted: Bool = false
    var resolvedVenue: ClubVenue? = nil
    /// When true: lime border (used for the "next booking" hero in Bookings list).
    var isNextBooking: Bool = false
    /// Set false to suppress the top-right status badge.
    var showStatusBadge: Bool = true
    /// When provided, the venue row becomes tappable for club navigation.
    var onClubTap: (() -> Void)? = nil
    /// When non-nil, renders an admin-only scheduled-game banner inside the card.
    var scheduledBannerCountdown: String? = nil

    private static let weekdayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d"; return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    private var venueName: String {
        if let v = resolvedVenue?.venueName, !v.isEmpty { return v }
        return clubName
    }

    // "6:00 PM · Intermediate · $15"
    private var metaLine: String {
        var parts: [String] = [Self.timeFmt.string(from: game.dateTime)]
        switch game.skillLevel.lowercased() {
        case "all":          parts.append("All Levels")
        case "beginner":     parts.append("Beginner")
        case "intermediate": parts.append("Intermediate")
        case "advanced":     parts.append("Advanced")
        default: break
        }
        if let fee = game.feeAmount, fee > 0 {
            parts.append(fee.truncatingRemainder(dividingBy: 1) == 0
                ? "$\(Int(fee))"
                : "$\(String(format: "%.2f", fee))")
        } else {
            parts.append("Free")
        }
        return parts.joined(separator: " · ")
    }

    private var formatLabel: String? {
        switch game.gameFormat.lowercased() {
        case "":                   return nil
        case "open_play":          return "Open Play"
        case "round_robin":        return "Round Robin"
        case "king_of_court":      return "King of the Court"
        case "dupr_king_of_court": return "DUPR King of Court"
        case "random":             return "Random"
        default:
            let s = game.gameFormat.replacingOccurrences(of: "_", with: " ").capitalized
            return s.isEmpty ? nil : s
        }
    }

    // Club-hash tonal gradient — matches BookingCompactCard date block
    private var dateBlockGradient: LinearGradient {
        let palettes: [(Color, Color)] = [
            (Brand.tonalNavyBase,     Brand.tonalNavyDeep),
            (Brand.tonalCharcoalBase, Brand.tonalCharcoalDeep),
            (Brand.tonalForestBase,   Brand.tonalForestDeep),
            (Brand.tonalTanBase,      Brand.tonalTanDeep),
            (Brand.tonalRoseBase,     Brand.tonalRoseDeep),
            (Brand.tonalSlateBase,    Brand.tonalSlateDeep),
        ]
        let (base, deep) = palettes[abs(game.clubID.hashValue) % palettes.count]
        return LinearGradient(colors: [base, deep], startPoint: .top, endPoint: .bottom)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                dateBlock
                contentStack
                    .padding(.vertical, 12)
                    .padding(.leading, 14)
                    .padding(.trailing, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let countdown = scheduledBannerCountdown {
                HStack(spacing: 5) {
                    Image(systemName: "eye.slash")
                        .font(.caption2.weight(.semibold))
                    Text("Not visible to the public")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    Text("Goes live in \(countdown)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10))
                .clipShape(
                    .rect(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 14,
                        bottomTrailingRadius: 14,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                )
            }
        }
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if showStatusBadge {
                availabilityBadge
                    .padding(.top, 10)
                    .padding(.trailing, 12)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isNextBooking ? Color(hex: "80FF00").opacity(0.4) : Brand.softOutline,
                    lineWidth: 1
                )
        )
        .shadow(
            color: .black.opacity(isNextBooking ? 0.07 : 0.04),
            radius: isNextBooking ? 8 : 6,
            y: 2
        )
    }

    // MARK: - Date Block

    private var dateBlock: some View {
        ZStack {
            dateBlockGradient

            Canvas { ctx, size in
                var x: CGFloat = -size.height
                while x < size.width + size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    ctx.stroke(path, with: .color(.white.opacity(0.045)), lineWidth: 1)
                    x += 14
                }
            }
            .allowsHitTesting(false)

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
        .clipShape(
            .rect(
                topLeadingRadius: 14,
                bottomLeadingRadius: 14,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
        )
    }

    // MARK: - Content Stack

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 3) {
            // First row: status dot + label + venue (when booked/waitlisted),
            // or plain venue line (when browsing unbooked games).
            if isBooked {
                statusDotRow(label: "Confirmed", color: Color(hex: "1A8A2E"))
            } else if isWaitlisted {
                statusDotRow(label: "Waitlisted", color: .orange)
            } else if !venueName.isEmpty {
                if let onClubTap {
                    Button(action: onClubTap) {
                        HStack(spacing: 3) {
                            Image(systemName: "mappin.circle")
                                .symbolRenderingMode(.monochrome)
                                .font(.system(size: 11))
                            Text(venueName)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(Brand.pineTeal)
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "mappin.circle")
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 11))
                            .foregroundStyle(Brand.mutedText)
                        Text(venueName)
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.mutedText)
                            .lineLimit(1)
                    }
                }
            }

            // Title
            Text(game.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Brand.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 36)

            // Time · Skill · Fee
            Text(metaLine)
                .font(.system(size: 13))
                .foregroundStyle(Brand.mutedText)
                .lineLimit(1)

            // Format (only when set)
            if let format = formatLabel {
                Text(format)
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.mutedText)
                    .lineLimit(1)
            }

            // Capacity bar — shown on booked cards only
            if isBooked, let confirmed = game.confirmedCount {
                CapacityProgressBar(
                    confirmed: confirmed,
                    maxSpots: game.maxSpots,
                    height: 5,
                    labelFont: .caption.weight(.medium)
                )
                .padding(.top, 3)
            }
        }
    }

    private func statusDotRow(label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
            if !venueName.isEmpty {
                Text("·")
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.secondaryText)
                Text(venueName)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Availability Badge

    @ViewBuilder
    private var availabilityBadge: some View {
        if game.status == "cancelled" {
            statusLabel("CANCELLED", color: Brand.errorRed)
        } else if isBooked {
            EmptyView()
        } else if isWaitlisted {
            statusLabel("WAITLIST", color: Brand.mutedText)
        } else if game.isFull {
            statusLabel("FULL", color: Brand.mutedText)
        } else if let left = game.spotsLeft {
            statusPill(
                left == 1 ? "1 SPOT" : "\(left) SPOTS",
                background: spotsBadgeBackground(left),
                foreground: spotsBadgeForeground(left)
            )
        }
    }

    private func spotsBadgeBackground(_ left: Int) -> Color {
        left <= 5 ? Color.orange.opacity(0.12) : Color(hex: "80FF00").opacity(0.10)
    }

    private func spotsBadgeForeground(_ left: Int) -> Color {
        left <= 5 ? Color.orange : Color(hex: "1A6B2E")
    }

    private func statusPill(_ label: String, background: Color, foreground: Color) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func statusLabel(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
    }
}
