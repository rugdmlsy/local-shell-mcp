import CoreLocation
import Foundation

@MainActor
final class LocationProvider: NSObject, @preconcurrency CLLocationManagerDelegate {
    enum LocationError: LocalizedError {
        case permissionRequired
        case unavailable
        case alreadyRequested

        var errorDescription: String? {
            switch self {
            case .permissionRequired: return "Location permission is required. Grant it from the app before invoking the remote location action."
            case .unavailable: return "A current location is unavailable."
            case .alreadyRequested: return "A location request is already in progress."
            }
        }
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func authorizationStatusName() -> String {
        switch manager.authorizationStatus {
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorized_always"
        case .authorizedWhenInUse: return "authorized_when_in_use"
        @unknown default: return "unknown"
        }
    }

    func currentLocation() async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else {
            throw LocationError.unavailable
        }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            break
        case .notDetermined, .denied, .restricted:
            throw LocationError.permissionRequired
        @unknown default:
            throw LocationError.permissionRequired
        }
        guard continuation == nil else {
            throw LocationError.alreadyRequested
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted,
           let continuation {
            self.continuation = nil
            continuation.resume(throwing: LocationError.permissionRequired)
        }
    }
}
