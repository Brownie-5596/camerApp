import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum StackMode: String, CaseIterable, Identifiable {
    case longExposure = "Long exposure"
    case average = "Average"
    case brightest = "Brightest"

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .longExposure: return "LONG"
        case .average: return "AVG"
        case .brightest: return "MAX"
        }
    }

    var explanation: String {
        switch self {
        case .longExposure:
            return "Adds the light from every frame, like a real long exposure. Use for dark scenes, light trails and smooth water."
        case .average:
            return "Averages the frames. Same brightness as one frame but far less noise. Best for aurora and the Milky Way."
        case .brightest:
            return "Keeps the brightest value of each pixel. Use for star trails, lightning and fireworks."
        }
    }
}

/// A read-only view of a locked BGRA pixel buffer.
struct FrameView {
    let base: UnsafePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

/// Combines video frames into one image. Works in linear light so adding frames
/// behaves like collecting light on a sensor for longer.
final class Stacker {
    let mode: StackMode
    private(set) var count = 0
    private var accumulator: UnsafeMutablePointer<Float>?
    private var width = 0
    private var height = 0

    private static let toLinear: [Float] = (0..<256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    private static let fromLinear: [UInt8] = (0..<4096).map { i in
        let l = Float(i) / 4095
        let c = l <= 0.0031308 ? l * 12.92 : 1.055 * powf(l, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (c * 255).rounded())))
    }

    init(mode: StackMode) {
        self.mode = mode
    }

    deinit {
        accumulator?.deallocate()
    }

    func add(_ frame: FrameView) {
        if accumulator == nil {
            width = frame.width
            height = frame.height
            let size = width * height * 4
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: size)
            buffer.initialize(repeating: 0, count: size)
            accumulator = buffer
        }
        guard let acc = accumulator, frame.width == width, frame.height == height else { return }

        let rowLength = width * 4
        Self.toLinear.withUnsafeBufferPointer { lut in
            for y in 0..<height {
                let src = frame.base + y * frame.bytesPerRow
                let dst = acc + y * rowLength
                if mode == .brightest {
                    for i in 0..<rowLength {
                        let v = lut[Int(src[i])]
                        if v > dst[i] { dst[i] = v }
                    }
                } else {
                    for i in 0..<rowLength {
                        dst[i] += lut[Int(src[i])]
                    }
                }
            }
        }
        count += 1
    }

    /// Encodes the stack as a HEIF image.
    func makeHEIF(orientation: CGImagePropertyOrientation) -> Data? {
        guard let acc = accumulator, count > 0 else { return nil }
        let scale: Float = mode == .average ? 1 / Float(count) : 1
        let pixelCount = width * height
        var pixels = [UInt8](repeating: 255, count: pixelCount * 4)

        Self.fromLinear.withUnsafeBufferPointer { lut in
            pixels.withUnsafeMutableBufferPointer { out in
                for p in 0..<pixelCount {
                    let i = p * 4
                    for c in 0..<3 {
                        let v = min(max(acc[i + c] * scale, 0), 1)
                        out[i + c] = lut[Int(v * 4095)]
                    }
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                      | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation.rawValue,
            kCGImageDestinationLossyCompressionQuality: 0.92,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
