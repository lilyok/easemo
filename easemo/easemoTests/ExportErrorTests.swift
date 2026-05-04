import XCTest
@testable import easemo

/// Verifies the `ExportError` enum surface so call sites and other tests can
/// pattern-match on failure modes (`if case .alreadyRunning ...`) instead of
/// reading magic NSError codes.
final class ExportErrorTests: XCTestCase {

    func testAlreadyRunningHasUserFacingMessage() {
        let error = ExportError.alreadyRunning
        XCTAssertEqual(error.errorDescription, "An export is already in progress.")
    }

    func testSessionUnavailableMentionsPreset() throws {
        let error = ExportError.sessionUnavailable(presetName: "AVAssetExportPresetHighestQuality")
        let description = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(description.contains("AVAssetExportPresetHighestQuality"),
                      "Error message should mention which preset failed: \(description)")
    }

    func testSessionFailedPropagatesUnderlyingMessage() {
        let error = ExportError.sessionFailed(message: "Disk full")
        XCTAssertEqual(error.errorDescription, "Disk full")
    }

    func testUnexpectedStatusIncludesRawValue() throws {
        let error = ExportError.unexpectedStatus(rawValue: 42)
        let description = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(description.contains("42"))
    }

    func testEnumIsEquatable() {
        XCTAssertEqual(ExportError.alreadyRunning, ExportError.alreadyRunning)
        XCTAssertNotEqual(ExportError.sessionFailed(message: "a"),
                          ExportError.sessionFailed(message: "b"))
    }
}
