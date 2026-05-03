import AVFoundation
import XCTest
@testable import easemo

/// Validates that `VideoComposer` produces an `AVAudioMix` whose parameters
/// keep audio pitch natural at non-1× speeds, and that the optional mute
/// switch silences audio on the output track.
@MainActor
final class VideoComposerAudioTests: XCTestCase {

    private var screenURL: URL!
    private var audioURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        screenURL = try await TestMediaFixtures.makeSilentVideo(seconds: 1.0)
        audioURL = try await TestMediaFixtures.makeSilentAudio(seconds: 1.0)
    }

    override func tearDown() async throws {
        for url in [screenURL, audioURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        try await super.tearDown()
    }

    func testAudioMixUsesSpectralPitchAlgorithm() async throws {
        let result = RecordingResult(
            screenURL: screenURL,
            cameraURL: nil,
            audioURL: audioURL,
            canvasSize: CGSize(width: 320, height: 240),
            startTime: .zero,
            duration: CMTime(seconds: 1.0, preferredTimescale: 600),
            layout: .default
        )

        let composer = VideoComposer()
        let bundle = try await composer.compose(result: result,
                                                layout: .default,
                                                speed: 2.0,
                                                trimStart: 0,
                                                trimEnd: 1.0)

        let mix = try XCTUnwrap(bundle.audioMix, "Audio mix must be present when audioURL is supplied.")
        let parameters = try XCTUnwrap(mix.inputParameters.first as? AVMutableAudioMixInputParameters)
        XCTAssertEqual(parameters.audioTimePitchAlgorithm, .spectral,
                       "Voice pace must change without changing pitch (no chipmunk effect).")
    }

    func testMuteAudioZeroesVolume() async throws {
        let result = RecordingResult(
            screenURL: screenURL,
            cameraURL: nil,
            audioURL: audioURL,
            canvasSize: CGSize(width: 320, height: 240),
            startTime: .zero,
            duration: CMTime(seconds: 1.0, preferredTimescale: 600),
            layout: .default
        )

        let composer = VideoComposer()
        let bundle = try await composer.compose(result: result,
                                                layout: .default,
                                                speed: 1.0,
                                                trimStart: 0,
                                                trimEnd: 1.0,
                                                muteAudio: true)

        let mix = try XCTUnwrap(bundle.audioMix)
        let parameters = try XCTUnwrap(mix.inputParameters.first as? AVMutableAudioMixInputParameters)
        var volume: Float = -1
        var timeRange: CMTimeRange = .zero
        let hasVolume = parameters.getVolumeRamp(for: .zero,
                                                 startVolume: &volume,
                                                 endVolume: nil,
                                                 timeRange: &timeRange)
        XCTAssertTrue(hasVolume, "Mute should install a volume ramp at t=0.")
        XCTAssertEqual(volume, 0.0, accuracy: 0.0001)
    }

    func testNoAudioMixWhenAudioURLIsNil() async throws {
        let result = RecordingResult(
            screenURL: screenURL,
            cameraURL: nil,
            audioURL: nil,
            canvasSize: CGSize(width: 320, height: 240),
            startTime: .zero,
            duration: CMTime(seconds: 1.0, preferredTimescale: 600),
            layout: .default
        )

        let composer = VideoComposer()
        let bundle = try await composer.compose(result: result,
                                                layout: .default,
                                                speed: 1.5,
                                                trimStart: 0,
                                                trimEnd: 1.0)
        XCTAssertNil(bundle.audioMix)
    }
}
