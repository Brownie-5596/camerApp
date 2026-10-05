import CoreLocation
import Foundation

/// Keeps the latest position and compass heading for photo metadata.
/// `snapshot()` is safe to call from any thread.
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var latestLocation: CLLocation?
    private var latestHeading: CLHeading?
    private var wanted = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.headingFilter = 1
    }

    /// Call on the main thread.
    func start() {
        wanted = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            begin()
        default:
            break
        }
    }

    /// Call on the main thread.
    func stop() {
        wanted = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        lock.lock()
        latestLocation = nil
        latestHeading = nil
        lock.unlock()
    }

    func snapshot(enabled: Bool) -> (location: CLLocation?, heading: CLHeading?) {
        enabled ? snapshot() : (nil, nil)
    }

    func snapshot() -> (location: CLLocation?, heading: CLHeading?) {
        lock.lock()
        defer { lock.unlock() }
        // Don't stamp photos with a position from long ago.
        if let location = latestLocation, abs(location.timestamp.timeIntervalSinceNow) > 600 {
            return (nil, latestHeading)
        }
        return (latestLocation, latestHeading)
    }

    private func begin() {
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if wanted && (status == .authorizedWhenInUse || status == .authorizedAlways) { begin() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lock.lock()
        latestLocation = location
        lock.unlock()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        lock.lock()
        latestHeading = newHeading
        lock.unlock()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
