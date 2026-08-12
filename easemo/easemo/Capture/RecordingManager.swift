import AVFoundation
import Combine
import CoreMedia
import CoreGraphics
import Foundation
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

/// `RecordingManager` is responsible for the **screen** portion of a capture
/// session.
///
/// Pipeline:
/// 1. Discover shareable content (`SCShareableContent`) and pick a display.
/// 2. Build an `SCContentFilter` for that display and an `SCStreamConfiguration`
///    matching the requested frame rate.
/// 3. Create an `SCStream`, attach a `SCStreamOutput` and forward video
///    `CMSampleBuffer`s to a `SampleBufferWriter` that writes an MP4 file.
/// 4. On stop, finalize the writer and surface the produced file URL.
///
/// The manager is intentionally agnostic of UI state — it exposes simple
/// publishers (`isRecording`, `lastError`) that a view-model can observe.
@MainActor
public final class RecordingManager: NSObject, ObservableObject {

    public enum State: Equatable {
        case idle
        case preparing
        case recording
        case stopping
    }

    public enum RecordingError: LocalizedError {
        case noDisplayAvailable
        case permissionDenied
        case alreadyRunning
        case underlying(String)

        public var errorDescription: String? {
            switch self {
            case .noDisplayAvailable:
                return "No display is available for capture."
            case .permissionDenied:
                return "Screen recording permission was denied. Enable it in System Settings → Privacy & Security → Screen Recording."
            case .alreadyRunning:
                return "A recording is already in progress."
            case .underlying(let message):
                return message
            }
        }
    }

    // MARK: Published state

    @Published public private(set) var state: State = .idle
    @Published public private(set) var lastError: RecordingError?
    @Published public private(set) var canvasSize: CGSize = .zero
    @Published public private(set) var startTime: CMTime = .zero

    public var isRecording: Bool { state == .recording }

    // MARK: Internals

    private let outputDirectory: URL
    private let outputQueue = DispatchQueue(label: "easemo.recording.output")

    #if canImport(ScreenCaptureKit)
    private var stream: SCStream?
    private var streamOutput: ScreenStreamOutput?
    #endif

    nonisolated public init(outputDirectory: URL = FileManager.default.temporaryDirectory) {
        self.outputDirectory = outputDirectory
        super.init()
    }

    // MARK: Public API

    /// Begin recording the main display.
    /// - Parameter frameRate: Target frames per second.
    /// - Returns: The URL the screen recording is being written to.
    @discardableResult
    public func startRecording(frameRate: Int = 30) async throws -> URL {
        guard state == .idle else { throw RecordingError.alreadyRunning }
        state = .preparing
        lastError = nil

        #if canImport(ScreenCaptureKit)
        do {
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                throw RecordingError.permissionDenied
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                               onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                state = .idle
                throw RecordingError.noDisplayAvailable
            }

            // Exclude our own app entirely from screen capture whenever possible.
            // Floating panels (PiP webcam) sometimes do not appear in `content.windows`
            // with correct ownership — then excluding window IDs alone still records the
            // PiP, and export composites the camera again → duplicated face in output.
            let filter: SCContentFilter
            if let bundleIdentifier = Bundle.main.bundleIdentifier,
               let ownApp = content.applications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                filter = SCContentFilter(display: display,
                                         excludingApplications: [ownApp],
                                         exceptingWindows: [])
            } else if let bundleIdentifier = Bundle.main.bundleIdentifier {
                let ownWindows = content.windows.filter { window in
                    window.owningApplication?.bundleIdentifier == bundleIdentifier
                }
                filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            } else {
                filter = SCContentFilter(display: display, excludingWindows: [])
            }
            let config = SCStreamConfiguration()
            let scale = Int(NSScreen.main?.backingScaleFactor ?? 1)
            config.width = display.width * scale
            config.height = display.height * scale
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            config.queueDepth = 6
            config.showsCursor = true
            config.pixelFormat = kCVPixelFormatType_32BGRA

            let size = CGSize(width: config.width, height: config.height)
            let url = outputDirectory.appendingPathComponent("easemo-screen-\(UUID().uuidString).mp4")
            let writer = try SampleBufferWriter(url: url, size: size, frameRate: frameRate)
            self.canvasSize = size

            let weakSelf = WeakBox(self)
            let output = ScreenStreamOutput(writer: writer) { [weakSelf] firstPTS in
                Task { @MainActor in
                    weakSelf.value?.startTime = firstPTS
                }
            } errorHandler: { [weakSelf] message in
                Task { @MainActor in
                    weakSelf.value?.lastError = .underlying(message)
                }
            }
            self.streamOutput = output

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: outputQueue)
            self.stream = stream

            try await stream.startCapture()
            state = .recording
            return url
        } catch let error as RecordingError {
            state = .idle
            lastError = error
            throw error
        } catch {
            state = .idle
            // ScreenCaptureKit surfaces permission errors through generic
            // NSError; mapping is best-effort.
            let nsError = error as NSError
            let isPermission = (nsError.code == -3801)
                || nsError.localizedDescription.localizedCaseInsensitiveContains("permission")
            let mapped: RecordingError = isPermission
                ? .permissionDenied
                : .underlying(error.localizedDescription)
            lastError = mapped
            throw mapped
        }
        #else
        state = .idle
        throw RecordingError.underlying("ScreenCaptureKit is unavailable on this platform.")
        #endif
    }

    /// Stop the recording and finalize the file. The returned URL is the same
    /// URL returned by `startRecording`.
    @discardableResult
    public func stopRecording() async throws -> URL {
        guard state == .recording else {
            #if canImport(ScreenCaptureKit)
            if let url = streamOutput?.writer.url { return url }
            #endif
            throw RecordingError.underlying("No active recording.")
        }
        state = .stopping

        #if canImport(ScreenCaptureKit)
        if let stream = stream {
            do { try await stream.stopCapture() } catch {
                lastError = .underlying(error.localizedDescription)
            }
        }
        let output = streamOutput
        stream = nil
        streamOutput = nil
        // `stopCapture()` can return while a final delegate callback is
        // already queued. Drain that queue before marking the writer input
        // finished so no sample can be appended during finalization.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            outputQueue.async {
                continuation.resume()
            }
        }
        #endif

        #if canImport(ScreenCaptureKit)
        return try await withCheckedThrowingContinuation { continuation in
            guard let writer = output?.writer else {
                continuation.resume(throwing: RecordingError.underlying("Writer missing"))
                Task { @MainActor in self.state = .idle }
                return
            }
            writer.finish { result in
                Task { @MainActor in
                    self.state = .idle
                    switch result {
                    case .success(let url):
                        continuation.resume(returning: url)
                    case .failure(let error):
                        self.lastError = .underlying(error.localizedDescription)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        #else
        state = .idle
        throw RecordingError.underlying("ScreenCaptureKit unavailable.")
        #endif
    }
}

/// Lightweight weak holder used to bridge non-isolated callbacks back to the
/// main actor without retaining the manager.
private final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

#if canImport(ScreenCaptureKit)
/// Owns the per-recording mutable state (writer, first-sample timestamp) and
/// exposes a non-isolated callback path for `SCStream`.
final class ScreenStreamOutput: NSObject, SCStreamOutput {
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

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let info = attachments.first,
           let statusRaw = info[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstSampleTime == nil {
            firstSampleTime = pts
            do { try writer.start(at: pts) }
            catch {
                errorHandler(error.localizedDescription)
                return
            }
            firstFrameHandler(pts)
        }
        writer.append(sampleBuffer)
    }
}
#endif
