import Foundation

/// Parses incoming URLs into typed deep link destinations.
///
/// Supported schemes:
///   bookadink://club/{uuid}
///   bookadink://game/{uuid}
///
/// When universal links are configured (bookadink.com), the same
/// path structure applies:
///   https://bookadink.com/club/{uuid}
///   https://bookadink.com/game/{uuid}
enum DeepLink: Equatable {
    case club(id: UUID)
    case game(id: UUID)

    init?(url: URL) {
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

        // Universal link: https://bookadink.com/club/{uuid}
        guard url.host == "bookadink.com" else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 2, let id = UUID(uuidString: components[1]) else { return nil }
        switch components[0] {
        case "club": self = .club(id: id)
        case "game": self = .game(id: id)
        default: return nil
        }
    }

    /// Shareable URL for this deep link destination.
    var shareURL: URL {
        switch self {
        case .club(let id):
            return URL(string: "https://bookadink.com/club/\(id.uuidString)")!
        case .game(let id):
            return URL(string: "https://bookadink.com/game/\(id.uuidString)")!
        }
    }

    static func clubURL(id: UUID) -> URL {
        DeepLink.club(id: id).shareURL
    }

    static func gameURL(id: UUID) -> URL {
        DeepLink.game(id: id).shareURL
    }
}
