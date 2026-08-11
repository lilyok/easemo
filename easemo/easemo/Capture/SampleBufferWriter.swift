import AVFoundation
import CoreMedia
import Foundation

/// Thin wrapper around `AVAssetWriter` + `AVAssetWriterInput` used by both the
/// screen and camera capture pipelines.
///
/// The writer is intentionally minimal: it appends `CMSampleBuffer`s as they
/// arrive and rebases their presentation timestamps to a shared `start` time
/// so that all tracks for a session share the same zero point. This keeps
/// the post-recording composition logic (`VideoComposer`) trivial.
final class SampleBufferWriter {

    enum WriterError: Error {
        case alreadyStarted
        case notStarted
        case underlying(Error)
        case failed(String)
    }

    /// Output URL of the produced movie file.
    let url: URL

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let queue: DispatchQueue

    private var hasStartedSession = false
    private var lastPresentationTime: CMTime = .zero
    private var isFinishing = false
    private var finishResult: Result<URL, Error>?
    private var finishCompletions: [(Result<URL, Error>) -> Void] = []

    /// Create a writer for the given URL with H.264 video output.
    /// - Parameters:
    ///   - url: Destination file URL. The file must not exist.
    ///   - size: Pixel dimensions of the video track.
    ///   - frameRate: Target nominal frame rate (used for bit-rate hints).
    init(url: URL, size: CGSize, frameRate: Int) throws {
        self.url = url
        self.queue = DispatchQueue(label: "easemo.writer.\(UUID().uuidString)")

        do {
            self.writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw WriterError.underlying(error)
        }

        let bitrate = Int(size.width * size.height * 6) // ~6 bits/pixel base
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        self.videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        self.videoInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput) else {
            throw WriterError.failed("AVAssetWriter cannot add video input")
        }
        writer.add(videoInput)
    }

    /// Begin writing. Must be called exactly once before `append`.
    func start(at time: CMTime) throws {
        try queue.sync {
            guard !hasStartedSession else { throw WriterError.alreadyStarted }
            guard writer.startWriting() else {
                throw WriterError.failed(writer.error?.localizedDescription ?? "startWriting failed")
            }
            writer.startSession(atSourceTime: time)
            hasStartedSession = true
        }
    }

    /// Append one sample to the underlying writer input. Out-of-order samples
    /// (older than the last appended one) are silently dropped to keep the
    /// timeline monotonic — ScreenCaptureKit can occasionally redeliver the
    /// "idle" frame which would otherwise stall the encoder.
    func append(_ sampleBuffer: CMSampleBuffer) {
        queue.sync {
            guard hasStartedSession, !isFinishing else { return }
            guard writer.status == .writing else { return }
            guard videoInput.isReadyForMoreMediaData else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard CMTIME_IS_VALID(pts) else { return }
            if CMTIME_IS_VALID(lastPresentationTime),
               CMTimeCompare(pts, lastPresentationTime) <= 0 {
                return
            }
            videoInput.append(sampleBuffer)
            lastPresentationTime = pts
        }
    }

    /// Finalize the file. Safe to call multiple times and concurrently with
    /// capture callbacks that are still delivering their final samples.
    func finish(_ completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            guard self.hasStartedSession else {
                completion(.failure(WriterError.notStarted))
                return
            }
            if let result = self.finishResult {
                completion(result)
                return
            }

            self.finishCompletions.append(completion)
            guard !self.isFinishing else { return }
            guard self.writer.status == .writing else {
                let result: Result<URL, Error>
                if self.writer.status == .completed {
                    result = .success(self.url)
                } else {
                    result = .failure(
                        WriterError.failed(self.writer.error?.localizedDescription
                            ?? "Cannot finish writer in status \(self.writer.status.rawValue)")
                    )
                }
                self.finishResult = result
                let completions = self.finishCompletions
                self.finishCompletions.removeAll()
                completions.forEach { $0(result) }
                return
            }
            self.isFinishing = true
            self.videoInput.markAsFinished()
            self.writer.finishWriting {
                self.queue.async {
                    let result: Result<URL, Error>
                    if self.writer.status == .completed {
                        result = .success(self.url)
                    } else {
                        result = .failure(
                            WriterError.failed(self.writer.error?.localizedDescription ?? "writer failed")
                        )
                    }
                    self.finishResult = result
                    let completions = self.finishCompletions
                    self.finishCompletions.removeAll()
                    completions.forEach { $0(result) }
                }
            }
        }
    }
}
