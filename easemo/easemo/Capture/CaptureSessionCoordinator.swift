import AVFoundation
import Combine
import CoreMedia
import Foundation

/// `CaptureSessionCoordinator` orchestrates the screen and camera capture
/// pipelines as a single unit.
///
/// Responsibilities:
/// - Start both `RecordingManager` and `CameraManager` so they share a
///   common wall-clock origin (best-effort: ScreenCaptureKit and
///   AVCaptureSession use independent clocks; we record both `startTime`
///   values and let the composer align them at composition time).
/// - Stop both pipelines and bundle their outputs in a `RecordingResult`.
/// - Expose a single elapsed-time publisher for the UI.
@MainActor
public final class CaptureSessionCoordinator: ObservableObject {

    public enum CoordinatorError: LocalizedError {
        case alreadyRunning
        case notRunning
        case underlying(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "A capture session is already running."
            case .notRunning:     return "No capture session is currently running."
            case .underlying(let message): return message
            }
        }
    }

    @Published public private(set) var isRecording = false
    @Published public private(set) var elapsedSeconds: TimeInterval = 0
    @Published public private(set) var lastResult: RecordingResult?
    @Published public private(set) var lastErrorMessage: String?

    public let recordingManager: RecordingManager
    public let cameraManager: CameraManager

    private var configuration: RecordingConfiguration = .init()
    private var timer: Timer?
    private var startWallClock: Date?

    public init(recordingManager: RecordingManager = RecordingManager(),
                cameraManager: CameraManager = CameraManager()) {
        self.recordingManager = recordingManager
        self.cameraManager = cameraManager
    }

    // MARK: Public API

    /// Start screen + (optional) camera recording.
    public func start(configuration: RecordingConfiguration) async throws {
        guard !isRecording else { throw CoordinatorError.alreadyRunning }
        self.configuration = configuration
        lastErrorMessage = nil

        if configuration.includeCamera {
            try await cameraManager.startPreview()
        }

        // Start screen first because it tends to take longer (permission
        // dialog, content discovery). Once it is running, kick off the
        // camera writer immediately so their start timestamps are close.
        _ = try await recordingManager.startRecording(frameRate: configuration.screenFrameRate)
        if configuration.includeCamera {
            _ = try cameraManager.startRecording(frameRate: configuration.cameraFrameRate)
        }

        startWallClock = Date()
        isRecording = true
        startTimer()
    }

    /// Stop both pipelines and return the produced `RecordingResult`.
    @discardableResult
    public func stop() async throws -> RecordingResult {
        guard isRecording else { throw CoordinatorError.notRunning }
        stopTimer()
        isRecording = false

        let cameraURL: URL?
        if configuration.includeCamera, cameraManager.state == .recording {
            cameraURL = try? await cameraManager.stopRecording()
        } else {
            cameraURL = nil
        }
        let screenURL = try await recordingManager.stopRecording()

        if configuration.includeCamera {
            cameraManager.stopPreview()
        }

        let duration = CMTime(seconds: elapsedSeconds, preferredTimescale: 600)
        let result = RecordingResult(
            screenURL: screenURL,
            cameraURL: cameraURL,
            canvasSize: recordingManager.canvasSize,
            startTime: recordingManager.startTime,
            duration: duration,
            layout: configuration.overlay
        )
        lastResult = result
        return result
    }

    // MARK: Helpers

    private func startTimer() {
        elapsedSeconds = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let start = self.startWallClock else { return }
                self.elapsedSeconds = Date().timeIntervalSince(start)
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
