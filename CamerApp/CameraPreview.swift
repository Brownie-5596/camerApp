import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let camera: CameraController
    let redMode: Bool
    let onShutterEvent: () -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        PreviewUIView(previewLayer: camera.previewLayer)
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        view.redMode = redMode
        view.onShutterEvent = onShutterEvent
    }
}

final class PreviewUIView: UIView {
    private let previewLayer: AVCaptureVideoPreviewLayer
    /// Multiplying by pure red drops the green and blue channels, so the preview is red-only at night.
    private let redLayer = CALayer()

    var redMode = false {
        didSet { redLayer.isHidden = !redMode }
    }

    /// Volume buttons and the Camera Control button.
    var onShutterEvent: (() -> Void)?

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(previewLayer)
        redLayer.backgroundColor = UIColor.red.cgColor
        redLayer.compositingFilter = "multiplyBlendMode"
        redLayer.isHidden = true
        layer.addSublayer(redLayer)

        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { [weak self] event in
                if event.phase == .ended { self?.onShutterEvent?() }
            }
            addInteraction(interaction)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        redLayer.frame = bounds
        CATransaction.commit()
    }
}
