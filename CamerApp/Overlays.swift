import SwiftUI

struct GridOverlay: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3
                let y = size.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(color), lineWidth: 0.5)
        }
    }
}

/// A horizon line that stays level with the world; it lights up when the camera is straight.
struct LevelOverlay: View {
    @ObservedObject var level: LevelMonitor
    let theme: Theme
    /// How far the screen itself is rotated (landscape UI), so the line is drawn relative to it.
    var interfaceRotation: Double = 0

    var body: some View {
        let roll = level.rollDegrees - interfaceRotation
        let nearest = (roll / 90).rounded() * 90
        let isLevel = abs(roll - nearest) < 1
        ZStack {
            // Reference marks for the nearest straight orientation.
            HStack(spacing: 140) {
                Rectangle().frame(width: 16, height: 1)
                Rectangle().frame(width: 16, height: 1)
            }
            .foregroundStyle(theme.primary.opacity(0.6))
            .rotationEffect(.degrees(-nearest))

            Rectangle()
                .fill(isLevel ? theme.accent : theme.primary.opacity(0.8))
                .frame(width: 120, height: isLevel ? 2 : 1)
                .rotationEffect(.degrees(-roll))
        }
        .opacity(level.isFlat ? 0.25 : 1)
    }
}

struct HistogramView: View {
    let bins: [Float]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard bins.count > 1 else { return }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, value) in bins.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(bins.count - 1)
                // Square root so faint tones are still visible.
                let y = size.height * (1 - CGFloat(value.squareRoot()))
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(color.opacity(0.75)))
        }
        .frame(width: 110, height: 46)
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// The light meter scale from a camera viewfinder, plus what the stack will do.
struct MeterRow: View {
    @ObservedObject var camera: CameraController
    let theme: Theme

    var body: some View {
        HStack(spacing: 10) {
            ExposureScale(ev: camera.meterEV, theme: theme)
                .frame(height: 18)
            Text(Stops.evLabel(camera.meterEV))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 40, alignment: .trailing)
            if camera.isLongExposure {
                Text(stackDescription)
                    .font(.system(.caption2, design: .monospaced).bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.accent.opacity(0.2)))
                    .foregroundStyle(theme.accent)
            }
        }
        .foregroundStyle(theme.primary)
    }

    private var stackDescription: String {
        let sub = Stops.shutterLabel(camera.subExposure)
        let frames = camera.plannedFrames.map { "\($0)" } ?? "BULB"
        return "\(camera.stackMode.shortName) \(frames)×\(sub) → \(camera.longExposureOutput)"
    }
}

struct ExposureScale: View {
    let ev: Float
    let theme: Theme

    var body: some View {
        Canvas { context, size in
            let range: CGFloat = 3
            func x(_ value: CGFloat) -> CGFloat { size.width * (value + range) / (2 * range) }
            for step in -9...9 {
                let value = CGFloat(step) / 3
                let isWhole = step % 3 == 0
                let height: CGFloat = step == 0 ? 10 : (isWhole ? 7 : 4)
                var tick = Path()
                tick.move(to: CGPoint(x: x(value), y: 0))
                tick.addLine(to: CGPoint(x: x(value), y: height))
                context.stroke(tick, with: .color(theme.primary.opacity(isWhole ? 0.9 : 0.5)), lineWidth: 1)
            }
            let clamped = min(max(CGFloat(ev.isFinite ? ev : 0), -range), range)
            var marker = Path()
            marker.move(to: CGPoint(x: x(clamped), y: 11))
            marker.addLine(to: CGPoint(x: x(clamped) - 5, y: size.height))
            marker.addLine(to: CGPoint(x: x(clamped) + 5, y: size.height))
            marker.closeSubpath()
            let outOfRange = abs(ev) > 3
            context.fill(marker, with: .color(outOfRange ? theme.accent : theme.primary))
        }
    }
}
