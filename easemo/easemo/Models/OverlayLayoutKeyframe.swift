import CoreGraphics
import Foundation

/// Snapshot of PiP `OverlayLayout` along the approximate recording timeline (elapsed seconds UI clock).
/// Built while the user moves/resizes PiP during capture so export can match motion.
public struct OverlayLayoutKeyframe: Equatable, Codable, Sendable {
    /// Seconds since recording began (approximate; aligned with elapsed capture UI clock).
    public var timeSeconds: Double
    public var layout: OverlayLayout

    public init(timeSeconds: Double, layout: OverlayLayout) {
        self.timeSeconds = timeSeconds
        self.layout = layout
    }
}

/// Drives **per-frame** PiP geometry inside one `OverlayInstruction` so the video composition does not
/// split into dozens of slices (shape tweaks used to cause screen-track decoder drop-outs → black flashes).
public struct OverlayMotionTimeline: Equatable, Sendable {
    public let trimStartSeconds: Double
    public let playbackSpeed: Double
    public let keyframes: [OverlayLayoutKeyframe]
    public let fallbackLayout: OverlayLayout
    public let cameraAspect: CGFloat

    public init(trimStartSeconds: Double,
                playbackSpeed: Double,
                keyframes: [OverlayLayoutKeyframe],
                fallbackLayout: OverlayLayout,
                cameraAspect: CGFloat) {
        self.trimStartSeconds = trimStartSeconds
        self.playbackSpeed = playbackSpeed
        self.keyframes = keyframes
        self.fallbackLayout = fallbackLayout
        self.cameraAspect = cameraAspect
    }
}

public enum OverlayTimelineSample {
    /// Step function: last keyframe whose `timeSeconds` ≤ `seconds`.
    public static func layout(atSourceSeconds seconds: Double,
                              keyframes: [OverlayLayoutKeyframe],
                              fallback: OverlayLayout) -> OverlayLayout {
        guard let first = keyframes.first else { return fallback }
        var picked = first.layout
        for key in keyframes {
            if key.timeSeconds <= seconds + 1e-9 {
                picked = key.layout
            } else {
                break
            }
        }
        return picked
    }
}
