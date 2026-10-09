import AppKit
import CoreVideo
import SwiftUI

/// Displays live screen-capture frames by writing IOSurfaces onto a CALayer.
/// Frames are pushed from `ScreenPreviewManager` and do not go through SwiftUI.
struct ScreenPreviewView: NSViewRepresentable {
    var manager: ScreenPreviewManager

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        manager.attachPreviewView(view)
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        manager.attachPreviewView(nsView)
    }

    static func dismantleNSView(_ nsView: PreviewNSView, coordinator: ()) {
        nsView.clear()
    }

    final class PreviewNSView: NSView {
        private var displayedBuffer: CVPixelBuffer?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.contentsGravity = .resizeAspect
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.masksToBounds = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

        func present(_ image: CGImage) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = image
            CATransaction.commit()
            displayedBuffer = nil
        }

        func present(_ pixelBuffer: CVPixelBuffer) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() {
                layer?.contents = surface
            }
            CATransaction.commit()
            displayedBuffer = pixelBuffer
        }

        func clear() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = nil
            CATransaction.commit()
            displayedBuffer = nil
        }
    }
}
