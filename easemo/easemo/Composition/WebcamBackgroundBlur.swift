import CoreImage
import Vision

/// Blurs the **webcam** image behind the subject using Vision person segmentation.
/// Used during export composition; the screen recording is left untouched.
enum WebcamBackgroundBlur {

    /// Returns `base` unchanged when `enabled` is false or segmentation fails.
    static func applyIfEnabled(_ enabled: Bool, base: CIImage) -> CIImage {
        guard enabled else { return base }
        guard let blended = apply(base: base) else { return base }
        return blended
    }

    private static func apply(base: CIImage) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(ciImage: base, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNPixelBufferObservation else {
            return nil
        }
        let maskBuffer = observation.pixelBuffer
        var mask = CIImage(cvPixelBuffer: maskBuffer)
        let baseExtent = base.extent
        let maskExtent = mask.extent
        if maskExtent.size != baseExtent.size {
            let sx = baseExtent.width / max(maskExtent.width, 1)
            let sy = baseExtent.height / max(maskExtent.height, 1)
            mask = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            let dx = baseExtent.origin.x - mask.extent.origin.x
            let dy = baseExtent.origin.y - mask.extent.origin.y
            mask = mask.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        }
        mask = mask.cropped(to: baseExtent)

        let shortEdge = min(baseExtent.width, baseExtent.height)
        let blurRadius = min(max(shortEdge * 0.04, 8), 42)
        let blurred = base
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: baseExtent)

        return base.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: blurred,
            kCIInputMaskImageKey: mask
        ]).cropped(to: baseExtent)
    }
}
