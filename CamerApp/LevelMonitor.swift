import CoreMotion
import Foundation

/// Reports how far the phone is rotated from level, for the horizon line.
final class LevelMonitor: ObservableObject {
    /// Clockwise rotation of the phone in degrees (0 = upright portrait, 90 = landscape with the top to the right).
    @Published var rollDegrees: Double = 0
    /// True when the phone points mostly up or down, where roll isn't meaningful.
    @Published var isFlat = false

    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 20
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let g = motion?.gravity else { return }
            self.rollDegrees = atan2(g.x, -g.y) * 180 / .pi
            self.isFlat = abs(g.z) > 0.9
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
