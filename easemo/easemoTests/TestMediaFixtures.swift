import AVFoundation
import CoreMedia
import Foundation

/// Errors thrown from synthesised media fixtures so that a failure in the
/// fixture itself surfaces as a clear test failure instead of an unrelated
/// runtime trap or a silently-empty asset that breaks downstream
/// expectations.
enum TestMediaFixtureError: LocalizedError {
    case formatDescriptionCreationFailed(OSStatus)
    case blockBufferCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case pixelBufferCreationFailed(CVReturn)
    case noFramesProduced
    case writerStartFailed(message: String)
    case writerFinishFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .formatDescriptionCreationFailed(let status):
            return "CMAudioFormatDescriptionCreate failed (\(status))."
        case .blockBufferCreationFailed(let status):
            return "CMBlockBufferCreateWithMemoryBlock failed (\(status))."
        case .sampleBufferCreationFailed(let status):
            return "CMSampleBufferCreateReady failed (\(status))."
        case .pixelBufferCreationFailed(let status):
            return "CVPixelBufferCreate failed (\(status))."
        case .noFramesProduced:
            return "Fixture finished without appending any frames."
        case .writerStartFailed(let message):
            return "AVAssetWriter.startWriting failed: \(message)."
        case .writerFinishFailed(let message):
            return "AVAssetWriter.finishWriting did not complete: \(message)."
        }
    }
}

/// Synthesised media files for unit tests. These avoid the need to ship
/// binary fixtures in the repository and avoid relying on the real screen
/// or microphone capture pipelines (which the test runner cannot exercise).
enum TestMediaFixtures {

    static func makeSilentVideo(seconds: Double,
                                size: CGSize = CGSize(width: 320, height: 240),
                                fps: Int = 10) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("easemo-test-screen-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let pixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: pixelAttributes)
        writer.add(input)
        guard writer.startWriting() else {
            throw TestMediaFixtureError.writerStartFailed(
                message: writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = max(1, Int(seconds * Double(fps)))
        let timescale = CMTimeScale(fps)
        var appendedFrames = 0
        for i in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var pixelBuffer: CVPixelBuffer?
            let pbStatus = CVPixelBufferCreate(kCFAllocatorDefault,
                                               Int(size.width), Int(size.height),
                                               kCVPixelFormatType_32BGRA,
                                               pixelAttributes as CFDictionary,
                                               &pixelBuffer)
            guard pbStatus == kCVReturnSuccess, let pb = pixelBuffer else {
                throw TestMediaFixtureError.pixelBufferCreationFailed(pbStatus)
            }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                memset(base, 0, CVPixelBufferGetDataSize(pb))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: timescale))
            appendedFrames += 1
        }
        // Belt-and-braces: surface the unlikely "writer finished but the
        // track is empty" case rather than handing back a 0-frame asset
        // that downstream tests would treat as legitimate.
        guard appendedFrames > 0 else {
            input.markAsFinished()
            await writer.finishWriting()
            throw TestMediaFixtureError.noFramesProduced
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw TestMediaFixtureError.writerFinishFailed(
                message: writer.error?.localizedDescription ?? "status=\(writer.status.rawValue)")
        }
        return url
    }

    static func makeSilentAudio(seconds: Double,
                                sampleRate: Double = 44_100) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("easemo-test-audio-\(UUID().uuidString).m4a")
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: 64_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        // Build the source format description **before** starting the writer:
        // if format-description creation fails, we want to throw without
        // leaving a half-initialised writer behind on disk.
        let bytesPerFrame: UInt32 = 2 // 16-bit mono PCM source
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let format = formatDescription else {
            throw TestMediaFixtureError.formatDescriptionCreationFailed(formatStatus)
        }

        guard writer.startWriting() else {
            throw TestMediaFixtureError.writerStartFailed(
                message: writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let chunkSamples: UInt32 = 1024
        let totalSamples = UInt32(seconds * sampleRate)
        var produced: UInt32 = 0

        while produced < totalSamples {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let frames = min(chunkSamples, totalSamples - produced)
            let dataSize = Int(frames * bytesPerFrame)
            // Allocate the audio data on the heap and let the block buffer
            // free it via the default block allocator. Using `Data` here
            // would be unsafe because its storage can be released as soon
            // as the closure returns, while CMBlockBuffer keeps a raw
            // pointer to those bytes.
            let memory = malloc(dataSize)
            if let memory = memory {
                memset(memory, 0, dataSize)
            }
            var blockBuffer: CMBlockBuffer?
            let blockStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: memory,
                blockLength: dataSize,
                blockAllocator: kCFAllocatorMalloc,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataSize,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            guard blockStatus == noErr, let bb = blockBuffer else {
                if let memory = memory { free(memory) }
                throw TestMediaFixtureError.blockBufferCreationFailed(blockStatus)
            }
            var sampleBuffer: CMSampleBuffer?
            let pts = CMTime(value: CMTimeValue(produced), timescale: CMTimeScale(sampleRate))
            var timing = CMSampleTimingInfo(duration: CMTime(value: CMTimeValue(frames),
                                                             timescale: CMTimeScale(sampleRate)),
                                             presentationTimeStamp: pts,
                                             decodeTimeStamp: .invalid)
            var sampleSizeArray: [Int] = [Int(bytesPerFrame)]
            let sampleStatus = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: bb,
                formatDescription: format,
                sampleCount: CMItemCount(frames),
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSizeArray,
                sampleBufferOut: &sampleBuffer
            )
            guard sampleStatus == noErr, let sb = sampleBuffer else {
                throw TestMediaFixtureError.sampleBufferCreationFailed(sampleStatus)
            }
            input.append(sb)
            produced += frames
        }

        input.markAsFinished()
        await writer.finishWriting()

        // Final-status check: an early bail or a mid-write failure inside
        // AVFoundation can leave us with a 0-byte file. Fail loudly so
        // callers get a useful error rather than a flaky empty asset.
        guard writer.status == .completed else {
            throw TestMediaFixtureError.writerFinishFailed(
                message: writer.error?.localizedDescription ?? "status=\(writer.status.rawValue)")
        }
        return url
    }
}
