import XCTest
@testable import easemo

final class OverlayLayoutTests: XCTestCase {

    func testBottomRightFrameWithinCanvas() {
        let layout = OverlayLayout(widthFraction: 0.25,
                                   edgeInset: 32,
                                   position: .bottomRight,
                                   shape: .rectangle)
        let canvas = CGSize(width: 1920, height: 1080)
        let frame = layout.frame(in: canvas, cameraAspect: 16.0/9.0)

        XCTAssertEqual(frame.width, 480, accuracy: 1)
        XCTAssertEqual(frame.height, 270, accuracy: 1)
        XCTAssertEqual(frame.maxX, canvas.width - 32, accuracy: 1)
        XCTAssertEqual(frame.maxY, canvas.height - 32, accuracy: 1)
    }

    func testWidthFractionIsClamped() {
        let layout = OverlayLayout(widthFraction: 5.0,
                                   edgeInset: 0,
                                   position: .topLeft,
                                   shape: .circle)
        let frame = layout.frame(in: CGSize(width: 1000, height: 800),
                                 cameraAspect: 1.0)
        XCTAssertLessThanOrEqual(frame.width, 500)
    }

    func testCornerVariations() {
        let canvas = CGSize(width: 1000, height: 800)
        let aspect: CGFloat = 16.0/9.0
        let inset: CGFloat = 24

        for position in OverlayPosition.allCases {
            let layout = OverlayLayout(widthFraction: 0.2,
                                       edgeInset: inset,
                                       position: position,
                                       shape: .rectangle)
            let frame = layout.frame(in: canvas, cameraAspect: aspect)
            XCTAssertGreaterThanOrEqual(frame.minX, 0, "\(position) clipped on the left")
            XCTAssertGreaterThanOrEqual(frame.minY, 0, "\(position) clipped on the top")
            XCTAssertLessThanOrEqual(frame.maxX, canvas.width, "\(position) overflow right")
            XCTAssertLessThanOrEqual(frame.maxY, canvas.height, "\(position) overflow bottom")
        }
    }
}
