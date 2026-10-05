import AVFoundation

/// Puts the camera's settings on the Camera Control button (iPhone 16 and later).
/// Press to shoot. Light-press to show the controls, light-press twice to pick which one,
/// then slide your finger along the button to change it.
///
/// The lists here cover every lens, so the controls don't have to be rebuilt when you switch
/// lenses (rebuilding would close the overlay while you're using it). Values a lens can't do
/// are clamped to the nearest one it can.
@available(iOS 18.0, *)
final class CameraControlsManager: NSObject, AVCaptureSessionControlsDelegate {
    private weak var camera: CameraController?
    private let lenses: [LensOption]
    /// Whole stops make each notch of the slide a bigger change.
    var fullStops = UserDefaults.standard.bool(forKey: "controlFullStops")
    private var shutterValues: [ShutterStop] = []
    private var isoValues: [Float] = []
    private var zoomSlider: AVCaptureSlider?

    private var shutterPicker: AVCaptureIndexPicker?
    private var isoPicker: AVCaptureIndexPicker?
    private var focusSlider: AVCaptureSlider?
    private var evSlider: AVCaptureSlider?
    private var lensPicker: AVCaptureIndexPicker?
    private var whiteBalanceSlider: AVCaptureSlider?
    private var stackPicker: AVCaptureIndexPicker?
    private var lightningPicker: AVCaptureIndexPicker?

    init(camera: CameraController, lenses: [LensOption]) {
        self.camera = camera
        self.lenses = lenses
    }

    /// Call on the session queue.
    func install(on session: AVCaptureSession) {
        guard session.supportsControls else { return }

        shutterValues = (fullStops ? Stops.shutterFullStops : Stops.shutter).map { .time($0) } + [.bulb]
        isoValues = fullStops ? Stops.isoFullStops : Stops.iso

        let shutterValues = self.shutterValues
        let shutter = AVCaptureIndexPicker("Shutter", symbolName: "timer",
                                           localizedIndexTitles: shutterValues.map(\.label))
        shutter.setActionQueue(.main) { [weak self] index in
            guard shutterValues.indices.contains(index) else { return }
            self?.camera?.setShutter(shutterValues[index])
        }

        let isoValues = self.isoValues
        let iso = AVCaptureIndexPicker("ISO", symbolName: "camera.aperture",
                                       localizedIndexTitles: isoValues.map { Stops.whole($0) })
        iso.setActionQueue(.main) { [weak self] index in
            guard isoValues.indices.contains(index) else { return }
            self?.camera?.setISO(isoValues[index])
        }

        let focus = AVCaptureSlider("Focus", symbolName: "scope", in: 0...1)
        focus.localizedValueFormat = "%.2f"
        focus.setActionQueue(.main) { [weak self] value in self?.camera?.setLensPosition(value) }

        let ev = AVCaptureSlider("Exposure", symbolName: "plusminus.circle", in: -3...3, step: 1.0 / 3.0)
        ev.setActionQueue(.main) { [weak self] value in self?.camera?.setEVBias(value) }

        let lenses = self.lenses
        let lens = AVCaptureIndexPicker("Lens", symbolName: "camera", localizedIndexTitles: lenses.map(\.name))
        lens.setActionQueue(.main) { [weak self] index in
            guard lenses.indices.contains(index) else { return }
            self?.camera?.selectLens(lenses[index].id)
        }

        let zoom = AVCaptureSlider("Zoom", symbolName: "plus.magnifyingglass", in: 1...10)
        zoom.localizedValueFormat = "%.1f×"
        zoom.prominentValues = [1, 2, 5, 10]
        zoom.setActionQueue(.main) { [weak self] value in self?.camera?.setZoom(CGFloat(value)) }

        let whiteBalance = AVCaptureSlider("White balance", symbolName: "thermometer.medium", in: 2000...10000, step: 100)
        whiteBalance.localizedValueFormat = "%.0fK"
        whiteBalance.setActionQueue(.main) { [weak self] value in self?.camera?.setWhiteBalance(value) }

        let modes = StackMode.allCases
        let stack = AVCaptureIndexPicker("Long exposure mode", symbolName: "square.stack.3d.down.right",
                                         localizedIndexTitles: modes.map(\.rawValue))
        stack.setActionQueue(.main) { [weak self] index in
            guard modes.indices.contains(index) else { return }
            self?.camera?.stackMode = modes[index]
        }

        let lightning = AVCaptureIndexPicker("Lightning trigger", symbolName: "bolt",
                                             localizedIndexTitles: ["Off", "On"])
        lightning.setActionQueue(.main) { [weak self] index in self?.camera?.setLightning(index == 1) }

        // Most useful first, in case the phone limits how many controls an app can have.
        var controls: [AVCaptureControl] = [shutter, iso, focus, ev]
        if lenses.count > 1 { controls.append(lens) }
        controls += [zoom, whiteBalance, stack, lightning]

        // The delegate must be set before any control is added, or AVFoundation throws.
        session.setControlsDelegate(self, queue: .main)
        session.beginConfiguration()
        for control in session.controls { session.removeControl(control) }
        for control in controls where session.controls.count < session.maxControlsCount {
            if session.canAddControl(control) { session.addControl(control) }
        }
        session.commitConfiguration()

        shutterPicker = shutter
        isoPicker = iso
        focusSlider = focus
        evSlider = ev
        lensPicker = lens
        whiteBalanceSlider = whiteBalance
        stackPicker = stack
        lightningPicker = lightning
        zoomSlider = zoom
    }

    /// Bring the controls in line with whatever was changed on screen.
    private func sync() {
        guard let camera else { return }
        shutterPicker?.selectedIndex = Stops.nearestIndex(of: camera.exposureSeconds,
                                                          bulb: camera.bulb && !camera.autoShutter,
                                                          in: shutterValues)
        isoPicker?.selectedIndex = Stops.nearestIndex(of: camera.iso, in: isoValues)
        focusSlider?.value = camera.lensPosition
        evSlider?.value = camera.evBias
        if let index = lenses.firstIndex(where: { $0.id == camera.currentLensID }) {
            lensPicker?.selectedIndex = index
        }
        whiteBalanceSlider?.value = min(max(camera.whiteBalanceKelvin, 2000), 10000)
        if let index = StackMode.allCases.firstIndex(of: camera.stackMode) {
            stackPicker?.selectedIndex = index
        }
        lightningPicker?.selectedIndex = camera.lightningArmed ? 1 : 0
        zoomSlider?.value = Float(camera.zoomFactor)
    }

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) { sync() }
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) { sync() }
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}
}
