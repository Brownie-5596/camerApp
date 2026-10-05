import SwiftUI

/// Scene modes for aurora, lightning and the night sky, plus three custom slots.
struct PresetsSheet: View {
    @ObservedObject var camera: CameraController
    let theme: Theme
    @State private var custom: [String: CameraPreset] = PresetStore.loadAll()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Scenes") {
                    ForEach(CameraPreset.builtIn) { preset in
                        Button {
                            camera.apply(preset)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.name)
                                    .font(.headline)
                                    .foregroundStyle(theme.primary)
                                Text(preset.detail)
                                    .font(.footnote)
                                    .foregroundStyle(theme.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .listRowBackground(Color.white.opacity(0.06))

                Section {
                    ForEach(PresetStore.slots, id: \.self) { slot in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(slot).font(.headline)
                                Text(custom[slot]?.summary ?? "Empty")
                                    .font(.caption)
                                    .foregroundStyle(theme.secondary)
                            }
                            Spacer()
                            Button("Save") {
                                let preset = camera.currentPreset(slot: slot)
                                PresetStore.save(preset)
                                custom[slot] = preset
                                camera.show("Saved current settings to \(slot)")
                            }
                            .buttonStyle(.bordered)
                            Button("Use") {
                                if let preset = custom[slot] {
                                    camera.apply(preset)
                                    dismiss()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(custom[slot] == nil)
                        }
                        .foregroundStyle(theme.primary)
                    }
                } header: {
                    Text("My modes")
                } footer: {
                    Text("Save stores the current shutter, ISO, EV, focus, white balance, stacking mode and lightning trigger.")
                }
                .listRowBackground(Color.white.opacity(0.06))
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Modes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
