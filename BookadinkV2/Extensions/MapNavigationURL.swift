import Foundation

enum MapNavigationURL {
    private static let maxDestinationLength = 240

    static func directions(to destination: String) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Defensive cap: malformed backend rows can contain very large payloads in location fields.
        guard trimmed.count <= maxDestinationLength else { return nil }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(encoded)")
    }
}
