import Foundation
import UIKit

@MainActor
final class Intervalometer: ObservableObject {
    @Published var delaySeconds: Double = 0
    @Published var intervalSeconds: Double = 5
    @Published var shotCount: Int = 10
    @Published var unlimited = false

    @Published private(set) var isRunning = false
    @Published private(set) var shotsTaken = 0
    @Published private(set) var countdown: Double = 0

    private var task: Task<Void, Never>?

    var statusText: String {
        let shots = unlimited ? "\(shotsTaken)" : "\(shotsTaken)/\(shotCount)"
        if countdown > 0 { return "Shot \(shots) · next in \(Int(countdown.rounded(.up)))s" }
        return "Shot \(shots)"
    }

    func start(camera: CameraController) {
        guard !isRunning else { return }
        isRunning = true
        shotsTaken = 0
        UIApplication.shared.isIdleTimerDisabled = true

        task = Task {
            await wait(delaySeconds)
            while !Task.isCancelled && (unlimited || shotsTaken < shotCount) {
                let started = Date()
                _ = await camera.captureAsync()
                if Task.isCancelled { return }
                shotsTaken += 1
                if !unlimited && shotsTaken >= shotCount { break }
                // Interval is measured start-to-start; long exposures eat into it.
                await wait(intervalSeconds - Date().timeIntervalSince(started))
            }
            if !Task.isCancelled { finish() }
        }
    }

    func stop() {
        task?.cancel()
        finish()
    }

    private func finish() {
        task = nil
        isRunning = false
        countdown = 0
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func wait(_ seconds: Double) async {
        var remaining = seconds
        while remaining > 0 && !Task.isCancelled {
            countdown = remaining
            let step = min(remaining, 0.25)
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            remaining -= step
        }
        countdown = 0
    }
}
