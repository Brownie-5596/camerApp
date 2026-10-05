import SwiftUI
import UIKit

enum CameraSetting: String, CaseIterable, Identifiable {
    case iso = "ISO"
    case shutter = "SHUTTER"
    case ev = "EV"
    case focus = "FOCUS"
    case whiteBalance = "WB"
    var id: String { rawValue }
}

/// The exposure "dials": pick a setting, then turn it with the slider.
struct SettingsPanel: View {
    @ObservedObject var camera: CameraController
    @Binding var selected: CameraSetting
    let theme: Theme

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
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
                                .minimumScaleFactor(0.6)
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
                    modeAction(selected)
                } label: {
                    Text(modeTitle(selected))
                        .font(.caption.bold())
                        .frame(width: 64)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(modeHighlighted(selected) ? theme.accent.opacity(0.25) : Color.white.opacity(0.08)))
                }
                .foregroundStyle(modeHighlighted(selected) ? theme.accent : theme.primary)

                dial(for: selected)
            }
        }
    }

    private func valueText(_ setting: CameraSetting) -> String {
        switch setting {
        case .iso:
            return (camera.autoISO ? "A " : "") + Stops.whole(camera.iso)
        case .shutter:
            if camera.autoShutter { return "A " + Stops.shutterLabel(camera.exposureSeconds) }
            return camera.bulb ? "BULB" : Stops.shutterLabel(camera.exposureSeconds)
        case .ev:
            return Stops.evLabel(camera.evBias)
        case .focus:
            return camera.autoFocus ? "AF" : String(format: "%.2f", camera.lensPosition)
        case .whiteBalance:
            return (camera.autoWhiteBalance ? "A " : "") + Stops.whole(camera.whiteBalanceKelvin) + "K"
        }
    }

    private func modeTitle(_ setting: CameraSetting) -> String {
        switch setting {
        case .iso: return camera.autoISO ? "AUTO" : "MANUAL"
        case .shutter: return camera.autoShutter ? "AUTO" : "MANUAL"
        case .ev: return "RESET"
        case .focus: return camera.autoFocus ? "AF" : "MF"
        case .whiteBalance: return camera.autoWhiteBalance ? "AWB" : "MANUAL"
        }
    }

    private func modeHighlighted(_ setting: CameraSetting) -> Bool {
        switch setting {
        case .iso: return camera.autoISO
        case .shutter: return camera.autoShutter
        case .ev: return camera.evBias != 0
        case .focus: return camera.autoFocus
        case .whiteBalance: return camera.autoWhiteBalance
        }
    }

    private func modeAction(_ setting: CameraSetting) {
        switch setting {
        case .iso: camera.setAutoISO(!camera.autoISO)
        case .shutter: camera.setAutoShutter(!camera.autoShutter)
        case .ev: camera.setEVBias(0)
        case .focus: camera.setAutoFocus(!camera.autoFocus)
        case .whiteBalance: camera.setAutoWhiteBalance(!camera.autoWhiteBalance)
        }
    }

    @ViewBuilder
    private func dial(for setting: CameraSetting) -> some View {
        switch setting {
        case .iso:
            StepSlider(count: camera.isoStops.count,
                       index: Stops.nearestIndex(of: camera.iso, in: camera.isoStops)) {
                camera.setISOIndex($0)
            }
        case .shutter:
            StepSlider(count: camera.shutterStops.count,
                       index: Stops.nearestIndex(of: camera.exposureSeconds, bulb: camera.bulb && !camera.autoShutter,
                                                 in: camera.shutterStops)) {
                camera.setShutterIndex($0)
            }
        case .ev:
            StepSlider(count: Stops.evBias.count,
                       index: Stops.nearestIndex(ofEV: camera.evBias)) {
                camera.setEVBias(Stops.evBias[$0])
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
            Slider(value: Binding(get: { Double(min(max(camera.whiteBalanceKelvin, 2000), 10000)) },
                                  set: { camera.setWhiteBalance(Float($0)) }),
                   in: 2000...10000)
        }
    }
}

/// A slider that clicks between fixed stops, with a haptic tick like a camera dial.
struct StepSlider: View {
    let count: Int
    let index: Int
    let onChange: (Int) -> Void

    var body: some View {
        Slider(value: Binding(get: { Double(index) },
                              set: { value in
                                  let newIndex = min(max(Int(value.rounded()), 0), count - 1)
                                  if newIndex != index {
                                      UISelectionFeedbackGenerator().selectionChanged()
                                      onChange(newIndex)
                                  }
                              }),
               in: 0...Double(max(count - 1, 1)),
               step: 1)
    }
}
