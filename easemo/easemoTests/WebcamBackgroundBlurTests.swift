import CoreImage
import XCTest
@testable import easemo

final class WebcamBackgroundBlurTests: XCTestCase {

    func testDownscaledForLiveVisionInputScalesWhenLongEdgeExceedsCap() {
        let solid = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let out = WebcamBackgroundBlur.downscaledForLiveVisionInput(solid, maxLongEdge: 640)
        let e = out.extent
        XCTAssertEqual(max(e.width, e.height), 640, accuracy: 0.5)
        XCTAssertEqual(e.width / e.height, 1920 / 1080, accuracy: 0.02)
    }

    func testDownscaledForLiveVisionInputNoOpWhenAlreadySmaller() {
        let solid = CIImage(color: CIColor.red).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 240))
        let out = WebcamBackgroundBlur.downscaledForLiveVisionInput(solid, maxLongEdge: 640)
        XCTAssertEqual(out.extent, solid.extent)
    }

    func testDownscaledForLiveVisionInputNilCapReturnsOriginal() {
        let solid = CIImage(color: CIColor.red).cropped(to: CGRect(x: 0, y: 0, width: 4000, height: 2000))
        let out = WebcamBackgroundBlur.downscaledForLiveVisionInput(solid, maxLongEdge: nil)
        XCTAssertEqual(out.extent, solid.extent)
    }

    func testApplyIfEnabledFalseReturnsInput() {
        let input = CIImage(color: CIColor.blue).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let out = WebcamBackgroundBlur.applyIfEnabled(false, base: input)
        XCTAssertEqual(out.extent, input.extent)
    }

    func testApplyLiveIfEnabledFalseReturnsNil() {
        let input = CIImage(color: CIColor.blue).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        XCTAssertNil(WebcamBackgroundBlur.applyLiveIfEnabled(false, base: input))
    }

    func testEasemoCIContextIsSingleton() {
        XCTAssertTrue(EasemoCIContext.shared === EasemoCIContext.shared)
    }
}
