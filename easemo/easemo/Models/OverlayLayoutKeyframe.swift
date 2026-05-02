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
