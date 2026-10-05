import SwiftUI

struct IntervalometerView: View {
    @ObservedObject var intervalometer: Intervalometer
    @ObservedObject var camera: CameraController
    let theme: Theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Intervalometer")
                    .font(.headline)

                Stepper(value: $intervalometer.delaySeconds, in: 0...600, step: 1) {
                    row("Start delay", "\(Int(intervalometer.delaySeconds))s")
                }
                Stepper {
                    row("Interval", Intervalometer.label(for: intervalometer.intervalSeconds))
                } onIncrement: {
                    intervalometer.stepInterval(1)
                } onDecrement: {
                    intervalometer.stepInterval(-1)
                }
                Toggle("Unlimited shots", isOn: $intervalometer.unlimited)
                if !intervalometer.unlimited {
                    Stepper(value: $intervalometer.shotCount, in: 1...9999) {
                        row("Shots", "\(intervalometer.shotCount)")
                    }
                }

                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(theme.secondary)

                Button {
                    if intervalometer.isRunning {
                        intervalometer.stop()
                        if camera.isStacking { camera.finishStack() }
                    } else {
                        intervalometer.start(camera: camera)
                        dismiss()
                    }
                } label: {
                    Text(intervalometer.isRunning ? "Stop" : "Start")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent.opacity(0.25)))
                }
                .foregroundStyle(theme.accent)
            }
            .padding(20)
        }
        .foregroundStyle(theme.primary)
    }

    private var explanation: String {
        let shutter = camera.isLongExposure
            ? (camera.bulb ? "BULB" : Stops.shutterLabel(camera.exposureSeconds) + " stacked")
            : (camera.autoShutter ? "auto shutter" : Stops.shutterLabel(camera.exposureSeconds))
        if intervalometer.intervalSeconds == 0 {
            return "Continuous: each shot (\(shutter)) starts as soon as the last one finishes. With a long shutter speed you get back-to-back exposures, ideal for lightning and aurora time-lapses. The screen stays on while it runs."
        }
        return "Takes a shot (\(shutter)) every \(Intervalometer.label(for: intervalometer.intervalSeconds)), measured start to start. If a shot takes longer than the interval, the next one starts straight away. The screen stays on while it runs."
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}
