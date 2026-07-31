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
            requestActivation: { panelIsActive = true },
            panelIsActive: { panelIsActive },
            hideCursor: { events.append("hide"); return .success },
            showCursor: { events.append("show"); return .success }
        )
        let controller = BlackoutFocusController(operations: operations)
        controller.enter(targetFrames: [CGRect(x: 0, y: 0, width: 10_000, height: 10_000)])
        controller.leave()

        XCTAssertEqual(events, ["hide", "show", "yield", "activate"])
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

    func testResignDoesNotRestoreFocusToPreviousApplication() {
        var panelIsActive = false
        var activationCount = 0
        let previous = BlackoutPreviousApplication(
            processIdentifier: 42,
            isRunning: { true },
            activate: {
                activationCount += 1
                return true
            }
        )
        let operations = makeOperations(
            frontmost: { previous },
            requestActivation: { panelIsActive = true },
            panelIsActive: { panelIsActive },
            hideCursor: { .success },
            showCursor: { .success }
        )
        let controller = BlackoutFocusController(operations: operations)
        controller.enter(targetFrames: [CGRect(x: 0, y: 0, width: 10_000, height: 10_000)])
        NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: nil)
        panelIsActive = false
        controller.leave()

        XCTAssertEqual(activationCount, 0)
    }

    func testRepeatedEnterAndLeaveAreIdempotent() {
        var hideCount = 0
        var showCount = 0
        let operations = makeOperations(
            hideCursor: { hideCount += 1; return .success },
            showCursor: { showCount += 1; return .success }
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
            showCursor: { showResults.removeFirst() },
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
            showCursor: { showCount += 1; return .success }
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

    private func makeOperations(
        frontmost: @escaping () -> BlackoutPreviousApplication? = { nil },
        requestActivation: @escaping () -> Void = {},
        panelIsActive: @escaping () -> Bool = { true },
        mouseLocation: @escaping () -> CGPoint = { CGPoint(x: 5, y: 5) },
        hideCursor: @escaping () -> CGError = { .success },
        showCursor: @escaping () -> CGError = { .success },
        schedule: @escaping (@escaping () -> Void) -> Void = { $0() },
        activationTimeout: TimeInterval = 0.5
    ) -> BlackoutFocusOperations {
        BlackoutFocusOperations(
            currentProcessIdentifier: 7,
            frontmostApplication: frontmost,
            makeProxyWindow: {
                NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            },
            requestActivation: requestActivation,
            panelIsActive: panelIsActive,
            mouseLocation: mouseLocation,
            hideCursor: hideCursor,
            showCursor: showCursor,
            schedule: schedule,
            activationTimeout: activationTimeout
        )
    }
}
