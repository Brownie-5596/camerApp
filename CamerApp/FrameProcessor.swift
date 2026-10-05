import AVFoundation
import CoreImage
import CoreMotion
import ImageIO
import QuartzCore

/// What the histogram shows, plus the numbers behind the exposure check.
struct HistogramReading {
    /// 64 bars, 0 (black) … 63 (white), scaled so the tallest is 1.
    var bins: [Float] = []
    /// Share of the picture that is pure white (blown out).
    var clipped: Float = 0
    /// Share of the picture that is nearly black.
    var dark: Float = 0
    /// Average brightness, 0–1.
    var mean: Float = 0

    enum Verdict {
        case good, tooBright, tooDark, unknown
    }

    var verdict: Verdict {
        if bins.isEmpty { return .unknown }
        if clipped > 0.02 { return .tooBright }
        if dark > 0.5 || mean < 0.04 { return .tooDark }
        return .good
    }
}

/// Receives the live video frames. Drives the histogram, focus peaking, the clipping warning,
/// stacked long exposures (with alignment) and lightning detection.
final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "camerapp.frames", qos: .userInitiated)

    /// Called on the main thread.
    var onHistogram: ((HistogramReading) -> Void)?
    /// Called on the main thread. `nil` clears the overlay.
    var onOverlay: ((CGImage?) -> Void)?

    /// Metadata for an encoded image: (frame count, width, height) → properties.
    typealias MetadataBuilder = (_ frames: Int, _ width: Int, _ height: Int) -> [String: Any]

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    /// Size of the incoming frames, e.g. "4032×3024", for the camera report.
    let frameSize = Locked<String>("no frames yet")
    private var lastFrameWidth = 0

    private final class StackJob {
        let stacker: Stacker
        let total: Int?
        let metadata: MetadataBuilder
        let progress: (Int) -> Void
        let framesDone: (Int) -> Void
        let completion: (Data?, Int, Int) -> Void
        /// Line frames up if the camera moves. Horizontal field of view in degrees, nil = off.
        let alignFieldOfView: Double?
        var reference: [GrayImage]?
        var referenceAttitude: CMQuaternion?
        var aligned = 0

        init(stacker: Stacker, total: Int?, metadata: @escaping MetadataBuilder, alignFieldOfView: Double?,
             progress: @escaping (Int) -> Void, framesDone: @escaping (Int) -> Void,
             completion: @escaping (Data?, Int, Int) -> Void) {
            self.stacker = stacker
            self.total = total
            self.metadata = metadata
            self.alignFieldOfView = alignFieldOfView
            self.progress = progress
            self.framesDone = framesDone
            self.completion = completion
        }
    }

    private struct LightningWatch {
        let threshold: Float
        let metadata: MetadataBuilder
        let onCatch: (Data?) -> Void
        var baseline: Float?
        var cooldownUntil: CFTimeInterval = 0
    }

    // Frame-queue state
    private var peakingEnabled = false
    private var clippingEnabled = false
    private var overlayOrientation: CGImagePropertyOrientation = .right
    private var peakingColor: (CGFloat, CGFloat, CGFloat) = (0, 1, 0)
    private var clippingColor: (CGFloat, CGFloat, CGFloat) = (1, 0, 0.6)
    private var lastHistogramTime: CFTimeInterval = 0
    private var lastOverlayTime: CFTimeInterval = 0
    /// Maps a pixel's brightness to what it will be in the finished picture (long exposures add light).
    private var histogramMap = [UInt8](0...255)
    private var job: StackJob?
    private var lightning: LightningWatch?
    private var lastFrameTime = CMTime.invalid
    private var frameInterval = 1.0 / 30

    // MARK: - Control (call from any thread)

    func setOverlays(peaking: Bool, clipping: Bool, orientation: CGImagePropertyOrientation, redMode: Bool) {
        queue.async {
            self.peakingEnabled = peaking
            self.clippingEnabled = clipping
            self.overlayOrientation = orientation
            self.peakingColor = redMode ? (1, 0, 0) : (0.2, 1, 0.2)
            self.clippingColor = redMode ? (1, 0.3, 0.3) : (1, 0, 0.6)
            if !peaking && !clipping {
                DispatchQueue.main.async { self.onOverlay?(nil) }
            }
        }
    }

    /// Makes the histogram show the finished photo: a long exposure of N frames is N times brighter
    /// than the single frames the preview shows.
    func setHistogramGain(_ gain: Float) {
        let map: [UInt8] = (0...255).map { i in
            guard gain != 1 else { return UInt8(i) }
            let c = Float(i) / 255
            let linear = c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
            let boosted = min(1, linear * gain)
            let encoded = boosted <= 0.0031308 ? boosted * 12.92 : 1.055 * powf(boosted, 1 / 2.4) - 0.055
            return UInt8(max(0, min(255, (encoded * 255).rounded())))
        }
        queue.async { self.histogramMap = map }
    }

    /// Starts stacking the next `frames` frames, or until `finishStack()` when `frames` is nil.
    /// Pass `alignFieldOfView` to line up frames if the camera gets bumped.
    /// `framesDone` fires as soon as collecting stops (so the next shot can begin);
    /// `completion` (data, frames, re-aligned frames) fires once the image is encoded.
    /// All callbacks run on the main thread.
    func startStack(mode: StackMode, frames: Int?, alignFieldOfView: Double?, metadata: @escaping MetadataBuilder,
                    progress: @escaping (Int) -> Void,
                    framesDone: @escaping (Int) -> Void,
                    completion: @escaping (Data?, Int, Int) -> Void) {
        queue.async {
            guard self.job == nil else {
                DispatchQueue.main.async {
                    framesDone(0)
                    completion(nil, 0, 0)
                }
                return
            }
            self.job = StackJob(stacker: Stacker(mode: mode), total: frames, metadata: metadata,
                                alignFieldOfView: alignFieldOfView,
                                progress: progress, framesDone: framesDone, completion: completion)
        }
    }

    func finishStack() {
        queue.async { self.completeJob() }
    }

    /// Pass a threshold to watch for sudden brightness jumps, or nil to stop watching.
    /// `onCatch` is called on the main thread with the encoded image.
    func setLightning(threshold: Float?, metadata: @escaping MetadataBuilder, onCatch: @escaping (Data?) -> Void) {
        queue.async {
            if let threshold {
                self.lightning = LightningWatch(threshold: threshold, metadata: metadata, onCatch: onCatch)
            } else {
                self.lightning = nil
            }
        }
    }

    // MARK: - Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if lastFrameTime.isValid {
            let delta = (timestamp - lastFrameTime).seconds
            if delta > 0 && delta < 5 { frameInterval = frameInterval * 0.8 + delta * 0.2 }
        }
        lastFrameTime = timestamp
        let now = CACurrentMediaTime()

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let frame = FrameView(base: UnsafePointer(base.assumingMemoryBound(to: UInt8.self)),
                              width: CVPixelBufferGetWidth(pixelBuffer),
                              height: CVPixelBufferGetHeight(pixelBuffer),
                              bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer))
        if frame.width != lastFrameWidth {
            lastFrameWidth = frame.width
            frameSize.set("\(frame.width)×\(frame.height)")
        }

        if let job {
            job.stacker.add(frame, shift: alignmentShift(for: frame, job: job))
            let added = job.stacker.count
            DispatchQueue.main.async { job.progress(added) }
            if let total = job.total, added >= total { completeJob() }
        }

        let histogramDue = now - lastHistogramTime > 0.2
        let watching = lightning != nil && job == nil
        if histogramDue || watching {
            let stats = lumaStats(frame, step: max(4, frame.width / 160))
            if histogramDue {
                lastHistogramTime = now
                let reading = stats.reading
                DispatchQueue.main.async { self.onHistogram?(reading) }
            }
            if watching { detectLightning(mean: stats.rawMean, frame: frame, now: now) }
        }

        if (peakingEnabled || clippingEnabled) && now - lastOverlayTime > 0.12 {
            lastOverlayTime = now
            let image = makeOverlay(pixelBuffer)
            DispatchQueue.main.async { self.onOverlay?(image) }
        }
    }

    /// Gyroscope says whether the phone turned since the first frame; if it did, measure the shift
    /// from the pictures themselves. Returns the shift in frame pixels.
    private func alignmentShift(for frame: FrameView, job: StackJob) -> (dx: Int, dy: Int) {
        guard let fieldOfView = job.alignFieldOfView else { return (0, 0) }
        let attitude = Motion.shared.attitude
        guard let reference = job.reference else {
            job.reference = Alignment.pyramid(from: frame)
            job.referenceAttitude = attitude
            return (0, 0)
        }
        if let first = job.referenceAttitude, let attitude {
            let pixelsPerRadian = Double(frame.width) / 2 / tan(fieldOfView * .pi / 360)
            if Motion.angle(first, attitude) * pixelsPerRadian < 1.5 { return (0, 0) }
        }
        guard let finest = reference.last else { return (0, 0) }
        let s = Alignment.shift(reference: reference, moving: Alignment.pyramid(from: frame))
        let scale = Double(frame.width) / Double(finest.width)
        let shift = (dx: Int((s.dx * scale).rounded()), dy: Int((s.dy * scale).rounded()))
        if shift.dx != 0 || shift.dy != 0 { job.aligned += 1 }
        return shift
    }

    private func completeJob() {
        guard let job else { return }
        self.job = nil
        let count = job.stacker.count
        let aligned = job.aligned
        DispatchQueue.main.async { job.framesDone(count) }
        // Encoding a full-resolution image takes a moment; keep the live view (and the next stack) running.
        DispatchQueue.global(qos: .userInitiated).async {
            let data = job.stacker.makeHEIF { width, height in job.metadata(count, width, height) }
            DispatchQueue.main.async { job.completion(data, count, aligned) }
        }
    }

    private func detectLightning(mean: Float, frame: FrameView, now: CFTimeInterval) {
        guard var watch = lightning else { return }
        if let baseline = watch.baseline, now > watch.cooldownUntil, mean - baseline > watch.threshold {
            // A flash: keep the brightest pixels from the next ~0.6 s so the whole bolt is caught.
            let frames = max(3, Int((0.6 / frameInterval).rounded()))
            watch.cooldownUntil = now + 0.6 + 1.0
            lightning = watch
            let onCatch = watch.onCatch
            let burst = StackJob(stacker: Stacker(mode: .brightest), total: frames, metadata: watch.metadata,
                                 alignFieldOfView: nil, progress: { _ in }, framesDone: { _ in },
                                 completion: { data, _, _ in onCatch(data) })
            burst.stacker.add(frame)
            job = burst
        } else {
            watch.baseline = watch.baseline.map { $0 * 0.9 + mean * 0.1 } ?? mean
            lightning = watch
        }
    }

    private func lumaStats(_ frame: FrameView, step: Int) -> (reading: HistogramReading, rawMean: Float) {
        var bins = [Float](repeating: 0, count: 64)
        var rawSum = 0
        var sum = 0
        var clipped = 0
        var dark = 0
        var samples = 0
        histogramMap.withUnsafeBufferPointer { map in
            var y = 0
            while y < frame.height {
                let row = frame.base + y * frame.bytesPerRow
                var x = 0
                while x < frame.width {
                    let p = row + x * 4
                    let raw = (Int(p[2]) * 54 + Int(p[1]) * 183 + Int(p[0]) * 19) >> 8
                    let luma = Int(map[raw])
                    bins[luma >> 2] += 1
                    rawSum += raw
                    sum += luma
                    if luma >= 250 { clipped += 1 }
                    if luma <= 8 { dark += 1 }
                    samples += 1
                    x += step
                }
                y += step
            }
        }
        let peak = bins.max() ?? 0
        let n = Float(max(samples, 1))
        let reading = HistogramReading(bins: bins.map { peak > 0 ? $0 / peak : 0 },
                                       clipped: Float(clipped) / n,
                                       dark: Float(dark) / n,
                                       mean: Float(sum) / n / 255)
        return (reading, Float(rawSum) / n / 255)
    }

    /// Focus peaking (sharp edges glow) and/or a clipping warning (blown-out areas turn pink).
    private func makeOverlay(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = 640 / max(source.extent.width, source.extent.height)
        let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = small.extent
        var overlay: CIImage?

        if peakingEnabled {
            let (r, g, b) = peakingColor
            overlay = small
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 5])
                .cropped(to: extent)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 3, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: r, y: g, z: b, w: -0.6),
                ])
                .applyingFilter("CIColorClamp")
        }

        if clippingEnabled {
            let (r, g, b) = clippingColor
            // Opaque only where brightness is above ~98%.
            let clip = small
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 12.5, y: 31, z: 6.5, w: 0),
                    "inputBiasVector": CIVector(x: r, y: g, z: b, w: -48.5),
                ])
                .applyingFilter("CIColorClamp")
            overlay = overlay.map { clip.composited(over: $0) } ?? clip
        }

        guard let overlay else { return nil }
        let oriented = overlay.oriented(overlayOrientation)
        return ciContext.createCGImage(oriented, from: oriented.extent)
    }
}
