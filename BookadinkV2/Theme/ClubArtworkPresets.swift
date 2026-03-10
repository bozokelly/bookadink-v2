import Foundation

enum ClubProfileImagePresets {
    private static let scheme = "bookadink-avatar"
    private static let host = "club"

    static var all: [ProfileAvatarPreset] {
        ProfileAvatarPresets.all
    }

    static func preset(for id: String?) -> ProfileAvatarPreset? {
        ProfileAvatarPresets.preset(for: id)
    }

    static func preset(for imageURL: URL?) -> ProfileAvatarPreset? {
        preset(for: presetID(from: imageURL))
    }

    static func presetURL(for id: String) -> URL? {
        guard preset(for: id) != nil else { return nil }
        return URL(string: "\(scheme)://\(host)/\(id)")
    }

    static func presetID(from url: URL?) -> String? {
        guard let url else { return nil }
        guard url.host == host else { return nil }
        guard url.scheme == scheme else { return nil }

        let id = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        guard preset(for: id) != nil else { return nil }
        return id
    }
}
