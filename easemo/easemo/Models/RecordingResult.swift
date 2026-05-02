import CoreMedia
import Foundation

/// Result of a single recording session.
///
/// Holds URLs to the on-disk artifacts produced by `RecordingManager` and
/// `CameraManager` along with the shared start timestamp the
/// `CaptureSessionCoordinator` used for synchronization.
public struct RecordingResult: Equatable {
    /// File URL of the screen recording (always present).
    public let screenURL: URL
    /// File URL of the webcam recording (nil if the user disabled the camera).
    public let cameraURL: URL?
    /// Output canvas size used when recording the screen, in pixels.
    public let canvasSize: CGSize
    /// Wall-clock start timestamp used by the coordinator for alignment.
    public let startTime: CMTime
    /// Duration of the screen recording. The camera recording is expected to
    /// be very close (within a frame or two) but may differ slightly.
    public let duration: CMTime
    /// Preferred layout metadata for this take (typically last known PiP placement).
    public let layout: OverlayLayout
    /// PiP layout over recording time — non-empty enables moving overlay in export/preview.
    public let overlayMotion: [OverlayLayoutKeyframe]

    public init(screenURL: URL,
                cameraURL: URL?,
                canvasSize: CGSize,
                startTime: CMTime,
                duration: CMTime,
                layout: OverlayLayout,
                overlayMotion: [OverlayLayoutKeyframe] = []) {
        self.screenURL = screenURL
        self.cameraURL = cameraURL
        self.canvasSize = canvasSize
        self.startTime = startTime
        self.duration = duration
        self.layout = layout
        self.overlayMotion = overlayMotion
    }
}
