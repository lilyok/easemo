import AVFoundation
import Combine
import Foundation

/// Errors thrown by `ExportManager`. Modelled as a single `LocalizedError`
/// enum so call sites and tests can pattern-match on the failure mode
/// (`if case .alreadyRunning ...`) instead of reading magic NSError codes.
public enum ExportError: LocalizedError, Equatable {
    /// Returned when `export(...)` is called while a previous export is
    /// still in progress.
    case alreadyRunning
    /// `AVAssetExportSession(asset:presetName:)` returned `nil` — usually
    /// because the requested preset cannot be applied to the supplied
    /// composition (e.g. unsupported resolution).
    case sessionUnavailable(presetName: String)
    /// Wraps an `AVAssetExportSession.error` propagated from AVFoundation.
    case sessionFailed(message: String)
    /// `AVAssetExportSession.status` ended in something other than
    /// `.completed`, `.cancelled`, or `.failed`. The associated value is the
    /// raw status (`session.status.rawValue`) for diagnostics.
    case unexpectedStatus(rawValue: Int)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "An export is already in progress."
        case .sessionUnavailable(let preset):
            return "Could not create an AVAssetExportSession with preset \(preset)."
        case .sessionFailed(let message):
            return message
        case .unexpectedStatus(let rawValue):
            return "Export ended in an unexpected status (\(rawValue))."
        }
    }
}

/// `ExportManager` is responsible for rendering a `ComposedAssetBundle` to
/// disk as an MP4 (H.264) file using `AVAssetExportSession`.
///
/// The class exposes a `progress` publisher driven by an internal display-link
/// style timer that polls `AVAssetExportSession.progress`. Cancellation is
/// supported and forwarded to the underlying session.
@MainActor
public final class ExportManager: ObservableObject {

    public enum State: Equatable {
        case idle
        case exporting
        case completed(URL)
        case failed(String)
        case cancelled
    }

    @Published public private(set) var progress: Double = 0
    @Published public private(set) var state: State = .idle

    private var session: AVAssetExportSession?
    private var pollTimer: Timer?

    nonisolated public init() {}

    /// Export the supplied composition to `outputURL`.
    /// - Parameters:
    ///   - bundle: The composed asset bundle returned from `VideoComposer`.
    ///   - outputURL: Destination file URL. Any existing file is replaced.
    ///   - presetName: AVAssetExportSession preset (defaults to highest quality).
    /// - Important: The export manager owns at most one in-flight session.
    ///   Calling `export(...)` while a previous export is still running
    ///   throws `ExportError.alreadyRunning`; cancel the existing one first.
    public func export(bundle: ComposedAssetBundle,
                       to outputURL: URL,
                       presetName: String = AVAssetExportPresetHighestQuality) async throws -> URL {

        // Reject re-entrant exports: a concurrent call would orphan the
        // existing session and stack a second progress timer. The UI also
        // disables the export button while exporting, but this guard makes
        // the contract explicit at the API boundary.
        if case .exporting = state {
            throw ExportError.alreadyRunning
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        guard let session = AVAssetExportSession(asset: bundle.composition,
                                                 presetName: presetName) else {
            let error = ExportError.sessionUnavailable(presetName: presetName)
            state = .failed(error.localizedDescription)
            throw error
        }

        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.videoComposition = bundle.videoComposition
        // Attach the audio mix (if any). The mix pins the time-stretch
        // algorithm to `.spectral` so audio at non-1× playback speeds
        // preserves pitch and the speaker's voice sounds natural.
        if let audioMix = bundle.audioMix {
            session.audioMix = audioMix
        }
        session.audioTimePitchAlgorithm = .spectral

        self.session = session
        self.progress = 0
        self.state = .exporting
        startPollingProgress()

        // `defer` guarantees we tear down the polling timer even if the
        // continuation throws or the task is cancelled mid-await — so a
        // quick re-export call cannot stack timers behind a leaked one.
        defer { stopPollingProgress() }

        // The legacy `exportAsynchronously(completionHandler:)` API plays
        // better with strict Swift 6 concurrency than the implicit-async
        // `await session.export()` overload, which currently flags
        // non-Sendable warnings on `AVAssetExportSession` properties.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .failed:
                    let message = session.error?.localizedDescription ?? "Export failed."
                    continuation.resume(throwing: ExportError.sessionFailed(message: message))
                default:
                    continuation.resume(throwing: ExportError.unexpectedStatus(rawValue: session.status.rawValue))
                }
            }
        }

        switch session.status {
        case .completed:
            state = .completed(outputURL)
            progress = 1.0
            return outputURL
        case .cancelled:
            state = .cancelled
            throw CancellationError()
        case .failed:
            let message = session.error?.localizedDescription ?? "Export failed."
            state = .failed(message)
            throw ExportError.sessionFailed(message: message)
        default:
            let error = ExportError.unexpectedStatus(rawValue: session.status.rawValue)
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    public func cancel() {
        session?.cancelExport()
        stopPollingProgress()
        state = .cancelled
    }

    // MARK: - Progress polling

    /// Start (or restart) the progress poll timer. Idempotent: if a previous
    /// timer is still scheduled — e.g. a quick re-export, or a path that
    /// failed before reaching `stopPollingProgress` — it is invalidated
    /// before installing the new one so timers cannot stack.
    private func startPollingProgress() {
        stopPollingProgress()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let session = self.session else { return }
                self.progress = Double(session.progress)
            }
        }
        self.pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPollingProgress() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
