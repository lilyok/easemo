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
/// sync with the video. To keep voices natural at non-1× speeds, the audio
/// track is rendered through an `AVAudioMix` whose
/// `audioTimePitchAlgorithm` is set to `.spectral` (formant-preserving
/// time-stretch) — playback is faster/slower without the chipmunk effect.
public struct ComposedAssetBundle {
    public let composition: AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    /// Audio mix that pins time-stretching to `.spectral` (pitch preserved).
    /// `nil` when there is no audio track in the composition.
    public let audioMix: AVAudioMix?
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
    ///   - trimStart: Start offset in seconds (applied before speed scaling).
    ///   - trimEnd: End offset in seconds (applied before speed scaling).
    ///   - muteAudio: When true, the audio track is silenced in the output.
    public func compose(result: RecordingResult,
                        layout: OverlayLayout,
                        speed: Double,
                        trimStart: Double,
                        trimEnd: Double,
                        muteAudio: Bool = false) async throws -> ComposedAssetBundle {

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
        let totalSeconds = max(0, screenDuration.seconds)
        let minDuration: Double = 0.1
        let clampedStart = min(max(trimStart, 0), max(totalSeconds - minDuration, 0))
        let clampedEnd = min(max(trimEnd, clampedStart + minDuration), totalSeconds)
        let startTime = CMTime(seconds: clampedStart, preferredTimescale: 600)
        let selectedDuration = CMTime(seconds: max(clampedEnd - clampedStart, minDuration), preferredTimescale: 600)
        let screenRange = CMTimeRange(start: startTime, duration: selectedDuration)

        // ----- Screen track -----
        guard let composedScreen = composition.addMutableTrack(withMediaType: .video,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoComposerError.underlying("Failed to add screen track to composition.")
        }
        try composedScreen.insertTimeRange(screenRange, of: screenVideoTrack, at: .zero)
        let screenNaturalSize = try await screenVideoTrack.load(.naturalSize)
        let screenTransform = try await screenVideoTrack.load(.preferredTransform)
        composedScreen.preferredTransform = screenTransform

        let motionKeyframes = result.overlayMotion.sorted { $0.timeSeconds < $1.timeSeconds }
        let overlayUsesMotion = !motionKeyframes.isEmpty

        func cameraVisibleAnywhere(for motion: [OverlayLayoutKeyframe], fallback: OverlayLayout) -> Bool {
            if motion.isEmpty { return fallback.isVisible }
            return motion.contains { $0.layout.isVisible }
        }
        let shouldInsertCameraTrack = result.cameraURL != nil
            && cameraVisibleAnywhere(for: motionKeyframes, fallback: layout)

        // ----- Optional camera track -----
        var composedCamera: AVMutableCompositionTrack?
        var cameraAspect: CGFloat = 16.0/9.0
        if shouldInsertCameraTrack, let cameraURL = result.cameraURL {
            let cameraAsset = AVURLAsset(url: cameraURL)
            if try await loadable(cameraAsset),
               let cameraVideoTrack = try await cameraAsset.loadTracks(withMediaType: .video).first {

                let cameraTransform = try await cameraVideoTrack.load(.preferredTransform)
                let cameraDuration = try await cameraAsset.load(.duration)
                let remainingAfterStart = CMTimeMaximum(.zero, cameraDuration - startTime)
                let usable = CMTimeMinimum(remainingAfterStart, selectedDuration)
                let cameraRange = CMTimeRange(start: startTime, duration: usable)
                let camTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid)
                if usable > .zero {
                    try camTrack?.insertTimeRange(cameraRange, of: cameraVideoTrack, at: .zero)
                    composedCamera = camTrack
                    camTrack?.preferredTransform = cameraTransform
                }

                let cameraNatural = try await cameraVideoTrack.load(.naturalSize)
                let cameraRendered = applyTransform(cameraTransform, to: cameraNatural)
                if cameraRendered.height > 0 {
                    cameraAspect = cameraRendered.width / cameraRendered.height
                }
            }
        }

        // ----- Optional microphone audio track -----
        var composedAudio: AVMutableCompositionTrack?
        if let audioURL = result.audioURL {
            let audioAsset = AVURLAsset(url: audioURL)
            if try await loadable(audioAsset),
               let audioSourceTrack = try await audioAsset.loadTracks(withMediaType: .audio).first {
                let audioDuration = try await audioAsset.load(.duration)
                let remainingAfterStart = CMTimeMaximum(.zero, audioDuration - startTime)
                let usable = CMTimeMinimum(remainingAfterStart, selectedDuration)
                if usable > .zero,
                   let track = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) {
                    let audioRange = CMTimeRange(start: startTime, duration: usable)
                    try? track.insertTimeRange(audioRange, of: audioSourceTrack, at: .zero)
                    composedAudio = track
                }
            }
        }

        // ----- Apply playback speed -----
        if abs(clampedSpeed - 1.0) > .ulpOfOne {
            let newDuration = CMTimeMultiplyByFloat64(selectedDuration, multiplier: 1.0 / clampedSpeed)
            for track in composition.tracks {
                track.scaleTimeRange(CMTimeRange(start: .zero, duration: track.timeRange.duration),
                                     toDuration: newDuration)
            }
        }

        // Never use `composition.tracks.first`; order is undefined and can grab audio or the wrong timeline.
        let scaledDuration = composedScreen.timeRange.duration
        let renderSize = applyTransform(screenTransform, to: screenNaturalSize)

        // ----- Build video composition -----
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.customVideoCompositorClass = OverlayVideoCompositor.self

        let instructions = buildOverlayInstructions(
            motionKeyframes: overlayUsesMotion ? motionKeyframes : [],
            fallbackLayout: layout,
            composedScreen: composedScreen,
            composedCamera: composedCamera,
            renderSize: renderSize,
            cameraAspect: cameraAspect,
            trimStart: clampedStart,
            trimEnd: clampedEnd,
            playbackSpeed: clampedSpeed,
            scaledDuration: scaledDuration
        )
        videoComposition.instructions = instructions

        // ----- Audio mix (pitch-preserving time stretch) -----
        // When the user picks a non-1× playback speed, `scaleTimeRange` is
        // applied to the audio track above. By default, AVFoundation also
        // scales the pitch (chipmunk effect at 2×, deep voice at 0.5×). We
        // explicitly opt in to `.spectral` time-stretching, which keeps
        // formants intact so the speaker's voice sounds natural at any
        // supported speed.
        let audioMix: AVAudioMix? = {
            guard let composedAudio = composedAudio else { return nil }
            let mix = AVMutableAudioMix()
            let parameters = AVMutableAudioMixInputParameters(track: composedAudio)
            parameters.audioTimePitchAlgorithm = .spectral
            if muteAudio {
                parameters.setVolume(0, at: .zero)
            }
            mix.inputParameters = [parameters]
            return mix
        }()

        return ComposedAssetBundle(composition: composition,
                                   videoComposition: videoComposition,
                                   audioMix: audioMix,
                                   renderSize: renderSize,
                                   scaledDuration: scaledDuration)
    }

    private func overlayLayout(atSourceTime seconds: Double,
                               motionKeyframes: [OverlayLayoutKeyframe],
                               fallback: OverlayLayout) -> OverlayLayout {
        guard let first = motionKeyframes.first else { return fallback }
        var picked = first.layout
        for key in motionKeyframes {
            if key.timeSeconds <= seconds + 1e-9 {
                picked = key.layout
            } else {
                break
            }
        }
        return picked
    }

    private func buildOverlayInstructions(motionKeyframes: [OverlayLayoutKeyframe],
                                          fallbackLayout: OverlayLayout,
                                          composedScreen: AVMutableCompositionTrack,
                                          composedCamera: AVMutableCompositionTrack?,
                                          renderSize: CGSize,
                                          cameraAspect: CGFloat,
                                          trimStart: Double,
                                          trimEnd: Double,
                                          playbackSpeed: Double,
                                          scaledDuration: CMTime) -> [OverlayInstruction] {
        let cameraPersistentID = composedCamera?.trackID
        let preferredTimescale: CMTimeScale = scaledDuration.timescale != 0 ? scaledDuration.timescale : 600

        func makeSlice(timeRange: CMTimeRange, layout: OverlayLayout) -> OverlayInstruction {
            OverlayInstruction(
                timeRange: timeRange,
                screenTrackID: composedScreen.trackID,
                compositionCameraTrackID: cameraPersistentID,
                overlayCameraCompositionTrackID: layout.isVisible ? cameraPersistentID : nil,
                cameraFrame: layout.frame(in: renderSize, cameraAspect: cameraAspect),
                shape: layout.shape
            )
        }

        guard CMTimeCompare(scaledDuration, .zero) > 0 else {
            let lay = overlayLayout(atSourceTime: trimStart,
                                   motionKeyframes: motionKeyframes.isEmpty ? [] : motionKeyframes,
                                   fallback: fallbackLayout)
            return [makeSlice(timeRange: CMTimeRange(start: .zero, duration: scaledDuration), layout: lay)]
        }

        if motionKeyframes.isEmpty {
            return [makeSlice(timeRange: CMTimeRange(start: .zero, duration: scaledDuration), layout: fallbackLayout)]
        }

        struct Change {
            var time: CMTime
            var layout: OverlayLayout
        }

        let startLayout = overlayLayout(atSourceTime: trimStart,
                                        motionKeyframes: motionKeyframes,
                                        fallback: fallbackLayout)
        var changes: [Change] = [Change(time: .zero, layout: startLayout)]

        for key in motionKeyframes {
            let sourceT = key.timeSeconds
            if sourceT <= trimStart { continue }
            if sourceT >= trimEnd - 1e-9 { break }
            let compSec = (sourceT - trimStart) / playbackSpeed
            if !compSec.isFinite || compSec <= 0 { continue }
            let t = CMTime(seconds: compSec, preferredTimescale: preferredTimescale)
            if CMTimeCompare(t, scaledDuration) >= 0 { break }
            changes.append(Change(time: t, layout: key.layout))
        }

        changes.sort { CMTimeCompare($0.time, $1.time) < 0 }

        var merged: [Change] = []
        for c in changes {
            if let last = merged.last, CMTimeCompare(last.time, c.time) == 0 {
                merged[merged.count - 1] = c
                continue
            }
            if let last = merged.last, last.layout == c.layout { continue }
            merged.append(c)
        }

        guard !merged.isEmpty else {
            return [makeSlice(timeRange: CMTimeRange(start: .zero, duration: scaledDuration), layout: fallbackLayout)]
        }

        var instructions: [OverlayInstruction] = []
        for index in merged.indices {
            let start = merged[index].time
            let layout = merged[index].layout
            let end = index + 1 < merged.count ? merged[index + 1].time : scaledDuration
            let sliceDur = CMTimeSubtract(end, start)
            if CMTimeCompare(sliceDur, .zero) <= 0 { continue }
            instructions.append(makeSlice(timeRange: CMTimeRange(start: start, duration: sliceDur), layout: layout))
        }

        if instructions.isEmpty {
            return [makeSlice(timeRange: CMTimeRange(start: .zero, duration: scaledDuration), layout: fallbackLayout)]
        }
        return instructions
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
