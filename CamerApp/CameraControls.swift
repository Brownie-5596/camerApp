import AVFoundation

/// Puts ISO, shutter, exposure compensation, focus and white balance on the
/// Camera Control button (iPhone 16 and later). Light-press to pick a setting, slide to change it.
@available(iOS 18.0, *)
final class CameraControlsManager: NSObject, AVCaptureSessionControlsDelegate {
    private weak var camera: CameraController?
    private var isoPicker: AVCaptureIndexPicker?
    private var shutterPicker: AVCaptureIndexPicker?
    private var evSlider: AVCaptureSlider?
    private var focusSlider: AVCaptureSlider?
    private var whiteBalanceSlider: AVCaptureSlider?

    init(camera: CameraController) {
        self.camera = camera
    }

    /// Call on the session queue whenever the lens changes.
    func install(on session: AVCaptureSession, isoStops: [Float], shutterStops: [ShutterStop]) {
        guard session.supportsControls else { return }

        let iso = AVCaptureIndexPicker("ISO", symbolName: "camera.aperture",
                                       localizedIndexTitles: isoStops.map { Stops.whole($0) })
        iso.setActionQueue(.main) { [weak self] index in self?.camera?.setISOIndex(index) }

        let shutter = AVCaptureIndexPicker("Shutter", symbolName: "timer",
                                           localizedIndexTitles: shutterStops.map(\.label))
        shutter.setActionQueue(.main) { [weak self] index in self?.camera?.setShutterIndex(index) }

        let ev = AVCaptureSlider("Exposure", symbolName: "plusminus.circle", in: -3...3, step: 1.0 / 3.0)
        ev.setActionQueue(.main) { [weak self] value in self?.camera?.setEVBias(value) }

        let focus = AVCaptureSlider("Focus", symbolName: "scope", in: 0...1)
        focus.setActionQueue(.main) { [weak self] value in self?.camera?.setLensPosition(value) }

        let whiteBalance = AVCaptureSlider("White balance", symbolName: "thermometer.medium", in: 2000...10000, step: 100)
        whiteBalance.localizedValueFormat = "%.0fK"
        whiteBalance.setActionQueue(.main) { [weak self] value in self?.camera?.setWhiteBalance(value) }

        session.beginConfiguration()
        for control in session.controls { session.removeControl(control) }
        let controls: [AVCaptureControl] = [shutter, iso, ev, focus, whiteBalance]
        for control in controls where session.controls.count < session.maxControlsCount {
            if session.canAddControl(control) { session.addControl(control) }
        }
        session.commitConfiguration()
        session.setControlsDelegate(self, queue: .main)

        isoPicker = iso
        shutterPicker = shutter
        evSlider = ev
        focusSlider = focus
        whiteBalanceSlider = whiteBalance
    }

    /// Bring the controls in line with whatever was changed on screen.
    private func sync() {
        guard let camera else { return }
        isoPicker?.selectedIndex = Stops.nearestIndex(of: camera.iso, in: camera.isoStops)
        shutterPicker?.selectedIndex = Stops.nearestIndex(of: camera.exposureSeconds, bulb: camera.bulb, in: camera.shutterStops)
        evSlider?.value = camera.evBias
        focusSlider?.value = camera.lensPosition
        whiteBalanceSlider?.value = min(max(camera.whiteBalanceKelvin, 2000), 10000)
    }

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) { sync() }
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) { sync() }
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}
}
