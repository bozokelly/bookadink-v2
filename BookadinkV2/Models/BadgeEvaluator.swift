import SwiftUI

struct BadgeEvaluator {

    @MainActor
    static func evaluate(for profile: UserProfile, appState: AppState) -> [ProfileBadge] {
        let confirmedBookings = appState.bookings.filter {
            if case .confirmed = $0.booking.state { return true }
            return false
        }
        let bookingCount = confirmedBookings.count
        let sortedBookingDates = confirmedBookings.compactMap(\.booking.createdAt).sorted()

        let totalClubCount = appState.clubs.filter { club in
            if appState.isClubAdmin(for: club) { return true }
            switch appState.membershipState(for: club) {
            case .approved, .unknown: return true
            default: return false
            }
        }.count

        let isAdmin = appState.clubs.contains { appState.isClubAdmin(for: $0) }

        let history = appState.duprHistory.sorted { $0.recordedAt < $1.recordedAt }
        let duprImproved: Bool = {
            guard history.count >= 2 else { return false }
            return (history.last!.rating - history.first!.rating) >= 0.1
        }()

        let gold = Color(red: 1.0, green: 0.78, blue: 0.0)

        return [
            ProfileBadge(
                id: "first_booking",
                title: "First Dink",
                description: "Made your first booking.",
                systemImage: "figure.pickleball",
                colour: Brand.pineTeal,
                earnedAt: bookingCount >= 1 ? sortedBookingDates.first : nil
            ),
            ProfileBadge(
                id: "ten_games",
                title: "On A Roll",
                description: "Played 10 confirmed games.",
                systemImage: "flame.fill",
                colour: Brand.spicyOrange,
                earnedAt: bookingCount >= 10 ? sortedBookingDates.dropFirst(9).first : nil
            ),
            ProfileBadge(
                id: "fifty_games",
                title: "Court Regular",
                description: "Played 50 confirmed games.",
                systemImage: "trophy.fill",
                colour: gold,
                earnedAt: bookingCount >= 50 ? sortedBookingDates.dropFirst(49).first : nil
            ),
            ProfileBadge(
                id: "five_clubs",
                title: "Social Player",
                description: "Member or admin of 5+ clubs.",
                systemImage: "person.3.fill",
                colour: .indigo,
                earnedAt: totalClubCount >= 5 ? Date() : nil
            ),
            ProfileBadge(
                id: "admin",
                title: "Club Admin",
                description: "Admin of at least one club.",
                systemImage: "shield.lefthalf.filled",
                colour: Brand.pineTeal,
                earnedAt: isAdmin ? Date() : nil
            ),
            ProfileBadge(
                id: "dupr_updated",
                title: "Rated Player",
                description: "Logged your first DUPR update.",
                systemImage: "chart.line.uptrend.xyaxis",
                colour: Brand.emeraldAction,
                earnedAt: history.count >= 1 ? history.first?.recordedAt : nil
            ),
            ProfileBadge(
                id: "dupr_improved",
                title: "Levelling Up",
                description: "DUPR improved by 0.1 or more.",
                systemImage: "arrow.up.circle.fill",
                colour: Brand.emeraldAction,
                earnedAt: duprImproved ? Date() : nil
            ),
            // Requires chat post tracking — not yet available
            ProfileBadge(
                id: "first_post",
                title: "Club Voice",
                description: "First post in a club chat.",
                systemImage: "bubble.left.fill",
                colour: .blue,
                earnedAt: nil
            ),
            ProfileBadge(
                id: "regular_contributor",
                title: "Chatterbox",
                description: "10+ posts in club chats.",
                systemImage: "text.bubble.fill",
                colour: .purple,
                earnedAt: nil
            ),
            // Requires account creation date — not yet available
            ProfileBadge(
                id: "member_1_year",
                title: "Veteran",
                description: "Member for 1 full year.",
                systemImage: "calendar.badge.checkmark",
                colour: Brand.pineTeal,
                earnedAt: nil
            ),
            ProfileBadge(
                id: "early_adopter",
                title: "OG Dinkster",
                description: "Joined in the first 6 months of Book A Dink.",
                systemImage: "star.fill",
                colour: gold,
                earnedAt: nil
            ),
        ]
    }
}
