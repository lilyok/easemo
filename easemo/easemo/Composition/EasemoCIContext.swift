import CoreImage

/// One GPU-backed `CIContext` for all easemo Core Image rendering (compositor, live blur, preview).
/// Avoids creating multiple contexts per frame, which would duplicate shader caches and memory.
enum EasemoCIContext {
    static let shared = CIContext(options: [.useSoftwareRenderer: false])
}
