import XCTest
@testable import PanelCtlCore

final class BlackoutGeometryTests: XCTestCase {
    @MainActor
    func testWindowPlacementOnConnectedExternalScreens() throws {
        let screens = NSScreen.screens.filter { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? NSNumber)?.uint32Value != CGMainDisplayID()
        }
        guard !screens.isEmpty else { throw XCTSkip("requires an external display") }

        let controller = BlackoutController()
        for screen in screens {
            let window = controller.makeWindow(
                for: screen,
                mode: .blocking,
                overlayOpacityPercent: 100
            )
            let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
            let targetID = try XCTUnwrap(
                (screen.deviceDescription[screenNumberKey] as? NSNumber)?.uint32Value
            )
            let windowScreenID = (
                window.screen?.deviceDescription[screenNumberKey] as? NSNumber
            )?.uint32Value
            let expectedQuartzBounds = CGDisplayBounds(targetID)
            let expectedFrame = BlackoutController.appKitFrame(
                forQuartzBounds: expectedQuartzBounds,
                mainQuartzBounds: CGDisplayBounds(CGMainDisplayID())
            )

            XCTAssertEqual(window.frame, expectedFrame)
            XCTAssertEqual(windowScreenID, targetID)
            XCTAssertTrue(BlackoutController.exactlyCovers(
                windowFrame: window.frame,
                screenFrame: expectedFrame,
                windowScreenID: windowScreenID,
                targetScreenID: targetID
            ))

            window.orderFrontRegardless()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            let windowInfo = try XCTUnwrap(
                CGWindowListCopyWindowInfo(
                    [.optionIncludingWindow],
                    CGWindowID(window.windowNumber)
                ) as? [[String: Any]]
            ).first {
                ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber
            }
            let rawBounds = try XCTUnwrap(windowInfo?[kCGWindowBounds as String])
            var compositorBounds = CGRect.zero
            XCTAssertTrue(
                CGRectMakeWithDictionaryRepresentation(
                    rawBounds as! CFDictionary,
                    &compositorBounds
                )
            )
            XCTAssertEqual(compositorBounds, expectedQuartzBounds)
            window.close()
        }
    }

    func testQuartzBoundsConvertToAppKitCoordinatesAroundMainDisplay() {
        let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let cases: [(quartz: CGRect, appKit: CGRect)] = [
            (CGRect(x: 1728, y: -738, width: 3440, height: 1440),
             CGRect(x: 1728, y: 415, width: 3440, height: 1440)),
            (CGRect(x: 1728, y: 702, width: 3440, height: 1440),
             CGRect(x: 1728, y: -1025, width: 3440, height: 1440)),
            (CGRect(x: -3440, y: 1117, width: 3440, height: 1440),
             CGRect(x: -3440, y: -1440, width: 3440, height: 1440))
        ]

        for testCase in cases {
            XCTAssertEqual(
                BlackoutController.appKitFrame(
                    forQuartzBounds: testCase.quartz,
                    mainQuartzBounds: main
                ),
                testCase.appKit
            )
        }
    }

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
