import Foundation

/// A small grayscale copy of a frame, used to measure how far the camera moved.
struct GrayImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    func halved() -> GrayImage {
        let w = width / 2
        let h = height / 2
        var out = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let row = 2 * y * width
                    for x in 0..<w {
                        let i = row + 2 * x
                        let sum = Int(src[i]) + Int(src[i + 1]) + Int(src[i + width]) + Int(src[i + width + 1])
                        dst[y * w + x] = UInt8(sum >> 2)
                    }
                }
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }
}

/// Lines frames up when the camera moved between them (a bumped tripod, a gust of wind).
///
/// The gyroscope says *whether* the camera moved; this then measures *exactly how far* by comparing
/// the pictures at several sizes (coarse to fine), so the correction can't go the wrong way.
/// It corrects sideways and up/down shifts, which is what a small bump causes.
enum Alignment {
    /// Width of the most detailed comparison image.
    static let finestWidth = 2048

    /// Comparison images from a locked BGRA video frame, coarsest first.
    static func pyramid(from frame: FrameView) -> [GrayImage] {
        let step = max(1, Int((Double(frame.width) / Double(finestWidth)).rounded(.up)))
        let w = frame.width / step
        let h = frame.height / step
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBufferPointer { out in
            for y in 0..<h {
                let row = frame.base + (y * step) * frame.bytesPerRow
                for x in 0..<w {
                    let p = row + (x * step) * 4
                    out[y * w + x] = UInt8((Int(p[2]) * 54 + Int(p[1]) * 183 + Int(p[0]) * 19) >> 8)
                }
            }
        }
        return levels(GrayImage(width: w, height: h, pixels: pixels))
    }

    /// Comparison images from a linear RGBA half-float image (the ProRAW stacker's frames).
    static func pyramid(fromLinear frame: UnsafePointer<Float16>, width: Int, height: Int) -> [GrayImage] {
        let step = max(1, Int((Double(width) / Double(finestWidth)).rounded(.up)))
        let w = width / step
        let h = height / step
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBufferPointer { out in
            for y in 0..<h {
                let row = frame + (y * step) * width * 4
                for x in 0..<w {
                    let p = row + (x * step) * 4
                    let luma = max(0, 0.3 * Float(p[0]) + 0.6 * Float(p[1]) + 0.1 * Float(p[2]))
                    // Square root brings faint detail up so night frames can still be compared.
                    out[y * w + x] = UInt8(min(255, luma.squareRoot() * 255))
                }
            }
        }
        return levels(GrayImage(width: w, height: h, pixels: pixels))
    }

    private static func levels(_ finest: GrayImage) -> [GrayImage] {
        var result = [finest]
        while let last = result.last, last.width > 320, last.height > 240 {
            result.append(last.halved())
        }
        return result.reversed()
    }

    /// How far the picture moved: something at (x, y) in `reference` is at (x + dx, y + dy) in
    /// `moving`, in finest-level pixels (y points down). Returns (0, 0) when it can't tell.
    static func shift(reference: [GrayImage], moving: [GrayImage]) -> (dx: Double, dy: Double) {
        guard reference.count == moving.count, let ref = reference.last, let mov = moving.last,
              ref.width == mov.width, ref.height == mov.height else { return (0, 0) }
        var cx = 0
        var cy = 0
        for (level, (r, m)) in zip(reference, moving).enumerated() {
            if level > 0 {
                cx *= 2
                cy *= 2
            }
            let radius = level == 0 ? 12 : 2
            var best = (score: Double.infinity, x: cx, y: cy)
            for dy in (cy - radius)...(cy + radius) {
                for dx in (cx - radius)...(cx + radius) {
                    let score = difference(r, m, dx, dy)
                    if score < best.score { best = (score, dx, dy) }
                }
            }
            cx = best.x
            cy = best.y
        }
        if cx == 0 && cy == 0 { return (0, 0) }
        // Only trust a match that is clearly better than "didn't move".
        let center = difference(ref, mov, cx, cy)
        let still = difference(ref, mov, 0, 0)
        guard center < still * 0.97 else { return (0, 0) }
        let fx = parabola(difference(ref, mov, cx - 1, cy), center, difference(ref, mov, cx + 1, cy))
        let fy = parabola(difference(ref, mov, cx, cy - 1), center, difference(ref, mov, cx, cy + 1))
        return (Double(cx) + fx, Double(cy) + fy)
    }

    private static func parabola(_ a: Double, _ b: Double, _ c: Double) -> Double {
        let curvature = a - 2 * b + c
        guard curvature > 0, a.isFinite, c.isFinite else { return 0 }
        return max(-0.5, min(0.5, 0.5 * (a - c) / curvature))
    }

    /// Average brightness difference between reference(x, y) and moving(x + dx, y + dy) where they overlap.
    private static func difference(_ ref: GrayImage, _ mov: GrayImage, _ dx: Int, _ dy: Int) -> Double {
        let x0 = max(0, -dx)
        let x1 = min(ref.width, mov.width - dx)
        let y0 = max(0, -dy)
        let y1 = min(ref.height, mov.height - dy)
        guard x1 - x0 > ref.width / 2, y1 - y0 > ref.height / 2 else { return .infinity }
        let step = ref.width > 600 ? 2 : 1
        var total = 0
        var count = 0
        ref.pixels.withUnsafeBufferPointer { r in
            mov.pixels.withUnsafeBufferPointer { m in
                var y = y0
                while y < y1 {
                    let refRow = y * ref.width
                    let movRow = (y + dy) * mov.width + dx
                    var x = x0
                    while x < x1 {
                        total += abs(Int(r[refRow + x]) - Int(m[movRow + x]))
                        count += 1
                        x += step
                    }
                    y += step
                }
            }
        }
        return count > 0 ? Double(total) / Double(count) : .infinity
    }
}
