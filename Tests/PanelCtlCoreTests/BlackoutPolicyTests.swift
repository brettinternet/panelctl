import XCTest
import AppKit
@testable import PanelCtlCore

final class BlackoutPolicyTests: XCTestCase {
    func testExternalPlaybackAssertionRecognizesCanonicalAndLegacyDisplayTypes() {
        for type in ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"] {
            let assertion: [AnyHashable: Any] = [
                "AssertType": type,
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

    func testInputActionHonorsPersistenceAndCoverage() {
        let stale = IdleSample(seconds: 20, lastInputUptime: 100)
        let fresh = IdleSample(seconds: 0, lastInputUptime: 101)
        let defaultPolicy = BlackoutPolicy(idleAfter: nil, timeout: nil, sleepAfter: nil)
        let persistentPolicy = BlackoutPolicy(
            idleAfter: nil,
            timeout: nil,
            sleepAfter: nil,
            keepBlackoutOnInput: true
        )

        XCTAssertEqual(
            defaultPolicy.inputAction(for: stale, after: 100, resetLimitOnInput: true),
            .none
        )
        XCTAssertEqual(
            defaultPolicy.inputAction(for: fresh, after: 100, resetLimitOnInput: true),
            .restore
        )
        XCTAssertEqual(
            persistentPolicy.inputAction(for: fresh, after: 100, resetLimitOnInput: true),
            .resetLimit
        )
        XCTAssertEqual(
            persistentPolicy.inputAction(for: fresh, after: 100, resetLimitOnInput: false),
            .none
        )
    }

    func testWorkingModeUsesEffectivePersistenceForPartialSelections() {
        let workingOptions = BlackoutOptions(
            selectors: ["1"],
            all: false,
            idleAfter: nil,
            timeout: 60,
            sleepAfter: nil,
            caffeinate: false,
            mode: .working
        )
        XCTAssertFalse(workingOptions.keepBlackoutOnInput)
        XCTAssertTrue(workingOptions.effectiveKeepBlackoutOnInput)

        let policy = BlackoutPolicy(
            idleAfter: workingOptions.idleAfter,
            timeout: workingOptions.timeout,
            sleepAfter: workingOptions.sleepAfter,
            keepBlackoutOnInput: workingOptions.effectiveKeepBlackoutOnInput
        )
        let fresh = IdleSample(seconds: 0, lastInputUptime: 101)
        XCTAssertEqual(
            policy.inputAction(for: fresh, after: 100, resetLimitOnInput: true),
            .resetLimit
        )
        XCTAssertEqual(
            policy.inputAction(for: fresh, after: 100, resetLimitOnInput: false),
            .none
        )
    }

    func testDirectOptionsValidateWorkingOverlayAndHardwarePercentages() {
        let invalidOverlay = BlackoutOptions(
            selectors: ["1"],
            all: false,
            idleAfter: nil,
            timeout: nil,
            sleepAfter: nil,
            caffeinate: false,
            mode: .working,
            overlayOpacityPercent: 0
        )
        XCTAssertThrowsError(try BlackoutController.validateOptions(invalidOverlay)) {
            XCTAssertEqual($0 as? BlackoutError, .invalidOverlayOpacity)
        }

        let invalidHardware = BlackoutOptions(
            selectors: ["1"],
            all: false,
            idleAfter: nil,
            timeout: nil,
            sleepAfter: nil,
            caffeinate: false,
            hardwareBrightnessPercent: 101
        )
        XCTAssertThrowsError(try BlackoutController.validateOptions(invalidHardware)) {
            XCTAssertEqual($0 as? BlackoutError, .invalidHardwareBrightness)
        }

        let blockingWithoutOpaqueOverlay = BlackoutOptions(
            selectors: ["1"],
            all: false,
            idleAfter: nil,
            timeout: nil,
            sleepAfter: nil,
            caffeinate: false,
            overlayOpacityPercent: nil
        )
        XCTAssertThrowsError(try BlackoutController.validateOptions(blockingWithoutOpaqueOverlay)) {
            XCTAssertEqual($0 as? BlackoutError, .workingOverlayRequired)
        }

        let validWorkingNoOverlay = BlackoutOptions(
            selectors: ["1"],
            all: false,
            idleAfter: nil,
            timeout: nil,
            sleepAfter: nil,
            caffeinate: false,
            mode: .working,
            overlayOpacityPercent: nil,
            hardwareBrightnessPercent: 0
        )
        XCTAssertNoThrow(try BlackoutController.validateOptions(validWorkingNoOverlay))
    }

    func testPersistentDimmingIsRejectedOnlyForBlockingRawFlag() {
        let persistentDimming = BlackoutOptions(
            selectors: ["1"],
            all: false,
            idleAfter: nil,
            timeout: nil,
            sleepAfter: nil,
            caffeinate: false,
            keepBlackoutOnInput: true,
            hardwareBrightnessPercent: 25
        )
        let workingDimming = BlackoutOptions(
            selectors: ["1"],
            all: false,
            idleAfter: nil,
            timeout: nil,
            sleepAfter: nil,
            caffeinate: false,
            keepBlackoutOnInput: true,
            mode: .working,
            hardwareBrightnessPercent: 25
        )
        let persistentOnly = BlackoutOptions(
            selectors: ["1"],
            all: false,
            idleAfter: nil,
            timeout: nil,
            sleepAfter: nil,
            caffeinate: false,
            keepBlackoutOnInput: true
        )

        XCTAssertThrowsError(try BlackoutController.validateOptions(persistentDimming)) {
            XCTAssertEqual($0 as? BlackoutError, .persistentDimming)
        }
        XCTAssertNoThrow(try BlackoutController.validateOptions(workingDimming))
        XCTAssertNoThrow(try BlackoutController.validateOptions(persistentOnly))
    }



    func testHiddenMirrorOverlayAuthorizationAllowsOnlyVerifiedMirrorSource() {
        let hidden = hiddenMirrorStatus()
        XCTAssertNil(HiddenMirrorSourceOverlayAuthorization.refusal(
            sourceUUID: "00000000-0000-0000-0000-000000000003",
            sourceDisplayID: 303,
            isMirrored: true,
            status: hidden
        ))

        let targetRefusal = HiddenMirrorSourceOverlayAuthorization.refusal(
            sourceUUID: "00000000-0000-0000-0000-000000000002",
            sourceDisplayID: 202,
            isMirrored: true,
            status: hidden
        )
        XCTAssertNotNil(targetRefusal, "the mirrored target is never authorized")

        let external = hiddenMirrorStatus(extraObservation: DisplayHideObservation(
            identity: DisplayHideIdentity(uuid: "00000000-0000-0000-0000-000000000004", displayID: 404, name: "External", vendor: 1, model: 4, serial: 44),
            state: .mirroredExternally,
            source: nil,
            detail: "Mirrored outside PanelCtl",
            isJournalTarget: false
        ))
        XCTAssertNotNil(HiddenMirrorSourceOverlayAuthorization.refusal(
            sourceUUID: "00000000-0000-0000-0000-000000000003",
            sourceDisplayID: 303,
            isMirrored: true,
            status: external
        ))

        for state in [DisplayHandoffStatus.State.recovery, .busy, .unsupported, .none] {
            let status = hiddenMirrorStatus(state: state, canShow: false)
            XCTAssertNotNil(HiddenMirrorSourceOverlayAuthorization.refusal(
                sourceUUID: "00000000-0000-0000-0000-000000000003",
                sourceDisplayID: 303,
                isMirrored: true,
                status: status
            ), "\(state) must refuse the source overlay")
        }

        XCTAssertNotNil(HiddenMirrorSourceOverlayAuthorization.refusal(
            sourceUUID: "00000000-0000-0000-0000-000000000003",
            sourceDisplayID: 303,
            isMirrored: false,
            status: hidden
        ), "a stale topology without a mirror set is refused")
        XCTAssertNotNil(HiddenMirrorSourceOverlayAuthorization.refusal(
            sourceUUID: "00000000-0000-0000-0000-000000000003",
            sourceDisplayID: 304,
            isMirrored: true,
            status: hidden
        ), "a changed source display ID is refused")
    }

    func testCoveredHiddenMirrorOverlayRevalidatesAndRemovesCoverageWithoutScreenEvents() {
        let hidden = hiddenMirrorStatus()
        var coveragePresent = true
        let stillAuthorized = HiddenMirrorSourceOverlayAuthorization.revalidateWhileCovered(
            sourceUUID: "00000000-0000-0000-0000-000000000003",
            sourceDisplayID: 303,
            isMirrored: true,
            status: hidden,
            removeCoverage: { coveragePresent = false }
        )
        XCTAssertNil(stillAuthorized)
        XCTAssertTrue(coveragePresent)

        for state in [DisplayHandoffStatus.State.recovery, .busy] {
            coveragePresent = true
            let refusal = HiddenMirrorSourceOverlayAuthorization.revalidateWhileCovered(
                sourceUUID: "00000000-0000-0000-0000-000000000003",
                sourceDisplayID: 303,
                isMirrored: true,
                status: hiddenMirrorStatus(state: state, canShow: false),
                removeCoverage: { coveragePresent = false }
            )
            XCTAssertNotNil(refusal, "\(state) revokes authorization on the next watcher tick")
            XCTAssertFalse(coveragePresent, "coverage must be removed without relying on a screen-change event")
        }
    }

    func testHiddenMirrorOverlayOptionsKeepFiniteAllScreenSafetyAndHardwareOff() throws {
        let options = BlackoutOptions(
            selectors: ["00000000-0000-0000-0000-000000000003"],
            all: false,
            idleAfter: 10,
            timeout: 60,
            sleepAfter: nil,
            caffeinate: false,
            watch: true,
            keepBlackoutOnInput: true,
            mode: .blocking,
            overlayOpacityPercent: 100,
            hardwareBrightnessPercent: nil,
            hiddenMirrorSourceUUID: "00000000-0000-0000-0000-000000000003"
        )
        XCTAssertNoThrow(try BlackoutController.validateOptions(options))
        XCTAssertThrowsError(try BlackoutController.validateSelection(
            selectedCount: 1, drawableCount: 1, hasSafetyLimit: false
        )) {
            XCTAssertEqual($0 as? BlackoutError, .allScreensSafety)
        }
        XCTAssertNoThrow(try BlackoutController.validateSelection(
            selectedCount: 1, drawableCount: 1, hasSafetyLimit: true
        ))

        let unsafe = BlackoutOptions(
            selectors: options.selectors,
            all: false,
            idleAfter: 10,
            timeout: nil,
            sleepAfter: nil,
            caffeinate: false,
            watch: true,
            mode: .blocking,
            overlayOpacityPercent: 100,
            hardwareBrightnessPercent: 10,
            hiddenMirrorSourceUUID: options.hiddenMirrorSourceUUID
        )
        XCTAssertThrowsError(try BlackoutController.validateOptions(unsafe)) {
            XCTAssertEqual($0 as? BlackoutError, .invalidHiddenMirrorSourceOverlay)
        }
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

    private func hiddenMirrorStatus(
        state: DisplayHandoffStatus.State = .hidden,
        canShow: Bool = true,
        extraObservation: DisplayHideObservation? = nil
    ) -> DisplayHandoffStatus {
        let targetIdentity = DisplayHideIdentity(
            uuid: "00000000-0000-0000-0000-000000000002",
            displayID: 202, name: "Target", vendor: 1, model: 2, serial: 22
        )
        let sourceIdentity = DisplayHideIdentity(
            uuid: "00000000-0000-0000-0000-000000000003",
            displayID: 303, name: "Source", vendor: 1, model: 3, serial: 33
        )
        let currentState: DisplayHideObservedState = state == .hidden ? .hiddenByPanelCtl : .recoveryNeeded
        var observations = [
            DisplayHideObservation(
                identity: targetIdentity,
                state: currentState,
                source: sourceIdentity,
                detail: nil,
                isJournalTarget: state != .none
            ),
            DisplayHideObservation(
                identity: sourceIdentity,
                state: .separate,
                source: nil,
                detail: nil,
                isJournalTarget: false
            )
        ]
        if let extraObservation { observations.append(extraObservation) }
        return DisplayHandoffStatus(
            state: state,
            target: DisplayHandoffIdentity(targetIdentity),
            source: DisplayHandoffIdentity(sourceIdentity),
            journalPath: "/tmp/panelctl-overlay-fixture/current.json",
            journalID: state == .none ? nil : "hidden-overlay-fixture",
            canShow: canShow,
            observations: observations,
            mirrorTopologyVerified: state == .hidden
        )
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

    func testTopologyRearmRejectsPreRecoveryIdleUntilFreshInputAndFullCountdown() {
        var state = BlackoutWatchState()
        let policy = BlackoutPolicy(idleAfter: 5, timeout: nil, sleepAfter: nil)
        state.reset(.topologyChanged, after: 100)

        XCTAssertFalse(state.consumeFreshInput(
            IdleSample(seconds: 3_600, lastInputUptime: 100),
            allowScreenWakeFallback: true
        ))
        XCTAssertFalse(state.mayBeginCycle)

        XCTAssertTrue(state.consumeFreshInput(
            IdleSample(seconds: 0, lastInputUptime: 101),
            allowScreenWakeFallback: true
        ))
        XCTAssertTrue(state.mayBeginCycle)
        XCTAssertFalse(policy.shouldBegin(idleSeconds: 0))
        XCTAssertFalse(policy.shouldBegin(idleSeconds: 4.9))
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
        XCTAssertEqual(
            BlackoutController.workspaceEvent(for: BlackoutController.screenLockedNotification),
            .reset(.suspension(.screenLocked))
        )
        XCTAssertEqual(
            BlackoutController.workspaceEvent(for: BlackoutController.screenUnlockedNotification),
            .resume(.screenLocked)
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
