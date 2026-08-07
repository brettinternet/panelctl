import AppKit
import XCTest
@testable import PanelCtlApp

@MainActor
final class BlackoutFocusControllerTests: XCTestCase {
    func testOutsideTargetDoesNotCaptureOrActivate() {
        var captures = 0
        var activations = 0
        let operations = makeOperations(
            frontmost: {
                captures += 1
                return nil
            },
            requestActivation: { activations += 1 }
        )
        let controller = BlackoutFocusController(operations: operations)

        controller.enter(targetFrames: [CGRect(x: 0, y: 0, width: 1, height: 1)])

        XCTAssertEqual(captures, 0)
        XCTAssertEqual(activations, 0)
    }

    func testActivationHidesAndLeaveShowsThenRestoresPrevious() {
        var events: [String] = []
        var panelIsActive = false
        let previous = BlackoutPreviousApplication(
            processIdentifier: 42,
            isRunning: { true },
            yieldActivation: { events.append("yield") },
            activate: {
                events.append("activate")
                return true
            }
        )
        let operations = makeOperations(
            frontmost: { previous },
            makeProxyWindow: { _ in
                BlackoutFocusWindow(
                    show: { events.append("window-show") },
                    close: { events.append("window-close") }
                )
            },
            requestActivation: { panelIsActive = true },
            panelIsActive: { panelIsActive },
            hideCursor: { events.append("hide"); return .success },
            restoreCursor: { _ in events.append("show"); return .success }
        )
        let controller = BlackoutFocusController(operations: operations)
        controller.enter(targetFrames: [CGRect(x: 0, y: 0, width: 10_000, height: 10_000)])
        controller.leave()

        XCTAssertEqual(events, ["window-show", "hide", "show", "window-close", "yield", "activate"])
    }

    func testLeavingRestoresTheCapturedCursor() {
        let cursor = NSCursor(image: NSImage(size: NSSize(width: 2, height: 2)), hotSpot: .zero)
        var restoredCursor: NSCursor?
        let operations = makeOperations(
            currentCursor: { cursor },
            restoreCursor: {
                restoredCursor = $0
                return .success
            }
        )
        let controller = BlackoutFocusController(operations: operations)

        controller.enter(targetFrames: [CGRect(x: 0, y: 0, width: 10_000, height: 10_000)])
        controller.leave()

        XCTAssertTrue(restoredCursor === cursor)
    }

    func testTransparentCursorHasTransparentPixel() throws {
        let representation = try XCTUnwrap(
            BlackoutFocusOperations.transparentCursor.image.representations
                .compactMap { $0 as? NSBitmapImageRep }
                .first
        )

        let bytes = UnsafeBufferPointer(start: try XCTUnwrap(representation.bitmapData), count: 4)
        XCTAssertEqual(Array(bytes), [0, 0, 0, 0])
    }

    func testDelayedActivationHidesOnlyAfterConfirmation() {
        var panelIsActive = false
        var pending: (() -> Void)?
        var hideCount = 0
        let operations = makeOperations(
            requestActivation: {},
            panelIsActive: { panelIsActive },
            hideCursor: { hideCount += 1; return .success },
            schedule: { pending = $0 }
        )
        let controller = BlackoutFocusController(operations: operations)
        controller.enter(targetFrames: [CGRect(x: 0, y: 0, width: 10_000, height: 10_000)])
        XCTAssertEqual(hideCount, 0)

        panelIsActive = true
        pending?()
        XCTAssertEqual(hideCount, 1)
    }

    func testActivationTimeoutCleansUpWithoutHidingCursor() {
        let panelIsActive = false
        var hideCount = 0
        let operations = makeOperations(
            panelIsActive: { panelIsActive },
            hideCursor: { hideCount += 1; return .success },
            activationTimeout: 0
        )
        let controller = BlackoutFocusController(operations: operations)

        controller.enter(targetFrames: [CGRect(x: 0, y: 0, width: 10_000, height: 10_000)])

        XCTAssertFalse(panelIsActive)
        XCTAssertEqual(hideCount, 0)
    }

    func testResignReactivatesFocusProxyWithoutRestoringPreviousApplication() {
        var panelIsActive = false
        var previousActivationCount = 0
        var panelActivationCount = 0
        var hideCount = 0
        var showCount = 0
        let previous = BlackoutPreviousApplication(
            processIdentifier: 42,
            isRunning: { true },
            activate: {
                previousActivationCount += 1
                return true
            }
        )
        let operations = makeOperations(
            frontmost: { previous },
            requestActivation: {
                panelActivationCount += 1
                panelIsActive = true
            },
            panelIsActive: { panelIsActive },
            hideCursor: { hideCount += 1; return .success },
            restoreCursor: { _ in showCount += 1; return .success }
        )
        let controller = BlackoutFocusController(operations: operations)
        let target = CGRect(x: 0, y: 0, width: 10_000, height: 10_000)

        controller.enter(targetFrames: [target])
        panelIsActive = false
        NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: nil)
        controller.enter(targetFrames: [target])

        XCTAssertEqual(previousActivationCount, 0)
        XCTAssertEqual(panelActivationCount, 2)
        XCTAssertEqual(hideCount, 2)
        XCTAssertEqual(showCount, 1)
    }

    func testRepeatedEnterAndLeaveAreIdempotent() {
        var hideCount = 0
        var showCount = 0
        let operations = makeOperations(
            hideCursor: { hideCount += 1; return .success },
            restoreCursor: { _ in showCount += 1; return .success }
        )
        let controller = BlackoutFocusController(operations: operations)

        controller.enter(targetFrames: [CGRect(x: 0, y: 0, width: 10_000, height: 10_000)])
        controller.enter(targetFrames: [CGRect(x: 0, y: 0, width: 10_000, height: 10_000)])
        controller.leave()
        controller.leave()

        XCTAssertEqual(hideCount, 1)
        XCTAssertEqual(showCount, 1)
    }

    func testFailedCursorRestoreKeepsFocusUntilRetrySucceeds() {
        var events: [String] = []
        var pending: (() -> Void)?
        var showResults: [CGError] = [.failure, .success]
        let previous = BlackoutPreviousApplication(
            processIdentifier: 42,
            isRunning: { true },
            activate: { events.append("activate"); return true }
        )
        let operations = makeOperations(
            frontmost: { previous },
            hideCursor: { .success },
            restoreCursor: { _ in showResults.removeFirst() },
            schedule: { pending = $0 }
        )
        let controller = BlackoutFocusController(operations: operations)

        controller.enter(targetFrames: [CGRect(x: 0, y: 0, width: 10, height: 10)])
        controller.leave()
        XCTAssertTrue(controller.isEngaged)
        XCTAssertTrue(events.isEmpty)

        pending?()
        XCTAssertFalse(controller.isEngaged)
        XCTAssertEqual(events, ["activate"])
    }

    func testMovingOutsideTargetRestoresCursorAndPreviousApplication() {
        var mouseLocation = CGPoint(x: 5, y: 5)
        var showCount = 0
        var activationCount = 0
        let previous = BlackoutPreviousApplication(
            processIdentifier: 42,
            isRunning: { true },
            activate: { activationCount += 1; return true }
        )
        let operations = makeOperations(
            frontmost: { previous },
            mouseLocation: { mouseLocation },
            restoreCursor: { _ in showCount += 1; return .success }
        )
        let controller = BlackoutFocusController(operations: operations)
        let target = CGRect(x: 0, y: 0, width: 10, height: 10)

        controller.enter(targetFrames: [target])
        mouseLocation = CGPoint(x: 20, y: 20)
        controller.enter(targetFrames: [target])

        XCTAssertEqual(showCount, 1)
        XCTAssertEqual(activationCount, 1)
        XCTAssertFalse(controller.isEngaged)
    }

    func testReentryWaitsForPreviousApplicationToDeactivate() {
        var mouseLocation = CGPoint(x: 5, y: 5)
        var panelIsActive = true
        var proxyCount = 0
        var activationRequests = 0
        var hideCount = 0
        var showCount = 0
        var previousActivationRequests = 0
        let previous = BlackoutPreviousApplication(
            processIdentifier: 42,
            isRunning: { true },
            activate: {
                previousActivationRequests += 1
                return true
            }
        )
        let operations = makeOperations(
            frontmost: { previous },
            makeProxyWindow: { _ in
                proxyCount += 1
                return BlackoutFocusWindow(show: {}, close: {})
            },
            requestActivation: {
                activationRequests += 1
                panelIsActive = true
            },
            panelIsActive: { panelIsActive },
            mouseLocation: { mouseLocation },
            hideCursor: { hideCount += 1; return .success },
            restoreCursor: { _ in showCount += 1; return .success }
        )
        let controller = BlackoutFocusController(operations: operations)
        let target = CGRect(x: 0, y: 0, width: 10, height: 10)

        controller.enter(targetFrames: [target])
        mouseLocation = CGPoint(x: 20, y: 20)
        controller.enter(targetFrames: [target])
        mouseLocation = CGPoint(x: 5, y: 5)
        controller.enter(targetFrames: [target])

        XCTAssertEqual(proxyCount, 1)
        XCTAssertEqual(activationRequests, 1)
        XCTAssertEqual(hideCount, 1)
        XCTAssertEqual(showCount, 1)
        XCTAssertEqual(previousActivationRequests, 1)

        panelIsActive = false
        NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: nil)
        XCTAssertEqual(showCount, 1)

        controller.enter(targetFrames: [target])

        XCTAssertEqual(proxyCount, 2)
        XCTAssertEqual(activationRequests, 2)
        XCTAssertEqual(hideCount, 2)
    }

    func testBlackoutRestoreKeyAcceptsOnlyPlainNonRepeatingEscape() throws {
        func event(
            keyCode: UInt16 = 53,
            modifiers: NSEvent.ModifierFlags = [],
            repeats: Bool = false
        ) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                isARepeat: repeats,
                keyCode: keyCode
            ))
        }

        XCTAssertTrue(isBlackoutRestoreKey(try event()))
        XCTAssertFalse(isBlackoutRestoreKey(try event(modifiers: .command)))
        XCTAssertFalse(isBlackoutRestoreKey(try event(modifiers: .shift)))
        XCTAssertFalse(isBlackoutRestoreKey(try event(repeats: true)))
        XCTAssertFalse(isBlackoutRestoreKey(try event(keyCode: 36)))
    }

    func testEscapeRestoreRequiresActivationAndLatchesOnlyAfterAcceptance() {
        var active = false
        var scheduled: [() -> Void] = []
        var escape: (() -> Void)?
        var restoreAttempts = 0
        let operations = makeOperations(
            makeProxyWindow: { callback in
                escape = callback
                return BlackoutFocusWindow(show: {}, close: {})
            },
            panelIsActive: { active },
            schedule: { scheduled.append($0) }
        )
        let controller = BlackoutFocusController(operations: operations) {
            restoreAttempts += 1
            return restoreAttempts > 1
        }

        controller.enter(targetFrames: [CGRect(x: 0, y: 0, width: 10, height: 10)])
        escape?()
        XCTAssertEqual(restoreAttempts, 0)

        active = true
        scheduled.removeFirst()()
        escape?()
        escape?()
        XCTAssertEqual(restoreAttempts, 2)

        controller.leave()
        escape?()
        XCTAssertEqual(restoreAttempts, 2)
    }

    private func makeOperations(
        frontmost: @escaping () -> BlackoutPreviousApplication? = { nil },
        makeProxyWindow: @escaping (@escaping () -> Void) -> BlackoutFocusWindow = { _ in
            BlackoutFocusWindow(show: {}, close: {})
        },
        requestActivation: @escaping () -> Void = {},
        panelIsActive: @escaping () -> Bool = { true },
        mouseLocation: @escaping () -> CGPoint = { CGPoint(x: 5, y: 5) },
        currentCursor: @escaping () -> NSCursor = { .arrow },
        hideCursor: @escaping () -> CGError = { .success },
        restoreCursor: @escaping (NSCursor) -> CGError = { _ in .success },
        schedule: @escaping (@escaping () -> Void) -> Void = { $0() },
        activationTimeout: TimeInterval = 0.5
    ) -> BlackoutFocusOperations {
        BlackoutFocusOperations(
            currentProcessIdentifier: 7,
            frontmostApplication: frontmost,
            makeProxyWindow: makeProxyWindow,
            requestActivation: requestActivation,
            panelIsActive: panelIsActive,
            mouseLocation: mouseLocation,
            currentCursor: currentCursor,
            hideCursor: hideCursor,
            restoreCursor: restoreCursor,
            schedule: schedule,
            activationTimeout: activationTimeout
        )
    }
}
