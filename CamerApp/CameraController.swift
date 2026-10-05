import AVFoundation
import Combine
import Photos
import UIKit

enum OutputFormat: String, CaseIterable, Identifiable {
    case raw = "RAW"
    case heif = "HEIF"
    var id: String { rawValue }
}

struct LensOption: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Owns the capture session and applies manual settings to the active camera.
/// Published properties are only touched on the main thread; device work runs on `sessionQueue`.
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()

    private let sessionQueue = DispatchQueue(label: "camerapp.session")
    private let photoOutput = AVCapturePhotoOutput()

    // Session-queue state
    private var device: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var devicesByID: [String: AVCaptureDevice] = [:]
    private var rawFormatType: OSType?
    private var inFlight: [Int64: PhotoCaptureProcessor] = [:]

    // Main-thread state
    private var uiDevice: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var readoutTimer: Timer?
    private var started = false

    @Published var permissionDenied = false
    @Published var lenses: [LensOption] = []
    @Published var currentLensID: String?

    @Published var autoExposure = true
    @Published var iso: Float = 100
    @Published var isoRange: ClosedRange<Float> = 25...3200
    @Published var exposureSeconds: Double = 1.0 / 60
    @Published var exposureRange: ClosedRange<Double> = (1.0 / 8000)...1

    @Published var autoFocus = true
    @Published var lensPosition: Float = 1

    @Published var autoWhiteBalance = true
    @Published var whiteBalanceKelvin: Float = 4000

    @Published var format: OutputFormat = .heif
    @Published var rawSupported = false
    @Published var isCapturing = false
    @Published var lastMessage: String?

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
        readoutTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.refreshReadouts()
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
        guard id != currentLensID else { return }
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
        session.commitConfiguration()
        guard device === newDevice else { return }

        photoOutput.maxPhotoQualityPrioritization = .quality
        // Bayer RAW (plain DNG), not Apple ProRAW.
        rawFormatType = photoOutput.availableRawPhotoPixelFormatTypes.first { !AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
        let hasRAW = rawFormatType != nil
        let fmt = newDevice.activeFormat
        let isoRange = fmt.minISO...fmt.maxISO
        let expRange = fmt.minExposureDuration.seconds...fmt.maxExposureDuration.seconds

        DispatchQueue.main.async {
            self.uiDevice = newDevice
            self.currentLensID = newDevice.uniqueID
            self.isoRange = isoRange
            self.exposureRange = expRange
            self.iso = min(max(self.iso, isoRange.lowerBound), isoRange.upperBound)
            self.exposureSeconds = min(max(self.exposureSeconds, expRange.lowerBound), expRange.upperBound)
            self.rawSupported = hasRAW
            if !hasRAW && self.format == .raw { self.format = .heif }

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

    func setAutoExposure(_ on: Bool) { autoExposure = on; applyExposure() }
    func setISO(_ value: Float) { iso = value; autoExposure = false; applyExposure() }
    func setExposure(_ seconds: Double) { exposureSeconds = seconds; autoExposure = false; applyExposure() }

    func setAutoFocus(_ on: Bool) { autoFocus = on; applyFocus() }
    func setLensPosition(_ value: Float) { lensPosition = value; autoFocus = false; applyFocus() }

    func setAutoWhiteBalance(_ on: Bool) { autoWhiteBalance = on; applyWhiteBalance() }
    func setWhiteBalance(_ kelvin: Float) { whiteBalanceKelvin = kelvin; autoWhiteBalance = false; applyWhiteBalance() }

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
        let auto = autoExposure, iso = self.iso, seconds = exposureSeconds
        withLockedDevice { d in
            if auto {
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            } else if d.isExposureModeSupported(.custom) {
                let f = d.activeFormat
                let clampedISO = min(max(iso, f.minISO), f.maxISO)
                let clampedSeconds = min(max(seconds, f.minExposureDuration.seconds), f.maxExposureDuration.seconds)
                d.setExposureModeCustom(duration: CMTime(seconds: clampedSeconds, preferredTimescale: 1_000_000),
                                        iso: clampedISO,
                                        completionHandler: nil)
            }
        }
    }

    private func applyFocus() {
        let auto = autoFocus, position = lensPosition
        withLockedDevice { d in
            if auto {
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            } else if d.isLockingFocusWithCustomLensPositionSupported {
                d.setFocusModeLocked(lensPosition: min(max(position, 0), 1), completionHandler: nil)
            }
        }
    }

    private func applyWhiteBalance() {
        let auto = autoWhiteBalance, kelvin = whiteBalanceKelvin
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

    /// While a setting is on auto, show what the camera picked so switching to manual starts from there.
    private func refreshReadouts() {
        guard let d = uiDevice else { return }
        if autoExposure {
            iso = d.iso
            let s = d.exposureDuration.seconds
            if s.isFinite && s > 0 { exposureSeconds = s }
        }
        if autoFocus { lensPosition = d.lensPosition }
        if autoWhiteBalance {
            let t = d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains).temperature
            if t.isFinite { whiteBalanceKelvin = t }
        }
    }

    // MARK: - Capture

    func capture(completion: @escaping (Bool) -> Void = { _ in }) {
        let wantRAW = format == .raw
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        isCapturing = true

        sessionQueue.async {
            let settings: AVCapturePhotoSettings
            var isRAW = false
            if wantRAW, let raw = self.rawFormatType {
                settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
                isRAW = true
            } else if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
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
            let processor = PhotoCaptureProcessor(isRAW: isRAW) { success, message in
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

    func captureAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.capture { continuation.resume(returning: $0) }
            }
        }
    }

    private func show(_ message: String) {
        lastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if self.lastMessage == message { self.lastMessage = nil }
        }
    }
}

final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let isRAW: Bool
    private let completion: (Bool, String) -> Void
    private var data: Data?

    init(isRAW: Bool, completion: @escaping (Bool, String) -> Void) {
        self.isRAW = isRAW
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if error == nil { data = photo.fileDataRepresentation() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error {
            completion(false, "Capture failed: \(error.localizedDescription)")
            return
        }
        guard let data else {
            completion(false, "Capture failed: no image data")
            return
        }
        PhotoLibrary.save(data, isRAW: isRAW, completion: completion)
    }
}

enum PhotoLibrary {
    static func save(_ data: Data, isRAW: Bool, completion: @escaping (Bool, String) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(false, "Allow Photos access in Settings to save")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                if isRAW { options.uniformTypeIdentifier = AVFileType.dng.rawValue }
                request.addResource(with: .photo, data: data, options: options)
            }) { success, error in
                if success {
                    completion(true, isRAW ? "Saved RAW" : "Saved HEIF")
                } else {
                    completion(false, "Save failed: \(error?.localizedDescription ?? "unknown error")")
                }
            }
        }
    }
}
