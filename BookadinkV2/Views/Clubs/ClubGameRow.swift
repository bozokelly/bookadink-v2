import CoreLocation
import SwiftUI

/// Standard game card used across the entire app: Home, Club, Bookings, and Nearby.
///
/// Layout:
///   Left rail  — Month (small caps) + Day (large bold)
///   Right col  — Title · Venue name · Time/Skill/Format line · Availability badge
struct UnifiedGameCard: View {
    let game: Game
    let clubName: String
    var isBooked: Bool = false
    var isWaitlisted: Bool = false
    var resolvedVenue: ClubVenue? = nil
    /// When true: lime left-edge sliver + lime border (used for "next booking" in Bookings list).
    var isNextBooking: Bool = false
    /// When provided, the venue/club name row becomes tappable and navigates to the club.
    var onClubTap: (() -> Void)? = nil

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d"; return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    // Venue name: prefer resolved venue, fallback to club name
    private var venueName: String {
        if let v = resolvedVenue?.venueName, !v.isEmpty { return v }
        return clubName
    }

    // Compact meta line: "6:00 PM · Intermediate · Round Robin"
    private var metaLine: String {
        var parts: [String] = [Self.timeFmt.string(from: game.dateTime)]
        switch game.skillLevel.lowercased() {
        case "beginner":     parts.append("Beginner")
        case "intermediate": parts.append("Intermediate")
        case "advanced":     parts.append("Advanced")
        default: break
        }
        switch game.gameFormat.lowercased() {
        case "open_play": break
        case "round_robin":        parts.append("Round Robin")
        case "king_of_court":      parts.append("King of the Court")
        case "dupr_king_of_court": parts.append("DUPR King of Court")
        case "random":             parts.append("Random")
        default:
            if !game.gameFormat.isEmpty {
                parts.append(game.gameFormat.replacingOccurrences(of: "_", with: " ").capitalized)
            }
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            dateRail
            contentStack
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isNextBooking ? Color(hex: "80FF00").opacity(0.4) : Brand.softOutline,
                    lineWidth: 1
                )
        )
        .overlay(alignment: .leading) {
            if isNextBooking {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(hex: "80FF00"))
                    .frame(width: 3)
                    .padding(.vertical, 12)
            }
        }
        .shadow(
            color: .black.opacity(isNextBooking ? 0.07 : 0.04),
            radius: isNextBooking ? 8 : 6,
            y: 2
        )
    }

    // MARK: - Date Rail

    private var dateRail: some View {
        VStack(spacing: 1) {
            Text(Self.monthFmt.string(from: game.dateTime).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Brand.mutedText)
                .tracking(0.5)
            Text(Self.dayFmt.string(from: game.dateTime))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.ink)
                .lineLimit(1)
        }
        .frame(width: 44, alignment: .top)
        .padding(.top, 2)
    }

    // MARK: - Content Stack

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title
            Text(game.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Brand.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Venue / club name — tappable when onClubTap is provided
            if !venueName.isEmpty {
                if let onClubTap {
                    Button(action: onClubTap) {
                        HStack(spacing: 3) {
                            Image(systemName: "mappin.circle")
                                .font(.system(size: 11))
                            Text(venueName)
                                .font(.system(size: 13))
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
                            .font(.system(size: 11))
                            .foregroundStyle(Brand.mutedText)
                        Text(venueName)
                            .font(.system(size: 13))
                            .foregroundStyle(Brand.mutedText)
                            .lineLimit(1)
                    }
                }
            }

            // Time · Skill · Format
            Text(metaLine)
                .font(.system(size: 13))
                .foregroundStyle(Brand.mutedText)
                .lineLimit(1)

            // Availability badge
            availabilityBadge
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Availability Badge

    @ViewBuilder
    private var availabilityBadge: some View {
        if game.status == "cancelled" {
            statusLabel("CANCELLED", color: Brand.errorRed)
        } else if isBooked {
            statusPill("BOOKED",
                       background: Color(hex: "80FF00").opacity(0.14),
                       foreground: Color(hex: "1A6B2E"))
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
        } else {
            // confirmedCount not available — show total
            statusLabel("\(game.maxSpots) SPOTS", color: Brand.mutedText)
        }
    }

    private func spotsBadgeBackground(_ left: Int) -> Color {
        switch left {
        case 1:     return Color.red.opacity(0.12)
        case 2...5: return Color.orange.opacity(0.12)
        default:    return Color(hex: "80FF00").opacity(0.10)
        }
    }

    private func spotsBadgeForeground(_ left: Int) -> Color {
        switch left {
        case 1:     return Color.red
        case 2...5: return Color.orange
        default:    return Color(hex: "1A6B2E")
        }
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
