import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let camera: CameraController
    let redMode: Bool

    func makeUIView(context: Context) -> PreviewUIView {
        PreviewUIView(previewLayer: camera.previewLayer)
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        view.redMode = redMode
    }
}

final class PreviewUIView: UIView {
    private let previewLayer: AVCaptureVideoPreviewLayer
    /// Multiplying by pure red drops the green and blue channels, so the preview is red-only at night.
    private let redLayer = CALayer()

    var redMode = false {
        didSet { redLayer.isHidden = !redMode }
    }

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(previewLayer)
        redLayer.backgroundColor = UIColor.red.cgColor
        redLayer.compositingFilter = "multiplyBlendMode"
        redLayer.isHidden = true
        layer.addSublayer(redLayer)
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
