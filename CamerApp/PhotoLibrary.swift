import AVFoundation
import CoreLocation
import Photos

/// Handles one photo capture. Reports when the exposure ends (so the next shot can start
/// while this one is still being processed), when processing ends, and once it's saved.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let customizer: MetadataCustomizer
    private let location: CLLocation?
    private let deviceID: String?
    private let onExposureDone: () -> Void
    private let onCaptured: (Bool) -> Void
    private let onSaved: (Bool, String) -> Void
    private let onTiming: (String) -> Void
    private var processed: Data?
    private var raw: Data?

    // Timing, to see where the time between pressing and saving goes.
    private let requested = CACurrentMediaTime()
    private var exposureStarted: CFTimeInterval?
    private var exposureEnded: CFTimeInterval?
    private var processingEnded: CFTimeInterval?
    private var expectedProcessing: Double?

    init(gps: [String: Any]?, location: CLLocation?, deviceID: String?,
         onExposureDone: @escaping () -> Void,
         onCaptured: @escaping (Bool) -> Void,
         onSaved: @escaping (Bool, String) -> Void,
         onTiming: @escaping (String) -> Void) {
        self.customizer = MetadataCustomizer(gps: gps)
        self.location = location
        self.deviceID = deviceID
        self.onExposureDone = onExposureDone
        self.onCaptured = onCaptured
        self.onSaved = onSaved
        self.onTiming = onTiming
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        if #available(iOS 17.0, *) {
            let range = resolvedSettings.photoProcessingTimeRange
            if range.duration.isValid { expectedProcessing = range.end.seconds }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        exposureStarted = CACurrentMediaTime()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        exposureEnded = CACurrentMediaTime()
        onExposureDone()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        processingEnded = CACurrentMediaTime()
        guard error == nil, let data = photo.fileDataRepresentation(with: customizer) else { return }
        if photo.isRawPhoto {
            raw = data
        } else {
            processed = data
            if let deviceID { Metadata.rememberLens(from: photo.metadata, deviceID: deviceID) }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        reportTiming(size: resolvedSettings.photoDimensions)
        if let error {
            onCaptured(false)
            onSaved(false, "Capture failed: \(error.localizedDescription)")
            return
        }
        switch (raw, processed) {
        case let (raw?, processed?):
            onCaptured(true)
            PhotoLibrary.save(primary: processed, raw: raw, location: location, successMessage: "Saved RAW+HEIF", completion: onSaved)
        case let (raw?, nil):
            onCaptured(true)
            PhotoLibrary.save(primary: raw, primaryType: AVFileType.dng.rawValue, location: location,
                              successMessage: "Saved RAW", completion: onSaved)
        case let (nil, processed?):
            onCaptured(true)
            PhotoLibrary.save(primary: processed, location: location, successMessage: "Saved HEIF", completion: onSaved)
        default:
            onCaptured(false)
            onSaved(false, "Capture failed: no image data")
        }
    }

    private func reportTiming(size: CMVideoDimensions) {
        let end = CACurrentMediaTime()
        func seconds(_ from: CFTimeInterval?, _ to: CFTimeInterval?) -> String {
            guard let from, let to else { return "?" }
            return String(format: "%.2fs", to - from)
        }
        var text = "waiting for frame \(seconds(requested, exposureStarted)), "
            + "exposing \(seconds(exposureStarted, exposureEnded)), "
            + "processing \(seconds(exposureEnded, processingEnded ?? end)), "
            + "total \(seconds(requested, end)) for \(size.width)×\(size.height)"
        if let expectedProcessing { text += String(format: " (iOS expected processing up to %.2fs)", expectedProcessing) }
        onTiming(text)
    }
}

enum PhotoLibrary {
    /// Saves one photo, optionally with a RAW file attached (shown as RAW+HEIF in Photos).
    /// `completion` runs on the main thread.
    static func save(primary: Data,
                     primaryType: String? = nil,
                     raw: Data? = nil,
                     location: CLLocation? = nil,
                     successMessage: String,
                     completion: @escaping (Bool, String) -> Void) {
        let finish: (Bool, String) -> Void = { ok, message in
            DispatchQueue.main.async { completion(ok, message) }
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                finish(false, "Allow Photos access in Settings to save")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                if let location { request.location = location }
                let options = PHAssetResourceCreationOptions()
                if let primaryType { options.uniformTypeIdentifier = primaryType }
                request.addResource(with: .photo, data: primary, options: options)
                if let raw {
                    let rawOptions = PHAssetResourceCreationOptions()
                    rawOptions.uniformTypeIdentifier = AVFileType.dng.rawValue
                    request.addResource(with: .alternatePhoto, data: raw, options: rawOptions)
                }
            }) { success, error in
                if success {
                    finish(true, successMessage)
                } else {
                    finish(false, "Save failed: \(error?.localizedDescription ?? "unknown error")")
                }
            }
        }
    }
}
