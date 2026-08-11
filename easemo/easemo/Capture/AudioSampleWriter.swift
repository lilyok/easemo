import AVFoundation
import CoreMedia
import Foundation

/// AVAssetWriter wrapper specialised for an **audio-only** track.
///
/// Mirrors `SampleBufferWriter`'s shape but emits an `.m4a` file with an
/// AAC-encoded mono/stereo audio track. Kept separate from the video writer
/// so the audio capture pipeline can run independently of the screen and
/// camera writers and so each writer's queue/finalization can be reasoned
/// about in isolation.
final class AudioSampleWriter {

    enum WriterError: Error {
        case alreadyStarted
        case notStarted
        case underlying(Error)
        case failed(String)
    }

    let url: URL

    private let writer: AVAssetWriter
    private let audioInput: AVAssetWriterInput
    private let queue = DispatchQueue(label: "easemo.audio-writer.\(UUID().uuidString)")

    private var hasStartedSession = false
    private var lastPresentationTime: CMTime = .zero
    private var isFinishing = false
    private var finishResult: Result<URL, Error>?
    private var finishCompletions: [(Result<URL, Error>) -> Void] = []

    /// - Parameters:
    ///   - url: Destination `.m4a` file URL. Must not exist.
    ///   - sampleRate: Output sample rate in Hz (defaults to 44.1 kHz).
    ///   - channels: Output channel count (1 or 2).
    init(url: URL, sampleRate: Double = 44_100, channels: Int = 1) throws {
        self.url = url
        do {
            self.writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        } catch {
            throw WriterError.underlying(error)
        }

        var channelLayout = AudioChannelLayout()
        channelLayout.mChannelLayoutTag = (channels == 2) ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono
        let layoutData = Data(bytes: &channelLayout,
                              count: MemoryLayout<AudioChannelLayout>.size)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: channels,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: 128_000,
            AVChannelLayoutKey: layoutData
        ]

        self.audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        self.audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(audioInput) else {
            throw WriterError.failed("AVAssetWriter cannot add audio input")
        }
        writer.add(audioInput)
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

    /// Append one audio sample. Drops out-of-order samples to keep the
    /// timeline strictly monotonic.
    func append(_ sampleBuffer: CMSampleBuffer) {
        queue.sync {
            guard hasStartedSession, !isFinishing else { return }
            guard audioInput.isReadyForMoreMediaData else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard CMTIME_IS_VALID(pts) else { return }
            if CMTIME_IS_VALID(lastPresentationTime),
               CMTimeCompare(pts, lastPresentationTime) < 0 {
                return
            }
            audioInput.append(sampleBuffer)
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
            self.isFinishing = true
            self.audioInput.markAsFinished()
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
