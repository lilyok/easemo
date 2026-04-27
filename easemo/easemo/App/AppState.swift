import Combine
import Foundation
import SwiftUI

/// Top-level routes that the root view switches between.
public enum AppRoute: Equatable {
    case recording
    case editing(RecordingResult)
}

/// Single source of truth for the running app.
///
/// `AppState` owns the long-lived service objects (`CaptureSessionCoordinator`,
/// `VideoComposer`, `ExportManager`) and exposes view-model style state to
/// SwiftUI. View models are kept inside `AppState` rather than per-view
/// `@StateObject`s because the recording session has to survive view
/// transitions (e.g. switching from the recording screen to the editing
/// screen the moment the user clicks "Stop").
@MainActor
public final class AppState: ObservableObject {

    @Published public var route: AppRoute = .recording

    /// Capture configuration the user has set on the recording screen.
    @Published public var configuration: RecordingConfiguration = .init()

    /// Live overlay layout (mirrors `configuration.overlay` so SwiftUI can
    /// bind to a single property for previews).
    @Published public var overlay: OverlayLayout = .default {
        didSet { configuration.overlay = overlay }
    }

    /// Playback speed selected on the editing screen.
    @Published public var playbackSpeed: Double = 1.0

    /// Status string shown in the UI (recording timer / export progress).
    @Published public var statusMessage: String = ""

    /// User-facing error to surface in the UI.
    @Published public var errorMessage: String?

    public let coordinator: CaptureSessionCoordinator
    public let composer: VideoComposer
    public let exportManager: ExportManager

    private var cancellables = Set<AnyCancellable>()

    public init(coordinator: CaptureSessionCoordinator = CaptureSessionCoordinator(),
                composer: VideoComposer = VideoComposer(),
                exportManager: ExportManager = ExportManager()) {
        self.coordinator = coordinator
        self.composer = composer
        self.exportManager = exportManager

        coordinator.$elapsedSeconds
            .sink { [weak self] seconds in
                guard let self = self, self.coordinator.isRecording else { return }
                self.statusMessage = Self.formatElapsed(seconds)
            }
            .store(in: &cancellables)

        exportManager.$progress
            .sink { [weak self] progress in
                guard let self = self else { return }
                if case .exporting = self.exportManager.state {
                    self.statusMessage = String(format: "Exporting… %d%%", Int(progress * 100))
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Recording flow

    public func startRecording() async {
        do {
            errorMessage = nil
            statusMessage = "Preparing…"
            try await coordinator.start(configuration: configuration)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = ""
        }
    }

    public func stopRecording() async {
        do {
            let result = try await coordinator.stop()
            statusMessage = "Recording finished — \(Self.formatElapsed(result.duration.seconds))"
            playbackSpeed = 1.0
            overlay = result.layout
            route = .editing(result)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Editing → Export flow

    public func export(result: RecordingResult, to destination: URL) async {
        do {
            errorMessage = nil
            statusMessage = "Composing…"
            let bundle = try await composer.compose(result: result,
                                                    layout: overlay,
                                                    speed: playbackSpeed)
            statusMessage = "Exporting…"
            _ = try await exportManager.export(bundle: bundle, to: destination)
            statusMessage = "Saved to \(destination.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = ""
        }
    }

    public func backToRecording() {
        route = .recording
        statusMessage = ""
    }

    // MARK: Helpers

    public static func formatElapsed(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
