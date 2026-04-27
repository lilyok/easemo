import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

/// `VideoComposer` builds an `AVMutableComposition` and a matching
/// `AVMutableVideoComposition` that overlays the camera recording on top of
/// the screen recording.
///
/// Compositing happens **after** the recordings are produced. We do not
/// render frames in real-time during capture, which keeps capture cheap and
/// crash-resistant for long sessions.
///
/// The composer produces:
/// - `composition`: an `AVMutableComposition` with up to two video tracks
///   (screen + camera) plus any audio tracks discovered.
/// - `videoComposition`: an `AVMutableVideoComposition` that uses our custom
///   `OverlayVideoCompositor` to lay the camera over the screen with optional
///   shape masking (rectangle / circle).
///
/// Speed adjustment is implemented with `scaleTimeRange(_:toDuration:)` on
/// every track inside the composition so that audio (when present) stays in
/// sync with the video.
public struct ComposedAssetBundle {
    public let composition: AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    public let renderSize: CGSize
    public let scaledDuration: CMTime
}

public enum VideoComposerError: LocalizedError {
    case missingScreenAsset
    case noVideoTracks
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .missingScreenAsset:
            return "The screen recording is missing or could not be loaded."
        case .noVideoTracks:
            return "The screen recording does not contain a video track."
        case .underlying(let message):
            return message
        }
    }
}

public final class VideoComposer {

    public init() {}

    /// Build a composition for the given recording result.
    /// - Parameters:
    ///   - result: The recording result produced by `CaptureSessionCoordinator`.
    ///   - layout: Overlay layout (camera position / shape / size).
    ///   - speed: Playback speed multiplier (e.g. 1.0 = normal, 2.0 = double).
    public func compose(result: RecordingResult,
                        layout: OverlayLayout,
                        speed: Double) async throws -> ComposedAssetBundle {

        let clampedSpeed = max(0.25, min(speed, 4.0))

        let screenAsset = AVURLAsset(url: result.screenURL)
        guard try await loadable(screenAsset) else {
            throw VideoComposerError.missingScreenAsset
        }

        guard let screenVideoTrack = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw VideoComposerError.noVideoTracks
        }

        let composition = AVMutableComposition()

        let screenDuration = try await screenAsset.load(.duration)
        let screenRange = CMTimeRange(start: .zero, duration: screenDuration)

        // ----- Screen track -----
        guard let composedScreen = composition.addMutableTrack(withMediaType: .video,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoComposerError.underlying("Failed to add screen track to composition.")
        }
        try composedScreen.insertTimeRange(screenRange, of: screenVideoTrack, at: .zero)
        let screenNaturalSize = try await screenVideoTrack.load(.naturalSize)
        let screenTransform = try await screenVideoTrack.load(.preferredTransform)
        composedScreen.preferredTransform = screenTransform

        // ----- Optional camera track -----
        var composedCamera: AVMutableCompositionTrack?
        var cameraAspect: CGFloat = 16.0/9.0
        if layout.isVisible, let cameraURL = result.cameraURL {
            let cameraAsset = AVURLAsset(url: cameraURL)
            if try await loadable(cameraAsset),
               let cameraVideoTrack = try await cameraAsset.loadTracks(withMediaType: .video).first {

                let cameraDuration = try await cameraAsset.load(.duration)
                let usable = CMTimeMinimum(cameraDuration, screenDuration)
                let cameraRange = CMTimeRange(start: .zero, duration: usable)
                let camTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid)
                try camTrack?.insertTimeRange(cameraRange, of: cameraVideoTrack, at: .zero)
                composedCamera = camTrack

                let cameraNatural = try await cameraVideoTrack.load(.naturalSize)
                if cameraNatural.height > 0 {
                    cameraAspect = cameraNatural.width / cameraNatural.height
                }

                // Audio (if any) — camera mic is the most common source.
                if let cameraAudioTrack = try await cameraAsset.loadTracks(withMediaType: .audio).first,
                   let composedAudio = composition.addMutableTrack(withMediaType: .audio,
                                                                   preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try? composedAudio.insertTimeRange(cameraRange, of: cameraAudioTrack, at: .zero)
                }
            }
        }

        // ----- Apply playback speed -----
        if abs(clampedSpeed - 1.0) > .ulpOfOne {
            let newDuration = CMTimeMultiplyByFloat64(screenDuration, multiplier: 1.0 / clampedSpeed)
            for track in composition.tracks {
                track.scaleTimeRange(CMTimeRange(start: .zero, duration: track.timeRange.duration),
                                     toDuration: newDuration)
            }
        }

        let scaledDuration: CMTime = composition.tracks.first?.timeRange.duration ?? screenDuration
        let renderSize = applyTransform(screenTransform, to: screenNaturalSize)
        let cameraFrame = layout.frame(in: renderSize, cameraAspect: cameraAspect)

        // ----- Build video composition -----
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.customVideoCompositorClass = OverlayVideoCompositor.self

        let instruction = OverlayInstruction(
            timeRange: CMTimeRange(start: .zero, duration: scaledDuration),
            screenTrackID: composedScreen.trackID,
            cameraTrackID: (layout.isVisible ? composedCamera?.trackID : nil),
            cameraFrame: cameraFrame,
            shape: layout.shape
        )
        videoComposition.instructions = [instruction]

        return ComposedAssetBundle(composition: composition,
                                   videoComposition: videoComposition,
                                   renderSize: renderSize,
                                   scaledDuration: scaledDuration)
    }

    // MARK: - Helpers

    private func applyTransform(_ transform: CGAffineTransform, to size: CGSize) -> CGSize {
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    private func loadable(_ asset: AVURLAsset) async throws -> Bool {
        let (isPlayable, _) = try await asset.load(.isPlayable, .duration)
        return isPlayable
    }
}
