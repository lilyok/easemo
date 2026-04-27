import AVFoundation
import SwiftUI

/// SwiftUI wrapper around `AVCaptureVideoPreviewLayer` so the live webcam feed
/// can be displayed inside SwiftUI views.
struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    var shape: OverlayShape

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.shape = shape
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        nsView.shape = shape
        nsView.layoutSubtreeIfNeeded()
    }

    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        var shape: OverlayShape = .rectangle {
            didSet { needsLayout = true }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
            switch shape {
            case .circle:
                let side = min(bounds.width, bounds.height)
                let mask = CAShapeLayer()
                mask.path = CGPath(ellipseIn: CGRect(x: (bounds.width - side)/2,
                                                     y: (bounds.height - side)/2,
                                                     width: side, height: side),
                                   transform: nil)
                previewLayer.mask = mask
            case .rectangle:
                previewLayer.mask = nil
            }
        }
    }
}
