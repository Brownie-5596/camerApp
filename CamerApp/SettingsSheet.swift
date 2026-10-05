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
                } header: {
                    Text("Photo format")
                } footer: {
                    Text(camera.rawSupported
                         ? "RAW saves a plain 12 MP DNG. ProRAW is Apple's RAW (like the Camera app) and can be 48 MP. RAW+HEIF saves both as one photo."
                         : "This lens doesn't offer RAW.")
                }

                if let label = camera.highResolutionLabel {
                    Section {
                        Toggle("Full resolution (\(label))", isOn: $camera.useHighResolution)
                    } footer: {
                        Text("Uses the whole \(label) sensor for HEIF and ProRAW photos (also the 12MP/48MP chip at the top). Plain RAW is always 12 MP, and blended long exposures use the video stream, so they are lower resolution; use the RAW frames mode for full-resolution stars.")
                    }
                }

                Section {
                    Toggle("Save location", isOn: $camera.saveLocation)
                } header: {
                    Text("Metadata")
                } footer: {
                    Text("Photos include GPS position, altitude, compass direction and speed, plus the usual camera details: iPhone model, lens, focal length, aperture, shutter speed, ISO, white balance and resolution. Stacked shots also record how many frames they were built from.")
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
                    Text("Volume buttons work as a shutter release. Hold the on-screen shutter to shoot a burst.")
                        .font(.footnote)
                    Text("Camera Control (iPhone 16 and later): press to shoot. Light-press to show a setting, then slide to change it. Light-press twice to choose which setting: shutter, ISO, focus, exposure, lens, white balance, long exposure mode or lightning trigger.")
                        .font(.footnote)
                    Toggle("Camera Control: whole stops", isOn: $camera.cameraControlFullStops)
                    Text("Whole stops make each notch of the slide a bigger jump (1/60 → 1/30 instead of 1/60 → 1/50), so you need to slide less.")
                        .font(.footnote)
                    Text("Pinch the preview to zoom; tap the zoom badge to go back to 1×. The ◎ button turns on focus peaking (sharp edges glow green).")
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
