import CoreLocation
import Foundation

enum LocationPermissionStatus {
    case notDetermined
    case denied
    case restricted
    case authorizedWhenInUse
    case authorizedAlways
}

@MainActor
final class LocationManager: NSObject, ObservableObject {
    @Published var userLocation: CLLocation?
    @Published var permissionStatus: LocationPermissionStatus = .notDetermined
    /// Drives the soft-ask location primer (Phase 1.3). True when the system status is
    /// `.notDetermined` and we have not yet shown the primer this session. The primer view
    /// (`LocationPermissionPrimerView`) presents itself via this flag and calls
    /// `confirmLocationPermissionFromPrimer()` (system prompt) or
    /// `skipLocationPermissionPrimer()`. We never set this to true if the user has skipped
    /// during the same app session.
    @Published var shouldShowLocationPrimer: Bool = false
    /// Session-only lock — flipped true on Skip / dismiss. Prevents the primer from
    /// re-appearing within the same launch even if `requestPermissionIfNeeded` fires again
    /// (e.g. user revisits HomeView).
    private var locationPrimerDismissedThisSession: Bool = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        updatePermissionStatus(manager.authorizationStatus)
    }

    func requestPermissionIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            // Phase 1.3: defer the cold system permission prompt. Show the soft-ask primer
            // (`LocationPermissionPrimerView`) via `shouldShowLocationPrimer`. The primer's
            // CTA calls `confirmLocationPermissionFromPrimer()` which fires the actual
            // system prompt. If the user has already skipped within this session, do not re-show.
            if !locationPrimerDismissedThisSession {
                shouldShowLocationPrimer = true
            }
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    /// Called by `LocationPermissionPrimerView` when the user taps the primary CTA.
    /// Triggers the iOS system permission prompt (the call we deferred from
    /// `requestPermissionIfNeeded`) and starts a one-off location fetch on grant.
    /// Idempotent against late status changes (e.g. user toggled in Settings).
    func confirmLocationPermissionFromPrimer() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    /// Called when the user taps Not now / dismisses the primer. Locks the primer for the
    /// rest of this app session so it does not re-appear on subsequent HomeView appearances.
    func skipLocationPermissionPrimer() {
        locationPrimerDismissedThisSession = true
        shouldShowLocationPrimer = false
    }

    private func updatePermissionStatus(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:       permissionStatus = .notDetermined
        case .denied:              permissionStatus = .denied
        case .restricted:          permissionStatus = .restricted
        case .authorizedWhenInUse: permissionStatus = .authorizedWhenInUse
        case .authorizedAlways:    permissionStatus = .authorizedAlways
        @unknown default:          permissionStatus = .notDetermined
        }
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.userLocation = location
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Silently ignore transient errors; userLocation stays nil → graceful fallback
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.updatePermissionStatus(status)
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }
}
