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
    /// PiP layout keyed by elapsed recording time so export/preview can reproduce motion during capture.
    private var overlayMotionKeyframes: [OverlayLayoutKeyframe] = []

    @MainActor
    public convenience init() {
        self.init(recordingManager: RecordingManager(),
                  cameraManager: CameraManager())
    }

    @MainActor
    public init(recordingManager: RecordingManager,
                cameraManager: CameraManager) {
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

        overlayMotionKeyframes = [
            OverlayLayoutKeyframe(timeSeconds: 0, layout: configuration.overlay)
        ]

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

    /// Samples current PiP layout while recording (elapsed-time axis). Debounced merges.
    public func recordPiPLayoutSample(_ layout: OverlayLayout) {
        guard isRecording else { return }
        let t = max(0, elapsedSeconds)
        if var last = overlayMotionKeyframes.last, t - last.timeSeconds < 0.075 {
            last = OverlayLayoutKeyframe(timeSeconds: t, layout: layout)
            overlayMotionKeyframes[overlayMotionKeyframes.count - 1] = last
        } else {
            overlayMotionKeyframes.append(OverlayLayoutKeyframe(timeSeconds: t, layout: layout))
        }
    }

    /// Stop both pipelines and return the produced `RecordingResult`.
    ///
    /// - Parameter finalOverlay: Webcam overlay as of **stop time** (`customCenter`, size, shape during recording).
    ///   Recording started with frozen `configuration`, but PiP placement can change while capturing;
    ///   export/preview must use this value, not the initial snapshot.
    @discardableResult
    public func stop(finalOverlay overlay: OverlayLayout) async throws -> RecordingResult {
        guard isRecording else { throw CoordinatorError.notRunning }
        stopTimer()

        recordPiPLayoutSample(overlay)

        let durationSeconds = elapsedSeconds
        let motionKeyframes = consolidateOverlayMotionKeyframes(
            recordingDuration: max(durationSeconds, 0.05),
            finalOverlay: overlay
        )

        isRecording = false

        let cameraURL: URL?
        if configuration.includeCamera, cameraManager.state == .recording {
            do {
                cameraURL = try await cameraManager.stopRecording()
            } catch {
                lastErrorMessage = "Camera overlay could not be finalized: \(error.localizedDescription)"
                cameraURL = cameraManager.lastRecordingURL
            }
        } else {
            cameraURL = nil
        }
        let screenURL = try await recordingManager.stopRecording()

        if configuration.includeCamera {
            cameraManager.stopPreview()
        }

        let duration = CMTime(seconds: durationSeconds, preferredTimescale: 600)
        let result = RecordingResult(
            screenURL: screenURL,
            cameraURL: cameraURL,
            canvasSize: recordingManager.canvasSize,
            startTime: recordingManager.startTime,
            duration: duration,
            layout: overlay,
            overlayMotion: motionKeyframes
        )
        overlayMotionKeyframes.removeAll()
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

    /// Collapse duplicates and freeze the timeline end at recording duration so segments fully cover `[0, D]`.
    private func consolidateOverlayMotionKeyframes(recordingDuration: Double,
                                                   finalOverlay: OverlayLayout) -> [OverlayLayoutKeyframe] {
        let dur = max(recordingDuration, 0.05)
        var keyed = overlayMotionKeyframes
            .sorted { $0.timeSeconds < $1.timeSeconds }
            .map { OverlayLayoutKeyframe(timeSeconds: min(max(0, $0.timeSeconds), dur), layout: $0.layout) }

        guard !keyed.isEmpty else {
            return [
                OverlayLayoutKeyframe(timeSeconds: 0, layout: finalOverlay),
                OverlayLayoutKeyframe(timeSeconds: dur, layout: finalOverlay)
            ]
        }

        var out: [OverlayLayoutKeyframe] = []
        for k in keyed where k.timeSeconds.isFinite {
            guard let last = out.last else {
                out.append(k)
                continue
            }
            if last.layout != k.layout {
                out.append(k)
            }
        }

        if out.first!.timeSeconds > 0.001 {
            out.insert(OverlayLayoutKeyframe(timeSeconds: 0, layout: out.first!.layout), at: 0)
        }

        /// Snap near-end timestamps to `dur` when needed; append a terminal change only when layout differs.
        if let last = out.last {
            if abs(last.timeSeconds - dur) < 1e-3 {
                if last.layout != finalOverlay {
                    out[out.count - 1] = OverlayLayoutKeyframe(timeSeconds: dur, layout: finalOverlay)
                }
            } else if last.timeSeconds < dur && last.layout != finalOverlay {
                out.append(OverlayLayoutKeyframe(timeSeconds: dur, layout: finalOverlay))
            }
        } else {
            out = [
                OverlayLayoutKeyframe(timeSeconds: 0, layout: finalOverlay),
                OverlayLayoutKeyframe(timeSeconds: dur, layout: finalOverlay)
            ]
        }

        return out
    }
}
