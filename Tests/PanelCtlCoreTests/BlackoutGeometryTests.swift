import XCTest
@testable import PanelCtlCore

final class BlackoutGeometryTests: XCTestCase {
    func testContentRectUsesTargetScreenFrameAtCreation() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1728, height: 1117),
            CGRect(x: -3440, y: -1440, width: 3440, height: 1440),
            CGRect(x: 1728, y: 415, width: 1440, height: 3440),
            CGRect(x: -0.5, y: 702.25, width: 7680, height: 4320)
        ]

        for frame in frames {
            XCTAssertEqual(
                BlackoutController.windowContentRect(for: frame),
                frame
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

    @MainActor
    func testConfigureWindowBlockingOpaqueProperties() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        BlackoutController.configureWindow(
            window,
            mode: .blocking,
            overlayOpacityPercent: 100
        )

        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertTrue(window.isOpaque)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertEqual(window.backgroundColor, .black)
        XCTAssertEqual(window.level, .screenSaver)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(window.hasShadow)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertEqual(window.animationBehavior, .none)
        XCTAssertEqual(window.contentView?.layer?.backgroundColor, NSColor.black.cgColor)
    }

    @MainActor
    func testConfigureWindowWorkingPartialProperties() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        BlackoutController.configureWindow(
            window,
            mode: .working,
            overlayOpacityPercent: 60
        )

        XCTAssertEqual(window.alphaValue, 0.6)
        XCTAssertFalse(window.isOpaque)
        XCTAssertTrue(window.ignoresMouseEvents)
    }

    @MainActor
    func testConfigureWindowWorkingFullOpacityRemainsClickThrough() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        BlackoutController.configureWindow(
            window,
            mode: .working,
            overlayOpacityPercent: 100
        )

        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(window.isOpaque)
        XCTAssertTrue(window.ignoresMouseEvents)
    }

    @MainActor
    func testConfigureWindowWorkingNoOverlayKeepsZeroAlphaSentinel() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        BlackoutController.configureWindow(
            window,
            mode: .working,
            overlayOpacityPercent: nil
        )

        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertFalse(window.isOpaque)
        XCTAssertTrue(window.ignoresMouseEvents)
    }

}
