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
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
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
