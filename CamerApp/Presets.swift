import Foundation

/// A saved set of camera settings, like the scene modes or C1/C2/C3 custom modes on a camera.
struct CameraPreset: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var detail: String
    var autoISO: Bool
    var iso: Float
    var autoShutter: Bool
    var exposureSeconds: Double
    var bulb: Bool
    var evBias: Float
    /// nil leaves focus alone. false switches to manual focus at the current (or saved) position.
    var autoFocus: Bool?
    var lensPosition: Float?
    var autoWhiteBalance: Bool
    var kelvin: Float
    var stackMode: StackMode
    var armLightning: Bool

    var summary: String {
        let isoText = autoISO ? "Auto ISO" : "ISO \(Stops.whole(iso))"
        let shutterText = autoShutter ? "Auto shutter" : (bulb ? "BULB" : Stops.shutterLabel(exposureSeconds))
        let wbText = autoWhiteBalance ? "AWB" : "\(Stops.whole(kelvin))K"
        let focusText = autoFocus == true ? "AF" : "MF"
        return "\(shutterText) · \(isoText) · \(wbText) · \(focusText) · \(stackMode.shortName)"
    }

    static let builtIn: [CameraPreset] = [
        CameraPreset(id: "auto", name: "Auto",
                     detail: "Everything automatic. Daytime storms, scenery and everyday shots.",
                     autoISO: true, iso: 100, autoShutter: true, exposureSeconds: 1.0 / 60, bulb: false, evBias: 0,
                     autoFocus: true, lensPosition: nil, autoWhiteBalance: true, kelvin: 5000,
                     stackMode: .longExposure, armLightning: false),
        CameraPreset(id: "aurora", name: "Aurora",
                     detail: "4s long exposure at ISO 1000, 3800K, manual focus. Focus on a bright star first (magnifier + peaking). Try 2s if the aurora is moving fast, 8s if it is faint.",
                     autoISO: false, iso: 1000, autoShutter: false, exposureSeconds: 4, bulb: false, evBias: 0,
                     autoFocus: false, lensPosition: nil, autoWhiteBalance: false, kelvin: 3800,
                     stackMode: .longExposure, armLightning: false),
        CameraPreset(id: "aurora-clean", name: "Aurora (low noise)",
                     detail: "Averages 10 one-second frames at ISO 3200. Much cleaner than a single frame; best for slow, steady aurora.",
                     autoISO: false, iso: 3200, autoShutter: false, exposureSeconds: 10, bulb: false, evBias: 0,
                     autoFocus: false, lensPosition: nil, autoWhiteBalance: false, kelvin: 3800,
                     stackMode: .average, armLightning: false),
        CameraPreset(id: "milkyway", name: "Milky Way",
                     detail: "15s long exposure at ISO 1600, 4000K, manual focus. Use the 1× or 0.5× lens.",
                     autoISO: false, iso: 1600, autoShutter: false, exposureSeconds: 15, bulb: false, evBias: 0,
                     autoFocus: false, lensPosition: nil, autoWhiteBalance: false, kelvin: 4000,
                     stackMode: .longExposure, armLightning: false),
        CameraPreset(id: "night-lightning", name: "Night lightning",
                     detail: "15s Brightest stack: every flash is kept without over-exposing the sky. Set the intervalometer to Continuous + Unlimited for back-to-back exposures.",
                     autoISO: false, iso: 100, autoShutter: false, exposureSeconds: 15, bulb: false, evBias: 0,
                     autoFocus: false, lensPosition: nil, autoWhiteBalance: false, kelvin: 4500,
                     stackMode: .brightest, armLightning: false),
        CameraPreset(id: "day-lightning", name: "Day / dusk lightning",
                     detail: "1/30 with auto ISO, −0.7 EV, and the lightning trigger armed. Saves automatically when the sky flashes.",
                     autoISO: true, iso: 100, autoShutter: false, exposureSeconds: 1.0 / 30, bulb: false, evBias: -0.7,
                     autoFocus: false, lensPosition: nil, autoWhiteBalance: true, kelvin: 5000,
                     stackMode: .brightest, armLightning: true),
        CameraPreset(id: "star-trails", name: "Star trails",
                     detail: "BULB Brightest stack at ISO 400: press to start, press again when done. 20+ minutes gives long trails.",
                     autoISO: false, iso: 400, autoShutter: false, exposureSeconds: 1, bulb: true, evBias: 0,
                     autoFocus: false, lensPosition: nil, autoWhiteBalance: false, kelvin: 4000,
                     stackMode: .brightest, armLightning: false),
    ]
}

/// The user's own modes, stored on the phone.
enum PresetStore {
    static let slots = ["C1", "C2", "C3"]

    static func load(_ slot: String) -> CameraPreset? {
        guard let data = UserDefaults.standard.data(forKey: "preset." + slot) else { return nil }
        return try? JSONDecoder().decode(CameraPreset.self, from: data)
    }

    static func loadAll() -> [String: CameraPreset] {
        var presets: [String: CameraPreset] = [:]
        for slot in slots {
            if let preset = load(slot) { presets[slot] = preset }
        }
        return presets
    }

    static func save(_ preset: CameraPreset) {
        if let data = try? JSONEncoder().encode(preset) {
            UserDefaults.standard.set(data, forKey: "preset." + preset.id)
        }
    }
}
