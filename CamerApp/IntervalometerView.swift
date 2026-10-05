import SwiftUI

struct IntervalometerView: View {
    @ObservedObject var intervalometer: Intervalometer
    let camera: CameraController
    let theme: Theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Intervalometer")
                .font(.headline)

            Stepper(value: $intervalometer.delaySeconds, in: 0...600, step: 1) {
                row("Start delay", "\(Int(intervalometer.delaySeconds))s")
            }
            Stepper(value: $intervalometer.intervalSeconds, in: 1...3600, step: 1) {
                row("Interval", "\(Int(intervalometer.intervalSeconds))s")
            }
            Toggle("Unlimited shots", isOn: $intervalometer.unlimited)
            if !intervalometer.unlimited {
                Stepper(value: $intervalometer.shotCount, in: 1...9999) {
                    row("Shots", "\(intervalometer.shotCount)")
                }
            }

            Button {
                if intervalometer.isRunning {
                    intervalometer.stop()
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
        .foregroundStyle(theme.primary)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}
