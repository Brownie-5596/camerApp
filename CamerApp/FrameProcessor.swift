import AVFoundation
import CoreImage
import ImageIO
import QuartzCore

/// Receives the live video frames. Drives the histogram, focus peaking,
/// stacked long exposures and lightning detection.
final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "camerapp.frames", qos: .userInitiated)

    /// Called on the main thread.
    var onHistogram: (([Float]) -> Void)?
    /// Called on the main thread. `nil` clears the overlay.
    var onPeaking: ((CGImage?) -> Void)?

    /// Metadata for an encoded image: (frame count, width, height) → properties.
    typealias MetadataBuilder = (_ frames: Int, _ width: Int, _ height: Int) -> [String: Any]

    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private final class StackJob {
        let stacker: Stacker
        let total: Int?
        let metadata: MetadataBuilder
        let progress: (Int) -> Void
        let framesDone: (Int) -> Void
        let completion: (Data?, Int) -> Void

        init(stacker: Stacker, total: Int?, metadata: @escaping MetadataBuilder, progress: @escaping (Int) -> Void,
             framesDone: @escaping (Int) -> Void, completion: @escaping (Data?, Int) -> Void) {
            self.stacker = stacker
            self.total = total
            self.metadata = metadata
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
    private var peakingOrientation: CGImagePropertyOrientation = .right
    private var peakingColor: (CGFloat, CGFloat, CGFloat) = (0, 1, 0)
    private var lastHistogramTime: CFTimeInterval = 0
    private var lastPeakingTime: CFTimeInterval = 0
    private var job: StackJob?
    private var lightning: LightningWatch?
    private var lastFrameTime = CMTime.invalid
    private var frameInterval = 1.0 / 30

    // MARK: - Control (call from any thread)

    func setPeaking(enabled: Bool, orientation: CGImagePropertyOrientation, redMode: Bool) {
        queue.async {
            self.peakingEnabled = enabled
            self.peakingOrientation = orientation
            self.peakingColor = redMode ? (1, 0, 0) : (0.2, 1, 0.2)
            if !enabled {
                DispatchQueue.main.async { self.onPeaking?(nil) }
            }
        }
    }

    /// Starts stacking the next `frames` frames, or until `finishStack()` when `frames` is nil.
    /// `framesDone` fires as soon as collecting stops (so the next shot can begin);
    /// `completion` fires once the image is encoded. All callbacks run on the main thread.
    func startStack(mode: StackMode, frames: Int?, metadata: @escaping MetadataBuilder,
                    progress: @escaping (Int) -> Void,
                    framesDone: @escaping (Int) -> Void,
                    completion: @escaping (Data?, Int) -> Void) {
        queue.async {
            guard self.job == nil else {
                DispatchQueue.main.async {
                    framesDone(0)
                    completion(nil, 0)
                }
                return
            }
            self.job = StackJob(stacker: Stacker(mode: mode), total: frames, metadata: metadata,
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

        if let job {
            job.stacker.add(frame)
            let added = job.stacker.count
            DispatchQueue.main.async { job.progress(added) }
            if let total = job.total, added >= total { completeJob() }
        }

        let histogramDue = now - lastHistogramTime > 0.2
        let watching = lightning != nil && job == nil
        if histogramDue || watching {
            let stats = Self.lumaStats(frame, step: max(4, frame.width / 160))
            if histogramDue {
                lastHistogramTime = now
                let histogram = stats.histogram
                DispatchQueue.main.async { self.onHistogram?(histogram) }
            }
            if watching { detectLightning(mean: stats.mean, frame: frame, now: now) }
        }

        if peakingEnabled && now - lastPeakingTime > 0.12 {
            lastPeakingTime = now
            let image = makePeakingImage(pixelBuffer)
            DispatchQueue.main.async { self.onPeaking?(image) }
        }
    }

    private func completeJob() {
        guard let job else { return }
        self.job = nil
        let count = job.stacker.count
        DispatchQueue.main.async { job.framesDone(count) }
        // Encoding a full-resolution image takes a moment; keep the live view (and the next stack) running.
        DispatchQueue.global(qos: .userInitiated).async {
            let data = job.stacker.makeHEIF { width, height in job.metadata(count, width, height) }
            DispatchQueue.main.async { job.completion(data, count) }
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
                                 progress: { _ in }, framesDone: { _ in }, completion: { data, _ in onCatch(data) })
            burst.stacker.add(frame)
            job = burst
        } else {
            watch.baseline = watch.baseline.map { $0 * 0.9 + mean * 0.1 } ?? mean
            lightning = watch
        }
    }

    private static func lumaStats(_ frame: FrameView, step: Int) -> (histogram: [Float], mean: Float) {
        var bins = [Float](repeating: 0, count: 64)
        var sum = 0
        var samples = 0
        var y = 0
        while y < frame.height {
            let row = frame.base + y * frame.bytesPerRow
            var x = 0
            while x < frame.width {
                let p = row + x * 4
                let luma = (Int(p[2]) * 54 + Int(p[1]) * 183 + Int(p[0]) * 19) >> 8
                bins[luma >> 2] += 1
                sum += luma
                samples += 1
                x += step
            }
            y += step
        }
        let peak = bins.max() ?? 0
        let histogram = bins.map { peak > 0 ? $0 / peak : 0 }
        let mean = samples > 0 ? Float(sum) / Float(samples) / 255 : 0
        return (histogram, mean)
    }

    private func makePeakingImage(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = 640 / max(source.extent.width, source.extent.height)
        let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = small.extent
        let edges = small
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 5])
            .cropped(to: extent)
        let (r, g, b) = peakingColor
        let overlay = edges
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 3, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: r, y: g, z: b, w: -0.6),
            ])
            .applyingFilter("CIColorClamp")
            .oriented(peakingOrientation)
        return ciContext.createCGImage(overlay, from: overlay.extent)
    }
}
