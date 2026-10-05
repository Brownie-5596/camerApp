import Foundation
import ImageIO

/// A position on the shutter dial. `.bulb` stays open until you press the shutter again.
enum ShutterStop: Hashable {
    case time(Double)
    case bulb

    var label: String {
        switch self {
        case .bulb: return "BULB"
        case .time(let t): return Stops.shutterLabel(t)
        }
    }
}

/// Standard 1/3-stop camera scales, so the dials click through familiar values.
enum Stops {
    static let iso: [Float] = [
        25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
        1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800,
    ]

    static let shutter: [Double] = [
        1.0 / 8000, 1.0 / 6400, 1.0 / 5000, 1.0 / 4000, 1.0 / 3200, 1.0 / 2500, 1.0 / 2000,
        1.0 / 1600, 1.0 / 1250, 1.0 / 1000, 1.0 / 800, 1.0 / 640, 1.0 / 500, 1.0 / 400,
        1.0 / 320, 1.0 / 250, 1.0 / 200, 1.0 / 160, 1.0 / 125, 1.0 / 100, 1.0 / 80, 1.0 / 60,
        1.0 / 50, 1.0 / 40, 1.0 / 30, 1.0 / 25, 1.0 / 20, 1.0 / 15, 1.0 / 13, 1.0 / 10,
        1.0 / 8, 1.0 / 6, 1.0 / 5, 1.0 / 4, 0.3, 0.4, 0.5, 0.6, 0.8, 1, 1.3, 1.6, 2, 2.5,
        3.2, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30, 40, 50, 60, 90, 120, 180, 240, 300, 480, 600,
    ]

    static let isoFullStops: [Float] = [25, 50, 100, 200, 400, 800, 1600, 3200, 6400, 12800]

    static let shutterFullStops: [Double] = [
        1.0 / 8000, 1.0 / 4000, 1.0 / 2000, 1.0 / 1000, 1.0 / 500, 1.0 / 250, 1.0 / 125, 1.0 / 60,
        1.0 / 30, 1.0 / 15, 1.0 / 8, 1.0 / 4, 0.5, 1, 2, 4, 8, 15, 30, 60, 120, 240, 480,
    ]

    static let evBias: [Float] = (-9...9).map { Float($0) / 3 }

    static func isoStops(in range: ClosedRange<Float>) -> [Float] {
        var stops = iso.filter { $0 > range.lowerBound * 1.02 && $0 < range.upperBound * 0.98 }
        stops.insert(range.lowerBound, at: 0)
        stops.append(range.upperBound)
        return stops
    }

    /// Everything from the sensor's fastest speed up to 10 minutes, plus Bulb.
    /// Speeds slower than `maxExposure` are made by stacking frames.
    static func shutterStops(minExposure: Double, maxExposure: Double) -> [ShutterStop] {
        var times = shutter.filter { $0 >= minExposure * 0.98 }
        if !times.contains(where: { abs($0 - maxExposure) / maxExposure < 0.03 }) {
            times.append(maxExposure)
            times.sort()
        }
        return times.map { .time($0) } + [.bulb]
    }

    static func nearestIndex(of value: Float, in stops: [Float]) -> Int {
        let v = log(max(value, 0.0001))
        var best = 0
        var bestDistance = Float.infinity
        for (i, stop) in stops.enumerated() {
            let d = abs(log(max(stop, 0.0001)) - v)
            if d < bestDistance { bestDistance = d; best = i }
        }
        return best
    }

    static func nearestIndex(ofEV ev: Float) -> Int {
        evBias.indices.min { abs(evBias[$0] - ev) < abs(evBias[$1] - ev) } ?? 0
    }

    static func nearestIndex(of seconds: Double, bulb: Bool, in stops: [ShutterStop]) -> Int {
        if bulb, let i = stops.firstIndex(of: .bulb) { return i }
        let v = log(max(seconds, 1e-6))
        var best = 0
        var bestDistance = Double.infinity
        for (i, stop) in stops.enumerated() {
            guard case .time(let t) = stop else { continue }
            let d = abs(log(t) - v)
            if d < bestDistance { bestDistance = d; best = i }
        }
        return best
    }

    static func shutterLabel(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "--" }
        if t < 0.29 { return "1/\(Int((1 / t).rounded()))" }
        if t < 1 { return String(format: "%.1fs", t) }
        if t >= 60 && t.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(t / 60))m" }
        if t == t.rounded() { return "\(Int(t))s" }
        return String(format: "%.1fs", t)
    }

    static func evLabel(_ ev: Float) -> String {
        guard ev.isFinite else { return "--" }
        if abs(ev) < 0.05 { return "0.0" }
        return String(format: "%@%.1f", ev > 0 ? "+" : "−", abs(ev))
    }

    static func whole(_ value: Float) -> String {
        value.isFinite ? "\(Int(value.rounded()))" : "--"
    }

    /// Converts a capture rotation angle (degrees clockwise) into the EXIF orientation for a sensor-oriented image.
    static func orientation(forRotationAngle angle: CGFloat) -> CGImagePropertyOrientation {
        switch Int((angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360).rounded()) {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }
}
