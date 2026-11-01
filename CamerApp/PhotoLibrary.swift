import AVFoundation
import CoreLocation
import ImageIO
import Photos

/// Handles one photo capture. Reports when the exposure ends (so the next shot can start
/// while this one is still being processed), when processing ends, and once it's saved.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let customizer: MetadataCustomizer
    private let location: CLLocation?
    private let deviceID: String?
    private let onRAWData: ((Data) -> Void)?
    private let onExposureDone: () -> Void
    private let onCaptured: (Bool) -> Void
    private let onSaved: (Bool, String) -> Void
    private let onTiming: (String) -> Void
    private let onActualExposure: ((Double, Int) -> Void)?
    private var processed: Data?
    private var raw: Data?

    // Timing, to see where the time between pressing and saving goes.
    private let requested = CACurrentMediaTime()
    private var exposureStarted: CFTimeInterval?
    private var exposureEnded: CFTimeInterval?
    private var processingEnded: CFTimeInterval?
    private var expectedProcessing: Double?

    init(gps: [String: Any]?, settings: String?, location: CLLocation?, deviceID: String?,
         onRAWData: ((Data) -> Void)? = nil,
         onExposureDone: @escaping () -> Void,
         onCaptured: @escaping (Bool) -> Void,
         onSaved: @escaping (Bool, String) -> Void,
         onTiming: @escaping (String) -> Void,
         onActualExposure: ((Double, Int) -> Void)? = nil) {
        self.customizer = MetadataCustomizer(gps: gps, settings: settings)
        self.location = location
        self.deviceID = deviceID
        self.onRAWData = onRAWData
        self.onExposureDone = onExposureDone
        self.onCaptured = onCaptured
        self.onSaved = onSaved
        self.onTiming = onTiming
        self.onActualExposure = onActualExposure
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
        if let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let seconds = exif[kCGImagePropertyExifExposureTime as String] as? Double {
            let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first ?? 0
            onActualExposure?(seconds, iso)
        }
        if photo.isRawPhoto {
            raw = data
            onRAWData?(data)
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
    /// Called (on any thread) with the main file of every photo saved successfully.
    static var onSaved: ((Data) -> Void)?

    /// A small preview image, using the embedded preview where there is one (RAW files).
    static func thumbnail(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 200,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Saves one photo, optionally with a RAW file attached (shown as RAW+HEIF in Photos).
    /// `completion` runs on the main thread.
    static func save(primary: Data,
                     primaryType: String? = nil,
                     raw: Data? = nil,
                     location: CLLocation? = nil,
                     successMessage: String,
                     attempt: Int = 1,
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
                    onSaved?(primary)
                    finish(true, successMessage)
                } else if attempt < 3, !isPermanent(error) {
                    // Saving can be interrupted while Photos is busy (e.g. with a burst of big RAW
                    // files); try again shortly.
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5 * Double(attempt)) {
                        save(primary: primary, primaryType: primaryType, raw: raw, location: location,
                             successMessage: successMessage, attempt: attempt + 1, completion: completion)
                    }
                } else {
                    finish(false, "Save failed: \(describe(error))")
                }
            }
        }
    }

    private static func isPermanent(_ error: Error?) -> Bool {
        guard let error = error as NSError?, error.domain == PHPhotosErrorDomain else { return false }
        return [3305, 3310, 3311].contains(error.code)
    }

    /// Plain-English versions of the Photos errors people actually hit.
    private static func describe(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "unknown error" }
        if error.domain == PHPhotosErrorDomain {
            switch error.code {
            case 3305: return "not enough storage on the iPhone. Free up space and try again"
            case 3301: return "Photos was interrupted (often low storage or too many large files at once)"
            case 3310, 3311: return "the app isn't allowed to add photos. Check Settings → Privacy → Photos"
            case 3302, 3303: return "the image file was invalid (code \(error.code))"
            default: break
            }
        }
        return "\(error.localizedDescription) (code \(error.code))"
    }
}
