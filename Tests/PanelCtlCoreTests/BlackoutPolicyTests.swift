import XCTest
import AppKit
@testable import PanelCtlCore

final class BlackoutPolicyTests: XCTestCase {
    func testExternalPlaybackAssertionIgnoresPanelCtlPID() {
        let assertion: [AnyHashable: Any] = [
            "AssertType": "PreventUserIdleDisplaySleep",
            "AssertLevel": NSNumber(value: 255)
        ]
        let assertions: [AnyHashable: Any] = [
            NSNumber(value: 42): [assertion],
            NSNumber(value: 99): [assertion]
        ]
        XCTAssertTrue(hasExternalDisplaySleepAssertion(in: assertions, excludingPID: 42))
        XCTAssertFalse(hasExternalDisplaySleepAssertion(
            in: [NSNumber(value: 42): [assertion]],
            excludingPID: 42
        ))
    }

    func testIdleThresholdIsInclusive() {
        let policy = BlackoutPolicy(idleAfter: 60, timeout: nil, sleepAfter: nil)
        XCTAssertFalse(policy.shouldBegin(idleSeconds: 59.999))
        XCTAssertTrue(policy.shouldBegin(idleSeconds: 60))
    }

    func testActivityDeferralOnlyAppliesToAutomaticIdleBlackout() {
        let automatic = BlackoutPolicy(idleAfter: 60, timeout: nil, sleepAfter: nil)
        XCTAssertTrue(automatic.shouldDeferForActivity(
            assertionActive: true,
            cameraActive: false,
            immediateBlackoutRequested: false
        ))
        XCTAssertFalse(automatic.shouldDeferForActivity(
            assertionActive: false,
            cameraActive: true,
            immediateBlackoutRequested: false
        ))
        XCTAssertFalse(automatic.shouldDeferForActivity(
            assertionActive: true,
            cameraActive: false,
            immediateBlackoutRequested: true
        ))

        let oneShot = BlackoutPolicy(idleAfter: nil, timeout: nil, sleepAfter: nil)
        XCTAssertFalse(oneShot.shouldDeferForActivity(
            assertionActive: true,
            cameraActive: false,
            immediateBlackoutRequested: false
        ))
        XCTAssertFalse(BlackoutPolicy(
            idleAfter: 60, timeout: nil, sleepAfter: nil, deferPlayback: false
        ).shouldDeferForActivity(
            assertionActive: true,
            cameraActive: false,
            immediateBlackoutRequested: false
        ))
    }

    func testCameraDeferralIsIndependentlyConfigurable() {
        let policy = BlackoutPolicy(
            idleAfter: 60,
            timeout: nil,
            sleepAfter: nil,
            deferCamera: true
        )
        XCTAssertTrue(policy.shouldDeferForActivity(
            assertionActive: false,
            cameraActive: true,
            immediateBlackoutRequested: false
        ))
        XCTAssertTrue(policy.shouldDeferForActivity(
            assertionActive: true,
            cameraActive: false,
            immediateBlackoutRequested: false
        ))
        XCTAssertFalse(policy.shouldDeferForActivity(
            assertionActive: false,
            cameraActive: true,
            immediateBlackoutRequested: true
        ))
    }

    func testPlaybackDeferralRestartsTheFullIdleCountdown() {
        let sample = IdleSample(seconds: 300, lastInputUptime: 100)
        let resumed = sample.applyingSyntheticActivity(at: 395)

        XCTAssertEqual(resumed.lastInputUptime, 395)
        XCTAssertEqual(resumed.seconds, 5)
        XCTAssertFalse(BlackoutPolicy(idleAfter: 60, timeout: nil, sleepAfter: nil)
            .shouldBegin(idleSeconds: resumed.seconds))
    }

    func testInputIsComparedByLastInputEpoch() {
        let policy = BlackoutPolicy(idleAfter: nil, timeout: nil, sleepAfter: nil)
        XCTAssertFalse(policy.hasNewInput(IdleSample(seconds: 20, lastInputUptime: 100), after: 100))
        XCTAssertTrue(policy.hasNewInput(IdleSample(seconds: 0, lastInputUptime: 101), after: 100))
    }

    func testLimitActionsAreInclusive() {
        let timeout = BlackoutPolicy(idleAfter: nil, timeout: 10, sleepAfter: nil)
        XCTAssertEqual(timeout.limitAction(elapsed: 9.999), .none)
        XCTAssertEqual(timeout.limitAction(elapsed: 10), .finish)

        let sleep = BlackoutPolicy(idleAfter: nil, timeout: nil, sleepAfter: 20)
        XCTAssertEqual(sleep.limitAction(elapsed: 19.999), .none)
        XCTAssertEqual(sleep.limitAction(elapsed: 20), .sleep)
    }

    func testIdleSampleTakesUptimeAfterPotentiallySlowQuery() throws {
        var now: TimeInterval = 100
        let source = StubIdleSource {
            now += 0.05
            return 10.05
        }
        let controller = BlackoutController(idleSource: source, uptime: { now })

        let sample = try controller.idleSample()

        XCTAssertEqual(sample.lastInputUptime, 90, accuracy: 0.000_001)
    }

    func testSyntheticActivityRestartsTheIdleInterval() {
        let idle = IdleSample(seconds: 60, lastInputUptime: 40)

        XCTAssertEqual(
            idle.applyingSyntheticActivity(at: 95),
            IdleSample(seconds: 5, lastInputUptime: 95)
        )
        XCTAssertEqual(
            IdleSample(seconds: 2, lastInputUptime: 98)
                .applyingSyntheticActivity(at: 95),
            IdleSample(seconds: 2, lastInputUptime: 98)
        )
    }

    func testManualActivityRearmsWithoutClearingSuspensions() {
        var timedOut = BlackoutWatchState()
        timedOut.reset(.timeout, after: 100)
        timedOut.acceptManualActivity()
        XCTAssertTrue(timedOut.mayBeginCycle)

        var sleeping = BlackoutWatchState()
        sleeping.reset(.suspension(.screensAsleep), after: 100)
        sleeping.acceptManualActivity()
        XCTAssertFalse(sleeping.mayBeginCycle)
        XCTAssertTrue(sleeping.suspensions.contains(.screensAsleep))
    }

    func testWatchInputRearmsOnlyAfterNewInputAndFullIdleInterval() {
        var state = BlackoutWatchState()
        let policy = BlackoutPolicy(idleAfter: 5, timeout: nil, sleepAfter: nil)

        state.reset(.input, after: 100)
        XCTAssertFalse(state.consumeFreshInput(
            IdleSample(seconds: 10, lastInputUptime: 100),
            allowScreenWakeFallback: true
        ))
        XCTAssertFalse(state.mayBeginCycle)

        let activity = IdleSample(seconds: 0, lastInputUptime: 101)
        XCTAssertTrue(state.consumeFreshInput(activity, allowScreenWakeFallback: true))
        XCTAssertTrue(state.mayBeginCycle)
        XCTAssertFalse(policy.shouldBegin(idleSeconds: activity.seconds))
        XCTAssertTrue(policy.shouldBegin(idleSeconds: 5))
    }

    func testWatchTimeoutRequiresFreshInputBeforeRearm() {
        var state = BlackoutWatchState()

        state.reset(.timeout, after: 100)
        XCTAssertFalse(state.consumeFreshInput(
            IdleSample(seconds: 10, lastInputUptime: 100),
            allowScreenWakeFallback: true
        ))
        XCTAssertTrue(state.awaitingFreshInput)
        XCTAssertFalse(state.mayBeginCycle)

        XCTAssertTrue(state.consumeFreshInput(
            IdleSample(seconds: 0, lastInputUptime: 101),
            allowScreenWakeFallback: true
        ))
        XCTAssertTrue(state.mayBeginCycle)
    }

    func testWatchSuspensionsWakeIndependently() {
        var state = BlackoutWatchState()

        state.reset(.suspension(.sessionInactive), after: 100)
        state.reset(.suspension(.systemSleeping), after: 100)
        state.resume(.sessionInactive, after: 101)
        XCTAssertFalse(state.mayBeginCycle)
        XCTAssertFalse(state.consumeFreshInput(
            IdleSample(seconds: 0, lastInputUptime: 102),
            allowScreenWakeFallback: true
        ))
        state.resume(.systemSleeping, after: 102)
        XCTAssertFalse(state.mayBeginCycle) // fresh activity is still required
        XCTAssertTrue(state.consumeFreshInput(
            IdleSample(seconds: 0, lastInputUptime: 103),
            allowScreenWakeFallback: true
        ))
        XCTAssertTrue(state.mayBeginCycle)
    }

    func testWatchTerminationIsSticky() {
        var state = BlackoutWatchState()
        state.reset(.timeout, after: 100)
        state.terminate()
        state.reset(.input, after: 100)
        XCTAssertFalse(state.consumeFreshInput(
            IdleSample(seconds: 0, lastInputUptime: 101),
            allowScreenWakeFallback: true
        ))
        XCTAssertTrue(state.terminated)
    }

    func testWatchInputRecoversOnlyMissingScreenWake() {
        var screenSleep = BlackoutWatchState()
        screenSleep.reset(.suspension(.screensAsleep), after: 100)
        XCTAssertTrue(screenSleep.consumeFreshInput(
            IdleSample(seconds: 0, lastInputUptime: 101),
            allowScreenWakeFallback: true
        ))
        XCTAssertTrue(screenSleep.mayBeginCycle)

        var sessionInactive = BlackoutWatchState()
        sessionInactive.reset(.suspension(.sessionInactive), after: 100)
        XCTAssertFalse(sessionInactive.consumeFreshInput(
            IdleSample(seconds: 0, lastInputUptime: 101),
            allowScreenWakeFallback: true
        ))
        XCTAssertFalse(sessionInactive.mayBeginCycle)
    }

    func testWorkspaceNotificationsMapToWatchEvents() {
        XCTAssertEqual(
            BlackoutController.workspaceEvent(for: NSWorkspace.sessionDidResignActiveNotification),
            .reset(.suspension(.sessionInactive))
        )
        XCTAssertEqual(
            BlackoutController.workspaceEvent(for: NSWorkspace.sessionDidBecomeActiveNotification),
            .resume(.sessionInactive)
        )
        XCTAssertEqual(
            BlackoutController.workspaceEvent(for: NSWorkspace.willSleepNotification),
            .reset(.suspension(.systemSleeping))
        )
        XCTAssertEqual(
            BlackoutController.workspaceEvent(for: NSWorkspace.didWakeNotification),
            .resume(.systemSleeping)
        )
        XCTAssertEqual(
            BlackoutController.workspaceEvent(for: NSWorkspace.screensDidSleepNotification),
            .reset(.suspension(.screensAsleep))
        )
        XCTAssertEqual(
            BlackoutController.workspaceEvent(for: NSWorkspace.screensDidWakeNotification),
            .resume(.screensAsleep)
        )
        XCTAssertNil(BlackoutController.workspaceEvent(for: Notification.Name("unrelated")))
    }

    func testWatchTargetFollowsUUIDWhileOneShotRetainsID() throws {
        let target = BlackoutScreenTarget(id: 5, uuid: "AAAA", selector: "AAAA")
        let reenumerated = [displayRecord(id: 9, uuid: "aaaa")]

        XCTAssertEqual(try target.resolvedID(in: reenumerated, watch: true), 9)
        XCTAssertEqual(try target.resolvedID(in: [], watch: false), 5)
    }

    func testWatchTargetRequiresAvailableStableUUID() {
        let uuidless = BlackoutScreenTarget(id: 5, uuid: nil, selector: "5")
        XCTAssertEqual(try uuidless.resolvedID(in: [], watch: false), 5)
        XCTAssertThrowsError(try uuidless.resolvedID(in: [], watch: true)) {
            XCTAssertEqual($0 as? BlackoutError, .watchRequiresStableUUID("5"))
        }

        let missing = BlackoutScreenTarget(id: 5, uuid: "AAAA", selector: "AAAA")
        XCTAssertThrowsError(try missing.resolvedID(in: [], watch: true)) {
            XCTAssertEqual($0 as? BlackoutError, .topologyChanged)
        }
    }
}

private struct StubIdleSource: IdleTimeSource {
    let read: () -> TimeInterval?

    func secondsSinceLastInput() -> TimeInterval? {
        read()
    }
}

private func displayRecord(id: UInt32, uuid: String?) -> DisplayRecord {
    DisplayRecord(
        index: 1,
        id: id,
        uuid: uuid,
        name: nil,
        active: true,
        online: true,
        asleep: false,
        builtin: false,
        main: false,
        vendor: 0,
        model: 0,
        serial: 0,
        bounds: DisplayBounds(.zero),
        pixelWidth: 0,
        pixelHeight: 0
    )
}
