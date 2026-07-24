import XCTest
@testable import PanelCtlCore

final class BlackoutGeometryTests: XCTestCase {
    func testContentRectUsesEveryScreenSizeWithoutGlobalOrigin() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1728, height: 1117),
            CGRect(x: -3440, y: -1440, width: 3440, height: 1440),
            CGRect(x: 1728, y: 415, width: 1440, height: 3440),
            CGRect(x: -0.5, y: 702.25, width: 7680, height: 4320)
        ]

        for frame in frames {
            XCTAssertEqual(
                BlackoutController.windowContentRect(for: frame),
                CGRect(origin: .zero, size: frame.size)
            )
        }
    }

    func testScreenFramesMustBeFiniteAndPositive() {
        XCTAssertTrue(BlackoutController.isValidScreenFrame(CGRect(x: -16_000, y: 16_000, width: 7680, height: 4320)))
        XCTAssertFalse(BlackoutController.isValidScreenFrame(CGRect(x: 0, y: 0, width: 0, height: 100)))
        XCTAssertFalse(BlackoutController.isValidScreenFrame(CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100)))
        XCTAssertFalse(BlackoutController.isValidScreenFrame(CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100)))
    }

    func testCoverageRequiresExactFrameAndScreenIdentity() {
        let screen = CGRect(x: 1728, y: -738, width: 3440, height: 1440)
        let targetID: UInt32 = 5
        XCTAssertTrue(BlackoutController.exactlyCovers(
            windowFrame: screen,
            screenFrame: screen,
            windowScreenID: targetID,
            targetScreenID: targetID
        ))

        let partialFrames = [
            CGRect(x: screen.minX + 1, y: screen.minY, width: screen.width - 1, height: screen.height),
            CGRect(x: screen.minX, y: screen.minY + 1, width: screen.width, height: screen.height - 1),
            CGRect(x: screen.minX, y: screen.minY, width: screen.width - 1, height: screen.height),
            CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height - 1)
        ]
        for partial in partialFrames {
            XCTAssertFalse(BlackoutController.exactlyCovers(
                windowFrame: partial,
                screenFrame: screen,
                windowScreenID: targetID,
                targetScreenID: targetID
            ))
        }
        XCTAssertFalse(BlackoutController.exactlyCovers(
            windowFrame: screen,
            screenFrame: screen,
            windowScreenID: 2,
            targetScreenID: targetID
        ))
    }
}
