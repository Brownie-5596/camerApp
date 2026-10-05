import PhotosUI
import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var camera: CameraController
    let theme: Theme
    @Binding var showGrid: Bool
    @Binding var showLevel: Bool
    @Binding var showHistogram: Bool
    @Binding var peaking: Bool
    @Binding var clippingWarning: Bool
    @Binding var dimScreen: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var choosingBlend = false

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

                if camera.availableMegapixels.count > 1 {
                    Section {
                        Picker("Photo size", selection: $camera.preferredMegapixels) {
                            ForEach(camera.availableMegapixels, id: \.self) { mp in
                                Text("\(mp) MP").tag(mp)
                            }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Resolution")
                    } footer: {
                        Text("All sizes use the full width of the sensor; nothing is cropped (keep zoom at 1×). HEIF can be any size. ProRAW is 12 or 48 MP. Plain RAW is always 12 MP. Also on the MP chip at the top.")
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
                    if camera.stackMode == .rawFrames {
                        Picker("Also blend in the app", selection: $camera.rawBlend) {
                            ForEach(RawBlend.allCases) { blend in
                                Text(blend.rawValue).tag(blend)
                            }
                        }
                        Text("After the frames are shot, the app combines them into one full-resolution picture (e.g. 48 MP ProRAW), as well as keeping every frame. It takes a few seconds per frame and runs in the background.")
                            .font(.footnote)
                    }
                    Toggle("Fix camera movement", isOn: $camera.alignFrames)
                    Toggle("Save RAW stacks as 16-bit TIFF", isOn: $camera.stackAsTIFF)
                } header: {
                    Text("Long exposures")
                } footer: {
                    Text("This lens can expose for up to \(Stops.shutterLabel(camera.maxDeviceExposure)) in one go. Choose a slower shutter speed (or BULB) and the app stacks frames to build the exposure. Fix camera movement uses the gyroscope to notice a bump, then lines the frames back up. TIFF keeps the most editing room but files are very large (about 380 MB at 48 MP); otherwise RAW stacks are 10-bit HEIF.")
                }

                Section {
                    PhotosPicker(selection: $pickedPhotos, maxSelectionCount: 300, matching: .images,
                                 preferredItemEncoding: .current) {
                        Label("Stack photos from your library…", systemImage: "square.stack.3d.up")
                    }
                } footer: {
                    Text("Pick a series of shots taken on a tripod (ProRAW frames work best) and blend them into one. Frames are lined up automatically if the camera moved.")
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

                Section {
                    Button("Copy camera report") {
                        UIPasteboard.general.string = camera.cameraReport()
                        camera.show("Camera report copied")
                    }
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    Text("Copies technical details about your camera and the app's settings. Paste it to Claude to help diagnose problems.")
                }

                Section {
                    Toggle("Grid", isOn: $showGrid)
                    Toggle("Level", isOn: $showLevel)
                    Toggle("Histogram", isOn: $showHistogram)
                    Toggle("Focus peaking", isOn: $peaking)
                    Toggle("Clipping warning", isOn: $clippingWarning)
                    Toggle("Dim screen during intervalometer", isOn: $dimScreen)
                } header: {
                    Text("Display")
                } footer: {
                    Text("Clipping warning shows blown-out (pure white) areas in pink. Tap the histogram for a guide on reading it.")
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
                    Text("Tap the preview to focus there. With manual focus, a tap focuses once and locks. Long-press the preview (or the AE/AF button) to lock exposure and focus.")
                        .font(.footnote)
                    Text("Tap the thumbnail to open the Photos app.")
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
            .onChange(of: pickedPhotos) { _, items in
                if !items.isEmpty { choosingBlend = true }
            }
            .confirmationDialog("Blend \(pickedPhotos.count) photos", isPresented: $choosingBlend, titleVisibility: .visible) {
                Button("Average (cleanest, aurora & Milky Way)") { stack(.average) }
                Button("Long exposure (adds the light)") { stack(.longExposure) }
                Button("Brightest (star trails, lightning)") { stack(.brightest) }
                Button("Cancel", role: .cancel) { pickedPhotos = [] }
            }
        }
    }

    private func stack(_ mode: StackMode) {
        let items = pickedPhotos
        pickedPhotos = []
        camera.stackPhotos(count: items.count, mode: mode) { index in
            try? await items[index].loadTransferable(type: Data.self)
        }
        dismiss()
    }
}
