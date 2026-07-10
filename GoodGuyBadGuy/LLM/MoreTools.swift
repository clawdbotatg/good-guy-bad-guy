import CoreLocation
import Foundation
import MLXLMCommon

/// Location tool: lets the model narrow species candidates by region.
/// iOS shows its permission dialog the first time the model calls it.
enum MoreTools {

    // MARK: get_location

    struct LocationInput: Codable {}
    struct LocationResult: Codable {
        let latitude: Double
        let longitude: Double
        let place: String
    }

    static let currentLocation = Tool<LocationInput, LocationResult>(
        name: "get_location",
        description: "Get the user's current location (coordinates and city).",
        parameters: []
    ) { _ in
        let location = try await LocationOnce.request()
        let placemark = try? await CLGeocoder()
            .reverseGeocodeLocation(location).first
        let place = [
            placemark?.locality, placemark?.administrativeArea, placemark?.country,
        ]
        .compactMap { $0 }.joined(separator: ", ")
        return LocationResult(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            place: place.isEmpty ? "unknown" : place
        )
    }

    // MARK: wiring

    static var specs: [ToolSpec] {
        [currentLocation.schema]
    }

    static func dispatch(_ call: ToolCall) async -> String? {
        do {
            switch call.function.name {
            case currentLocation.name: return try encode(await call.execute(with: currentLocation))
            default: return nil
            }
        } catch {
            return #"{"error": "\#(error.localizedDescription)"}"#
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? "{}"
    }
}

/// One-shot location fetch that owns the permission-dialog dance:
/// request authorization if undetermined, then a single location fix.
/// @MainActor is load-bearing: CLLocationManager delivers delegate callbacks
/// on the thread that created it, and only the main thread has a run loop —
/// created on a Task executor thread, the callbacks never fire and the tool
/// hangs forever (verified on device 2026-07-07).
@MainActor
final class LocationOnce: NSObject, CLLocationManagerDelegate {
    private var manager: CLLocationManager!
    private var continuation: CheckedContinuation<CLLocation, Error>?

    static func request() async throws -> CLLocation {
        try await LocationOnce().run()
    }

    private func run() async throws -> CLLocation {
        manager = CLLocationManager()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                finish(.failure(PhoneTools.ToolFailure.denied("location")))
            default:
                manager.requestLocation()
            }
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(PhoneTools.ToolFailure.denied("location")))
        default:
            break  // .notDetermined: dialog still up
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.first {
            finish(.success(location))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }
}
