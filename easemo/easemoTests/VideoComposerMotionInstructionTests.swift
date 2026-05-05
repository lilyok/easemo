import AVFoundation
import CoreMedia
import XCTest
@testable import easemo

/// Ensures we use a **static** overlay instruction when motion keyframes do not
/// change layout — avoids unnecessary `motionTimeline` compositing for the
/// common “fixed rectangle PiP” case.
@MainActor
final class VideoComposerMotionInstructionTests: XCTestCase {

    private var screenURL: URL?
    private var cameraURL: URL?

    override func setUp() async throws {
        try await super.setUp()
        screenURL = try await TestMediaFixtures.makeSilentVideo(seconds: 0.5)
        cameraURL = try await TestMediaFixtures.makeSilentVideo(seconds: 0.5)
    }

    override func tearDown() async throws {
        for url in [screenURL, cameraURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        screenURL = nil
        cameraURL = nil
        try await super.tearDown()
    }

    func testConstantMotionKeyframesUseStaticOverlayInstruction() async throws {
        let screenURL = try XCTUnwrap(screenURL)
        let cameraURL = try XCTUnwrap(cameraURL)
        let rectLayout = OverlayLayout(widthFraction: 0.2,
                                       edgeInset: 16,
                                       position: .bottomRight,
                                       shape: .rectangle)
        let motion: [OverlayLayoutKeyframe] = [
            OverlayLayoutKeyframe(timeSeconds: 0, layout: rectLayout),
            OverlayLayoutKeyframe(timeSeconds: 0.2, layout: rectLayout)
        ]
        let result = RecordingResult(
            screenURL: screenURL,
            cameraURL: cameraURL,
            audioURL: nil,
            canvasSize: CGSize(width: 320, height: 240),
            startTime: .zero,
            duration: CMTime(seconds: 0.5, preferredTimescale: 600),
            layout: rectLayout,
            overlayMotion: motion
        )

        let bundle = try await VideoComposer().compose(
            result: result,
            layout: rectLayout,
            speed: 1.0,
            trimStart: 0,
            trimEnd: 0.5
        )

        let instructions = bundle.videoComposition.instructions
        XCTAssertEqual(instructions.count, 1)
        let first = try XCTUnwrap(instructions.first as? OverlayInstruction)
        XCTAssertNil(first.motionTimeline, "Constant PiP layout should not use motion timeline.")
        XCTAssertEqual(first.shape, .rectangle)
    }

    func testConstantMotionKeyframesUseKeyframeLayoutWhenComposeLayoutDiffers() async throws {
        let screenURL = try XCTUnwrap(screenURL)
        let cameraURL = try XCTUnwrap(cameraURL)
        let keyframeLayout = OverlayLayout(widthFraction: 0.2,
                                           edgeInset: 16,
                                           position: .bottomRight,
                                           shape: .rectangle)
        let composeParameterLayout = OverlayLayout(widthFraction: 0.2,
                                                   edgeInset: 16,
                                                   position: .bottomLeft,
                                                   shape: .rectangle)
        let motion: [OverlayLayoutKeyframe] = [
            OverlayLayoutKeyframe(timeSeconds: 0, layout: keyframeLayout),
            OverlayLayoutKeyframe(timeSeconds: 0.2, layout: keyframeLayout)
        ]
        let result = RecordingResult(
            screenURL: screenURL,
            cameraURL: cameraURL,
            audioURL: nil,
            canvasSize: CGSize(width: 320, height: 240),
            startTime: .zero,
            duration: CMTime(seconds: 0.5, preferredTimescale: 600),
            layout: composeParameterLayout,
            overlayMotion: motion
        )

        let bundle = try await VideoComposer().compose(
            result: result,
            layout: composeParameterLayout,
            speed: 1.0,
            trimStart: 0,
            trimEnd: 0.5
        )

        let instructions = bundle.videoComposition.instructions
        XCTAssertEqual(instructions.count, 1)
        let first = try XCTUnwrap(instructions.first as? OverlayInstruction)
        XCTAssertNil(first.motionTimeline)
        let expectedFrame = keyframeLayout.frame(in: bundle.renderSize, cameraAspect: 16.0 / 9.0)
        XCTAssertEqual(first.cameraFrame, expectedFrame)
        XCTAssertEqual(first.shape, keyframeLayout.shape)
    }
}
