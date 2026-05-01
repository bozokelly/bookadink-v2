import CoreLocation
import Foundation

// MARK: - Geocode Result

/// Typed result from a venue address geocoding attempt.
/// Callers must handle all cases — no case is treated as a silent success.
enum GeocodeResult {
    /// Geocoding succeeded and returned a valid coordinate.
    case success(CLLocation)
    /// No address text was provided — nothing to geocode.
    case emptyAddress
    /// Geocoder ran successfully but returned no matching location.
    case noResult
    /// Geocoder threw an error (network failure, rate limit, etc.).
    case failed
}

// MARK: - Geocoding

extension LocationService {
    /// Geocodes a ClubVenueDraft's address fields.
    /// Returns a typed GeocodeResult — callers must not treat non-success as acceptable.
    static func geocode(draft: ClubVenueDraft) async -> GeocodeResult {
        let parts = [
            draft.streetAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            draft.suburb.trimmingCharacters(in: .whitespacesAndNewlines),
            draft.state.trimmingCharacters(in: .whitespacesAndNewlines),
            draft.postcode.trimmingCharacters(in: .whitespacesAndNewlines),
            draft.country.trimmingCharacters(in: .whitespacesAndNewlines)
        ].filter { !$0.isEmpty }
        guard !parts.isEmpty else { return .emptyAddress }
        let addressString = parts.joined(separator: ", ")
        return await withCheckedContinuation { continuation in
            CLGeocoder().geocodeAddressString(addressString) { placemarks, error in
                if error != nil {
                    continuation.resume(returning: .failed)
                } else if let location = placemarks?.first?.location {
                    continuation.resume(returning: .success(location))
                } else {
                    continuation.resume(returning: .noResult)
                }
            }
        }
    }
}

enum LocationService {

    // MARK: - Distance

    /// Returns the distance in metres between two coordinates, or nil if either is nil.
    static func distance(
        from origin: CLLocation?,
        to destination: CLLocation?
    ) -> CLLocationDistance? {
        guard let origin, let destination else { return nil }
        return origin.distance(from: destination)
    }

    // MARK: - Formatted Distance

    /// "0.4 km", "1.2 km", "14 km" — nil when distance is unavailable.
    static func formattedDistance(_ metres: CLLocationDistance?) -> String? {
        guard let metres else { return nil }
        let km = metres / 1_000
        if km < 1 {
            return String(format: "%.1f km", km)
        } else if km < 10 {
            return String(format: "%.1f km", km)
        } else {
            return String(format: "%.0f km", km)
        }
    }

    // MARK: - Coordinate Extraction
    //
    // RULE: Two entity types. Two distinct coordinate sources. Never mixed.
    //
    //   CLUBS  → primary venue coordinates (Stage 4: venue is the source of truth).
    //            When venues are available, primary venue coordinates take precedence.
    //            club.latitude / club.longitude is a fallback cache only.
    //            Use location(for:venues:) wherever venues are loaded.
    //            Use location(for:) only where venues are unavailable.
    //
    //   GAMES  → venue-first resolution.
    //            1. game.venueId FK match → ClubVenue coordinates
    //            2. game.venueName fallback match → ClubVenue coordinates
    //            3. Primary venue fallback
    //            4. club.latitude / club.longitude
    //            Used by: Home "Your Next Game", Games Near You, Game Detail.

    /// Returns a CLLocation for a Club using only its stored club-level coordinates.
    /// Use this only where venue data is unavailable.
    /// Prefer location(for:venues:) wherever venues are loaded.
    static func location(for club: Club) -> CLLocation? {
        guard let lat = club.latitude, let lng = club.longitude else { return nil }
        return CLLocation(latitude: lat, longitude: lng)
    }

    /// Returns a CLLocation for a Club, using primary venue coordinates as the
    /// authoritative source (Stage 4). Club-level coordinates are a fallback only.
    ///
    /// Priority:
    ///   1. Primary ClubVenue coordinates (isPrimary == true, has lat/lng)
    ///   2. Any ClubVenue with coordinates (non-primary fallback)
    ///   3. club.latitude / club.longitude (legacy fallback cache)
    ///
    /// Use this for Explore Nearby map pins and club distance labels.
    static func location(for club: Club, venues: [ClubVenue]) -> CLLocation? {
        // Primary venue is the source of truth — check it first.
        let candidate = venues.first(where: { $0.isPrimary && $0.latitude != nil })
                     ?? venues.first(where: { $0.latitude != nil })
        if let candidate, let loc = location(for: candidate) { return loc }
        // Fallback: club-level coordinate cache (pre-Stage 4 clubs, no venues yet).
        return location(for: club)
    }

    /// Returns a CLLocation for a ClubVenue if it has stored coordinates.
    static func location(for venue: ClubVenue) -> CLLocation? {
        guard let lat = venue.latitude, let lng = venue.longitude else { return nil }
        return CLLocation(latitude: lat, longitude: lng)
    }

    /// Returns the ClubVenue for a game.
    ///
    /// Resolution order:
    ///   1. `game.venueId` — exact FK match (no string comparison needed)
    ///   2. `game.venueName` — case-insensitive fallback for older games without venue_id
    ///
    /// This is the single source of truth for resolving which venue a game is played at.
    /// Use this everywhere you need the venue's structured address, coordinates, or
    /// display name — distance calculation, map navigation, and address display.
    static func resolvedVenue(for game: Game, venues: [ClubVenue]) -> ClubVenue? {
        // 1. Prefer venue_id FK match — fast and unambiguous
        if let venueId = game.venueId,
           let match = venues.first(where: { $0.id == venueId }) {
            return match
        }
        // 2. Fallback: case-insensitive venue_name match for pre-migration games
        guard let name = game.venueName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return venues.first(where: {
            $0.venueName.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(name) == .orderedSame
        })
    }

    /// Builds a formatted address string from a ClubVenue's structured fields.
    ///
    /// Format: "Street Address, Suburb STATE Postcode"
    /// Returns nil when no address fields are populated.
    static func formattedAddress(for venue: ClubVenue) -> String? {
        var parts: [String] = []
        if let street = venue.streetAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !street.isEmpty {
            parts.append(street)
        }
        var suburbState = [venue.suburb, venue.state]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if let pc = venue.postcode?.trimmingCharacters(in: .whitespacesAndNewlines), !pc.isEmpty {
            suburbState += (suburbState.isEmpty ? "" : " ") + pc
        }
        if !suburbState.isEmpty { parts.append(suburbState) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Resolves the best available CLLocation for a game.
    ///
    /// Priority:
    ///   1. Game's own latitude/longitude (stored directly on the games row)
    ///   2. Game's matched ClubVenue coordinates (venueId FK or venueName fallback)
    ///   3. Club's primary ClubVenue coordinates (isPrimary == true)
    ///   4. Club's own coordinates — fallback while venue geocoding stabilises
    ///
    /// Pass `clubs` to enable the club-coordinate fallback. Defaults to empty (no fallback).
    static func location(for game: Game, venues: [ClubVenue], clubs: [Club] = []) -> CLLocation? {
        // 1. Game-level coordinates — most direct source.
        if let lat = game.latitude, let lng = game.longitude {
            return CLLocation(latitude: lat, longitude: lng)
        }
        // 2. Resolved venue coordinates.
        if let match = resolvedVenue(for: game, venues: venues),
           let venueLocation = location(for: match) {
            return venueLocation
        }
        // 3. Primary venue fallback.
        if let primary = venues.first(where: { $0.isPrimary }),
           let primaryLocation = location(for: primary) {
            return primaryLocation
        }
        // 4. Club-level coordinates.
        if let club = clubs.first(where: { $0.id == game.clubID }) {
            return location(for: club)
        }
        return nil
    }

    // MARK: - Proximity Sorting

    /// Sorts clubs by distance from `origin` (nearest first).
    /// Uses club.latitude/longitude — no venue lookup (see coordinate extraction rules above).
    /// Clubs without coordinates are pushed to the end.
    static func sortByProximity(_ clubs: [Club], from origin: CLLocation?) -> [Club] {
        guard let origin else { return clubs }
        return clubs.sorted { a, b in
            let da = distance(from: origin, to: location(for: a))
            let db = distance(from: origin, to: location(for: b))
            switch (da, db) {
            case let (.some(d1), .some(d2)): return d1 < d2
            case (.some, .none):             return true
            case (.none, .some):             return false
            case (.none, .none):             return false
            }
        }
    }

    /// Sorts clubs by distance, using club coordinates with primary venue fallback.
    /// Use this for Explore Nearby where some clubs may only have venue-level geocoding.
    static func sortByProximity(
        _ clubs: [Club],
        from origin: CLLocation?,
        venuesByClubID: [UUID: [ClubVenue]]
    ) -> [Club] {
        guard let origin else { return clubs }
        return clubs.sorted { a, b in
            let da = distance(from: origin, to: location(for: a, venues: venuesByClubID[a.id] ?? []))
            let db = distance(from: origin, to: location(for: b, venues: venuesByClubID[b.id] ?? []))
            switch (da, db) {
            case let (.some(d1), .some(d2)): return d1 < d2
            case (.some, .none):             return true
            case (.none, .some):             return false
            case (.none, .none):             return false
            }
        }
    }

    /// Sorts games by distance from `origin`.
    ///
    /// Uses venue-first resolution: matched ClubVenue → primary venue → club coords (if provided).
    /// Games with no resolvable coordinates are pushed to the end.
    static func sortByProximity(
        _ games: [Game],
        from origin: CLLocation?,
        venuesByClubID: [UUID: [ClubVenue]] = [:],
        clubs: [Club] = []
    ) -> [Game] {
        guard let origin else { return games }
        return games.sorted { a, b in
            let da = distance(from: origin, to: location(for: a, venues: venuesByClubID[a.clubID] ?? [], clubs: clubs))
            let db = distance(from: origin, to: location(for: b, venues: venuesByClubID[b.clubID] ?? [], clubs: clubs))
            switch (da, db) {
            case let (.some(d1), .some(d2)): return d1 < d2
            case (.some, .none):             return true
            case (.none, .some):             return false
            case (.none, .none):             return false
            }
        }
    }

    // MARK: - Time-Bucketed Proximity Sort

    /// Ranks games for the "Games Near You" feature using a practical near-term ordering:
    ///
    ///   1. Today (next 24 h)     — sorted by proximity, then soonest time
    ///   2. This week (1–7 days)  — sorted by proximity, then soonest time
    ///   3. Later (7+ days)       — sorted by proximity, then soonest time
    ///
    /// This prevents a game that is 0.2 km nearer from outranking one that is
    /// happening hours sooner. When `origin` is nil the sort collapses to
    /// soonest-first within each bucket (no distance calculation needed).
    ///
    /// Pass `venuesByClubID` (from `AppState.clubVenuesByClubID`) to enable
    /// venue-aware distance resolution. Game venue → primary venue → no location.
    /// Games with no resolvable venue coordinates go to the bucket end.
    static func sortByTimeBucketThenProximity(
        _ games: [Game],
        from origin: CLLocation?,
        venuesByClubID: [UUID: [ClubVenue]] = [:],
        clubs: [Club] = []
    ) -> [Game] {
        let now    = Date()
        let in24h  = now.addingTimeInterval(24 * 3_600)
        let in7d   = now.addingTimeInterval(7  * 24 * 3_600)

        let today    = sortByProximity(
            games.filter { $0.dateTime < in24h                         }.sorted { $0.dateTime < $1.dateTime },
            from: origin, venuesByClubID: venuesByClubID, clubs: clubs)
        let thisWeek = sortByProximity(
            games.filter { $0.dateTime >= in24h && $0.dateTime < in7d }.sorted { $0.dateTime < $1.dateTime },
            from: origin, venuesByClubID: venuesByClubID, clubs: clubs)
        let later    = sortByProximity(
            games.filter { $0.dateTime >= in7d                         }.sorted { $0.dateTime < $1.dateTime },
            from: origin, venuesByClubID: venuesByClubID, clubs: clubs)

        return today + thisWeek + later
    }

    // MARK: - Distance Labels

    /// Formatted distance from `origin` to a club. Uses club.latitude/longitude only.
    static func distanceLabel(from origin: CLLocation?, to club: Club) -> String? {
        formattedDistance(distance(from: origin, to: location(for: club)))
    }

    /// Formatted distance from `origin` to a club, using primary venue coordinates as fallback.
    static func distanceLabel(from origin: CLLocation?, to club: Club, venues: [ClubVenue]) -> String? {
        formattedDistance(distance(from: origin, to: location(for: club, venues: venues)))
    }

    /// Formatted distance from `origin` to a specific ClubVenue.
    static func distanceLabel(from origin: CLLocation?, to venue: ClubVenue) -> String? {
        formattedDistance(distance(from: origin, to: location(for: venue)))
    }

    /// Formatted distance from `origin` to a game's resolved venue.
    /// Priority: matched ClubVenue → primary venue → club coords (if provided).
    static func distanceLabel(from origin: CLLocation?, game: Game, venues: [ClubVenue], clubs: [Club] = []) -> String? {
        formattedDistance(distance(from: origin, to: location(for: game, venues: venues, clubs: clubs)))
    }
}
