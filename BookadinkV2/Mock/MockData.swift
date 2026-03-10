import Foundation

enum MockData {
    static let clubs: [Club] = [
        Club(
            id: UUID(),
            name: "Aqua Jetty Pickleball",
            city: "Warnbro",
            region: "WA",
            memberCount: 57,
            description: "A social and competitive community club with evening ladder play, beginner coaching, and weekend socials.",
            contactEmail: "jahrenholz@gmail.com",
            address: "87 Warnbro Sound Ave, Warnbro WA 6169, Australia",
            imageSystemName: "tennis.racket.circle.fill",
            imageURL: nil,
            website: nil,
            managerName: "Rachel Ahrenholz",
            membersOnly: false,
            tags: ["Beginner Friendly", "Ladder", "Social"],
            topMembers: [
                ClubMember(id: UUID(), rank: 1, name: "Ben Hildreth", rating: 4.194, reliability: 100),
                ClubMember(id: UUID(), rank: 2, name: "Rajah Maraginot", rating: 3.912, reliability: 100),
                ClubMember(id: UUID(), rank: 3, name: "Dylan Quadrio", rating: 3.799, reliability: 95),
                ClubMember(id: UUID(), rank: 4, name: "Jesse Gordon", rating: 3.791, reliability: 77),
                ClubMember(id: UUID(), rank: 5, name: "Paul Clowry", rating: 3.745, reliability: 100)
            ]
        ),
        Club(
            id: UUID(),
            name: "Canberra Pickleball League",
            city: "Canberra",
            region: "ACT",
            memberCount: 177,
            description: "League-driven club with organized events, ratings, and rotating doubles sessions across multiple venues.",
            contactEmail: "admin@canberrapickleball.example",
            address: "Canberra ACT, Australia",
            imageSystemName: "figure.tennis",
            imageURL: nil,
            website: "https://example.com/cpl",
            managerName: "League Admin",
            membersOnly: false,
            tags: ["League", "Events", "Intermediate+"],
            topMembers: [
                ClubMember(id: UUID(), rank: 1, name: "Mia Reid", rating: 4.362, reliability: 98),
                ClubMember(id: UUID(), rank: 2, name: "Oscar Lane", rating: 4.120, reliability: 95),
                ClubMember(id: UUID(), rank: 3, name: "Tina Wu", rating: 3.998, reliability: 91)
            ]
        ),
        Club(
            id: UUID(),
            name: "Phoenix Pickleball Club",
            city: "Balikpapan",
            region: "East Kalimantan",
            memberCount: 59,
            description: "Community-first club running casual nights and mixed-skill sessions with a focus on welcoming new players.",
            contactEmail: "hello@phoenixpickleball.example",
            address: "Balikpapan, East Kalimantan",
            imageSystemName: "flame.circle.fill",
            imageURL: nil,
            website: nil,
            managerName: nil,
            membersOnly: true,
            tags: ["Community", "Social", "Coaching"],
            topMembers: [
                ClubMember(id: UUID(), rank: 1, name: "Lina Hart", rating: 4.008, reliability: 93),
                ClubMember(id: UUID(), rank: 2, name: "Marc Dela Cruz", rating: 3.887, reliability: 89)
            ]
        )
    ]
}
