import CoreImage
import CoreMotion
import Foundation
import ImageIO

/// How RAW frames are combined inside the app.
enum RawBlend: String, CaseIterable, Identifiable {
    case off = "Off"
    case average = "Average"
    case longExposure = "Long exposure"
    case brightest = "Brightest"

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .off: return "RAW"
        case .average: return "RAW+AVG"
        case .longExposure: return "RAW+LONG"
        case .brightest: return "RAW+MAX"
        }
    }

    var stackMode: StackMode? {
        switch self {
        case .off: return nil
        case .average: return .average
        case .longExposure: return .longExposure
        case .brightest: return .brightest
        }
    }
}

/// Stacks full-resolution photos (48 MP ProRAW, or any photo from the library) into one image.
///
/// Each frame is developed with Core Image, lined up with the first one if the camera moved,
/// and blended in linear light. The result keeps the first frame's metadata (camera, lens, GPS)
/// with the total exposure time.
final class RawStacker {
    let mode: StackMode
    let align: Bool
    /// Horizontal field of view in degrees, to turn a gyroscope angle into pixels. nil if unknown.
    let fieldOfView: Double?

    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private var accumulator: UnsafeMutablePointer<Float16>?
    private var frame: UnsafeMutablePointer<Float16>?
    private var reference: [GrayImage]?
    private var properties: [String: Any] = [:]

    private(set) var width = 0
    private(set) var height = 0
    private(set) var count = 0
    private(set) var aligned = 0
    private(set) var skipped = 0
    private var totalExposure = 0.0
    private var sourceDescription = "photos"

    init(mode: StackMode, align: Bool, fieldOfView: Double?) {
        self.mode = mode
        self.align = align
        self.fieldOfView = fieldOfView
    }

    deinit {
        accumulator?.deallocate()
        frame?.deallocate()
    }

    /// Adds one photo. `rotationSinceFirst` is how far the gyroscope says the phone turned since the
    /// first frame (radians); nil means unknown, so the pictures are always compared.
    func add(imageData: Data, rotationSinceFirst: Double?) {
        guard var image = Self.develop(imageData) else {
            skipped += 1
            return
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let w = Int(image.extent.width.rounded())
        let h = Int(image.extent.height.rounded())

        if accumulator == nil {
            width = w
            height = h
            let size = w * h * 4
            accumulator = .allocate(capacity: size)
            accumulator!.initialize(repeating: 0, count: size)
            frame = .allocate(capacity: size)
            properties = Self.readProperties(imageData)
            sourceDescription = Self.describeSource(imageData, width: w, height: h)
        }
        guard let acc = accumulator, let frame, w == width, h == height else {
            skipped += 1
            return
        }

        context.render(image, toBitmap: frame, rowBytes: w * 8,
                       bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAh, colorSpace: linear)
        if let exif = Self.readProperties(imageData)[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let exposure = exif[kCGImagePropertyExifExposureTime as String] as? Double {
            totalExposure += exposure
        }

        var shift = (dx: 0, dy: 0)
        if align {
            let pyramid = Alignment.pyramid(fromLinear: frame, width: w, height: h)
            if let reference {
                var worthChecking = true
                if let angle = rotationSinceFirst, let fieldOfView {
                    let pixelsPerRadian = Double(w) / 2 / tan(fieldOfView * .pi / 360)
                    worthChecking = angle * pixelsPerRadian > 1.5
                }
                if worthChecking, let finest = reference.last {
                    let s = Alignment.shift(reference: reference, moving: pyramid)
                    let scale = Double(w) / Double(finest.width)
                    shift = (Int((s.dx * scale).rounded()), Int((s.dy * scale).rounded()))
                    if shift.dx != 0 || shift.dy != 0 { aligned += 1 }
                }
            } else {
                reference = pyramid
            }
        }

        accumulate(into: acc, from: frame, shift: shift)
        count += 1
    }

    /// Running average (sum is the average × frames at the end) or per-pixel maximum, in linear light.
    private func accumulate(into acc: UnsafeMutablePointer<Float16>, from frame: UnsafeMutablePointer<Float16>,
                            shift: (dx: Int, dy: Int)) {
        let rowLength = width * 4
        let weight = 1 / Float(count + 1)
        let brightest = mode == .brightest
        for y in 0..<height {
            let sy = min(max(y + shift.dy, 0), height - 1)
            let src = frame + sy * rowLength
            let dst = acc + y * rowLength
            for x in 0..<width {
                let s = src + 4 * min(max(x + shift.dx, 0), width - 1)
                let d = dst + 4 * x
                for c in 0..<3 {
                    let v = Float(s[c])
                    if brightest {
                        if v > Float(d[c]) { d[c] = Float16(v) }
                    } else {
                        let a = Float(d[c])
                        d[c] = Float16(a + (v - a) * weight)
                    }
                }
                d[3] = 1
            }
        }
    }

    /// Encodes the result as 10-bit HEIF, or 16-bit TIFF for editing. Returns the data and a short description.
    func finish(tiff: Bool) -> (data: Data?, summary: String) {
        guard let acc = accumulator, count > 0 else {
            return (nil, "No frames could be read")
        }
        frame?.deallocate()
        frame = nil

        let bytes = Data(bytesNoCopy: acc, count: width * height * 8, deallocator: .none)
        var image = CIImage(bitmapData: bytes, bytesPerRow: width * 8,
                            size: CGSize(width: width, height: height), format: .RGBAh, colorSpace: linear)
        if mode == .longExposure && count > 1 {
            let gain = CGFloat(count)
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }

        let blendName: String
        switch mode {
        case .longExposure: blendName = "Long exposure"
        case .brightest: blendName = "Brightest pixels"
        default: blendName = "Average"
        }
        var summary = "\(blendName) of \(count) × \(sourceDescription)"
        if aligned > 0 { summary += ", \(aligned) re-aligned" }
        if skipped > 0 { summary += ", \(skipped) skipped" }
        image = image.settingProperties(outputProperties(comment: "Stacked in \(Metadata.software): \(summary)"))

        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let data: Data?
        if tiff {
            data = context.tiffRepresentation(of: image, format: .RGBA16, colorSpace: p3, options: [:])
        } else {
            let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            data = try? context.heif10Representation(of: image, colorSpace: p3, options: [quality: 0.92])
        }
        return (data, summary)
    }

    // MARK: - Helpers

    /// Develops a RAW (DNG/ProRAW) with noise reduction off (stacking removes the noise instead),
    /// or decodes any other photo.
    private static func develop(_ data: Data) -> CIImage? {
        if let raw = CIRAWFilter(imageData: data, identifierHint: nil), raw.outputImage != nil {
            if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = 0 }
            if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = 0 }
            return raw.outputImage
        }
        return CIImage(data: data, options: [.applyOrientationProperty: true])
    }

    private static func readProperties(_ data: Data) -> [String: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [:] }
        return properties
    }

    private static func describeSource(_ data: Data, width: Int, height: Int) -> String {
        let megapixels = width * height / 1_000_000
        let isRAW = CIRAWFilter(imageData: data, identifierHint: nil)?.outputImage != nil
        return "\(megapixels) MP \(isRAW ? "RAW" : "photos")"
    }

    /// First frame's camera, lens and GPS details, with the stack's total exposure.
    private func outputProperties(comment: String) -> [String: Any] {
        var output: [String: Any] = [:]
        var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        if totalExposure > 0 {
            exif[kCGImagePropertyExifExposureTime as String] = totalExposure
            exif[kCGImagePropertyExifShutterSpeedValue as String] = -log2(totalExposure)
        }
        exif[kCGImagePropertyExifPixelXDimension as String] = width
        exif[kCGImagePropertyExifPixelYDimension as String] = height
        exif[kCGImagePropertyExifUserComment as String] = comment
        output[kCGImagePropertyExifDictionary as String] = exif

        var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFSoftware as String] = Metadata.software
        tiff[kCGImagePropertyTIFFImageDescription as String] = comment
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        output[kCGImagePropertyTIFFDictionary as String] = tiff

        if let gps = properties[kCGImagePropertyGPSDictionary as String] { output[kCGImagePropertyGPSDictionary as String] = gps }
        // The developed image is already upright.
        output[kCGImagePropertyOrientation as String] = 1
        return output
    }
}

/// Collects ProRAW frames while they're shot (on disk, so memory stays low), then stacks them.
final class RawStackSession {
    let mode: StackMode
    let align: Bool
    let fieldOfView: Double

    private let queue = DispatchQueue(label: "camerapp.rawstack.files")
    private let folder: URL
    private var files: [Int: URL] = [:]
    private var attitudes: [Int: CMQuaternion] = [:]

    init(mode: StackMode, align: Bool, fieldOfView: Double) {
        self.mode = mode
        self.align = align
        self.fieldOfView = fieldOfView
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rawstack-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func setAttitude(_ attitude: CMQuaternion?, index: Int) {
        queue.async { if let attitude { self.attitudes[index] = attitude } }
    }

    func store(_ data: Data, index: Int) {
        queue.async {
            let url = self.folder.appendingPathComponent("\(index).dng")
            if (try? data.write(to: url)) != nil { self.files[index] = url }
        }
    }

    /// Waits for `expected` frames to arrive (they finish processing after the shooting ends),
    /// then stacks them. Callbacks run on the main thread.
    func run(expected: Int, tiff: Bool, progress: @escaping (String) -> Void,
             completion: @escaping (Data?, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline, self.queue.sync(execute: { self.files.count }) < expected {
                Thread.sleep(forTimeInterval: 0.2)
            }
            let (files, attitudes) = self.queue.sync { (self.files, self.attitudes) }
            let indices = files.keys.sorted()
            let stacker = RawStacker(mode: self.mode, align: self.align, fieldOfView: self.fieldOfView)
            let firstAttitude = indices.first.flatMap { attitudes[$0] }
            for (n, index) in indices.enumerated() {
                DispatchQueue.main.async { progress("Stacking RAW \(n + 1)/\(indices.count)…") }
                autoreleasepool {
                    guard let url = files[index], let data = try? Data(contentsOf: url) else { return }
                    var rotation: Double?
                    if let first = firstAttitude, let current = attitudes[index] {
                        rotation = Motion.angle(first, current)
                    }
                    stacker.add(imageData: data, rotationSinceFirst: rotation)
                    try? FileManager.default.removeItem(at: url)
                }
            }
            DispatchQueue.main.async { progress("Saving stacked image…") }
            let result = stacker.finish(tiff: tiff)
            try? FileManager.default.removeItem(at: self.folder)
            DispatchQueue.main.async { completion(result.data, result.summary) }
        }
    }
}
