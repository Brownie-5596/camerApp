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
        CameraPreset(id: "stars", name: "Stars (like iPhone Night mode)",
                     detail: "30s long exposure with Auto ISO aiming slightly dark (−1 EV), auto white balance and your saved star focus (★). The closest match to the Camera app's 30s Night mode shots, with a dark sky and lots of stars.",
                     autoISO: true, iso: 1600, autoShutter: false, exposureSeconds: 30, bulb: false, evBias: -1,
                     autoFocus: false, lensPosition: nil, autoWhiteBalance: true, kelvin: 4000,
                     stackMode: .longExposure, armLightning: false),
        CameraPreset(id: "aurora", name: "Aurora",
                     detail: "4s long exposure, Auto ISO (−0.7 EV), 3800K, star focus. Try 2s if the aurora is moving fast, 8s if it is faint.",
                     autoISO: true, iso: 1000, autoShutter: false, exposureSeconds: 4, bulb: false, evBias: -0.7,
                     autoFocus: false, lensPosition: nil, autoWhiteBalance: false, kelvin: 3800,
                     stackMode: .longExposure, armLightning: false),
        CameraPreset(id: "aurora-clean", name: "Aurora (low noise)",
                     detail: "Averages 10 one-second frames with Auto ISO (−0.7 EV). Much cleaner than a single frame; best for slow, steady aurora that is bright enough in 1 second.",
                     autoISO: true, iso: 3200, autoShutter: false, exposureSeconds: 10, bulb: false, evBias: -0.7,
                     autoFocus: false, lensPosition: nil, autoWhiteBalance: false, kelvin: 3800,
                     stackMode: .average, armLightning: false),
        CameraPreset(id: "milkyway", name: "Milky Way",
                     detail: "20s long exposure, Auto ISO (−1 EV), 4000K, star focus. Use the 1× or 0.5× lens.",
                     autoISO: true, iso: 1600, autoShutter: false, exposureSeconds: 20, bulb: false, evBias: -1,
                     autoFocus: false, lensPosition: nil, autoWhiteBalance: false, kelvin: 4000,
                     stackMode: .longExposure, armLightning: false),
        CameraPreset(id: "night-lightning", name: "Night lightning",
                     detail: "15s Brightest stack at ISO 100: the sky stays dark and every flash is kept without blowing out. Set the intervalometer to Continuous + Unlimited for back-to-back exposures.",
                     autoISO: false, iso: 100, autoShutter: false, exposureSeconds: 15, bulb: false, evBias: 0,
                     autoFocus: false, lensPosition: nil, autoWhiteBalance: false, kelvin: 4500,
                     stackMode: .brightest, armLightning: false),
        CameraPreset(id: "day-lightning", name: "Day / dusk lightning",
                     detail: "1/30 with auto ISO, −0.7 EV, and the lightning trigger armed. Saves automatically when the sky flashes.",
                     autoISO: true, iso: 100, autoShutter: false, exposureSeconds: 1.0 / 30, bulb: false, evBias: -0.7,
                     autoFocus: false, lensPosition: nil, autoWhiteBalance: true, kelvin: 5000,
                     stackMode: .brightest, armLightning: true),
        CameraPreset(id: "star-trails", name: "Star trails",
                     detail: "BULB Brightest stack with Auto ISO (−1.5 EV) and star focus: press to start, press again when done. 20+ minutes gives long trails.",
                     autoISO: true, iso: 400, autoShutter: false, exposureSeconds: 1, bulb: true, evBias: -1.5,
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
