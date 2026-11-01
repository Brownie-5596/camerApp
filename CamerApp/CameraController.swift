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
    /// Plain RAW or ProRAW on its own (what the RAW frames mode can save).
    var isSingleRAW: Bool { self == .raw || self == .proRAW }
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
    private var overlaySettings = (peaking: false, clipping: false, redMode: false)
    private var statusTicks = 0
    private var rawStackRunning = false
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
    /// Focus position that makes stars sharp, saved per lens. (1.00 is past infinity on iPhones;
    /// stars are usually sharp somewhere around 0.75–0.85.)
    @Published var starFocus: Float?
    /// True while the app sweeps the focus looking for the sharpest stars.
    @Published var findingStarFocus = false
    @Published var focusSearchStatus: String?

    @Published var autoWhiteBalance = true
    @Published var whiteBalanceKelvin: Float = 4000

    // Format, photo size and long-exposure mode keep each other consistent: whatever you
    // changed last wins, and anything that no longer fits is adjusted with a message.
    @Published var format: OutputFormat = .heif {
        didSet {
            UserDefaults.standard.set(format.rawValue, forKey: "format")
            guard format != oldValue else { return }
            if !format.isSingleRAW && stackMode == .rawFrames {
                stackMode = .average
                show("\(format.rawValue): long exposures now blend (AVG). RAW frames needs RAW or ProRAW")
            } else if (format == .raw || format == .rawPlusHEIF) && effectiveMegapixels > 12 {
                preferredMegapixels = 12
                show("\(format.rawValue) is 12 MP. For 48 MP RAW use ProRAW")
            } else if format == .proRAW && !proRAWSizes.contains(effectiveMegapixels) {
                preferredMegapixels = proRAWSizes.last ?? 12
                show("ProRAW comes in \(proRAWSizes.map { "\($0)" }.joined(separator: " or ")) MP. Using \(preferredMegapixels) MP")
            }
        }
    }
    @Published var stackMode: StackMode = .longExposure {
        didSet {
            UserDefaults.standard.set(stackMode.rawValue, forKey: "stackMode")
            guard stackMode != oldValue else { return }
            updateHistogramGain()
            if stackMode == .rawFrames && !format.isSingleRAW {
                // Plain RAW: untouched sensor data, honours long exposures, and stacks best.
                format = rawSupported ? .raw : .proRAW
                show("RAW frames: each frame saved as \(outputMegapixels) MP \(format.rawValue)")
            }
        }
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
    /// Preferred photo size in megapixels. Lenses that can't do it use the nearest smaller size.
    @Published var preferredMegapixels = 12 {
        didSet {
            UserDefaults.standard.set(preferredMegapixels, forKey: "megapixels")
            guard preferredMegapixels != oldValue else { return }
            let size = effectiveMegapixels
            let proRAWSize = proRAWSupported && proRAWSizes.contains(size)
            if size > 12 && (format == .raw || format == .rawPlusHEIF) {
                // Plain RAW is 12 MP only: the latest choice (the size) wins.
                format = proRAWSize ? .proRAW : .heif
                show("\(size) MP RAW isn't possible. Switched to \(format.rawValue)")
            } else if format == .proRAW && !proRAWSizes.contains(size) {
                format = .heif
                show("\(size) MP is HEIF only (ProRAW is \(proRAWSizes.map { "\($0)" }.joined(separator: " or ")) MP). Switched to HEIF")
            }
        }
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
    /// Size of blended long exposures (built from the video frames).
    @Published var stackMegapixels = 12
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
    /// Photos whose exposure is done but that iOS is still processing.
    @Published var processingCount = 0
    private let lastCaptureTiming = Locked<String>("no photo taken yet")
    @Published var isStacking = false
    @Published var stackFrames = 0
    @Published var stackFrameTarget: Int?
    @Published var stackSubExposure: Double = 1
    @Published var timerRemaining: Int?
    @Published var lightningArmed = false
    @Published var lightningCount = 0
    @Published var lastMessage: String?
    @Published var histogram = HistogramReading()
    /// Focus peaking / clipping warning drawn over the preview.
    @Published var overlayImage: CGImage?
    /// Thumbnail of the last saved photo.
    @Published var lastThumbnail: CGImage?
    /// Battery and free space, shown when nothing else is happening.
    @Published var deviceStatus = ""
    @Published var aeafLocked = false
    /// Progress of an in-app RAW stack, e.g. "Stacking RAW 3/20…".
    @Published var rawStackStatus: String?

    /// How RAW frames are combined in the app after shooting (or Off to just save them).
    @Published var rawBlend: RawBlend = .average {
        didSet {
            UserDefaults.standard.set(rawBlend.rawValue, forKey: "rawBlend")
            updateHistogramGain()
        }
    }
    /// Line frames up again if the camera moves during a stack.
    @Published var alignFrames = false {
        didSet { UserDefaults.standard.set(alignFrames, forKey: "alignFrames") }
    }
    /// Save in-app RAW stacks as 16-bit TIFF (large, best for editing) instead of 10-bit HEIF.
    @Published var stackAsTIFF = false {
        didSet { UserDefaults.standard.set(stackAsTIFF, forKey: "stackAsTIFF") }
    }

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
        rawBlend = RawBlend(rawValue: defaults.string(forKey: "rawBlend") ?? "") ?? .average
        // Version 0.3.10 could shift frames when the camera hadn't moved; start again from off.
        if !defaults.bool(forKey: "alignFrames.reset") {
            defaults.set(true, forKey: "alignFrames.reset")
            defaults.set(false, forKey: "alignFrames")
        }
        alignFrames = defaults.bool(forKey: "alignFrames")
        stackAsTIFF = defaults.bool(forKey: "stackAsTIFF")
        frameProcessor.onHistogram = { [weak self] in self?.histogram = $0 }
        frameProcessor.onOverlay = { [weak self] in self?.overlayImage = $0 }
        PhotoLibrary.onSaved = { [weak self] data in
            DispatchQueue.global(qos: .utility).async {
                let thumbnail = PhotoLibrary.thumbnail(from: data)
                DispatchQueue.main.async { if let thumbnail { self?.lastThumbnail = thumbnail } }
            }
        }
        // Settings saved by an older version might not fit together; tidy them up.
        if format == .raw || format == .rawPlusHEIF { preferredMegapixels = min(preferredMegapixels, 12) }
        if stackMode == .rawFrames && !format.isSingleRAW { format = .proRAW }
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
        guard isLongExposure, addsLight, let frames = plannedFrames else { return 0 }
        return Float(log2(Double(frames)))
    }

    /// Long exposure mode (or RAW frames blended as a long exposure): frames are added together.
    private var addsLight: Bool {
        stackMode == .longExposure || (stackMode == .rawFrames && rawBlend == .longExposure)
    }

    /// Keeps the histogram showing the finished photo rather than one preview frame.
    private func updateHistogramGain() {
        frameProcessor.setHistogramGain(Float(pow(2, Double(stackGainEV))))
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
            var devices = discovery.devices.sorted {
                (order.firstIndex(of: $0.deviceType) ?? 0) < (order.firstIndex(of: $1.deviceType) ?? 0)
            }
            if let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
                devices.append(front)
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

            let lastLens = UserDefaults.standard.string(forKey: "lastLens")
            let mainCamera = devices.first { $0.deviceType == .builtInWideAngleCamera && $0.position == .back }
            if let initial = devices.first(where: { $0.uniqueID == lastLens }) ?? mainCamera ?? devices.first {
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
        let wide = devices.first { $0.deviceType == .builtInWideAngleCamera && $0.position == .back }
        let wideTan = wide.map { tan(Double($0.activeFormat.videoFieldOfView) * .pi / 360) }
        return devices.map { device in
            var name: String
            switch device.deviceType {
            case .builtInUltraWideCamera: name = "0.5×"
            case .builtInWideAngleCamera: name = "1×"
            case .builtInTelephotoCamera: name = "Tele"
            default: name = device.localizedName
            }
            if device.position == .front {
                return LensOption(id: device.uniqueID, name: "Front")
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
            "Zero shutter lag: supported \(photoOutput.isZeroShutterLagSupported), on \(photoOutput.isZeroShutterLagEnabled); "
                + "responsive capture: supported \(photoOutput.isResponsiveCaptureSupported), on \(photoOutput.isResponsiveCaptureEnabled)",
        ]
        if #available(iOS 18.0, *) {
            report.append("Camera Control: supported \(session.supportsControls), max controls \(session.maxControlsCount)")
        }
        // Stacks use the video frames, halved if they're bigger than 16 MP.
        let frameArea = Int(formatSize.width) * Int(formatSize.height)
        let stackMP = (frameArea > 16_000_000 ? frameArea / 4 : frameArea) / 1_000_000
        sessionReport.set(report.joined(separator: "\n"))

        DispatchQueue.main.async {
            self.uiDevice = newDevice
            self.lensInfo = Metadata.lensInfo(for: newDevice)
            self.starFocus = (UserDefaults.standard.object(forKey: "starFocus." + newDevice.uniqueID) as? NSNumber)?.floatValue
            self.currentLensID = newDevice.uniqueID
            UserDefaults.standard.set(newDevice.uniqueID, forKey: "lastLens")
            self.magnifierOn = false
            self.isoRange = isoRange
            self.isoStops = isoStops
            self.minDeviceExposure = minExposure
            self.maxDeviceExposure = maxExposure
            self.shutterStops = shutterStops
            self.availableMegapixels = megapixelChoices.isEmpty ? [12] : megapixelChoices
            self.stackMegapixels = max(stackMP, 1)
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

    func setAutoISO(_ on: Bool) { autoISO = on; if on { aeafLocked = false }; applyExposure() }

    /// AE/AF lock: freeze exposure and focus where they are now (or let them go back to auto).
    func toggleAEAFLock() {
        if aeafLocked {
            autoISO = true
            autoShutter = true
            bulb = false
            autoFocus = true
            aeafLocked = false
            show("AE/AF unlocked")
        } else {
            autoISO = false
            autoShutter = false
            bulb = false
            exposureSeconds = min(max(exposureSeconds, minDeviceExposure), maxDeviceExposure)
            autoFocus = false
            aeafLocked = true
            show("AE/AF locked")
        }
        applyExposure()
        applyFocus()
    }

    func setAutoShutter(_ on: Bool) {
        autoShutter = on
        if on { aeafLocked = false }
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

    func setAutoFocus(_ on: Bool) { autoFocus = on; if on { aeafLocked = false }; applyFocus() }
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
            if let position = preset.lensPosition {
                lensPosition = position
            } else if !autoFocus, let starFocus {
                // Night scenes use the star focus saved for this lens.
                lensPosition = starFocus
            }
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
        updateHistogramGain()
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
        statusTicks += 1
        if statusTicks % 40 == 1 { updateDeviceStatus() }
    }

    // MARK: - Shutter

    /// The shutter button, volume buttons and Camera Control all come here.
    func shutterPressed() {
        if findingStarFocus {
            show("Finding star focus. Tap STOP to cancel")
            return
        }
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

    /// Lets a couple of photos process in the background, but no more, so fast sequences
    /// don't run the phone out of memory.
    @MainActor
    func waitForProcessingRoom(limit: Int = 2) async {
        while processingCount >= limit {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func takePictureAsync() async -> Bool {
        await waitForProcessingRoom()
        return await withCheckedContinuation { continuation in
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
                                            focalLength35mm: nil, fNumber: 1.8),
                 settings: settingsSummary(format: format))
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

        let alignFieldOfView = alignFrames ? uiDevice.map { Double($0.activeFormat.videoFieldOfView) } : nil
        frameProcessor.startStack(mode: mode, frames: frames, alignFieldOfView: alignFieldOfView, metadata: { count, width, height in
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
        }, completion: { [weak self] data, count, aligned in
            guard let self else { return }
            guard let data, count > 0 else {
                self.show("Long exposure failed")
                return
            }
            let total = Stops.shutterLabel(Double(count) * sub)
            var description = mode == .longExposure ? "\(total) long exposure" : "\(total) \(mode.rawValue.lowercased()) stack"
            if aligned > 0 { description += " (\(aligned) frames re-aligned)" }
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
        let rawFormat = rawFramesFormat
        // Each frame is a big file, and blending in the app keeps a temporary copy too.
        let frameMB = Double(megapixels(for: rawFormat) > 13 ? 75 : (rawFormat == .proRAW ? 25 : 20))
        let neededGB = Double(frames ?? 60) * frameMB * (rawBlend == .off ? 1 : 2) / 1000 + 0.5
        if let freeGB = freeSpaceGB(), freeGB < neededGB {
            show(String(format: "Not enough storage: %.1f GB free, this needs about %.1f GB", freeGB, neededGB))
            completion(false)
            return
        }
        // Optionally blend the frames into one picture in the app as well.
        var session: RawStackSession?
        if let mode = rawBlend.stackMode {
            if rawStackRunning {
                show("Still stacking the last RAW set: frames will be saved without blending")
            } else {
                session = RawStackSession(mode: mode, align: alignFrames,
                                          fieldOfView: Double(uiDevice?.activeFormat.videoFieldOfView ?? 70))
            }
        }
        isStacking = true
        stackFrames = 0
        stackFrameTarget = frames
        stackSubExposure = subExposure
        rawFramesTask = Task { @MainActor in
            var taken = 0
            while !Task.isCancelled, frames == nil || taken < frames! {
                await self.waitForProcessingRoom()
                let index = taken
                var keepRAW: ((Data) -> Void)?
                if let session {
                    keepRAW = { data in session.store(data, index: index) }
                }
                let ok = await withCheckedContinuation { continuation in
                    self.capturePhoto(formatOverride: rawFormat, onRAWData: keepRAW) { continuation.resume(returning: $0) }
                }
                if !ok { break }
                session?.setAttitude(Motion.shared.attitude, index: index)
                taken += 1
                self.stackFrames = taken
            }
            self.isStacking = false
            self.stackFrameTarget = nil
            self.rawFramesTask = nil
            self.show("Saved \(taken) RAW frames")
            completion(taken > 0)
            if let session, taken > 0 {
                self.runRawStack(session, expected: taken)
            }
        }
    }

    /// Blends the collected RAW frames in the background and saves the result.
    private func runRawStack(_ session: RawStackSession, expected: Int) {
        rawStackRunning = true
        let fix = location.snapshot(enabled: saveLocation)
        session.run(expected: expected, tiff: stackAsTIFF, progress: { [weak self] text in
            self?.rawStackStatus = text
        }, completion: { [weak self] data, summary in
            guard let self else { return }
            self.rawStackRunning = false
            self.rawStackStatus = nil
            guard let data else {
                self.show("RAW stack failed: \(summary)")
                return
            }
            PhotoLibrary.save(primary: data, primaryType: self.stackAsTIFF ? "public.tiff" : nil,
                              location: fix.location, successMessage: "Saved: \(summary)") { _, message in
                self.show(message)
            }
        })
    }

    /// Stacks photos picked from the library. `load` fetches photo number i.
    func stackPhotos(count: Int, mode: StackMode, load: @escaping (Int) async -> Data?) {
        guard !rawStackRunning else {
            show("A stack is already being made")
            return
        }
        rawStackRunning = true
        rawStackStatus = "Loading photos…"
        let align = alignFrames
        let tiff = stackAsTIFF
        Task.detached(priority: .userInitiated) { [weak self] in
            let stacker = RawStacker(mode: mode, align: align, fieldOfView: nil, expectedFrames: count)
            for i in 0..<count {
                await MainActor.run { self?.rawStackStatus = "Stacking photo \(i + 1)/\(count)…" }
                guard let data = await load(i) else { continue }
                autoreleasepool { stacker.add(imageData: data, rotationSinceFirst: nil) }
            }
            await MainActor.run { self?.rawStackStatus = "Saving stacked image…" }
            let result = stacker.finish(tiff: tiff)
            await MainActor.run {
                guard let self else { return }
                self.rawStackRunning = false
                self.rawStackStatus = nil
                guard let data = result.data else {
                    self.show("Stack failed: \(result.summary)")
                    return
                }
                PhotoLibrary.save(primary: data, primaryType: tiff ? "public.tiff" : nil,
                                  successMessage: "Saved: \(result.summary)") { _, message in
                    self.show(message)
                }
            }
        }
    }

    private func freeSpaceGB() -> Double? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Double(free) / 1_000_000_000
    }

    private func updateDeviceStatus() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        var parts: [String] = []
        let battery = UIDevice.current.batteryLevel
        if battery >= 0 { parts.append("Battery \(Int((battery * 100).rounded()))%") }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            parts.append(String(format: "%.0f GB free", Double(free) / 1_000_000_000))
        }
        deviceStatus = parts.joined(separator: " · ")
    }

    private func capturePhoto(formatOverride: OutputFormat? = nil, onRAWData: ((Data) -> Void)? = nil,
                              completion: @escaping (Bool) -> Void) {
        let format = formatOverride ?? self.format
        let megapixels = self.megapixels(for: format)
        let highResolution = megapixels > 13
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        let fix = location.snapshot(enabled: saveLocation)
        let gps = fix.location.map { Metadata.gps(location: $0, heading: fix.heading) }
        let settingsNote = settingsSummary(format: format)
        let requestedExposure: Double? = autoShutter ? nil : subExposure
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
            // Main-thread bookkeeping: the camera counts as free once the exposure is over,
            // while iOS keeps processing the photo in the background.
            var released = false
            var counted = false
            let release: (Bool) -> Void = { success in
                guard !released else { return }
                released = true
                self.isCapturing = false
                completion(success)
            }
            let processor = PhotoCaptureProcessor(gps: gps, settings: settingsNote, location: fix.location, deviceID: deviceID, onRAWData: onRAWData, onExposureDone: {
                DispatchQueue.main.async {
                    counted = true
                    self.processingCount += 1
                    release(true)
                }
            }, onCaptured: { success in
                self.sessionQueue.async { self.inFlight[id] = nil }
                DispatchQueue.main.async {
                    if counted { self.processingCount -= 1 }
                    if let device = self.uiDevice { self.lensInfo = Metadata.lensInfo(for: device) }
                    release(success)
                }
            }, onSaved: { _, message in
                self.show(message)
            }, onTiming: { timing in
                self.lastCaptureTiming.set(timing)
            }, onActualExposure: { seconds, iso in
                // Tell the user when iOS didn't use the exposure they set.
                guard let requested = requestedExposure, seconds < requested / 2 else { return }
                DispatchQueue.main.async {
                    self.show("iOS changed this shot to \(Stops.shutterLabel(seconds)) at ISO \(iso) instead of \(Stops.shutterLabel(requested))")
                }
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

    func setOverlays(peaking: Bool, clipping: Bool, redMode: Bool) {
        overlaySettings = (peaking, clipping, redMode)
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview ?? 90
        frameProcessor.setOverlays(peaking: peaking, clipping: clipping,
                                   orientation: Stops.orientation(forRotationAngle: angle), redMode: redMode)
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        setOverlays(peaking: overlaySettings.peaking, clipping: overlaySettings.clipping, redMode: overlaySettings.redMode)
    }

    /// The size photos will actually be, given the preference and what this lens can do.
    var effectiveMegapixels: Int {
        availableMegapixels.filter { $0 <= preferredMegapixels }.max() ?? availableMegapixels.first ?? 12
    }

    /// Plain (Bayer) RAW is a 12 MP readout; ProRAW comes in 12 or 48 MP; HEIF in any size.
    func megapixels(for format: OutputFormat) -> Int {
        let smallest = availableMegapixels.first ?? 12
        // The full 48 MP readout only works for short exposures; iOS silently swaps longer ones
        // for 1/15 s at a huge ISO (black or ruined photos), so stay at 12 MP for those.
        if !exposureAllowsHighResolution { return smallest }
        switch format {
        case .raw, .rawPlusHEIF: return smallest
        case .proRAW: return effectiveMegapixels >= (proRAWSizes.last ?? smallest) ? (proRAWSizes.last ?? smallest) : smallest
        case .heif: return effectiveMegapixels
        }
    }

    /// Plain-English advice when the manual settings are well off what the meter wants,
    /// e.g. "Meter +6.6: too bright. Try ISO 100".
    /// ProRAW comes in the smallest and largest sizes only (12 or 48 MP), not 24.
    var proRAWSizes: [Int] {
        let sizes = [availableMegapixels.first ?? 12, availableMegapixels.last ?? 12]
        return sizes[0] == sizes[1] ? [sizes[0]] : sizes
    }

    /// Advice for the status line: exposure first, then focus.
    var shootingHint: String? {
        exposureHint ?? focusHint
    }

    /// Autofocus can't lock onto stars; in the dark it drifts to its closest setting and blurs everything.
    var focusHint: String? {
        let frameTime = autoShutter ? exposureSeconds : subExposure
        guard isLongExposure || frameTime >= 0.25 else { return nil }
        if autoFocus {
            if let starFocus {
                return String(format: "Night: tap ★ to use your star focus (%.2f)", starFocus)
            }
            return "Night: set focus to MF, focus on a bright star, then long-press ★ to save it"
        }
        if lensPosition > 0.95 && starFocus == nil {
            return "Focus 1.00 is past infinity on iPhone. Stars are usually sharp around 0.75–0.85"
        }
        return nil
    }

    /// Remembers the current focus as "star focus" for this lens.
    func saveStarFocus() {
        guard let id = currentLensID else { return }
        UserDefaults.standard.set(lensPosition, forKey: "starFocus." + id)
        starFocus = lensPosition
        show(String(format: "Star focus saved for this lens (%.2f)", lensPosition))
    }

    /// Switches to manual focus at the saved star focus.
    func useStarFocus() {
        guard let starFocus else {
            show("Focus on a bright star (magnifier + peaking), then long-press ★ to save it")
            return
        }
        setLensPosition(starFocus)
        show(String(format: "Star focus %.2f", starFocus))
    }

    /// Finds star focus automatically: sweeps the focus over the night sky with short, bright frames,
    /// measures how tightly the stars are focused at each step, then sets and saves the sharpest.
    /// Needs a tripod and some bright stars near the middle of the picture. Takes about 20–30 s.
    func findStarFocus() {
        guard !findingStarFocus, !isStacking else { return }
        findingStarFocus = true
        let before = (autoISO: autoISO, autoShutter: autoShutter, bulb: bulb, iso: iso,
                      exposure: exposureSeconds, autoFocus: autoFocus, focus: lensPosition)

        // Short frames at high ISO, so each focus step only takes a fraction of a second.
        autoISO = false
        autoShutter = false
        bulb = false
        iso = min(isoRange.upperBound, 6400)
        exposureSeconds = max(minDeviceExposure, min(0.25, maxDeviceExposure))
        autoFocus = false
        applyExposure()

        Task { @MainActor in
            let coarse = stride(from: 0.55, through: 1.0, by: 0.025).map { Float($0) }
            var samples: [(position: Float, score: Double)] = []
            var step = 0
            let totalSteps = coarse.count + 11

            func measure(_ position: Float) async -> Double {
                step += 1
                self.focusSearchStatus = "Finding star focus \(step)/\(totalSteps)…"
                self.lensPosition = position
                self.withLockedDevice { d in
                    if d.isLockingFocusWithCustomLensPositionSupported {
                        d.setFocusModeLocked(lensPosition: position, completionHandler: nil)
                    }
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
                // Skip one frame that may have been exposed while the lens was moving.
                return await self.frameProcessor.sharpness(skipFrames: 1)
            }

            for position in coarse where self.findingStarFocus {
                samples.append((position, await measure(position)))
            }
            if let roughBest = Self.bestFocus(samples) {
                let fine = stride(from: -0.03, through: 0.0301, by: 0.006).map { roughBest + Float($0) }
                for position in fine where self.findingStarFocus && position >= 0 && position <= 1 {
                    samples.append((position, await measure(position)))
                }
            }

            let cancelled = !self.findingStarFocus
            self.findingStarFocus = false
            self.focusSearchStatus = nil
            self.autoISO = before.autoISO
            self.autoShutter = before.autoShutter
            self.bulb = before.bulb
            self.iso = before.iso
            self.exposureSeconds = before.exposure
            self.applyExposure()

            if !cancelled, let best = Self.bestFocus(samples) {
                self.autoFocus = false
                self.lensPosition = best
                self.applyFocus()
                if let id = self.currentLensID {
                    UserDefaults.standard.set(best, forKey: "starFocus." + id)
                }
                self.starFocus = best
                self.show(String(format: "Star focus found and saved: %.2f", best))
            } else {
                self.autoFocus = before.autoFocus
                self.lensPosition = before.focus
                self.applyFocus()
                self.show(cancelled ? "Star focus search stopped"
                                    : "Couldn't find sharp stars. Aim at clear sky with bright stars in the middle and try again")
            }
        }
    }

    func cancelStarFocusSearch() {
        findingStarFocus = false
    }

    /// The focus position with the sharpest stars, or nil if the measurements show no clear peak
    /// (no stars visible, clouds, or too bright).
    private static func bestFocus(_ samples: [(position: Float, score: Double)]) -> Float? {
        guard let best = samples.max(by: { $0.score < $1.score }), best.score > 0 else { return nil }
        let scores = samples.map(\.score).sorted()
        let typical = scores[scores.count / 2]
        guard best.score > typical * 1.2 else { return nil }
        // Several steps can tie when bright stars saturate; take the middle of the best ones near the peak.
        let near = samples.filter { $0.score >= best.score * 0.97 && abs($0.position - best.position) <= 0.05 }
        return near.map(\.position).reduce(0, +) / Float(near.count)
    }

    var exposureHint: String? {
        guard !fullAuto, meterEV.isFinite, abs(meterEV) > 1.5 else { return nil }
        let reading = "Meter \(Stops.evLabel(meterEV)): \(meterEV > 0 ? "too bright" : "too dark")"
        guard !autoISO else {
            return "\(reading). Use a \(meterEV > 0 ? "shorter" : "longer") shutter"
        }
        let wanted = iso * powf(2, -meterEV)
        if wanted < isoRange.lowerBound * 0.9 {
            return "\(reading) even at ISO \(Stops.whole(isoRange.lowerBound)). Use a shorter shutter"
        }
        if wanted > isoRange.upperBound * 1.1 {
            return "\(reading) even at ISO \(Stops.whole(isoRange.upperBound)). Use a longer shutter"
        }
        let suggestion = isoStops[Stops.nearestIndex(of: wanted, in: isoStops)]
        return "\(reading). Try ISO \(Stops.whole(suggestion)) (or Auto)"
    }

    /// iOS reads out the whole 48 MP sensor only at about 1/15 s or faster. (Apple's own Night mode
    /// photos are 12 MP for the same reason.)
    static let maxHighResolutionExposure = 1.0 / 15

    var exposureAllowsHighResolution: Bool {
        if autoShutter { return true }
        return !isLongExposure && exposureSeconds <= Self.maxHighResolutionExposure * 1.05
    }

    /// Size of the next normal photo.
    var outputMegapixels: Int { megapixels(for: format) }

    /// Format each frame is saved in by the RAW frames long-exposure mode.
    var rawFramesFormat: OutputFormat {
        format.isSingleRAW ? format : (rawSupported ? .raw : .proRAW)
    }

    /// What a long exposure will produce, e.g. "12MP HEIF" or "48MP ProRAW frames".
    var longExposureOutput: String {
        if stackMode == .rawFrames {
            let frames = "\(megapixels(for: rawFramesFormat))MP \(rawFramesFormat.rawValue)"
            return rawBlend == .off ? "\(frames) frames" : "\(frames) + \(rawBlend.shortName.replacingOccurrences(of: "RAW+", with: "")) stack"
        }
        return "\(stackMegapixels)MP HEIF"
    }

    private func cameraControlsReport() -> String {
        if #available(iOS 18.0, *) {
            let names = session.controls.compactMap { control -> String? in
                if let slider = control as? AVCaptureSlider { return slider.localizedTitle }
                if let picker = control as? AVCaptureIndexPicker { return picker.localizedTitle }
                return nil
            }
            return "Camera Control installed (\(names.count)): \(names.joined(separator: ", "))"
        }
        return "Camera Control: needs iOS 18"
    }

    /// The app's settings in one line; stored in every photo (EXIF user comment) so they can be checked later.
    func settingsSummary(format: OutputFormat) -> String {
        let lens = lenses.first { $0.id == currentLensID }?.name ?? "?"
        var parts = [
            Metadata.software,
            "\(format.rawValue) \(megapixels(for: format))MP",
            "lens \(lens), zoom \(String(format: "%.1f", zoomFactor))×",
            "ISO \(Int(iso.rounded())) \(autoISO ? "auto" : "manual")",
            "shutter \(bulb ? "BULB" : Stops.shutterLabel(exposureSeconds)) \(autoShutter ? "auto" : "manual")",
            "EV \(Stops.evLabel(evBias))",
            autoFocus ? "AF" : "MF \(String(format: "%.2f", lensPosition))",
            autoWhiteBalance ? "AWB" : "WB \(Int(whiteBalanceKelvin.rounded()))K",
        ]
        if isLongExposure {
            let mode = stackMode == .rawFrames ? "RAW frames + \(rawBlend.rawValue)" : stackMode.rawValue
            let frames = plannedFrames.map { "\($0)" } ?? "BULB"
            parts.append("long exposure \(mode), \(frames) × \(Stops.shutterLabel(subExposure))")
            parts.append("align \(alignFrames ? "on" : "off")")
        }
        return parts.joined(separator: " · ")
    }

    /// Everything useful for diagnosing problems remotely, to paste into a chat.
    func cameraReport() -> String {
        var lines = [
            "\(Metadata.software) on \(Metadata.deviceModel), iOS \(UIDevice.current.systemVersion)",
            sessionReport.get(),
            cameraControlsReport(),
            "Video frames (used for stacks): \(frameProcessor.frameSize.get())",
            "Last photo timing: \(lastCaptureTiming.get())",
            "Format \(format.rawValue), photo size \(outputMegapixels) MP (preferred \(preferredMegapixels)), stack mode \(stackMode.rawValue) → \(longExposureOutput)",
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
