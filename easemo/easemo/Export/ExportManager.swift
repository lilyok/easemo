import AVFoundation
import Combine
import Foundation

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
    public func export(bundle: ComposedAssetBundle,
                       to outputURL: URL,
                       presetName: String = AVAssetExportPresetHighestQuality) async throws -> URL {

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        guard let session = AVAssetExportSession(asset: bundle.composition,
                                                 presetName: presetName) else {
            state = .failed("Could not create AVAssetExportSession.")
            throw NSError(domain: "easemo.export", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create AVAssetExportSession."])
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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .failed:
                    let err = session.error ?? NSError(domain: "easemo.export", code: -2,
                                                      userInfo: [NSLocalizedDescriptionKey: "Export failed."])
                    continuation.resume(throwing: err)
                default:
                    continuation.resume(throwing: NSError(domain: "easemo.export", code: -3,
                                                          userInfo: [NSLocalizedDescriptionKey: "Unexpected export status."]))
                }
            }
        }
        stopPollingProgress()

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
            throw session.error ?? NSError(domain: "easemo.export", code: -2,
                                           userInfo: [NSLocalizedDescriptionKey: message])
        default:
            state = .failed("Unexpected export status: \(session.status.rawValue)")
            throw NSError(domain: "easemo.export", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected export status."])
        }
    }

    public func cancel() {
        session?.cancelExport()
        stopPollingProgress()
        state = .cancelled
    }

    // MARK: - Progress polling

    private func startPollingProgress() {
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
