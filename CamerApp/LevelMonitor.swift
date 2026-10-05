import CoreMotion
import Foundation

/// One motion manager for the whole app: the level, and noticing when the camera moves
/// between stacked frames.
final class Motion {
    static let shared = Motion()
    private let manager = CMMotionManager()

    /// Call on the main thread.
    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical)
    }

    /// Latest orientation of the phone. Safe to read from any thread.
    var attitude: CMQuaternion? { manager.deviceMotion?.attitude.quaternion }
    var gravity: CMAcceleration? { manager.deviceMotion?.gravity }

    /// How far (radians) the phone turned between two orientations.
    static func angle(_ a: CMQuaternion, _ b: CMQuaternion) -> Double {
        let dot = abs(a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z)
        return 2 * acos(min(1, dot))
    }
}

/// Reports how far the phone is rotated from level, for the horizon line.
final class LevelMonitor: ObservableObject {
    /// Clockwise rotation of the phone in degrees (0 = upright portrait, 90 = landscape with the top to the right).
    @Published var rollDegrees: Double = 0
    /// True when the phone points mostly up or down, where roll isn't meaningful.
    @Published var isFlat = false

    private var timer: Timer?

    func start() {
        Motion.shared.start()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self, let g = Motion.shared.gravity else { return }
            self.rollDegrees = atan2(g.x, -g.y) * 180 / .pi
            self.isFlat = abs(g.z) > 0.9
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
