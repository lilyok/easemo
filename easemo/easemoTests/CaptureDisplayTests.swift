import XCTest
@testable import easemo

final class CaptureDisplayTests: XCTestCase {

    func testPrefersExplicitDisplayWhenAvailable() {
        let resolved = CaptureDisplayResolver.resolveID(
            preferred: 42,
            available: [7, 42, 9],
            main: 7
        )
        XCTAssertEqual(resolved, 42)
    }

    func testFallsBackToMainWhenPreferredIsMissing() {
        let resolved = CaptureDisplayResolver.resolveID(
            preferred: 99,
            available: [7, 8],
            main: 7
        )
        XCTAssertEqual(resolved, 7)
    }

    func testFallsBackToFirstWhenMainIsMissing() {
        let resolved = CaptureDisplayResolver.resolveID(
            preferred: nil,
            available: [3, 4],
            main: 1
        )
        XCTAssertEqual(resolved, 3)
    }

    func testReturnsNilWhenNoDisplaysExist() {
        let resolved = CaptureDisplayResolver.resolveID(
            preferred: 1,
            available: [],
            main: 1
        )
        XCTAssertNil(resolved)
    }

    func testRecordingConfigurationDefaultsToNilDisplay() {
        XCTAssertNil(RecordingConfiguration().selectedDisplayID)
    }

    func testMenuTitleMarksMainDisplay() {
        let display = CaptureDisplay(id: 1, name: "Built-in", width: 1920, height: 1080, isMain: true)
        XCTAssertTrue(display.menuTitle.contains("Main"))
        XCTAssertTrue(display.menuTitle.contains("1920×1080"))
    }

    func testRejectsInactiveOrZeroSizeDisplays() {
        XCTAssertFalse(CaptureDisplay.isSelectableCaptureTarget(
            displayID: 1, width: 0, height: 1080, isOnline: true, isActive: true, mirrorMasterID: nil
        ))
        XCTAssertFalse(CaptureDisplay.isSelectableCaptureTarget(
            displayID: 1, width: 1920, height: 1080, isOnline: true, isActive: false, mirrorMasterID: nil
        ))
    }

    func testRejectsMirroredCopyButKeepsMaster() {
        XCTAssertFalse(CaptureDisplay.isSelectableCaptureTarget(
            displayID: 2, width: 1920, height: 1080, isOnline: true, isActive: true, mirrorMasterID: 1
        ))
        XCTAssertTrue(CaptureDisplay.isSelectableCaptureTarget(
            displayID: 1, width: 1920, height: 1080, isOnline: true, isActive: true, mirrorMasterID: 1
        ))
        XCTAssertTrue(CaptureDisplay.isSelectableCaptureTarget(
            displayID: 1, width: 1920, height: 1080, isOnline: true, isActive: true, mirrorMasterID: nil
        ))
    }
}
