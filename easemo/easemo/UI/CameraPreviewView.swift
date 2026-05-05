import AVFoundation
import AppKit
import CoreImage
import CoreVideo
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
        nsView.needsLayout = true
    }

    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        /// Reused so fast resizes do not swap mask instances (avoids one-frame gaps vs. video).
        private let circleMaskLayer = CAShapeLayer()
        var shape: OverlayShape = .rectangle {
            didSet { needsLayout = true }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            // Avoid black “slivers” when the mask and preview settle at different times during layout.
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.addSublayer(previewLayer)
            circleMaskLayer.fillColor = NSColor.white.cgColor
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            switch shape {
            case .circle:
                let side = min(bounds.width, bounds.height)
                let ellipse = CGRect(
                    x: (bounds.width - side) / 2,
                    y: (bounds.height - side) / 2,
                    width: side,
                    height: side
                )
                circleMaskLayer.frame = bounds
                circleMaskLayer.path = CGPath(ellipseIn: ellipse, transform: nil)
                previewLayer.mask = circleMaskLayer
            case .rectangle:
                previewLayer.mask = nil
            }
            CATransaction.commit()
        }
    }
}

/// Shows either the low-latency preview layer or Vision-blurred frames from `CameraManager`.
struct AdaptiveCameraPreviewView: View {
    let session: AVCaptureSession
    @ObservedObject var cameraManager: CameraManager
    var shape: OverlayShape

    var body: some View {
        Group {
            if cameraManager.blurBackgroundEnabled {
                ZStack {
                    if cameraManager.liveBlurPreviewPixelBuffer == nil {
                        Color.black.opacity(0.35)
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    CameraVisionPreviewView(cameraManager: cameraManager)
                }
                .clipShape(shape == .circle ? AnyShape(Circle()) : AnyShape(Rectangle()))
            } else {
                CameraPreviewView(session: session, shape: shape)
            }
        }
    }
}

/// Type-erased `Shape` so we can switch circle vs rectangle without duplicating view trees.
private struct AnyShape: Shape {
    private let pathBuilder: (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        pathBuilder = { rect in shape.path(in: rect) }
    }

    func path(in rect: CGRect) -> Path {
        pathBuilder(rect)
    }
}

/// Displays the latest `CVPixelBuffer` produced by `CameraLiveBackgroundBlurProcessor`.
private struct CameraVisionPreviewView: NSViewRepresentable {
    @ObservedObject var cameraManager: CameraManager

    func makeNSView(context: Context) -> VisionPreviewNSView {
        VisionPreviewNSView()
    }

    func updateNSView(_ nsView: VisionPreviewNSView, context: Context) {
        nsView.displayPixelBuffer = cameraManager.liveBlurPreviewPixelBuffer
    }

    final class VisionPreviewNSView: NSView {
        private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        var displayPixelBuffer: CVPixelBuffer? {
            didSet { refreshContents() }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.contentsGravity = .resizeAspectFill
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

        override func layout() {
            super.layout()
            refreshContents()
        }

        private func refreshContents() {
            guard let pb = displayPixelBuffer else {
                layer?.contents = nil
                return
            }
            let ci = CIImage(cvPixelBuffer: pb)
            let extent = ci.extent.integral
            guard extent.width > 1, extent.height > 1,
                  let cg = ciContext.createCGImage(ci, from: extent) else {
                layer?.contents = nil
                return
            }
            layer?.contents = cg
        }
    }
}
