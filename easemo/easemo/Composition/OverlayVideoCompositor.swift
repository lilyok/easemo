import AVFoundation
import CoreImage
import CoreVideo
import Foundation

/// Errors thrown by `OverlayVideoCompositor.render(request:)`. Modelled as a
/// typed `LocalizedError` enum so AVFoundation surfaces them to consumers
/// (`request.finish(with:)`) with stable, pattern-matchable cases instead of
/// magic NSError codes — matching the style of `ExportError` and
/// `TestMediaFixtureError` elsewhere in the project.
public enum CompositorError: LocalizedError, Equatable {
    /// AVFoundation handed us an instruction that wasn't an `OverlayInstruction`.
    case unexpectedInstructionType
    /// `request.renderContext.newPixelBuffer()` returned nil — usually means
    /// the render context isn't yet configured or is out of pool memory.
    case renderContextProducedNilBuffer

    public var errorDescription: String? {
        switch self {
        case .unexpectedInstructionType:
            return "Compositor received an unexpected instruction type."
        case .renderContextProducedNilBuffer:
            return "Render context returned a nil pixel buffer."
        }
    }
}

/// Custom `AVVideoCompositing` implementation that composites two video tracks
/// (screen + camera) using Core Image. This is the foundation that lets us
/// apply non-rectangular masks (circle) and transforms in a pixel-correct way
/// without forcing real-time compositing during capture.
///
/// The pipeline per frame is:
/// 1. Pull the source pixel buffer for the screen track and convert to a
///    `CIImage`.
/// 2. Pull the source pixel buffer for the camera track (if present) and
///    transform it to the configured overlay frame.
/// 3. Optionally mask the transformed camera layer to a circle.
/// 4. Composite camera over screen, render to the destination pixel buffer.
///
/// **Threading contract.** All mutable state (`renderContext`) is touched
/// only from `renderQueue`, a private serial dispatch queue: writes happen
/// inside `renderQueue.sync` from `renderContextChanged(_:)` and the render
/// pass runs on the same queue via `renderQueue.async` inside
/// `startRequest(_:)`. The other stored references (`ciContext`,
/// `renderQueue`) are immutable `let`s. Because no shared mutable state
/// crosses queues, the compositor is safe to hand to AVFoundation from any
/// thread; we declare `@unchecked Sendable` to opt out of the strict
/// Sendable check that AVFoundation's protocol cannot satisfy on its own
/// (the `[String: Any]` attribute dictionaries are non-Sendable). If new
/// stored properties are added that hold mutable state, they MUST also be
/// confined to `renderQueue`, or this annotation must be revisited.
final class OverlayVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {

    /// Hints AVFoundation about the pixel formats we accept and produce.
    let sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    private let renderQueue = DispatchQueue(label: "easemo.overlay-compositor")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var renderContext: AVVideoCompositionRenderContext?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderQueue.sync { self.renderContext = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let buffer = try self.render(request: request)
                request.finish(withComposedVideoFrame: buffer)
            } catch {
                request.finish(with: error)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        // Render requests are short and complete on the render queue; nothing
        // to actively cancel beyond letting the queue drain.
    }

    // MARK: - Render

    private func render(request: AVAsynchronousVideoCompositionRequest) throws -> CVPixelBuffer {
        guard let instruction = request.videoCompositionInstruction as? OverlayInstruction else {
            throw CompositorError.unexpectedInstructionType
        }
        guard let destination = request.renderContext.newPixelBuffer() else {
            throw CompositorError.renderContextProducedNilBuffer
        }

        let renderSize = request.renderContext.size

        // Background = screen track.
        var output: CIImage = CIImage(color: CIColor.black).cropped(to: CGRect(origin: .zero, size: renderSize))
        if let screenBuffer = request.sourceFrame(byTrackID: instruction.screenTrackID) {
            let screenImage = CIImage(cvPixelBuffer: screenBuffer)
            // Fit screen frame to render size preserving aspect.
            let screenScaled = scaledToFit(screenImage, in: renderSize)
            output = screenScaled.composited(over: output)
        }

        // Foreground = camera track (optional).
        if let cameraTrackID = instruction.cameraTrackID,
           let cameraBuffer = request.sourceFrame(byTrackID: cameraTrackID) {
            var camera = CIImage(cvPixelBuffer: cameraBuffer)
            // Camera images can be flipped/rotated depending on the source
            // device. Trust the natural transform AVFoundation provides via
            // its frame extents — we already accounted for orientation when
            // building the composition, so we just scale to the overlay frame.

            let frame = instruction.cameraFrame
            let cameraExtent = camera.extent
            let scaleX = frame.width / max(cameraExtent.width, 1)
            let scaleY = frame.height / max(cameraExtent.height, 1)

            // Flip Y because Core Image origin is bottom-left while we want
            // `cameraFrame` measured from the top-left of the canvas.
            let flippedY = renderSize.height - frame.maxY
            camera = camera.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            camera = camera.transformed(by: CGAffineTransform(translationX: frame.origin.x, y: flippedY))

            if instruction.shape == .circle {
                let radius = min(frame.width, frame.height) / 2.0
                let centerX = frame.origin.x + frame.width / 2.0
                let centerY = flippedY + frame.height / 2.0
                let mask = CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": CIVector(x: centerX, y: centerY),
                    "inputRadius0": radius - 1,
                    "inputRadius1": radius,
                    "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                    "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)
                ])?.outputImage?.cropped(to: CGRect(origin: .zero, size: renderSize))

                if let mask = mask {
                    camera = camera.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: CIImage(color: CIColor.clear).cropped(to: CGRect(origin: .zero, size: renderSize)),
                        kCIInputMaskImageKey: mask
                    ])
                }
            }

            output = camera.composited(over: output)
        }

        ciContext.render(output, to: destination,
                         bounds: CGRect(origin: .zero, size: renderSize),
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        return destination
    }

    private func scaledToFit(_ image: CIImage, in size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = min(size.width / extent.width, size.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent
        let dx = (size.width - scaledExtent.width) / 2 - scaledExtent.origin.x
        let dy = (size.height - scaledExtent.height) / 2 - scaledExtent.origin.y
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }
}

/// Custom video composition instruction that carries the parameters our
/// compositor needs (track IDs, overlay frame, shape).
final class OverlayInstruction: NSObject, AVVideoCompositionInstructionProtocol {

    let screenTrackID: CMPersistentTrackID
    /// When `nil`, the PiP overlay is skipped for this slice; camera frames may still be listed in `requiredSourceTrackIDs`.
    let cameraTrackID: CMPersistentTrackID?
    let cameraFrame: CGRect
    let shape: OverlayShape

    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    /// - Parameters:
    ///   - compositionCameraTrackID: When set, IDs are appended to **every** slice’s `requiredSourceTrackIDs`.
    ///     Keeping decoder inputs stable across slices avoids intermittent black video with custom compositors.
    ///   - overlayCameraCompositionTrackID: Track used for overlay sampling (`nil` = hide overlay this slice).
    init(timeRange: CMTimeRange,
         screenTrackID: CMPersistentTrackID,
         compositionCameraTrackID: CMPersistentTrackID?,
         overlayCameraCompositionTrackID: CMPersistentTrackID?,
         cameraFrame: CGRect,
         shape: OverlayShape) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = overlayCameraCompositionTrackID
        self.cameraFrame = cameraFrame
        self.shape = shape
        var ids: [NSValue] = [NSNumber(value: screenTrackID)]
        if let compositionCameraTrackID {
            ids.append(NSNumber(value: compositionCameraTrackID))
        }
        self.requiredSourceTrackIDs = ids
    }
}
