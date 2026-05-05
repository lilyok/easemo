import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// Throttled Vision + Core Image pipeline for **live** webcam preview (recording screen + floating HUD).
/// Runs on its own queue so the camera sample queue stays responsive for file recording.
final class CameraLiveBackgroundBlurProcessor: NSObject {

    private let visionQueue = DispatchQueue(label: "easemo.camera.live-blur.vision", qos: .userInitiated)
    private let ciContext = EasemoCIContext.shared

    private let lock = NSLock()
    private var isBusy = false
    private var pendingPixelBuffer: CVPixelBuffer?
    private var lastProcessedTime: CFAbsoluteTime = 0
    /// Minimum seconds between Vision runs (live preview is intentionally low FPS).
    private let minInterval: CFAbsoluteTime = 1.0 / 12.0

    private let onFrame: @MainActor (CVPixelBuffer) -> Void

    init(onFrame: @escaping @MainActor (CVPixelBuffer) -> Void) {
        self.onFrame = onFrame
    }

    /// Call from the camera sample queue for every frame when live blur is enabled.
    func enqueuePixelBufferIfNeeded(_ pixelBuffer: CVPixelBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if isBusy {
            pendingPixelBuffer = pixelBuffer
            lock.unlock()
            return
        }
        if now - lastProcessedTime < minInterval {
            lock.unlock()
            return
        }
        isBusy = true
        lastProcessedTime = now
        lock.unlock()

        let bufferCopy = pixelBuffer
        visionQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.finishVisionPass() }

            let base = CIImage(cvPixelBuffer: bufferCopy)
            guard let blurred = WebcamBackgroundBlur.applyLiveIfEnabled(true, base: base, maxLongEdge: 640) else { return }

            let extent = blurred.extent
            let w = max(2, Int(ceil(extent.width)))
            let h = max(2, Int(ceil(extent.height)))

            var attrs: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            var dst: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                w,
                h,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &dst
            )
            guard status == kCVReturnSuccess, let dst else { return }

            let bounds = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
            self.ciContext.render(
                blurred,
                to: dst,
                bounds: bounds,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )

            Task { @MainActor in
                self.onFrame(dst)
            }
        }
    }

    private func finishVisionPass() {
        var next: CVPixelBuffer?
        lock.lock()
        isBusy = false
        if let pending = pendingPixelBuffer {
            pendingPixelBuffer = nil
            next = pending
        }
        lock.unlock()

        if let next {
            enqueuePixelBufferIfNeeded(next)
        }
    }
}
