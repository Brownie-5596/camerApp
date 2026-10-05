import Foundation

@MainActor
final class Intervalometer: ObservableObject {
    /// 0 means continuous: the next shot starts as soon as the last one is done.
    static let intervalChoices: [Double] = [
        0, 0.5, 1, 2, 3, 4, 5, 8, 10, 15, 20, 30, 45, 60, 90, 120, 180, 300, 600, 900, 1800, 3600,
    ]

    @Published var delaySeconds: Double = 0 {
        didSet { UserDefaults.standard.set(delaySeconds, forKey: "interval.delay") }
    }
    @Published var intervalSeconds: Double = 5 {
        didSet { UserDefaults.standard.set(intervalSeconds, forKey: "interval.seconds") }
    }
    @Published var shotCount: Int = 10 {
        didSet { UserDefaults.standard.set(shotCount, forKey: "interval.count") }
    }
    @Published var unlimited = false {
        didSet { UserDefaults.standard.set(unlimited, forKey: "interval.unlimited") }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var shotsTaken = 0
    @Published private(set) var countdown: Double = 0
    @Published private(set) var startedAt: Date?

    private var task: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "interval.seconds") != nil {
            delaySeconds = defaults.double(forKey: "interval.delay")
            intervalSeconds = defaults.double(forKey: "interval.seconds")
            shotCount = max(1, defaults.integer(forKey: "interval.count"))
            unlimited = defaults.bool(forKey: "interval.unlimited")
        }
    }

    var statusText: String {
        let shots = unlimited ? "\(shotsTaken)" : "\(shotsTaken)/\(shotCount)"
        let mode = intervalSeconds == 0 ? "Continuous" : "Interval"
        if countdown > 0 { return "\(mode) · shot \(shots) · next in \(Int(countdown.rounded(.up)))s" }
        return "\(mode) · shot \(shots)"
    }

    static func label(for seconds: Double) -> String {
        if seconds == 0 { return "Continuous" }
        if seconds < 1 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 {
            let minutes = Int(seconds) / 60
            let rest = Int(seconds) % 60
            return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest)s"
        }
        return "\(Int(seconds) / 3600) h"
    }

    func stepInterval(_ direction: Int) {
        let choices = Self.intervalChoices
        let current = choices.indices.min { abs(choices[$0] - intervalSeconds) < abs(choices[$1] - intervalSeconds) } ?? 0
        intervalSeconds = choices[min(max(current + direction, 0), choices.count - 1)]
    }

    func start(camera: CameraController) {
        guard !isRunning else { return }
        isRunning = true
        shotsTaken = 0
        startedAt = Date()

        task = Task {
            await wait(delaySeconds)
            while !Task.isCancelled && (unlimited || shotsTaken < shotCount) {
                let started = Date()
                // Uses whatever the camera is set to, including stacked long exposures.
                let ok = await camera.takePictureAsync()
                if Task.isCancelled { return }
                if ok { shotsTaken += 1 }
                if !unlimited && shotsTaken >= shotCount { break }
                // Interval is measured start-to-start; long exposures eat into it.
                let remaining = intervalSeconds - Date().timeIntervalSince(started)
                if remaining > 0 {
                    await wait(remaining)
                } else if !ok {
                    // Don't spin if the camera is refusing shots.
                    await wait(0.5)
                }
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
        startedAt = nil
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
