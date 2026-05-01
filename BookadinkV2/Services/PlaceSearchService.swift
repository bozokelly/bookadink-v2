import Combine
import CoreLocation
import Foundation
import MapKit

// MARK: - Result Model

/// A single autocomplete suggestion from the place search provider.
/// Title and subtitle come directly from the provider; coordinates are not yet resolved.
/// Call `PlaceSearchService.resolve(_:)` after selection to get full place details.
struct PlaceSearchSuggestion: Identifiable, Equatable {
    let id: UUID
    /// Primary display name — e.g. "Kwinana Recreation Centre"
    let title: String
    /// Secondary context — e.g. "Sulphur Road, Kwinana WA"
    let subtitle: String

    // NOTE: MKLocalSearchCompleter does not vend a stable place identifier.
    // We intentionally do not invent one. The raw completion is retained so
    // we can hand it back to MKLocalSearch for coordinate resolution.
    let _completion: MKLocalSearchCompletion

    static func == (lhs: PlaceSearchSuggestion, rhs: PlaceSearchSuggestion) -> Bool {
        lhs.id == rhs.id
    }
}

/// A fully resolved place — coordinates confirmed, ready to populate a ClubVenueDraft.
struct ResolvedPlace {
    /// Venue name suitable as a default for ClubVenueDraft.venueName
    let name: String
    /// Single-line formatted address — may be partial if Apple omits components
    let formattedAddress: String
    let coordinate: CLLocationCoordinate2D
    /// Locality (suburb/city) if Apple returns it
    let locality: String?
    /// Administrative area (state) if Apple returns it
    let administrativeArea: String?
    /// Postal code if Apple returns it
    let postalCode: String?
    /// Country name if Apple returns it
    let country: String?
    /// Thoroughfare (street address) if Apple returns it
    let thoroughfare: String?
}

// MARK: - State

/// Observable state for a place search session.
enum PlaceSearchState: Equatable {
    /// No query entered, or query was cleared.
    case idle
    /// Query is being debounced or completer is working.
    case searching
    /// Results are ready. May be empty.
    case results([PlaceSearchSuggestion])
    /// Full resolution of a selected suggestion is in progress.
    case resolving
    /// A suggestion was fully resolved.
    case resolved(ResolvedPlace)
    /// Provider or network failure.
    case failed(String)

    static func == (lhs: PlaceSearchState, rhs: PlaceSearchState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.searching, .searching), (.resolving, .resolving):
            return true
        case let (.results(a), .results(b)):
            return a == b
        case let (.failed(a), .failed(b)):
            return a == b
        case (.resolved, .resolved):
            // ResolvedPlace is a struct; treat any two .resolved states as unequal
            // for simplicity — the view always re-renders on this transition anyway.
            return false
        default:
            return false
        }
    }
}

// MARK: - Protocol

/// Abstraction over a place search / autocomplete provider.
/// Conform to this to swap in a different backend without touching Stage 3 UI.
@MainActor
protocol PlaceSearchProviding: ObservableObject {
    var state: PlaceSearchState { get }
    /// Update the search query. Short or empty strings produce `.idle`.
    func search(query: String)
    /// Resolve a suggestion to full place details including coordinates.
    func resolve(_ suggestion: PlaceSearchSuggestion) async
    /// Reset to idle and clear any pending work.
    func clear()
}

// MARK: - Apple Implementation

/// MKLocalSearchCompleter-backed place search.
/// Uses MKLocalSearch to resolve coordinates after a suggestion is selected.
@MainActor
final class ApplePlaceSearchService: NSObject, PlaceSearchProviding {

    @Published private(set) var state: PlaceSearchState = .idle

    // Minimum characters before a search fires.
    private let minimumQueryLength = 2
    // Debounce interval in nanoseconds (0.35 s).
    private let debounceInterval: UInt64 = 350_000_000

    private let completer: MKLocalSearchCompleter
    private var debounceTask: Task<Void, Never>?
    // Tracks the query that triggered the current completer request.
    // Results arriving for an older query are discarded.
    private var activeQuery: String = ""

    override init() {
        completer = MKLocalSearchCompleter()
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    // MARK: - PlaceSearchProviding

    func search(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count >= minimumQueryLength else {
            cancelDebounce()
            completer.cancel()
            activeQuery = ""
            state = .idle
            return
        }

        // Cancel any in-flight debounce task before starting a new one.
        cancelDebounce()
        state = .searching

        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.debounceInterval)
            } catch {
                // Task was cancelled — do nothing.
                return
            }
            // Stale-result guard: record the query we are about to fire.
            self.activeQuery = trimmed
            self.completer.queryFragment = trimmed
        }
    }

    func resolve(_ suggestion: PlaceSearchSuggestion) async {
        state = .resolving
        let request = MKLocalSearch.Request(completion: suggestion._completion)
        request.resultTypes = [.address, .pointOfInterest]
        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            guard let item = response.mapItems.first else {
                state = .failed("No location found for the selected place.")
                return
            }
            guard CLLocationCoordinate2DIsValid(item.placemark.coordinate) else {
                state = .failed("Selected place has no mappable location.")
                return
            }
            let place = ResolvedPlace(
                name: item.name ?? suggestion.title,
                formattedAddress: formattedAddress(from: item.placemark),
                coordinate: item.placemark.coordinate,
                locality: item.placemark.locality,
                administrativeArea: item.placemark.administrativeArea,
                postalCode: item.placemark.postalCode,
                country: item.placemark.country,
                thoroughfare: fullThoroughfare(from: item.placemark)
            )
            state = .resolved(place)
        } catch {
            state = .failed("Could not load place details. Try again.")
        }
    }

    func clear() {
        cancelDebounce()
        completer.cancel()
        activeQuery = ""
        state = .idle
    }

    // MARK: - Private

    private func cancelDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Builds a single-line formatted address from a CLPlacemark.
    private func formattedAddress(from placemark: CLPlacemark) -> String {
        var parts: [String] = []
        if let thoroughfare = fullThoroughfare(from: placemark) {
            parts.append(thoroughfare)
        }
        if let locality = placemark.locality { parts.append(locality) }
        if let area = placemark.administrativeArea { parts.append(area) }
        if let postcode = placemark.postalCode { parts.append(postcode) }
        return parts.joined(separator: ", ")
    }

    /// Returns "subThoroughfare + thoroughfare" (e.g. "12 Main Street") or just
    /// thoroughfare, or nil if neither is present.
    private func fullThoroughfare(from placemark: CLPlacemark) -> String? {
        let parts = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

// MARK: - MKLocalSearchCompleterDelegate

extension ApplePlaceSearchService: MKLocalSearchCompleterDelegate {

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            // Discard if results belong to a superseded query.
            guard completer.queryFragment == activeQuery else { return }
            let suggestions = completer.results.map { completion in
                PlaceSearchSuggestion(
                    id: UUID(),
                    title: completion.title,
                    subtitle: completion.subtitle,
                    _completion: completion
                )
            }
            state = .results(suggestions)
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            guard completer.queryFragment == activeQuery else { return }
            // MKErrorDomain 4 = "no results" — treat as empty results, not an error.
            let nsError = error as NSError
            if nsError.domain == MKError.errorDomain, nsError.code == MKError.placemarkNotFound.rawValue {
                state = .results([])
            } else {
                state = .failed("Search unavailable. Check your connection.")
            }
        }
    }
}
