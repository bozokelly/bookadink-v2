import Foundation

/// Parses incoming URLs into typed deep link destinations.
///
/// Supported schemes:
///   bookadink://club/{uuid}
///   bookadink://game/{uuid}
///
/// Universal links (future, when bookadink.com is live):
///   https://bookadink.com/club/{uuid}
///   https://www.bookadink.com/club/{uuid}
enum DeepLink: Equatable {
    case club(id: UUID)
    case game(id: UUID)
    case review(gameID: UUID)
    /// Stripe Connect onboarding return. `status` is "complete" or "refresh" (link expired).
    case connectReturn(clubID: UUID, status: String)

    private static let knownHosts: Set<String> = ["bookadink.com", "www.bookadink.com"]

    init?(url: URL) {
        // Stripe Connect return deep links:
        //   bookadink://stripe-return/{clubID}  — owner completed all onboarding steps
        //   bookadink://stripe-refresh/{clubID} — Account Link expired mid-flow
        if url.scheme == "bookadink",
           let host = url.host,
           (host == "stripe-return" || host == "stripe-refresh"),
           let clubID = UUID(uuidString: url.lastPathComponent) {
            let status = host == "stripe-return" ? "complete" : "refresh"
            self = .connectReturn(clubID: clubID, status: status)
            return
        }

        // Custom scheme: bookadink://club/{uuid}
        if url.scheme == "bookadink" {
            guard let host = url.host, let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            switch host {
            case "club": self = .club(id: id)
            case "game": self = .game(id: id)
            default: return nil
            }
            return
        }

        // Universal link: https://bookadink.com/club/{uuid} or https://www.bookadink.com/...
        guard let host = url.host, Self.knownHosts.contains(host) else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 2, let id = UUID(uuidString: components[1]) else { return nil }
        switch components[0] {
        case "club": self = .club(id: id)
        case "game": self = .game(id: id)
        default: return nil
        }
    }

    /// Shareable URL using the custom scheme so the app opens directly.
    /// Uses bookadink:// rather than HTTPS because bookadink.com is not yet
    /// a live website — HTTPS links just open Safari and hit 404.
    var shareURL: URL {
        switch self {
        case .club(let id):
            return URL(string: "bookadink://club/\(id.uuidString)")!
        case .game(let id):
            return URL(string: "bookadink://game/\(id.uuidString)")!
        case .review(let gameID):
            return URL(string: "bookadink://game/\(gameID.uuidString)")!
        case .connectReturn(let clubID, let status):
            let host = status == "complete" ? "stripe-return" : "stripe-refresh"
            return URL(string: "bookadink://\(host)/\(clubID.uuidString.lowercased())")!
        }
    }

    static func clubURL(id: UUID) -> URL {
        DeepLink.club(id: id).shareURL
    }

    static func gameURL(id: UUID) -> URL {
        DeepLink.game(id: id).shareURL
    }
}
