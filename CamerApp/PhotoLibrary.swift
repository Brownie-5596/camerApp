import AVFoundation
import Photos

final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Bool, String) -> Void
    private var processed: Data?
    private var raw: Data?

    init(completion: @escaping (Bool, String) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto { raw = data } else { processed = data }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error {
            completion(false, "Capture failed: \(error.localizedDescription)")
            return
        }
        switch (raw, processed) {
        case let (raw?, processed?):
            PhotoLibrary.save(primary: processed, raw: raw, successMessage: "Saved RAW+HEIF", completion: completion)
        case let (raw?, nil):
            PhotoLibrary.save(primary: raw, primaryType: AVFileType.dng.rawValue, successMessage: "Saved RAW", completion: completion)
        case let (nil, processed?):
            PhotoLibrary.save(primary: processed, successMessage: "Saved HEIF", completion: completion)
        default:
            completion(false, "Capture failed: no image data")
        }
    }
}

enum PhotoLibrary {
    /// Saves one photo, optionally with a RAW file attached (shown as RAW+HEIF in Photos).
    /// `completion` runs on the main thread.
    static func save(primary: Data,
                     primaryType: String? = nil,
                     raw: Data? = nil,
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
