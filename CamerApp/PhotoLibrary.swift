import AVFoundation
import CoreLocation
import Photos

/// Handles one photo capture. Reports as soon as the shutter is done (so the next shot can start)
/// and again once the photo is saved.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let customizer: MetadataCustomizer
    private let location: CLLocation?
    private let deviceID: String?
    private let onCaptured: (Bool) -> Void
    private let onSaved: (Bool, String) -> Void
    private var processed: Data?
    private var raw: Data?

    init(gps: [String: Any]?, location: CLLocation?, deviceID: String?,
         onCaptured: @escaping (Bool) -> Void, onSaved: @escaping (Bool, String) -> Void) {
        self.customizer = MetadataCustomizer(gps: gps)
        self.location = location
        self.deviceID = deviceID
        self.onCaptured = onCaptured
        self.onSaved = onSaved
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(with: customizer) else { return }
        if photo.isRawPhoto {
            raw = data
        } else {
            processed = data
            if let deviceID { Metadata.rememberLens(from: photo.metadata, deviceID: deviceID) }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
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
