import XCTest
@testable import easemo

/// Verifies the `CompositorError` enum surface so consumers (and any future
/// integration tests around `OverlayVideoCompositor.render(request:)`) can
/// pattern-match on failure modes instead of reading NSError codes.
final class CompositorErrorTests: XCTestCase {

    func testUnexpectedInstructionTypeMessage() {
        XCTAssertEqual(CompositorError.unexpectedInstructionType.errorDescription,
                       "Compositor received an unexpected instruction type.")
    }

    func testRenderContextNilBufferMessage() {
        XCTAssertEqual(CompositorError.renderContextProducedNilBuffer.errorDescription,
                       "Render context returned a nil pixel buffer.")
    }

    func testEnumIsEquatable() {
        XCTAssertEqual(CompositorError.unexpectedInstructionType, .unexpectedInstructionType)
        XCTAssertNotEqual(CompositorError.unexpectedInstructionType, .renderContextProducedNilBuffer)
    }
}
