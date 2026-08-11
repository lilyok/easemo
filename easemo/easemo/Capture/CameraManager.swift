import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import Foundation

/// `CameraManager` owns an `AVCaptureSession` configured with the default
/// front-facing webcam, runs a live preview, and (when recording) writes
/// frames out to an MP4 file via `SampleBufferWriter`.
///
/// The class exposes its `AVCaptureSession` so a `NSViewRepresentable` can
/// attach an `AVCaptureVideoPreviewLayer` for the live preview.
@MainActor
public final class CameraManager: NSObject, ObservableObject {

    public enum State: Equatable {
        case idle
        case preview
        case recording
    }

    public enum CameraError: LocalizedError {
        case noDeviceAvailable
        case permissionDenied
        case underlying(String)

        public var errorDescription: String? {
            switch self {
            case .noDeviceAvailable:
                return "No camera was found on this Mac."
            case .permissionDenied:
                return "Camera permission was denied. Enable it in System Settings → Privacy & Security → Camera."
            case .underlying(let message):
                return message
            }
        }
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var lastError: CameraError?
    @Published public private(set) var resolution: CGSize = .zero
    /// When true, live preview (recording screen + floating HUD) runs Vision blur on throttled frames.
    @Published public private(set) var blurBackgroundEnabled = false
    /// Latest blurred frame for live preview; nil until the first Vision pass completes.
    @Published public private(set) var liveBlurPreviewPixelBuffer: CVPixelBuffer?

    /// Underlying capture session for SwiftUI preview.
    public let session = AVCaptureSession()

    private let sampleQueue = DispatchQueue(label: "easemo.camera.samples")
    private var deviceInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let outputDirectory: URL

    /// Sample handler that owns the writer for a single recording.
    /// `sampleHandlerRef` is a thread-safe holder so the capture queue can
    /// read it without bouncing to the main actor for every frame.
    nonisolated private let sampleHandlerRef = LockedRef<CameraSampleHandler>()
    nonisolated private let liveBlurProcessorRef = LockedRef<CameraLiveBackgroundBlurProcessor>()
    private(set) public var startTime: CMTime = .zero
    private(set) public var lastRecordingURL: URL?
    private var activeRecordingURL: URL?

    nonisolated public init(outputDirectory: URL = FileManager.default.temporaryDirectory) {
        self.outputDirectory = outputDirectory
        super.init()
    }

    // MARK: Permissions

    /// Request camera permission. Returns true if access is authorized.
    public func requestAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: Preview lifecycle

    /// Configure the capture session and start the live preview. Safe to call
    /// repeatedly — successive calls are no-ops once the session is wired.
    public func startPreview() async throws {
        if state != .idle { return }

        guard await requestAuthorization() else {
            lastError = .permissionDenied
            throw CameraError.permissionDenied
        }

        do {
            try configureSession()
        } catch let error as CameraError {
            lastError = error
            throw error
        } catch {
            let mapped = CameraError.underlying(error.localizedDescription)
            lastError = mapped
            throw mapped
        }

        await Task.detached { [session] in
            session.startRunning()
        }.value
        state = .preview
    }

    public func stopPreview() {
        setBlurBackgroundEnabled(false)
        guard session.isRunning else { return }
        session.stopRunning()
        if state == .preview { state = .idle }
    }

    /// Enables or disables Vision-based background blur for **live** preview only (does not change the recorded camera file).
    public func setBlurBackgroundEnabled(_ enabled: Bool) {
        blurBackgroundEnabled = enabled
        if !enabled {
            liveBlurProcessorRef.value = nil
            liveBlurPreviewPixelBuffer = nil
        } else if liveBlurProcessorRef.value == nil {
            liveBlurProcessorRef.value = CameraLiveBackgroundBlurProcessor { [weak self] buffer in
                Task { @MainActor in
                    self?.liveBlurPreviewPixelBuffer = buffer
                }
            }
        }
    }

    // MARK: Recording lifecycle

    /// Start writing camera frames to disk. The session must already be
    /// running (`startPreview()` first).
    @discardableResult
    public func startRecording(frameRate: Int = 30) throws -> URL {
        guard state == .preview else {
            throw CameraError.underlying("Camera is not previewing — call startPreview() first.")
        }
        let url = outputDirectory.appendingPathComponent("easemo-camera-\(UUID().uuidString).mp4")
        let size = resolution == .zero ? CGSize(width: 1280, height: 720) : resolution
        let writer = try SampleBufferWriter(url: url, size: size, frameRate: frameRate)
        let weakSelf = WeakSelf(self)
        let handler = CameraSampleHandler(writer: writer) { [weakSelf] pts in
            Task { @MainActor in weakSelf.value?.startTime = pts }
        } errorHandler: { [weakSelf] message in
            Task { @MainActor in weakSelf.value?.lastError = .underlying(message) }
        }
        sampleHandlerRef.value = handler
        state = .recording
        activeRecordingURL = url
        return url
    }

    @discardableResult
    public func stopRecording() async throws -> URL {
        guard state == .recording, let handler = sampleHandlerRef.value else {
            if let fallbackURL = activeRecordingURL {
                lastRecordingURL = fallbackURL
                activeRecordingURL = nil
                return fallbackURL
            }
            throw CameraError.underlying("Camera is not recording.")
        }
        state = .preview
        sampleHandlerRef.value = nil
        // A delegate callback may have loaded the old handler immediately
        // before the reference was cleared. Wait for that callback to leave
        // the serial sample queue before finalizing its writer.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sampleQueue.async {
                continuation.resume()
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            handler.writer.finish { result in
                Task { @MainActor in
                    switch result {
                    case .success(let url):
                        self.lastRecordingURL = url
                        self.activeRecordingURL = nil
                        continuation.resume(returning: url)
                    case .failure(let error):
                        if let fallbackURL = self.activeRecordingURL {
                            self.lastRecordingURL = fallbackURL
                            self.activeRecordingURL = nil
                            continuation.resume(returning: fallbackURL)
                        } else {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }

    // MARK: Private

    private func configureSession() throws {
        if deviceInput != nil { return }
        let discoveredDevice: AVCaptureDevice? = {
            if let primary = AVCaptureDevice.default(for: .video) { return primary }
            var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
            if #available(macOS 14.0, *) {
                deviceTypes.append(.external)
            }
            let session = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes,
                                                           mediaType: .video,
                                                           position: .unspecified)
            return session.devices.first
        }()
        guard let device = discoveredDevice else { throw CameraError.noDeviceAvailable }

        session.beginConfiguration()
        session.sessionPreset = .high

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.underlying("Capture session refused the camera input.")
        }
        session.addInput(input)
        self.deviceInput = input

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraError.underlying("Capture session refused the video output.")
        }
        session.addOutput(output)
        self.videoOutput = output

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        if dims.width > 0, dims.height > 0 {
            resolution = CGSize(width: Int(dims.width), height: Int(dims.height))
        }

        session.commitConfiguration()
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    /// `AVCaptureVideoDataOutput` calls this delegate method on `sampleQueue`
    /// — a serial dispatch queue — for every frame. The hot path must not
    /// block the main actor, so we read the lock-protected handler reference
    /// directly and forward to it. The handler instance itself is only ever
    /// mutated on the same `sampleQueue`, which guarantees ordered access to
    /// its writer and first-frame state.
    public nonisolated func captureOutput(_ output: AVCaptureOutput,
                                          didOutput sampleBuffer: CMSampleBuffer,
                                          from connection: AVCaptureConnection) {
        sampleHandlerRef.value?.handle(sampleBuffer)

        if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            liveBlurProcessorRef.value?.enqueuePixelBufferIfNeeded(buffer)
        }
    }
}

/// Lightweight weak holder used to bridge non-isolated callbacks back to the
/// main actor without retaining the manager.
private final class WeakSelf {
    weak var value: CameraManager?
    init(_ value: CameraManager) { self.value = value }
}

/// Owns mutable per-recording state for the camera pipeline. Lives on the
/// capture queue once installed.
final class CameraSampleHandler {
    let writer: SampleBufferWriter
    private let firstFrameHandler: (CMTime) -> Void
    private let errorHandler: (String) -> Void
    private var firstSampleTime: CMTime?

    init(writer: SampleBufferWriter,
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

/// Lock-protected reference holder. Used so non-isolated callbacks
/// (e.g. an `AVCaptureVideoDataOutputSampleBufferDelegate` running on a
/// dispatch queue) can read a value updated from the main actor.
///
/// **Threading contract.** All access to `_value` is serialised through
/// `lock`; the lock is acquired in the simple non-recursive critical
/// sections of `value`'s getter/setter, never re-entered, and never held
/// while calling out to user code (no callbacks fire under the lock).
/// Because the only state is a single optional reference and the lock is
/// cheap (`NSLock`), we declare `@unchecked Sendable`: writers are exclusive,
/// readers see a consistent snapshot, and there is no shared mutable state
/// outside the lock. If new fields are added, they MUST also be guarded by
/// `lock`, or the `@unchecked Sendable` annotation must be revisited.
final class LockedRef<T: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
