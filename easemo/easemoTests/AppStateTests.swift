import XCTest
@testable import easemo

@MainActor
final class AppStateTests: XCTestCase {

    func testFormatElapsedShortDuration() {
        XCTAssertEqual(AppState.formatElapsed(0), "00:00")
        XCTAssertEqual(AppState.formatElapsed(5), "00:05")
        XCTAssertEqual(AppState.formatElapsed(65), "01:05")
    }

    func testFormatElapsedLongDuration() {
        XCTAssertEqual(AppState.formatElapsed(3700), "01:01:40")
    }

    func testRouteDefaultsToRecording() {
        let state = AppState()
        XCTAssertEqual(state.route, .recording)
    }

    func testOverlayBindingUpdatesConfiguration() {
        let state = AppState()
        var layout = OverlayLayout.default
        layout.shape = .rectangle
        layout.widthFraction = 0.3
        state.overlay = layout
        XCTAssertEqual(state.configuration.overlay.shape, .rectangle)
        XCTAssertEqual(state.configuration.overlay.widthFraction, 0.3, accuracy: 0.0001)
    }

    func testRecordingConfigurationDefaultsIncludeMicrophone() {
        let configuration = RecordingConfiguration()
        XCTAssertTrue(configuration.includeMicrophone,
                      "Microphone should be on by default to match the demo-recording use case.")
    }

    func testRecordingConfigurationDefaultsBlurWebcamBackground() {
        let configuration = RecordingConfiguration()
        XCTAssertTrue(configuration.blurBackgroundBehindWebcam)
    }

    func testMuteAudioDefaultsToFalseAndResetsOnBack() {
        let state = AppState()
        XCTAssertFalse(state.muteAudio)
        state.muteAudio = true
        state.backToRecording()
        XCTAssertFalse(state.muteAudio,
                       "Going back to the recording screen must clear per-take edit choices like mute.")
    }
}
