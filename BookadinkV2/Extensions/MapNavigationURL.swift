import CoreLocation
import Foundation

enum MapNavigationURL {
    private static let maxDestinationLength = 240

    /// Coordinate-based directions URL — precise pin, no string geocoding.
    /// Preferred over the string overload when exact lat/lng are available.
    /// Returns nil when both latitude and longitude are exactly zero (unset default).
    static func directions(to coordinate: CLLocationCoordinate2D) -> URL? {
        guard coordinate.latitude != 0 || coordinate.longitude != 0 else { return nil }
        let lat = String(format: "%.7f", coordinate.latitude)
        let lng = String(format: "%.7f", coordinate.longitude)
        return URL(string: "https://maps.apple.com/?daddr=\(lat),\(lng)&dirflg=d")
    }

    /// String-search directions URL — fallback when exact coordinates are unavailable.
    /// Defensive cap prevents malformed backend payloads from generating invalid URLs.
    static func directions(to destination: String) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maxDestinationLength else { return nil }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://maps.apple.com/?q=\(encoded)")
    }
}
