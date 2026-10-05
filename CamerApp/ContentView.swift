import SwiftUI

struct Theme {
    let redMode: Bool
    var accent: Color { redMode ? Color(red: 0.85, green: 0, blue: 0) : .yellow }
    var primary: Color { redMode ? Color(red: 0.7, green: 0, blue: 0) : .white }
    var secondary: Color { redMode ? Color(red: 0.4, green: 0, blue: 0) : .gray }
}

enum CameraSetting: String, CaseIterable, Identifiable {
    case iso = "ISO"
    case shutter = "SHUTTER"
    case focus = "FOCUS"
    case whiteBalance = "WB"
    var id: String { rawValue }
}

enum Formatters {
    static func shutter(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--" }
        if seconds >= 0.95 { return String(format: "%.1fs", seconds) }
        return "1/\(Int((1 / seconds).rounded()))"
    }

    static func whole(_ value: Float) -> String {
        value.isFinite ? "\(Int(value.rounded()))" : "--"
    }
}

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var intervalometer = Intervalometer()
    @AppStorage("redMode") private var redMode = false
    @State private var selectedSetting: CameraSetting = .shutter
    @State private var showIntervalometer = false

    private var theme: Theme { Theme(redMode: redMode) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.permissionDenied {
                Text("Camera access is off.\nTurn it on in Settings → Privacy & Security → Camera.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theme.primary)
                    .padding()
            } else {
                VStack(spacing: 12) {
                    topBar
                    preview
                    SettingsPanel(camera: camera, selected: $selectedSetting, theme: theme)
                    lensPicker
                    bottomBar
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .tint(theme.accent)
        .onAppear { camera.start() }
        .sheet(isPresented: $showIntervalometer) {
            IntervalometerView(intervalometer: intervalometer, camera: camera, theme: theme)
                .presentationDetents([.medium])
                .presentationBackground(.black)
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                camera.format = camera.format == .raw ? .heif : .raw
            } label: {
                Text(camera.format.rawValue)
                    .font(.system(.footnote, design: .monospaced).bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .overlay(Capsule().stroke(theme.primary, lineWidth: 1))
            }
            .disabled(!camera.rawSupported)
            Spacer()
            Button {
                redMode.toggle()
            } label: {
                Image(systemName: redMode ? "eye.fill" : "eye")
                    .font(.title3)
                    .frame(width: 44, height: 32)
            }
        }
        .foregroundStyle(theme.primary)
    }

    private var preview: some View {
        CameraPreview(camera: camera, redMode: redMode)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if intervalometer.isRunning {
                    badge(intervalometer.statusText)
                }
            }
            .overlay(alignment: .bottom) {
                if let message = camera.lastMessage {
                    badge(message)
                }
            }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.footnote.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.65), in: Capsule())
            .foregroundStyle(theme.primary)
            .padding(8)
    }

    private var lensPicker: some View {
        HStack(spacing: 12) {
            ForEach(camera.lenses) { lens in
                Button {
                    camera.selectLens(lens.id)
                } label: {
                    Text(lens.name)
                        .font(.footnote.bold())
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .foregroundStyle(lens.id == camera.currentLensID ? theme.accent : theme.primary)
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Button {
                showIntervalometer = true
            } label: {
                Image(systemName: "timer")
                    .font(.title2)
                    .frame(width: 56, height: 56)
            }
            .foregroundStyle(intervalometer.isRunning ? theme.accent : theme.primary)

            Spacer()
            shutterButton
            Spacer()

            Color.clear.frame(width: 56, height: 56)
        }
    }

    private var shutterButton: some View {
        Button {
            if intervalometer.isRunning {
                intervalometer.stop()
            } else {
                camera.capture()
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(theme.primary, lineWidth: 4)
                    .frame(width: 74, height: 74)
                if intervalometer.isRunning {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.accent)
                        .frame(width: 28, height: 28)
                } else {
                    Circle()
                        .fill(camera.isCapturing ? theme.secondary : theme.primary)
                        .frame(width: 60, height: 60)
                }
            }
        }
        .disabled(camera.isCapturing && !intervalometer.isRunning)
    }
}

struct SettingsPanel: View {
    @ObservedObject var camera: CameraController
    @Binding var selected: CameraSetting
    let theme: Theme

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(CameraSetting.allCases) { setting in
                    Button {
                        selected = setting
                    } label: {
                        VStack(spacing: 2) {
                            Text(setting.rawValue)
                                .font(.caption2)
                            Text(valueText(setting))
                                .font(.system(.footnote, design: .monospaced).bold())
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selected == setting ? theme.accent : Color.clear, lineWidth: 1)
                        )
                    }
                    .foregroundStyle(selected == setting ? theme.accent : theme.primary)
                }
            }

            HStack(spacing: 12) {
                Button {
                    setAuto(selected, !isAuto(selected))
                } label: {
                    Text(isAuto(selected) ? "AUTO" : "MANUAL")
                        .font(.caption.bold())
                        .frame(width: 72)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(isAuto(selected) ? theme.accent.opacity(0.25) : Color.white.opacity(0.08)))
                }
                .foregroundStyle(isAuto(selected) ? theme.accent : theme.primary)

                slider(for: selected)
            }
        }
    }

    private func valueText(_ setting: CameraSetting) -> String {
        let prefix = isAuto(setting) ? "A " : ""
        switch setting {
        case .iso: return prefix + Formatters.whole(camera.iso)
        case .shutter: return prefix + Formatters.shutter(camera.exposureSeconds)
        case .focus: return prefix + String(format: "%.2f", camera.lensPosition)
        case .whiteBalance: return prefix + Formatters.whole(camera.whiteBalanceKelvin) + "K"
        }
    }

    private func isAuto(_ setting: CameraSetting) -> Bool {
        switch setting {
        case .iso, .shutter: return camera.autoExposure
        case .focus: return camera.autoFocus
        case .whiteBalance: return camera.autoWhiteBalance
        }
    }

    private func setAuto(_ setting: CameraSetting, _ on: Bool) {
        switch setting {
        case .iso, .shutter: camera.setAutoExposure(on)
        case .focus: camera.setAutoFocus(on)
        case .whiteBalance: camera.setAutoWhiteBalance(on)
        }
    }

    @ViewBuilder
    private func slider(for setting: CameraSetting) -> some View {
        switch setting {
        case .iso:
            LogSlider(value: Double(camera.iso),
                      range: Double(camera.isoRange.lowerBound)...Double(camera.isoRange.upperBound)) {
                camera.setISO(Float($0))
            }
        case .shutter:
            LogSlider(value: camera.exposureSeconds, range: camera.exposureRange) {
                camera.setExposure($0)
            }
        case .focus:
            HStack(spacing: 6) {
                Image(systemName: "camera.macro").font(.caption)
                Slider(value: Binding(get: { Double(camera.lensPosition) },
                                      set: { camera.setLensPosition(Float($0)) }),
                       in: 0...1)
                Image(systemName: "mountain.2").font(.caption)
            }
            .foregroundStyle(theme.secondary)
        case .whiteBalance:
            Slider(value: Binding(get: { Double(camera.whiteBalanceKelvin) },
                                  set: { camera.setWhiteBalance(Float($0)) }),
                   in: 2000...10000)
        }
    }
}

/// A slider that moves evenly through stops (ISO, shutter) instead of linearly.
struct LogSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let onChange: (Double) -> Void

    var body: some View {
        let lower = log(max(range.lowerBound, 1e-9))
        let upper = max(log(max(range.upperBound, 1e-9)), lower + 0.001)
        Slider(value: Binding(get: { log(max(value, 1e-9)) },
                              set: { onChange(exp($0)) }),
               in: lower...upper)
    }
}
