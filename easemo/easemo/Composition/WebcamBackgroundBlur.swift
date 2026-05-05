import CoreImage
import CoreVideo
import Vision

/// Blurs the **webcam** image behind the subject using Vision person segmentation.
/// Used during export composition and optional live preview; the screen recording is left untouched.
enum WebcamBackgroundBlur {

    private static let accurateSegmentationRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()

    private static let balancedSegmentationRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()

    /// Returns `base` unchanged when `enabled` is false or segmentation fails.
    static func applyIfEnabled(_ enabled: Bool, base: CIImage) -> CIImage {
        guard enabled else { return base }
        guard let blended = applySegmentationBlur(base: base, request: accurateSegmentationRequest) else { return base }
        return blended
    }

    /// Lighter segmentation for real-time preview. Optionally downscales so Vision does less work.
    /// - Parameter maxLongEdge: When set, the image is scaled so its longer side is at most this value before Vision runs.
    static func applyLiveIfEnabled(_ enabled: Bool, base: CIImage, maxLongEdge: CGFloat? = 640) -> CIImage? {
        guard enabled else { return nil }
        let workBase = downscaleIfNeeded(base, maxLongEdge: maxLongEdge)
        return applySegmentationBlur(base: workBase, request: balancedSegmentationRequest)
    }

    private static func downscaleIfNeeded(_ image: CIImage, maxLongEdge: CGFloat?) -> CIImage {
        guard let cap = maxLongEdge, cap > 32 else { return image }
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        guard longEdge > cap else { return image }
        let scale = cap / longEdge
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private static func applySegmentationBlur(base: CIImage, request: VNGeneratePersonSegmentationRequest) -> CIImage? {
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
