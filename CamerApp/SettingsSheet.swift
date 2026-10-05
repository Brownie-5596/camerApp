import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var camera: CameraController
    let theme: Theme
    @Binding var showGrid: Bool
    @Binding var showLevel: Bool
    @Binding var showHistogram: Bool
    @Binding var peaking: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $camera.format) {
                        ForEach(OutputFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!camera.rawSupported)
                } header: {
                    Text("Photo format")
                } footer: {
                    Text(camera.rawSupported
                         ? "RAW saves an unprocessed DNG for editing. RAW+HEIF saves both as one photo."
                         : "This lens doesn't offer RAW.")
                }

                Section {
                    Picker("Mode", selection: $camera.stackMode) {
                        ForEach(StackMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(camera.stackMode.explanation)
                        .font(.footnote)
                } header: {
                    Text("Long exposures")
                } footer: {
                    Text("This lens can expose for up to \(Stops.shutterLabel(camera.maxDeviceExposure)) in one go. Choose a slower shutter speed (or BULB) and the app stacks frames to build the exposure. Stacked shots save as HEIF. Use a tripod.")
                }

                Section("Self-timer") {
                    Picker("Self-timer", selection: $camera.selfTimerSeconds) {
                        Text("Off").tag(0)
                        Text("2s").tag(2)
                        Text("10s").tag(10)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Picker("Sensitivity", selection: $camera.lightningSensitivity) {
                        ForEach(LightningSensitivity.allCases) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Lightning trigger")
                } footer: {
                    Text("Tap the bolt to start watching. Whenever the sky suddenly brightens, the app saves the brightest parts of the next half second. A shutter around 1/15 to 1/4 works well.")
                }

                Section("Display") {
                    Toggle("Grid", isOn: $showGrid)
                    Toggle("Level", isOn: $showLevel)
                    Toggle("Histogram", isOn: $showHistogram)
                    Toggle("Focus peaking", isOn: $peaking)
                }

                Section("Buttons") {
                    Text("Volume buttons work as a shutter release. On iPhone 16 and later, press Camera Control to shoot, or light-press it to slide through shutter, ISO, exposure, focus and white balance.")
                        .font(.footnote)
                    Text("Tap the preview to focus there. With manual focus, a tap focuses once and locks.")
                        .font(.footnote)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .foregroundStyle(theme.primary)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
