import AVFoundation
import CoreLocation
import Foundation
import ImageIO

/// What a lens reports in EXIF, e.g. "iPhone 16 Pro back triple camera 6.765mm f/1.78".
struct LensInfo {
    var model: String
    var focalLength: Double?
    var focalLength35mm: Int?
    var fNumber: Double
}

/// Camera settings at the moment a stacked or lightning shot started.
struct ShotInfo {
    let date: Date
    let iso: Float
    let frameExposure: Double
    let exposureProgram: Int
    let evBias: Float
    let manualWhiteBalance: Bool
    let lens: LensInfo
}

/// Builds EXIF / TIFF / GPS metadata so photos look like they came from the iPhone camera.
enum Metadata {
    static let software: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "CamerApp \(version)"
    }()

    /// Marketing name such as "iPhone 16 Pro". Learned from the first real photo; the table is a fallback.
    static var deviceModel: String {
        if let learned = UserDefaults.standard.string(forKey: "exif.model") { return learned }
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return modelNames[identifier] ?? "iPhone"
    }

    private static let modelNames: [String: String] = [
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max", "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,6": "iPhone SE (3rd generation)",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max", "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max", "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,5": "iPhone 16e", "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air",
    ]

    // MARK: - Lens

    /// Lens details for metadata. Exact values are learned from real photos taken with that lens;
    /// until then the 35 mm equivalent is worked out from the field of view.
    static func lensInfo(for device: AVCaptureDevice) -> LensInfo {
        let fNumber = Double(device.lensAperture)
        let fov = Double(device.activeFormat.videoFieldOfView)
        // 35 mm equivalent from the horizontal field of view of a 4:3 sensor (diagonal 43.27 mm).
        let computed35 = fov > 0 ? Int((17.31 / tan(fov * .pi / 360)).rounded()) : nil
        let side = device.position == .front ? "front" : "back"
        var info = LensInfo(model: "\(deviceModel) \(side) camera f/\(String(format: "%.2f", fNumber))",
                            focalLength: nil,
                            focalLength35mm: computed35,
                            fNumber: fNumber)
        if let learned = UserDefaults.standard.dictionary(forKey: "lens." + device.uniqueID) {
            if let model = learned["model"] as? String { info.model = model }
            if let focal = learned["focal"] as? Double { info.focalLength = focal }
            if let focal35 = learned["focal35"] as? Int { info.focalLength35mm = focal35 }
            if let f = learned["fNumber"] as? Double { info.fNumber = f }
        }
        return info
    }

    /// Remembers the exact lens details the system wrote into a real photo.
    static func rememberLens(from metadata: [String: Any], deviceID: String) {
        guard let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return }
        var entry: [String: Any] = [:]
        if let model = exif[kCGImagePropertyExifLensModel as String] as? String { entry["model"] = model }
        if let focal = exif[kCGImagePropertyExifFocalLength as String] as? Double { entry["focal"] = focal }
        if let focal35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int { entry["focal35"] = focal35 }
        if let f = exif[kCGImagePropertyExifFNumber as String] as? Double { entry["fNumber"] = f }
        if !entry.isEmpty { UserDefaults.standard.set(entry, forKey: "lens." + deviceID) }
        if let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let model = tiff[kCGImagePropertyTIFFModel as String] as? String {
            UserDefaults.standard.set(model, forKey: "exif.model")
        }
    }

    // MARK: - GPS

    static func gps(location: CLLocation, heading: CLHeading?) -> [String: Any] {
        var gps: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(location.coordinate.latitude),
            kCGImagePropertyGPSLatitudeRef as String: location.coordinate.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude as String: abs(location.coordinate.longitude),
            kCGImagePropertyGPSLongitudeRef as String: location.coordinate.longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSHPositioningError as String: location.horizontalAccuracy,
            kCGImagePropertyGPSDateStamp as String: gpsDateFormatter.string(from: location.timestamp),
            kCGImagePropertyGPSTimeStamp as String: gpsTimeFormatter.string(from: location.timestamp),
        ]
        if location.verticalAccuracy >= 0 {
            gps[kCGImagePropertyGPSAltitude as String] = abs(location.altitude)
            gps[kCGImagePropertyGPSAltitudeRef as String] = location.altitude < 0 ? 1 : 0
        }
        if location.speed >= 0 {
            gps[kCGImagePropertyGPSSpeed as String] = location.speed * 3.6
            gps[kCGImagePropertyGPSSpeedRef as String] = "K"
        }
        if let heading {
            let isTrue = heading.trueHeading >= 0
            let direction = isTrue ? heading.trueHeading : heading.magneticHeading
            gps[kCGImagePropertyGPSImgDirection as String] = direction
            gps[kCGImagePropertyGPSImgDirectionRef as String] = isTrue ? "T" : "M"
            gps[kCGImagePropertyGPSDestBearing as String] = direction
            gps[kCGImagePropertyGPSDestBearingRef as String] = isTrue ? "T" : "M"
        }
        return gps
    }

    // MARK: - Stacked images

    enum StackKind {
        case stack(StackMode)
        case lightning
    }

    /// Full EXIF/TIFF/GPS set for an image built from video frames.
    static func stackedImageProperties(shot: ShotInfo,
                                       kind: StackKind,
                                       frames: Int,
                                       width: Int,
                                       height: Int,
                                       orientation: CGImagePropertyOrientation,
                                       location: CLLocation?,
                                       heading: CLHeading?) -> [String: Any] {
        let total = Double(frames) * shot.frameExposure
        let frameLabel = Stops.shutterLabel(shot.frameExposure)
        let comment: String
        switch kind {
        case .stack(.longExposure): comment = "Long exposure stacked from \(frames) × \(frameLabel) frames"
        case .stack(.average): comment = "Average of \(frames) × \(frameLabel) frames"
        case .stack(.brightest), .stack(.rawFrames): comment = "Brightest pixels of \(frames) × \(frameLabel) frames"
        case .lightning: comment = "Lightning trigger: brightest pixels of \(frames) × \(frameLabel) frames"
        }

        let date = shot.date
        let dateString = exifDateFormatter.string(from: date)
        let offset = offsetString(for: date)
        let subsec = String(format: "%03d", Int((date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)) * 1000))

        var exif: [String: Any] = [
            kCGImagePropertyExifExposureTime as String: total,
            kCGImagePropertyExifShutterSpeedValue as String: -log2(total),
            kCGImagePropertyExifISOSpeedRatings as String: [Int(shot.iso.rounded())],
            kCGImagePropertyExifFNumber as String: shot.lens.fNumber,
            kCGImagePropertyExifApertureValue as String: 2 * log2(shot.lens.fNumber),
            kCGImagePropertyExifExposureProgram as String: shot.exposureProgram,
            kCGImagePropertyExifExposureMode as String: shot.exposureProgram == 1 ? 1 : 0,
            kCGImagePropertyExifExposureBiasValue as String: Double(shot.evBias),
            kCGImagePropertyExifWhiteBalance as String: shot.manualWhiteBalance ? 1 : 0,
            kCGImagePropertyExifMeteringMode as String: 5,
            kCGImagePropertyExifFlash as String: 16,
            kCGImagePropertyExifDateTimeOriginal as String: dateString,
            kCGImagePropertyExifDateTimeDigitized as String: dateString,
            kCGImagePropertyExifOffsetTime as String: offset,
            kCGImagePropertyExifOffsetTimeOriginal as String: offset,
            kCGImagePropertyExifOffsetTimeDigitized as String: offset,
            kCGImagePropertyExifSubsecTimeOriginal as String: subsec,
            kCGImagePropertyExifSubsecTimeDigitized as String: subsec,
            kCGImagePropertyExifLensMake as String: "Apple",
            kCGImagePropertyExifLensModel as String: shot.lens.model,
            kCGImagePropertyExifPixelXDimension as String: width,
            kCGImagePropertyExifPixelYDimension as String: height,
            kCGImagePropertyExifColorSpace as String: 1,
            kCGImagePropertyExifSensingMethod as String: 2,
            kCGImagePropertyExifSceneType as String: 1,
            kCGImagePropertyExifUserComment as String: comment,
        ]
        if let focal = shot.lens.focalLength { exif[kCGImagePropertyExifFocalLength as String] = focal }
        if let focal35 = shot.lens.focalLength35mm { exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] = focal35 }

        let tiff: [String: Any] = [
            kCGImagePropertyTIFFMake as String: "Apple",
            kCGImagePropertyTIFFModel as String: deviceModel,
            kCGImagePropertyTIFFSoftware as String: software,
            kCGImagePropertyTIFFDateTime as String: dateString,
            kCGImagePropertyTIFFImageDescription as String: comment,
        ]

        var properties: [String: Any] = [
            kCGImagePropertyOrientation as String: orientation.rawValue,
            kCGImagePropertyTIFFDictionary as String: tiff,
            kCGImagePropertyExifDictionary as String: exif,
            kCGImageDestinationLossyCompressionQuality as String: 0.92,
        ]
        if let location {
            properties[kCGImagePropertyGPSDictionary as String] = gps(location: location, heading: heading)
        }
        return properties
    }

    // MARK: - Dates

    private static func formatter(_ format: String, utc: Bool = false) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        if utc { formatter.timeZone = TimeZone(identifier: "UTC") }
        return formatter
    }

    private static let exifDateFormatter = formatter("yyyy:MM:dd HH:mm:ss")
    private static let gpsDateFormatter = formatter("yyyy:MM:dd", utc: true)
    private static let gpsTimeFormatter = formatter("HH:mm:ss.SS", utc: true)

    private static func offsetString(for date: Date) -> String {
        let seconds = TimeZone.current.secondsFromGMT(for: date)
        let minutes = abs(seconds) / 60
        return String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", minutes / 60, minutes % 60)
    }
}

/// Adds GPS to the metadata AVFoundation already writes (make, model, lens, exposure…).
final class MetadataCustomizer: NSObject, AVCapturePhotoFileDataRepresentationCustomizer {
    private let gps: [String: Any]?

    init(gps: [String: Any]?) {
        self.gps = gps
    }

    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        guard let gps else { return nil }
        var metadata = photo.metadata
        metadata[kCGImagePropertyGPSDictionary as String] = gps
        return metadata
    }
}

/// A value shared between threads.
final class Locked<Value> {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
