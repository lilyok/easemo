import AVFoundation
import CoreMedia
import Foundation

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
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameCount = max(1, Int(seconds * Double(fps)))
        let timescale = CMTimeScale(fps)
        for i in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault,
                                Int(size.width), Int(size.height),
                                kCVPixelFormatType_32BGRA,
                                pixelAttributes as CFDictionary,
                                &pixelBuffer)
            guard let pb = pixelBuffer else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                memset(base, 0, CVPixelBufferGetDataSize(pb))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: timescale))
        }
        input.markAsFinished()
        await writer.finishWriting()
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
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let chunkSamples: UInt32 = 1024
        let totalSamples = UInt32(seconds * sampleRate)
        var produced: UInt32 = 0
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
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                        asbd: &asbd,
                                        layoutSize: 0,
                                        layout: nil,
                                        magicCookieSize: 0,
                                        magicCookie: nil,
                                        extensions: nil,
                                        formatDescriptionOut: &formatDescription)
        guard let format = formatDescription else { return url }

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
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                memoryBlock: memory,
                                                blockLength: dataSize,
                                                blockAllocator: kCFAllocatorMalloc,
                                                customBlockSource: nil,
                                                offsetToData: 0,
                                                dataLength: dataSize,
                                                flags: 0,
                                                blockBufferOut: &blockBuffer)
            guard let bb = blockBuffer else {
                if let memory = memory { free(memory) }
                produced += frames
                continue
            }
            var sampleBuffer: CMSampleBuffer?
            let pts = CMTime(value: CMTimeValue(produced), timescale: CMTimeScale(sampleRate))
            var timing = CMSampleTimingInfo(duration: CMTime(value: CMTimeValue(frames),
                                                             timescale: CMTimeScale(sampleRate)),
                                             presentationTimeStamp: pts,
                                             decodeTimeStamp: .invalid)
            var sampleSizeArray: [Int] = [Int(bytesPerFrame)]
            CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                       dataBuffer: bb,
                                       formatDescription: format,
                                       sampleCount: CMItemCount(frames),
                                       sampleTimingEntryCount: 1,
                                       sampleTimingArray: &timing,
                                       sampleSizeEntryCount: 1,
                                       sampleSizeArray: &sampleSizeArray,
                                       sampleBufferOut: &sampleBuffer)
            if let sb = sampleBuffer {
                input.append(sb)
            }
            produced += frames
        }

        input.markAsFinished()
        await writer.finishWriting()
        return url
    }
}
