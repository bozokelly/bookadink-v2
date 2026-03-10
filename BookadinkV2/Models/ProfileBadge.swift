import SwiftUI

struct ProfileBadge: Identifiable {
    let id: String
    let title: String
    let description: String
    let systemImage: String
    let colour: Color
    let earnedAt: Date?

    var isEarned: Bool { earnedAt != nil }
}
