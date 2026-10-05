import AVFoundation
import Combine
import CoreLocation
import ImageIO
import UIKit

enum OutputFormat: String, CaseIterable, Identifiable {
    case heif = "HEIF"
    case raw = "RAW"
    case proRAW = "ProRAW"
    case rawPlusHEIF = "RAW+HEIF"
    var id: String { rawValue }
    var needsRAW: Bool { self != .heif }
}

enum LightningSensitivity: String, CaseIterable, Identifiable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    var id: String { rawValue }

    /// Jump in average brightness (0–1) that counts as a flash.
    var threshold: Float {
        switch self {
        case .low: return 0.08
        case .medium: return 0.04
        case .high: return 0.02
        }
    }
}

struct LensOption: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Owns the capture session and behaves like the brain of a manual camera:
/// metering modes, a shutter dial that continues past the sensor limit by stacking,
/// self-timer, magnifier, lightning trigger and photo metadata.
///
/// Published properties are only touched on the main thread; device work runs on `sessionQueue`.
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()
    let frameProcessor = FrameProcessor()

    private let sessionQueue = DispatchQueue(label: "camerapp.session")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let location = LocationService()

    // Session-queue state
    private var device: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var devicesByID: [String: AVCaptureDevice] = [:]
    private var rawFormatType: OSType?
    private var proRAWFormatType: OSType?
    /// Photo sizes this lens offers, keyed by megapixels (12, 24, 48…).
    private var photoDimensionsByMP: [Int: CMVideoDimensions] = [:]
    /// Technical summary of the current lens setup, for the camera report.
    private let sessionReport = Locked<String>("Camera not started")
    private var previewRotationObservation: NSKeyValueObservation?
    private var peakingSettings = (on: false, redMode: false)
    private var inFlight: [Int64: PhotoCaptureProcessor] = [:]
    private var cameraControls: AnyObject?

    // Main-thread state
    private var uiDevice: AVCaptureDevice?
    private var lensInfo: LensInfo?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var meterTimer: Timer?
    private var started = false
    private var lastExposureChange: CFTimeInterval = 0
    private var timerTask: Task<Void, Never>?
    /// Settings the lightning trigger stamps into its photos; read from the frame queue.
    private let lightningShotInfo = Locked<ShotInfo?>(nil)

    @Published var permissionDenied = false
    @Published var lenses: [LensOption] = []
    @Published var currentLensID: String?

    // Exposure. ISO and shutter can each be auto or manual, like P / S / ISO-priority / M on a camera.
    @Published var autoISO = true
    @Published var autoShutter = true
    @Published var iso: Float = 100
    @Published var isoRange: ClosedRange<Float> = 25...3200
    @Published var isoStops: [Float] = Stops.isoStops(in: 25...3200)
    @Published var exposureSeconds: Double = 1.0 / 60
    @Published var bulb = false
    @Published var shutterStops: [ShutterStop] = Stops.shutterStops(minExposure: 1.0 / 8000, maxExposure: 1)
    @Published var minDeviceExposure: Double = 1.0 / 8000
    @Published var maxDeviceExposure: Double = 1
    @Published var evBias: Float = 0
    /// What the light meter says the final picture will be, in stops from correct exposure.
    @Published var meterEV: Float = 0

    @Published var autoFocus = true
    @Published var lensPosition: Float = 1

    @Published var autoWhiteBalance = true
    @Published var whiteBalanceKelvin: Float = 4000

    @Published var format: OutputFormat = .heif {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "format") }
    }
    @Published var stackMode: StackMode = .longExposure {
        didSet { UserDefaults.standard.set(stackMode.rawValue, forKey: "stackMode") }
    }
    @Published var selfTimerSeconds = 0 {
        didSet { UserDefaults.standard.set(selfTimerSeconds, forKey: "selfTimer") }
    }
    @Published var lightningSensitivity: LightningSensitivity = .medium {
        didSet {
            UserDefaults.standard.set(lightningSensitivity.rawValue, forKey: "lightningSensitivity")
            if lightningArmed { setLightning(true) }
        }
    }
    /// Full sensor resolution (48 MP on Pro iPhones) for HEIF photos.
    /// Preferred photo size in megapixels. Lenses that can't do it use the nearest smaller size.
    @Published var preferredMegapixels = 12 {
        didSet { UserDefaults.standard.set(preferredMegapixels, forKey: "megapixels") }
    }
    @Published var saveLocation = true {
        didSet {
            UserDefaults.standard.set(saveLocation, forKey: "saveLocation")
            if saveLocation { location.start() } else { location.stop() }
        }
    }
    @Published var rawSupported = false
    /// e.g. "48 MP" when the lens can shoot above 12 MP.
    /// Photo sizes the current lens offers, e.g. [12, 24, 48].
    @Published var availableMegapixels: [Int] = [12]
    @Published var proRAWSupported = false
    /// Digital zoom on top of the selected lens (pinch the preview).
    @Published var zoomFactor: CGFloat = 1
    @Published var maxZoomFactor: CGFloat = 10
    /// Camera Control moves in whole stops instead of thirds (bigger change per swipe).
    @Published var cameraControlFullStops = false {
        didSet {
            UserDefaults.standard.set(cameraControlFullStops, forKey: "controlFullStops")
            reinstallCameraControls()
        }
    }

    @Published var magnifierOn = false
    @Published var isCapturing = false
    @Published var isStacking = false
    @Published var stackFrames = 0
    @Published var stackFrameTarget: Int?
    @Published var stackSubExposure: Double = 1
    @Published var timerRemaining: Int?
    @Published var lightningArmed = false
    @Published var lightningCount = 0
    @Published var lastMessage: String?
    @Published var histogram: [Float] = []
    @Published var peakingImage: CGImage?

    override init() {
        super.init()
        let defaults = UserDefaults.standard
        format = OutputFormat(rawValue: defaults.string(forKey: "format") ?? "") ?? .heif
        stackMode = StackMode(rawValue: defaults.string(forKey: "stackMode") ?? "") ?? .longExposure
        selfTimerSeconds = defaults.integer(forKey: "selfTimer")
        lightningSensitivity = LightningSensitivity(rawValue: defaults.string(forKey: "lightningSensitivity") ?? "") ?? .medium
        if defaults.object(forKey: "megapixels") != nil {
            preferredMegapixels = defaults.integer(forKey: "megapixels")
        } else if defaults.bool(forKey: "highResolution") {
            preferredMegapixels = 48
        }
        cameraControlFullStops = defaults.bool(forKey: "controlFullStops")
        if defaults.object(forKey: "saveLocation") != nil {
            saveLocation = defaults.bool(forKey: "saveLocation")
        }
        frameProcessor.onHistogram = { [weak self] in self?.histogram = $0 }
        frameProcessor.onPeaking = { [weak self] in self?.peakingImage = $0 }
    }

    // MARK: - Derived exposure state

    var fullAuto: Bool { autoISO && autoShutter }

    /// True when the chosen shutter speed is longer than the sensor allows, so frames get stacked.
    var isLongExposure: Bool {
        !autoShutter && (bulb || exposureSeconds > maxDeviceExposure * 1.02)
    }

    /// The exposure of each individual frame.
    var subExposure: Double {
        bulb ? maxDeviceExposure : min(exposureSeconds, maxDeviceExposure)
    }

    var plannedFrames: Int? {
        bulb ? nil : max(1, Int((exposureSeconds / subExposure).rounded()))
    }

    /// Adding N frames brightens the result by log2(N) stops.
    private var stackGainEV: Float {
        guard isLongExposure, stackMode == .longExposure, let frames = plannedFrames else { return 0 }
        return Float(log2(Double(frames)))
    }

    /// EXIF exposure program: 1 manual, 2 program, 4 shutter priority.
    private var exposureProgram: Int {
        if fullAuto { return 2 }
        if autoISO { return 4 }
        if autoShutter { return 2 }
        return 1
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        if saveLocation { location.start() }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.configure() } else { self.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    private func configure() {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspect
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.meterTick()
        }

        sessionQueue.async {
            let order: [AVCaptureDevice.DeviceType] = [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera]
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: order, mediaType: .video, position: .back)
            let devices = discovery.devices.sorted {
                (order.firstIndex(of: $0.deviceType) ?? 0) < (order.firstIndex(of: $1.deviceType) ?? 0)
            }
            for d in devices { self.devicesByID[d.uniqueID] = d }
            let options = Self.lensOptions(for: devices)

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }
            self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            // In the photo preset iOS otherwise shrinks these frames to preview size (~2 MP),
            // which is what stacked shots are built from. Ask for the full sensor readout instead.
            self.videoOutput.automaticallyConfiguresOutputBufferDimensions = false
            self.videoOutput.deliversPreviewSizedOutputBuffers = false
            self.videoOutput.setSampleBufferDelegate(self.frameProcessor, queue: self.frameProcessor.queue)
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }
            self.session.commitConfiguration()

            DispatchQueue.main.async { self.lenses = options }

            if let initial = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? devices.first {
                if let failure = Diagnostics.guarded("lens setup", { self.switchTo(initial) }) {
                    DispatchQueue.main.async { self.show(failure) }
                }
            }

            // Safety net: if setting up Camera Control crashed the app last time, skip it this time.
            let defaults = UserDefaults.standard
            let controlsCrashedBefore = defaults.bool(forKey: "controlsSetupInProgress")
            if #available(iOS 18.0, *), !controlsCrashedBefore {
                defaults.set(true, forKey: "controlsSetupInProgress")
                defaults.synchronize()
                let controls = CameraControlsManager(camera: self, lenses: options)
                if let failure = Diagnostics.guarded("Camera Control setup", { controls.install(on: self.session) }) {
                    DispatchQueue.main.async { self.show(failure) }
                }
                self.cameraControls = controls
            }

            self.session.startRunning()
            if controlsCrashedBefore {
                DispatchQueue.main.async { self.show("Camera Control setup skipped after a crash") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                defaults.set(false, forKey: "controlsSetupInProgress")
            }
        }
    }

    /// Names lenses by zoom relative to the main camera, e.g. 0.5×, 1×, 5×.
    private static func lensOptions(for devices: [AVCaptureDevice]) -> [LensOption] {
        let wide = devices.first { $0.deviceType == .builtInWideAngleCamera }
        let wideTan = wide.map { tan(Double($0.activeFormat.videoFieldOfView) * .pi / 360) }
        return devices.map { device in
            var name: String
            switch device.deviceType {
            case .builtInUltraWideCamera: name = "0.5×"
            case .builtInWideAngleCamera: name = "1×"
            case .builtInTelephotoCamera: name = "Tele"
            default: name = device.localizedName
            }
            let fov = Double(device.activeFormat.videoFieldOfView)
            if let wideTan, fov > 0, device.deviceType != .builtInWideAngleCamera {
                let zoom = wideTan / tan(fov * .pi / 360)
                if zoom < 0.95 {
                    name = String(format: "%.1f×", zoom)
                } else if zoom > 1.05 {
                    name = abs(zoom - zoom.rounded()) < 0.15 ? "\(Int(zoom.rounded()))×" : String(format: "%.1f×", zoom)
                }
            }
            return LensOption(id: device.uniqueID, name: name)
        }
    }

    // MARK: - Lens

    func selectLens(_ id: String) {
        guard id != currentLensID, !isStacking else { return }
        sessionQueue.async {
            if let d = self.devicesByID[id],
               let failure = Diagnostics.guarded("lens switch", { self.switchTo(d) }) {
                DispatchQueue.main.async { self.show(failure) }
            }
        }
    }

    /// Must run on `sessionQueue`.
    private func switchTo(_ newDevice: AVCaptureDevice) {
        guard let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return }
        session.beginConfiguration()
        if let videoInput { session.removeInput(videoInput) }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            videoInput = newInput
            device = newDevice
        } else if let videoInput, session.canAddInput(videoInput) {
            session.addInput(videoInput)
        }
        if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }
        session.commitConfiguration()
        guard device === newDevice else { return }

        photoOutput.maxPhotoQualityPrioritization = .quality
        let photoDimensions = newDevice.activeFormat.supportedMaxPhotoDimensions
        let area: (CMVideoDimensions) -> Int = { Int($0.width) * Int($0.height) }
        let largest = photoDimensions.max { area($0) < area($1) }
        if let largest { photoOutput.maxPhotoDimensions = largest }
        // 8064 × 6048 is 48.8 million pixels; Apple calls it 48 MP, so round down.
        var byMP: [Int: CMVideoDimensions] = [:]
        for dimensions in photoDimensions {
            byMP[area(dimensions) / 1_000_000] = dimensions
        }
        photoDimensionsByMP = byMP
        let megapixelChoices = byMP.keys.sorted()

        // Bayer RAW (plain DNG), not Apple ProRAW.
        if photoOutput.isAppleProRAWSupported { photoOutput.isAppleProRAWEnabled = true }
        rawFormatType = photoOutput.availableRawPhotoPixelFormatTypes.first { !AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
        proRAWFormatType = photoOutput.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
        let hasRAW = rawFormatType != nil
        let hasProRAW = proRAWFormatType != nil
        let maxZoom = min(10, newDevice.maxAvailableVideoZoomFactor)
        let fmt = newDevice.activeFormat
        let isoRange = fmt.minISO...fmt.maxISO
        let isoStops = Stops.isoStops(in: isoRange)
        let minExposure = fmt.minExposureDuration.seconds
        let maxExposure = fmt.maxExposureDuration.seconds
        let shutterStops = Stops.shutterStops(minExposure: minExposure, maxExposure: maxExposure)

        let describe: (CMVideoDimensions) -> String = { "\($0.width)×\($0.height)" }
        let formatSize = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        let frameRates = fmt.videoSupportedFrameRateRanges.map { String(format: "%.0f–%.0f fps", $0.minFrameRate, $0.maxFrameRate) }
        var report = [
            "Lens: \(newDevice.localizedName) (\(newDevice.deviceType.rawValue))",
            "Session preset: \(session.sessionPreset.rawValue)",
            "Active format: \(describe(formatSize)), \(frameRates.joined(separator: ", ")), FOV \(fmt.videoFieldOfView)°",
            "Photo sizes: \(photoDimensions.map(describe).joined(separator: ", "))",
            "Photo output max: \(describe(photoOutput.maxPhotoDimensions))",
            "ISO \(fmt.minISO)–\(fmt.maxISO), shutter \(Stops.shutterLabel(minExposure))–\(Stops.shutterLabel(maxExposure)), aperture f/\(newDevice.lensAperture)",
            "Bayer RAW: \(hasRAW ? "yes" : "no"), ProRAW: \(hasProRAW ? "yes" : "no")",
            "Max zoom: \(newDevice.maxAvailableVideoZoomFactor)",
        ]
        if #available(iOS 18.0, *) {
            report.append("Camera Control: supported \(session.supportsControls), max controls \(session.maxControlsCount), installed \(session.controls.count)")
        }
        sessionReport.set(report.joined(separator: "\n"))

        DispatchQueue.main.async {
            self.uiDevice = newDevice
            self.lensInfo = Metadata.lensInfo(for: newDevice)
            self.currentLensID = newDevice.uniqueID
            self.magnifierOn = false
            self.isoRange = isoRange
            self.isoStops = isoStops
            self.minDeviceExposure = minExposure
            self.maxDeviceExposure = maxExposure
            self.shutterStops = shutterStops
            self.availableMegapixels = megapixelChoices.isEmpty ? [12] : megapixelChoices
            self.proRAWSupported = hasProRAW
            self.zoomFactor = 1
            self.maxZoomFactor = maxZoom
            self.iso = min(max(self.iso, isoRange.lowerBound), isoRange.upperBound)
            if self.autoShutter {
                self.exposureSeconds = min(max(self.exposureSeconds, minExposure), maxExposure)
            }
            self.rawSupported = hasRAW
            if (self.format == .proRAW && !hasProRAW) || (self.format.needsRAW && self.format != .proRAW && !hasRAW) {
                self.format = .heif
            }

            let coordinator = AVCaptureDevice.RotationCoordinator(device: newDevice, previewLayer: self.previewLayer)
            self.rotationCoordinator = coordinator
            // Keep the preview upright as the screen rotates between portrait and landscape.
            self.previewRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                                  options: [.initial, .new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { self?.applyPreviewRotation(angle) }
            }

            self.applyExposure()
            self.applyFocus()
            self.applyWhiteBalance()
        }
    }

    // MARK: - Manual controls (call on main)

    func setAutoISO(_ on: Bool) { autoISO = on; applyExposure() }

    func setAutoShutter(_ on: Bool) {
        autoShutter = on
        if on {
            bulb = false
            exposureSeconds = min(max(exposureSeconds, minDeviceExposure), maxDeviceExposure)
        }
        applyExposure()
    }

    func setISO(_ value: Float) {
        iso = min(max(value, isoRange.lowerBound), isoRange.upperBound)
        autoISO = false
        applyExposure()
    }

    func setISOIndex(_ index: Int) {
        guard isoStops.indices.contains(index) else { return }
        setISO(isoStops[index])
    }

    func setShutter(_ stop: ShutterStop) {
        switch stop {
        case .bulb:
            bulb = true
        case .time(let t):
            bulb = false
            exposureSeconds = max(t, minDeviceExposure)
        }
        autoShutter = false
        applyExposure()
    }

    func setShutterIndex(_ index: Int) {
        guard shutterStops.indices.contains(index) else { return }
        setShutter(shutterStops[index])
    }

    func setEVBias(_ value: Float) {
        evBias = min(max(value, -3), 3)
        applyExposure()
    }

    func setAutoFocus(_ on: Bool) { autoFocus = on; applyFocus() }
    func setLensPosition(_ value: Float) { lensPosition = min(max(value, 0), 1); autoFocus = false; applyFocus() }

    func setAutoWhiteBalance(_ on: Bool) { autoWhiteBalance = on; applyWhiteBalance() }
    func setWhiteBalance(_ kelvin: Float) { whiteBalanceKelvin = kelvin; autoWhiteBalance = false; applyWhiteBalance() }

    func setMagnifier(_ on: Bool) {
        magnifierOn = on
        let target = on ? min(zoomFactor * 5, maxZoomFactor * 2) : zoomFactor
        withLockedDevice { d in
            d.videoZoomFactor = min(max(target, 1), d.maxAvailableVideoZoomFactor)
        }
    }

    func setZoom(_ factor: CGFloat) {
        zoomFactor = min(max(factor, 1), maxZoomFactor)
        magnifierOn = false
        let target = zoomFactor
        withLockedDevice { d in
            d.videoZoomFactor = min(target, d.maxAvailableVideoZoomFactor)
        }
    }

    private func reinstallCameraControls() {
        if #available(iOS 18.0, *) {
            let fullStops = cameraControlFullStops
            sessionQueue.async {
                guard let controls = self.cameraControls as? CameraControlsManager else { return }
                controls.fullStops = fullStops
                if let failure = Diagnostics.guarded("Camera Control setup", { controls.install(on: self.session) }) {
                    DispatchQueue.main.async { self.show(failure) }
                }
            }
        }
    }

    /// Tap on the preview. With autofocus on it focuses (and meters) there; with manual
    /// focus it does a one-shot autofocus and then locks, like an AF-ON button.
    func focus(atLayerPoint point: CGPoint) {
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        let continuous = autoFocus
        let meter = fullAuto
        withLockedDevice { d in
            if d.isFocusPointOfInterestSupported {
                d.focusPointOfInterest = devicePoint
                if continuous {
                    if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                } else if d.isFocusModeSupported(.autoFocus) {
                    d.focusMode = .autoFocus
                }
            }
            if meter && d.isExposurePointOfInterestSupported {
                d.exposurePointOfInterest = devicePoint
                d.exposureMode = .continuousAutoExposure
            }
        }
        if !continuous {
            show("Focusing…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let d = self.uiDevice, !self.autoFocus else { return }
                self.lensPosition = d.lensPosition
                self.applyFocus()
                self.show("Focus locked")
            }
        }
    }

    // MARK: - Presets

    func apply(_ preset: CameraPreset) {
        if isStacking { finishStack() }
        stackMode = preset.stackMode
        evBias = preset.evBias
        autoISO = preset.autoISO
        if !preset.autoISO { iso = min(max(preset.iso, isoRange.lowerBound), isoRange.upperBound) }
        autoShutter = preset.autoShutter
        bulb = !preset.autoShutter && preset.bulb
        if !preset.autoShutter { exposureSeconds = max(preset.exposureSeconds, minDeviceExposure) }
        if let autoFocus = preset.autoFocus {
            self.autoFocus = autoFocus
            if let position = preset.lensPosition { lensPosition = position }
        }
        autoWhiteBalance = preset.autoWhiteBalance
        if !preset.autoWhiteBalance { whiteBalanceKelvin = preset.kelvin }
        applyExposure()
        applyFocus()
        applyWhiteBalance()
        if preset.armLightning != lightningArmed { setLightning(preset.armLightning) }
        show("Mode: \(preset.name)")
    }

    func currentPreset(slot: String) -> CameraPreset {
        CameraPreset(id: slot, name: slot, detail: "",
                     autoISO: autoISO, iso: iso, autoShutter: autoShutter, exposureSeconds: exposureSeconds,
                     bulb: bulb, evBias: evBias, autoFocus: autoFocus, lensPosition: autoFocus ? nil : lensPosition,
                     autoWhiteBalance: autoWhiteBalance, kelvin: whiteBalanceKelvin, stackMode: stackMode,
                     armLightning: lightningArmed)
    }

    // MARK: - Applying settings to the device

    private func withLockedDevice(_ body: @escaping (AVCaptureDevice) -> Void) {
        sessionQueue.async {
            guard let d = self.device else { return }
            do {
                try d.lockForConfiguration()
                let failure = Diagnostics.guarded("camera setting") { body(d) }
                d.unlockForConfiguration()
                if let failure { DispatchQueue.main.async { self.show(failure) } }
            } catch {
                DispatchQueue.main.async { self.show("Couldn't change camera settings") }
            }
        }
    }

    private func applyExposure() {
        lastExposureChange = CACurrentMediaTime()
        let full = fullAuto
        let bias = evBias
        let iso = self.iso
        let seconds = autoShutter ? exposureSeconds : subExposure
        withLockedDevice { d in
            if full {
                d.activeVideoMaxFrameDuration = .invalid
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                d.setExposureTargetBias(min(max(bias, d.minExposureTargetBias), d.maxExposureTargetBias), completionHandler: nil)
            } else if d.isExposureModeSupported(.custom) {
                let f = d.activeFormat
                let clampedISO = min(max(iso, f.minISO), f.maxISO)
                let clampedSeconds = min(max(seconds, f.minExposureDuration.seconds), f.maxExposureDuration.seconds)
                Self.allowFrameDuration(clampedSeconds, on: d)
                d.setExposureTargetBias(0, completionHandler: nil)
                d.setExposureModeCustom(duration: CMTime(seconds: clampedSeconds, preferredTimescale: 1_000_000),
                                        iso: clampedISO,
                                        completionHandler: nil)
            }
        }
    }

    /// Slows the video frame rate when needed so each frame can be exposed for the full time.
    private static func allowFrameDuration(_ seconds: Double, on d: AVCaptureDevice) {
        let longest = d.activeFormat.videoSupportedFrameRateRanges
            .map { $0.maxFrameDuration }
            .max { $0.seconds < $1.seconds }
        guard let longest else { return }
        if seconds > d.activeVideoMaxFrameDuration.seconds + 0.000_001 {
            d.activeVideoMaxFrameDuration = seconds >= longest.seconds
                ? longest
                : CMTime(seconds: seconds, preferredTimescale: 1_000_000)
        }
    }

    private func applyFocus() {
        let auto = autoFocus
        let position = lensPosition
        withLockedDevice { d in
            if auto {
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            } else if d.isLockingFocusWithCustomLensPositionSupported {
                d.setFocusModeLocked(lensPosition: min(max(position, 0), 1), completionHandler: nil)
            }
        }
    }

    private func applyWhiteBalance() {
        let auto = autoWhiteBalance
        let kelvin = whiteBalanceKelvin
        withLockedDevice { d in
            if auto {
                if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
            } else if d.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: 0)
                var gains = d.deviceWhiteBalanceGains(for: values)
                let maxGain = d.maxWhiteBalanceGain
                gains.redGain = min(max(gains.redGain, 1), maxGain)
                gains.greenGain = min(max(gains.greenGain, 1), maxGain)
                gains.blueGain = min(max(gains.blueGain, 1), maxGain)
                d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            }
        }
    }

    /// Runs the light meter. In shutter-priority or ISO-priority it nudges the auto value
    /// towards correct exposure (allowing for stacked long exposures); otherwise it just reports.
    private func meterTick() {
        guard let d = uiDevice else { return }
        let offset = d.exposureTargetOffset

        if fullAuto {
            meterEV = offset.isFinite ? offset : 0
            iso = d.iso
            let s = d.exposureDuration.seconds
            if s.isFinite && s > 0 { exposureSeconds = s }
        } else if offset.isFinite {
            meterEV = offset + stackGainEV
            let frameTime = autoShutter ? exposureSeconds : subExposure
            let settleTime = max(0.6, 2.5 * frameTime)
            let now = CACurrentMediaTime()
            if (autoISO || autoShutter) && !isStacking && now - lastExposureChange > settleTime {
                let error = offset + stackGainEV - evBias
                if abs(error) > 0.15 {
                    let factor = pow(2.0, -Double(error) * 0.7)
                    if autoISO {
                        let newISO = min(max(iso * Float(factor), isoRange.lowerBound), isoRange.upperBound)
                        if abs(newISO - iso) / iso > 0.01 {
                            iso = newISO
                            applyExposure()
                        }
                    } else {
                        let newSeconds = min(max(exposureSeconds * factor, minDeviceExposure), maxDeviceExposure)
                        if abs(newSeconds - exposureSeconds) / exposureSeconds > 0.01 {
                            exposureSeconds = newSeconds
                            applyExposure()
                        }
                    }
                }
            }
        }

        if d.focusMode != .locked { lensPosition = d.lensPosition }
        if autoWhiteBalance {
            // Gains outside 1...max make AVFoundation throw, so clamp before converting.
            var gains = d.deviceWhiteBalanceGains
            let maxGain = d.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1), maxGain)
            gains.blueGain = min(max(gains.blueGain, 1), maxGain)
            var t: Float = .nan
            Diagnostics.guarded("white balance readout") {
                t = d.temperatureAndTintValues(for: gains).temperature
            }
            if t.isFinite { whiteBalanceKelvin = t }
        }
        if lightningArmed {
            lightningShotInfo.set(shotInfo(frameExposure: autoShutter ? exposureSeconds : subExposure))
        }
    }

    // MARK: - Shutter

    /// The shutter button, volume buttons and Camera Control all come here.
    func shutterPressed() {
        if isStacking {
            finishStack()
            return
        }
        if timerTask != nil {
            cancelSelfTimer()
            show("Timer cancelled")
            return
        }
        guard !isCapturing else { return }
        if selfTimerSeconds > 0 {
            startSelfTimer()
        } else {
            takePicture()
        }
    }

    private func startSelfTimer() {
        let seconds = selfTimerSeconds
        timerTask = Task { @MainActor in
            for remaining in stride(from: seconds, to: 0, by: -1) {
                self.timerRemaining = remaining
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            self.timerRemaining = nil
            self.timerTask = nil
            self.takePicture()
        }
    }

    func cancelSelfTimer() {
        timerTask?.cancel()
        timerTask = nil
        timerRemaining = nil
    }

    /// Takes one picture right now: a normal photo, or a stacked long exposure when the
    /// shutter speed is longer than the sensor allows. `completion` fires as soon as the
    /// camera is free for the next shot; saving carries on in the background.
    func takePicture(completion: @escaping (Bool) -> Void = { _ in }) {
        if magnifierOn { setMagnifier(false) }
        if isLongExposure && stackMode == .rawFrames {
            startRAWFrames(completion: completion)
        } else if isLongExposure {
            startStack(completion: completion)
        } else {
            capturePhoto(completion: completion)
        }
    }

    func takePictureAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.takePicture { continuation.resume(returning: $0) }
            }
        }
    }

    private var captureOrientation: CGImagePropertyOrientation {
        Stops.orientation(forRotationAngle: rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90)
    }

    private func shotInfo(frameExposure: Double) -> ShotInfo {
        ShotInfo(date: Date(),
                 iso: iso,
                 frameExposure: frameExposure,
                 exposureProgram: exposureProgram,
                 evBias: evBias,
                 manualWhiteBalance: !autoWhiteBalance,
                 lens: lensInfo ?? LensInfo(model: "\(Metadata.deviceModel) back camera", focalLength: nil,
                                            focalLength35mm: nil, fNumber: 1.8))
    }

    private func startStack(completion: @escaping (Bool) -> Void) {
        if lightningArmed { setLightning(false) }
        let mode = stackMode
        let sub = subExposure
        let frames = plannedFrames
        let shot = shotInfo(frameExposure: sub)
        let orientation = captureOrientation
        let location = self.location
        let saveLocation = self.saveLocation
        isStacking = true
        stackFrames = 0
        stackFrameTarget = frames
        stackSubExposure = sub

        frameProcessor.startStack(mode: mode, frames: frames, metadata: { count, width, height in
            let fix = location.snapshot(enabled: saveLocation)
            return Metadata.stackedImageProperties(shot: shot, kind: .stack(mode), frames: count,
                                                   width: width, height: height, orientation: orientation,
                                                   location: fix.location, heading: fix.heading)
        }, progress: { [weak self] count in
            self?.stackFrames = count
        }, framesDone: { [weak self] count in
            guard let self else { return }
            self.isStacking = false
            self.stackFrameTarget = nil
            completion(count > 0)
        }, completion: { [weak self] data, count in
            guard let self else { return }
            guard let data, count > 0 else {
                self.show("Long exposure failed")
                return
            }
            let total = Stops.shutterLabel(Double(count) * sub)
            let description = mode == .longExposure ? "\(total) long exposure" : "\(total) \(mode.rawValue.lowercased()) stack"
            let fix = location.snapshot(enabled: saveLocation)
            PhotoLibrary.save(primary: data, location: fix.location, successMessage: "Saved \(description)") { _, message in
                self.show(message)
            }
        })
    }

    /// Ends a Bulb exposure, or a timed one early, and saves what has been collected.
    func finishStack() {
        rawFramesTask?.cancel()
        frameProcessor.finishStack()
    }

    private var rawFramesTask: Task<Void, Never>?

    /// "RAW frames" long exposure: shoots the exposure as a series of full-resolution RAW photos
    /// (ProRAW 48 MP when available) for stacking later in an astro app such as Sequator or Siril.
    private func startRAWFrames(completion: @escaping (Bool) -> Void) {
        if lightningArmed { setLightning(false) }
        let frames = plannedFrames
        // Follow the chosen format if it's a RAW one; otherwise use the best RAW available.
        let rawFormat: OutputFormat = format == .raw || !proRAWSupported ? .raw : .proRAW
        isStacking = true
        stackFrames = 0
        stackFrameTarget = frames
        stackSubExposure = subExposure
        rawFramesTask = Task { @MainActor in
            var taken = 0
            while !Task.isCancelled, frames == nil || taken < frames! {
                let ok = await withCheckedContinuation { continuation in
                    self.capturePhoto(formatOverride: rawFormat) { continuation.resume(returning: $0) }
                }
                if !ok { break }
                taken += 1
                self.stackFrames = taken
            }
            self.isStacking = false
            self.stackFrameTarget = nil
            self.rawFramesTask = nil
            self.show("Saved \(taken) RAW frames for stacking")
            completion(taken > 0)
        }
    }

    private func capturePhoto(formatOverride: OutputFormat? = nil, completion: @escaping (Bool) -> Void) {
        let format = formatOverride ?? self.format
        // Plain (Bayer) RAW is a 12 MP readout; ProRAW comes in 12 or 48 MP; HEIF in any size.
        let megapixels: Int
        switch format {
        case .raw, .rawPlusHEIF: megapixels = availableMegapixels.first ?? 12
        case .proRAW: megapixels = effectiveMegapixels > 12 ? (availableMegapixels.last ?? 12) : (availableMegapixels.first ?? 12)
        case .heif: megapixels = effectiveMegapixels
        }
        let highResolution = megapixels > 13
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        let fix = location.snapshot(enabled: saveLocation)
        let gps = fix.location.map { Metadata.gps(location: $0, heading: fix.heading) }
        let deviceID = currentLensID
        isCapturing = true

        sessionQueue.async {
            let settings: AVCapturePhotoSettings
            let hevc = self.photoOutput.availablePhotoCodecTypes.contains(.hevc)
            if format == .proRAW, let raw = self.proRAWFormatType {
                settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
            } else if format.needsRAW, let raw = self.rawFormatType {
                if format == .rawPlusHEIF && hevc {
                    settings = AVCapturePhotoSettings(rawPixelFormatType: raw,
                                                      processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc])
                } else {
                    settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
                }
            } else if hevc {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            if let dimensions = self.photoDimensionsByMP[megapixels] {
                settings.maxPhotoDimensions = dimensions
            }
            // .speed keeps a single frame (the exposure you set is the exposure you get), but iOS
            // only delivers 48 MP and ProRAW at .balanced or higher.
            settings.photoQualityPrioritization = (highResolution || format == .proRAW) ? .balanced : .speed
            if self.photoOutput.supportedFlashModes.contains(.off) { settings.flashMode = .off }

            if let angle, let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }

            let id = settings.uniqueID
            let processor = PhotoCaptureProcessor(gps: gps, location: fix.location, deviceID: deviceID, onCaptured: { success in
                self.sessionQueue.async { self.inFlight[id] = nil }
                DispatchQueue.main.async {
                    self.isCapturing = false
                    if let device = self.uiDevice { self.lensInfo = Metadata.lensInfo(for: device) }
                    completion(success)
                }
            }, onSaved: { _, message in
                self.show(message)
            })
            self.inFlight[id] = processor
            if let failure = Diagnostics.guarded("capture", { self.photoOutput.capturePhoto(with: settings, delegate: processor) }) {
                self.inFlight[id] = nil
                DispatchQueue.main.async {
                    self.isCapturing = false
                    self.show(failure)
                    completion(false)
                }
            }
        }
    }

    // MARK: - Live view helpers

    func setPeaking(_ on: Bool, redMode: Bool) {
        peakingSettings = (on, redMode)
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview ?? 90
        frameProcessor.setPeaking(enabled: on, orientation: Stops.orientation(forRotationAngle: angle), redMode: redMode)
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        setPeaking(peakingSettings.on, redMode: peakingSettings.redMode)
    }

    /// The size photos will actually be, given the preference and what this lens can do.
    var effectiveMegapixels: Int {
        availableMegapixels.filter { $0 <= preferredMegapixels }.max() ?? availableMegapixels.first ?? 12
    }

    /// Everything useful for diagnosing problems remotely, to paste into a chat.
    func cameraReport() -> String {
        var lines = [
            "\(Metadata.software) on \(Metadata.deviceModel), iOS \(UIDevice.current.systemVersion)",
            sessionReport.get(),
            "Video frames (used for stacks): \(frameProcessor.frameSize.get())",
            "Format \(format.rawValue), resolution \(effectiveMegapixels) MP (preferred \(preferredMegapixels)), stack mode \(stackMode.rawValue)",
            "ISO \(autoISO ? "auto" : "manual") \(Int(iso)), shutter \(autoShutter ? "auto" : "manual") \(bulb ? "BULB" : Stops.shutterLabel(exposureSeconds)), EV \(Stops.evLabel(evBias)), zoom \(String(format: "%.1f", zoomFactor))×",
            "Focus \(autoFocus ? "auto" : "manual") \(String(format: "%.2f", lensPosition)), WB \(autoWhiteBalance ? "auto" : "manual") \(Int(whiteBalanceKelvin))K",
        ]
        if let error = UserDefaults.standard.string(forKey: "diagnostics.lastError") {
            lines.append("Last caught error: \(error)")
        }
        return lines.joined(separator: "\n")
    }

    func setLightning(_ on: Bool) {
        if on && isStacking { return }
        lightningArmed = on
        if on { lightningCount = 0 }
        lightningShotInfo.set(shotInfo(frameExposure: autoShutter ? exposureSeconds : subExposure))
        let shotInfoBox = lightningShotInfo
        let orientation = captureOrientation
        let location = self.location
        let saveLocation = self.saveLocation
        frameProcessor.setLightning(threshold: on ? lightningSensitivity.threshold : nil, metadata: { count, width, height in
            guard let shot = shotInfoBox.get() else { return [:] }
            let fix = location.snapshot(enabled: saveLocation)
            return Metadata.stackedImageProperties(shot: shot, kind: .lightning, frames: count,
                                                   width: width, height: height, orientation: orientation,
                                                   location: fix.location, heading: fix.heading)
        }) { [weak self] data in
            guard let self, let data else { return }
            let fix = location.snapshot(enabled: saveLocation)
            PhotoLibrary.save(primary: data, location: fix.location, successMessage: "⚡ Lightning saved") { ok, message in
                if ok { self.lightningCount += 1 }
                self.show(message)
            }
        }
    }

    func show(_ message: String) {
        lastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if self.lastMessage == message { self.lastMessage = nil }
        }
    }
}
