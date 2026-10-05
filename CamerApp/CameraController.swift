import AVFoundation
import Combine
import ImageIO
import UIKit

enum OutputFormat: String, CaseIterable, Identifiable {
    case heif = "HEIF"
    case raw = "RAW"
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
/// self-timer, magnifier and lightning trigger.
///
/// Published properties are only touched on the main thread; device work runs on `sessionQueue`.
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()
    let frameProcessor = FrameProcessor()

    private let sessionQueue = DispatchQueue(label: "camerapp.session")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()

    // Session-queue state
    private var device: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var devicesByID: [String: AVCaptureDevice] = [:]
    private var rawFormatType: OSType?
    private var inFlight: [Int64: PhotoCaptureProcessor] = [:]
    private var cameraControls: AnyObject?

    // Main-thread state
    private var uiDevice: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var meterTimer: Timer?
    private var started = false
    private var lastExposureChange: CFTimeInterval = 0
    private var timerTask: Task<Void, Never>?

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
    @Published var rawSupported = false

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

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
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
            let options = devices.map { LensOption(id: $0.uniqueID, name: Self.lensName(for: $0)) }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }
            self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self.frameProcessor, queue: self.frameProcessor.queue)
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }
            self.session.commitConfiguration()

            DispatchQueue.main.async { self.lenses = options }

            if let initial = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? devices.first {
                self.switchTo(initial)
            }
            self.session.startRunning()
        }
    }

    private static func lensName(for device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInUltraWideCamera: return "0.5×"
        case .builtInWideAngleCamera: return "1×"
        case .builtInTelephotoCamera: return "Tele"
        default: return device.localizedName
        }
    }

    // MARK: - Lens

    func selectLens(_ id: String) {
        guard id != currentLensID, !isStacking else { return }
        sessionQueue.async {
            if let d = self.devicesByID[id] { self.switchTo(d) }
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
        // Bayer RAW (plain DNG), not Apple ProRAW.
        rawFormatType = photoOutput.availableRawPhotoPixelFormatTypes.first { !AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
        let hasRAW = rawFormatType != nil
        let fmt = newDevice.activeFormat
        let isoRange = fmt.minISO...fmt.maxISO
        let isoStops = Stops.isoStops(in: isoRange)
        let minExposure = fmt.minExposureDuration.seconds
        let maxExposure = fmt.maxExposureDuration.seconds
        let shutterStops = Stops.shutterStops(minExposure: minExposure, maxExposure: maxExposure)

        if #available(iOS 18.0, *) {
            let controls = (cameraControls as? CameraControlsManager) ?? CameraControlsManager(camera: self)
            cameraControls = controls
            controls.install(on: session, isoStops: isoStops, shutterStops: shutterStops)
        }

        DispatchQueue.main.async {
            self.uiDevice = newDevice
            self.currentLensID = newDevice.uniqueID
            self.magnifierOn = false
            self.isoRange = isoRange
            self.isoStops = isoStops
            self.minDeviceExposure = minExposure
            self.maxDeviceExposure = maxExposure
            self.shutterStops = shutterStops
            self.iso = min(max(self.iso, isoRange.lowerBound), isoRange.upperBound)
            if self.autoShutter {
                self.exposureSeconds = min(max(self.exposureSeconds, minExposure), maxExposure)
            }
            self.rawSupported = hasRAW
            if !hasRAW && self.format.needsRAW { self.format = .heif }

            let coordinator = AVCaptureDevice.RotationCoordinator(device: newDevice, previewLayer: self.previewLayer)
            self.rotationCoordinator = coordinator
            let previewAngle = coordinator.videoRotationAngleForHorizonLevelPreview
            if let connection = self.previewLayer.connection, connection.isVideoRotationAngleSupported(previewAngle) {
                connection.videoRotationAngle = previewAngle
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

    func setShutterIndex(_ index: Int) {
        guard shutterStops.indices.contains(index) else { return }
        switch shutterStops[index] {
        case .bulb:
            bulb = true
        case .time(let t):
            bulb = false
            exposureSeconds = t
        }
        autoShutter = false
        applyExposure()
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
        withLockedDevice { d in
            d.videoZoomFactor = on ? min(5, d.activeFormat.videoMaxZoomFactor) : 1
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

    private func withLockedDevice(_ body: @escaping (AVCaptureDevice) -> Void) {
        sessionQueue.async {
            guard let d = self.device else { return }
            do {
                try d.lockForConfiguration()
                body(d)
                d.unlockForConfiguration()
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
            let t = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains).temperature
            if t.isFinite { whiteBalanceKelvin = t }
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
    /// shutter speed is longer than the sensor allows.
    func takePicture(completion: @escaping (Bool) -> Void = { _ in }) {
        if magnifierOn { setMagnifier(false) }
        if isLongExposure {
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

    private func startStack(completion: @escaping (Bool) -> Void) {
        if lightningArmed { setLightning(false) }
        let mode = stackMode
        let sub = subExposure
        let frames = plannedFrames
        isStacking = true
        stackFrames = 0
        stackFrameTarget = frames
        stackSubExposure = sub

        frameProcessor.startStack(mode: mode, frames: frames, orientation: captureOrientation, progress: { [weak self] count in
            self?.stackFrames = count
        }, completion: { [weak self] data, count in
            guard let self else { return }
            self.isStacking = false
            self.stackFrameTarget = nil
            guard let data, count > 0 else {
                self.show("Long exposure failed")
                completion(false)
                return
            }
            let total = Stops.shutterLabel(Double(count) * sub)
            let description = mode == .longExposure ? "\(total) long exposure" : "\(total) \(mode.rawValue.lowercased()) stack"
            PhotoLibrary.save(primary: data, successMessage: "Saved \(description)") { ok, message in
                self.show(message)
                completion(ok)
            }
        })
    }

    /// Ends a Bulb exposure, or a timed one early, and saves what has been collected.
    func finishStack() {
        frameProcessor.finishStack()
    }

    private func capturePhoto(completion: @escaping (Bool) -> Void) {
        let format = self.format
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        isCapturing = true

        sessionQueue.async {
            let settings: AVCapturePhotoSettings
            let hevc = self.photoOutput.availablePhotoCodecTypes.contains(.hevc)
            if format.needsRAW, let raw = self.rawFormatType {
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
            // Single frame, no multi-frame fusion, so the exposure you set is the exposure you get.
            settings.photoQualityPrioritization = .speed
            if self.photoOutput.supportedFlashModes.contains(.off) { settings.flashMode = .off }

            if let angle, let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }

            let id = settings.uniqueID
            let processor = PhotoCaptureProcessor { success, message in
                self.sessionQueue.async { self.inFlight[id] = nil }
                DispatchQueue.main.async {
                    self.isCapturing = false
                    self.show(message)
                    completion(success)
                }
            }
            self.inFlight[id] = processor
            self.photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    // MARK: - Live view helpers

    func setPeaking(_ on: Bool, redMode: Bool) {
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview ?? 90
        frameProcessor.setPeaking(enabled: on, orientation: Stops.orientation(forRotationAngle: angle), redMode: redMode)
    }

    func setLightning(_ on: Bool) {
        lightningArmed = on
        if on { lightningCount = 0 }
        frameProcessor.setLightning(threshold: on ? lightningSensitivity.threshold : nil,
                                    orientation: captureOrientation) { [weak self] data in
            guard let self, let data else { return }
            PhotoLibrary.save(primary: data, successMessage: "⚡ Lightning saved") { ok, message in
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
