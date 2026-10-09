import AVFoundation
import AppKit
import CoreVideo
import SwiftUI

/// SwiftUI wrapper around `AVCaptureVideoPreviewLayer` so the live webcam feed
/// can be displayed inside SwiftUI views.
struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    var shape: OverlayShape

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.intendedSession = session
        view.shape = shape
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        nsView.intendedSession = session
        nsView.shape = shape
    }

    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        /// Reused so fast resizes do not swap mask instances (avoids one-frame gaps vs. video).
        private let circleMaskLayer = CAShapeLayer()
        var intendedSession: AVCaptureSession? {
            didSet { attachSessionIfInWindow() }
        }
        var shape: OverlayShape = .rectangle {
            didSet { needsLayout = true }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            // Avoid black “slivers” when the mask and preview settle at different times during layout.
            layer?.backgroundColor = NSColor.clear.cgColor
            previewLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(previewLayer)
            circleMaskLayer.fillColor = NSColor.white.cgColor
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachSessionIfInWindow()
        }

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

        private func attachSessionIfInWindow() {
            guard window != nil else { return }
            if previewLayer.session !== intendedSession {
                previewLayer.session = intendedSession
            }
        }
    }
}

/// Shows either the low-latency preview layer or Vision-blurred frames from `CameraManager`.
struct AdaptiveCameraPreviewView: View {
    let session: AVCaptureSession
    @ObservedObject var cameraManager: CameraManager
    var shape: OverlayShape

    var body: some View {
        ZStack {
            CameraPreviewView(session: session, shape: shape)
                .opacity(cameraManager.blurBackgroundEnabled ? 0 : 1)
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
            }
        }
    }
}

/// Type-erased `Shape` so we can switch circle vs rectangle without duplicating view trees.
private struct AnyShape: Shape, @unchecked Sendable {
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
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() {
                layer?.contents = surface
            }
            CATransaction.commit()
        }
    }
}
