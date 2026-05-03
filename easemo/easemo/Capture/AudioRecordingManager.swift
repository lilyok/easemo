import AVFoundation
import Combine
import CoreMedia
import Foundation

/// `AudioRecordingManager` captures microphone audio into a standalone `.m4a`
/// file. It runs on its own `AVCaptureSession` (separate from the camera
/// session) so audio can be enabled/disabled independently and the camera
/// preview keeps running uninterrupted.
///
/// The pipeline:
/// 1. Pick the default audio input device (usually the built-in mic).
/// 2. Wire it into an `AVCaptureSession` with an `AVCaptureAudioDataOutput`.
/// 3. Forward sample buffers to an `AudioSampleWriter`.
/// 4. On stop, finalize the writer and surface the produced URL.
@MainActor
public final class AudioRecordingManager: NSObject, ObservableObject {

    public enum State: Equatable {
        case idle
        case ready
        case recording
    }

    public enum AudioError: LocalizedError {
        case noDeviceAvailable
        case permissionDenied
        case underlying(String)

        public var errorDescription: String? {
            switch self {
            case .noDeviceAvailable:
                return "No microphone was found on this Mac."
            case .permissionDenied:
                return "Microphone permission was denied. Enable it in System Settings → Privacy & Security → Microphone."
            case .underlying(let message):
                return message
            }
        }
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var lastError: AudioError?

    public let session = AVCaptureSession()

    private let outputDirectory: URL
    private let sampleQueue = DispatchQueue(label: "easemo.audio.samples")
    private var deviceInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?

    /// Per-recording handler that owns the writer; reads on the capture
    /// queue, writes from the main actor — guarded by a small lock.
    nonisolated private let sampleHandlerRef = LockedRef<AudioSampleHandler>()
    private(set) public var startTime: CMTime = .zero

    public init(outputDirectory: URL = FileManager.default.temporaryDirectory) {
        self.outputDirectory = outputDirectory
        super.init()
    }

    // MARK: - Permissions

    public func requestAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Lifecycle

    /// Configure the capture session and start it. Must be called before
    /// `startRecording(...)`.
    public func prepare() async throws {
        if state != .idle { return }

        guard await requestAuthorization() else {
            lastError = .permissionDenied
            throw AudioError.permissionDenied
        }

        do {
            try configureSession()
        } catch let error as AudioError {
            lastError = error
            throw error
        } catch {
            let mapped = AudioError.underlying(error.localizedDescription)
            lastError = mapped
            throw mapped
        }

        await Task.detached { [session] in
            session.startRunning()
        }.value
        state = .ready
    }

    public func teardown() {
        if session.isRunning { session.stopRunning() }
        if state == .ready { state = .idle }
    }

    @discardableResult
    public func startRecording() throws -> URL {
        guard state == .ready else {
            throw AudioError.underlying("Audio session is not ready — call prepare() first.")
        }
        let url = outputDirectory.appendingPathComponent("easemo-audio-\(UUID().uuidString).m4a")
        let writer = try AudioSampleWriter(url: url)
        let weakSelf = WeakAudio(self)
        let handler = AudioSampleHandler(writer: writer) { [weakSelf] pts in
            Task { @MainActor in weakSelf.value?.startTime = pts }
        } errorHandler: { [weakSelf] message in
            Task { @MainActor in weakSelf.value?.lastError = .underlying(message) }
        }
        sampleHandlerRef.value = handler
        state = .recording
        return url
    }

    @discardableResult
    public func stopRecording() async throws -> URL {
        guard state == .recording, let handler = sampleHandlerRef.value else {
            throw AudioError.underlying("Audio is not recording.")
        }
        state = .ready
        sampleHandlerRef.value = nil
        return try await withCheckedThrowingContinuation { continuation in
            handler.writer.finish { result in
                Task { @MainActor in
                    switch result {
                    case .success(let url): continuation.resume(returning: url)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - Private

    private func configureSession() throws {
        if deviceInput != nil { return }
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw AudioError.noDeviceAvailable
        }
        session.beginConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw AudioError.underlying("Capture session refused the audio input.")
        }
        session.addInput(input)
        self.deviceInput = input

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw AudioError.underlying("Capture session refused the audio output.")
        }
        session.addOutput(output)
        self.audioOutput = output

        session.commitConfiguration()
    }
}

extension AudioRecordingManager: AVCaptureAudioDataOutputSampleBufferDelegate {
    public nonisolated func captureOutput(_ output: AVCaptureOutput,
                                          didOutput sampleBuffer: CMSampleBuffer,
                                          from connection: AVCaptureConnection) {
        sampleHandlerRef.value?.handle(sampleBuffer)
    }
}

private final class WeakAudio {
    weak var value: AudioRecordingManager?
    init(_ value: AudioRecordingManager) { self.value = value }
}

/// Owns mutable per-recording state for the audio pipeline. Lives on the
/// capture queue once installed.
final class AudioSampleHandler {
    let writer: AudioSampleWriter
    private let firstFrameHandler: (CMTime) -> Void
    private let errorHandler: (String) -> Void
    private var firstSampleTime: CMTime?

    init(writer: AudioSampleWriter,
         firstFrameHandler: @escaping (CMTime) -> Void,
         errorHandler: @escaping (String) -> Void) {
        self.writer = writer
        self.firstFrameHandler = firstFrameHandler
        self.errorHandler = errorHandler
    }

    func handle(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstSampleTime == nil {
            firstSampleTime = pts
            do { try writer.start(at: pts) }
            catch { errorHandler(error.localizedDescription); return }
            firstFrameHandler(pts)
        }
        writer.append(sampleBuffer)
    }
}
