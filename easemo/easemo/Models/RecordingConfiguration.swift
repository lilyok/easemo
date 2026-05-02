import CoreGraphics
import Foundation

/// Shape used when masking the camera overlay during composition.
public enum OverlayShape: String, CaseIterable, Identifiable, Codable {
    case rectangle
    case circle

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .circle: return "Circle"
        }
    }
}

/// Position of the overlay relative to the screen recording.
public enum OverlayPosition: String, CaseIterable, Identifiable, Codable {
    case bottomRight
    case bottomLeft
    case topRight
    case topLeft

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bottomRight: return "Bottom Right"
        case .bottomLeft:  return "Bottom Left"
        case .topRight:    return "Top Right"
        case .topLeft:     return "Top Left"
        }
    }
}

/// Layout parameters for placing the camera overlay on top of the screen
/// recording. Values are intentionally simple (percent of screen width and
/// edge inset in pixels) so the layout can be persisted and reasoned about
/// without needing to know the absolute output resolution upfront.
public struct OverlayLayout: Equatable, Codable {
    /// Camera overlay width as a fraction of the screen width (0.05–0.5).
    public var widthFraction: CGFloat
    /// Inset from the chosen corner, in output pixels.
    public var edgeInset: CGFloat
    /// Position corner.
    public var position: OverlayPosition
    /// Shape mask applied to the overlay.
    public var shape: OverlayShape
    /// Optional normalized center point (0...1) used for free-form dragging.
    /// When `nil`, the `position` corner-based placement is used.
    public var customCenter: CGPoint?
    /// Whether the camera overlay should be rendered at all.
    public var isVisible: Bool

    public init(widthFraction: CGFloat = 0.22,
                edgeInset: CGFloat = 32,
                position: OverlayPosition = .bottomRight,
                shape: OverlayShape = .circle,
                customCenter: CGPoint? = nil,
                isVisible: Bool = true) {
        self.widthFraction = widthFraction
        self.edgeInset = edgeInset
        self.position = position
        self.shape = shape
        self.customCenter = customCenter
        self.isVisible = isVisible
    }

    public static let `default` = OverlayLayout()

    /// Compute the absolute frame for the overlay given the output canvas size
    /// and the natural camera aspect ratio.
    public func frame(in canvas: CGSize, cameraAspect: CGFloat) -> CGRect {
        let clampedFraction = min(max(widthFraction, 0.05), 0.5)
        let width = canvas.width * clampedFraction
        let height = width / max(cameraAspect, 0.1)

        if let customCenter {
            let centerX = min(max(customCenter.x, 0), 1) * canvas.width
            let centerY = min(max(customCenter.y, 0), 1) * canvas.height
            let minX = edgeInset
            let maxX = canvas.width - width - edgeInset
            let minY = edgeInset
            let maxY = canvas.height - height - edgeInset
            let x = min(max(centerX - (width / 2), minX), maxX)
            let y = min(max(centerY - (height / 2), minY), maxY)
            return CGRect(x: x, y: y, width: width, height: height).integral
        }

        let x: CGFloat
        let y: CGFloat
        // AVFoundation's video composition uses a coordinate space whose
        // origin is the top-left of the render, which matches macOS layer
        // geometry. Callers (`VideoComposer`) translate where necessary.
        switch position {
        case .bottomRight:
            x = canvas.width - width - edgeInset
            y = canvas.height - height - edgeInset
        case .bottomLeft:
            x = edgeInset
            y = canvas.height - height - edgeInset
        case .topRight:
            x = canvas.width - width - edgeInset
            y = edgeInset
        case .topLeft:
            x = edgeInset
            y = edgeInset
        }
        return CGRect(x: x, y: y, width: width, height: height).integral
    }
}

/// Combined recording configuration captured at the moment recording starts.
/// The configuration is immutable for the duration of a recording so that the
/// composer can rely on stable values when assembling tracks afterwards.
public struct RecordingConfiguration: Equatable {
    public var includeCamera: Bool
    public var overlay: OverlayLayout
    /// Target frame rate for the screen capture stream.
    public var screenFrameRate: Int
    /// Target frame rate for the camera stream.
    public var cameraFrameRate: Int

    public init(includeCamera: Bool = true,
                overlay: OverlayLayout = .default,
                screenFrameRate: Int = 30,
                cameraFrameRate: Int = 30) {
        self.includeCamera = includeCamera
        self.overlay = overlay
        self.screenFrameRate = screenFrameRate
        self.cameraFrameRate = cameraFrameRate
    }
}
