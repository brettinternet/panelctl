import AppKit
import ApplicationServices
import Darwin
import XCTest
@testable import PanelCtlApp
@testable import PanelCtlCore

@MainActor
final class DisplayHideAppTests: XCTestCase {
    // Keep AppKit's tracked-menu objects alive past XCTest's per-scope memory checker.
    private static var retainedNativeMenuFixtures: [AnyObject] = []
    private static let mainUUID = "00000000-0000-0000-0000-000000000001"
    private static let targetUUID = "00000000-0000-0000-0000-000000000002"
    private static let sourceUUID = "00000000-0000-0000-0000-000000000003"
    private static let replacementUUID = "00000000-0000-0000-0000-000000000004"
    private var displays: [DisplayRecord] {
        [
            Self.display(index: 1, id: 101, uuid: Self.mainUUID, name: "Main OLED", main: true),
            Self.display(index: 2, id: 202, uuid: Self.targetUUID, name: "Target", main: false),
            Self.display(index: 3, id: 303, uuid: Self.sourceUUID, name: "Mirror source", main: false)
        ]
    }

    private func activateForegroundNativeKeyboardFixture(
        requiresCGEventPostPermission: Bool = true
    ) throws -> (activationPolicy: NSApplication.ActivationPolicy, previouslyFrontmost: NSRunningApplication?) {
        guard ProcessInfo.processInfo.environment["PANELCTL_RUN_NATIVE_DISPLAY_KEYBOARD_FIXTURES"] == "1" else {
            throw XCTSkip("Foreground native-key fixtures are opt-in. Set PANELCTL_RUN_NATIVE_DISPLAY_KEYBOARD_FIXTURES=1 to activate the XCTest host; any CGEvent is posted only to that XCTest process PID.")
        }
        if requiresCGEventPostPermission && !CGPreflightPostEventAccess() {
            let hostPath = ProcessInfo.processInfo.arguments.first ?? ProcessInfo.processInfo.processName
            throw XCTSkip("Native Escape key validation requires Accessibility event-post access for the XCTest host at \(hostPath) (System Settings → Privacy & Security → Accessibility), plus PANELCTL_RUN_NATIVE_DISPLAY_KEYBOARD_FIXTURES=1.")
        }

        let previouslyFrontmost = NSWorkspace.shared.frontmostApplication
        let application = NSApplication.shared
        let originalActivationPolicy = application.activationPolicy()
        guard application.setActivationPolicy(.regular) else {
            throw XCTSkip("The opted-in XCTest host could not change to a regular app activation policy.")
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == currentPID else {
            application.setActivationPolicy(originalActivationPolicy)
            previouslyFrontmost?.activate(options: [.activateAllWindows])
            throw XCTSkip("The opted-in XCTest host did not become frontmost; no keyboard event was posted.")
        }
        return (originalActivationPolicy, previouslyFrontmost)
    }

    func testVerifiedRecoveryReleaseRearmsHelperBeforeStaleIdleCanTrigger() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-recovery-rearm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = try writeRearmHelper(in: directory)
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var preferences = ProtectionPreferences()
        preferences.isEnabled = true
        preferences.didChooseDisplays = true
        preferences.selectedDisplayUUIDs = [Self.mainUUID]
        defaults.set(try JSONEncoder().encode(preferences), forKey: "blackoutPreferences")

        setenv("PANELCTL_HELPER", helper.path, 1)
        unsetenv("PANELCTL_REARM_ON_START")
        defer {
            unsetenv("PANELCTL_HELPER")
            unsetenv("PANELCTL_REARM_ON_START")
            unsetenv("PANELCTL_TEST_LOG")
        }
        let hidden = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "resume-journal", canShow: true)
        let box = StatusBox(hidden)
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            idleSecondsProvider: { 3600 },
            status: { box.value },
            useManagedProtectionService: true
        )
        try await waitUntil { !model.protectionQuiescencePending }
        let actionLog = directory.appendingPathComponent("actions.log")
        let staleIdle = directory.appendingPathComponent("stale-idle")
        try Data().write(to: staleIdle)
        setenv("PANELCTL_TEST_STALE_IDLE", staleIdle.path, 1)
        setenv("PANELCTL_TEST_ACTION_LOG", actionLog.path, 1)
        defer { unsetenv("PANELCTL_TEST_ACTION_LOG"); unsetenv("PANELCTL_TEST_STALE_IDLE") }

        box.value = handoffStatus(.none, target: nil, source: nil)
        model.refreshHandoffStatus()
        let launches = try await waitForLogLines(1, at: directory.appendingPathComponent("launches.log"))
        XCTAssertEqual(launches, ["launch:1"])
        try await waitUntil { model.runtimeState == .waitingForInput }
        XCTAssertFalse(FileManager.default.fileExists(atPath: actionLog.path), "stale idle must not blackout or dim before fresh input")

        let stopped = expectation(description: "rearmed helper stopped")
        model.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
    }

    func testPreCaptureHideRefusalRearmsHelperAndDoesNotReuseOldIdle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-hide-refusal-rearm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = try writeRearmHelper(in: directory)
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var preferences = ProtectionPreferences()
        preferences.isEnabled = true
        preferences.didChooseDisplays = true
        preferences.selectedDisplayUUIDs = [Self.mainUUID]
        defaults.set(try JSONEncoder().encode(preferences), forKey: "blackoutPreferences")

        setenv("PANELCTL_HELPER", helper.path, 1)
        unsetenv("PANELCTL_REARM_ON_START")
        defer {
            unsetenv("PANELCTL_HELPER")
            unsetenv("PANELCTL_REARM_ON_START")
            unsetenv("PANELCTL_TEST_LOG")
        }
        let actionLog = directory.appendingPathComponent("actions.log")
        let staleIdle = directory.appendingPathComponent("stale-idle")
        setenv("PANELCTL_TEST_STALE_IDLE", staleIdle.path, 1)
        setenv("PANELCTL_TEST_ACTION_LOG", actionLog.path, 1)
        defer { unsetenv("PANELCTL_TEST_ACTION_LOG"); unsetenv("PANELCTL_TEST_STALE_IDLE") }
        var hideAttempts = 0
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            idleSecondsProvider: { 3600 },
            useManagedProtectionService: true,
            hideDisplay: { _, _ in
                hideAttempts += 1
                throw NSError(domain: "FakeMirrorWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "preflight refusal; no capture"])
            }
        )
        let launchesPath = directory.appendingPathComponent("launches.log")
        let initialLaunches = try await waitForLogLines(1, at: launchesPath)
        XCTAssertEqual(initialLaunches, ["launch:0"])
        try Data().write(to: staleIdle)
        model.setHideEnabled(true, for: displays[1])
        model.setHideSource(Self.mainUUID, for: Self.targetUUID)
        var request: DisplayHideRequest?
        model.onRequestHide = { request = $0 }
        model.requestHide(targetUUID: Self.targetUUID)
        model.confirmHide(try XCTUnwrap(request), acknowledged: true)
        try await waitUntil { !model.hideOperation.isBusy && hideAttempts == 1 }

        let restartedLaunches = try await waitForLogLines(2, at: launchesPath)
        XCTAssertEqual(restartedLaunches, ["launch:0", "launch:1"])
        try await waitUntil { model.runtimeState == .waitingForInput }
        XCTAssertFalse(FileManager.default.fileExists(atPath: actionLog.path), "pre-capture refusal must not reuse stale idle")
        XCTAssertTrue(model.notice?.message.contains("preflight refusal") == true)

        let stopped = expectation(description: "rearmed helper stopped")
        model.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
    }

    func testLegacyProtectionPreferencesRemainIndependentFromHideMigration() throws {
        let defaults = try makeDefaults()
        let legacy = Data(#"{"isEnabled":false,"idleSeconds":120,"allDisplays":false,"selectedDisplayUUIDs":["CCCC-UUID"],"didChooseDisplays":true}"#.utf8)
        defaults.set(legacy, forKey: "blackoutPreferences")
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }

        let model = makeModel(defaults: defaults, displays: displays)

        XCTAssertFalse(model.preferences.isEnabled)
        XCTAssertEqual(model.preferences.idleSeconds, 120)
        XCTAssertEqual(model.preferences.selectedDisplayUUIDs, ["CCCC-UUID"])
        XCTAssertFalse(model.preferences.allDisplays)
        XCTAssertTrue(model.hidePreferences.configurations.isEmpty)
        XCTAssertNil(defaults.data(forKey: "displayHidePreferences"))
        XCTAssertEqual(model.menuHideConfigurations, [])
    }

    func testPerDisplayHideConfigurationPersistsIndependently() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let model = makeModel(defaults: defaults, displays: displays)
        let protectionBefore = model.preferences
        let target = displays[1]
        let otherTarget = displays[2]

        model.setHideEnabled(true, for: target)
        model.setHideSource(Self.mainUUID, for: target.uuid!)
        model.setHideEnabled(true, for: otherTarget)
        model.setHideSource(Self.mainUUID, for: otherTarget.uuid!)
        model.setHideEnabled(false, for: target)

        let first = try XCTUnwrap(model.hidePreferences[target.uuid!])
        let second = try XCTUnwrap(model.hidePreferences[otherTarget.uuid!])
        XCTAssertFalse(first.enabled)
        XCTAssertEqual(first.source?.uuid, Self.mainUUID)
        XCTAssertTrue(second.enabled)
        XCTAssertEqual(second.source?.uuid, Self.mainUUID)
        XCTAssertEqual(model.preferences, protectionBefore)
        let savedProtectionData = try XCTUnwrap(defaults.data(forKey: "blackoutPreferences"))
        XCTAssertEqual(try JSONDecoder().decode(ProtectionPreferences.self, from: savedProtectionData), protectionBefore)
        XCTAssertNotNil(defaults.data(forKey: "displayHidePreferences"))

        let reloaded = makeModel(defaults: defaults, displays: displays)
        XCTAssertEqual(reloaded.hidePreferences, model.hidePreferences)
        XCTAssertEqual(reloaded.preferences, protectionBefore)
    }

    func testMissingAndChangedTargetsRemainBoundToTheirSavedIdentity() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let initial = makeModel(defaults: defaults, displays: displays)
        initial.setHideEnabled(true, for: displays[1])
        initial.setHideSource(Self.mainUUID, for: Self.targetUUID)
        let replacement = Self.display(index: 2, id: 202, uuid: Self.replacementUUID, name: "Target", main: false)
        let reloaded = makeModel(defaults: defaults, displays: [displays[0], replacement, displays[2]])

        let saved = try XCTUnwrap(reloaded.hideDisplayConfigurations.first {
            $0.target.uuid == Self.targetUUID
        })
        XCTAssertEqual(saved.target.name, "Target")
        XCTAssertTrue(saved.enabled)
        XCTAssertFalse(reloaded.identityIsCurrent(saved.target))
        XCTAssertTrue(reloaded.hideReadinessMessage(for: saved)?.contains("will not bind") == true)
        XCTAssertThrowsError(try reloaded.makeHideRequest(targetUUID: Self.targetUUID))
        XCTAssertFalse(reloaded.hasHideConfiguration(targetUUID: Self.replacementUUID))
    }

    func testOrdinaryDisableFailureOrUnknownCleanupBlocksLaterHide() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-hide-cleanup-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("fake-panelctl")
        let script = """
        #!/bin/bash
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        trap 'if [[ "$PANELCTL_TEST_CLEANUP_RESULT" != "unknown" ]]; then printf "{\\"state\\":\\"stopped\\",\\"blackedOutDisplayIDs\\":[],\\"cleanupSucceeded\\":false}\\n"; fi; exit 0' TERM
        while true; do /bin/sleep 0.02; done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        setenv("PANELCTL_HELPER", helper.path, 1)
        defer {
            unsetenv("PANELCTL_HELPER")
            unsetenv("PANELCTL_TEST_CLEANUP_RESULT")
        }

        for cleanupResult in ["false", "unknown"] {
            setenv("PANELCTL_TEST_CLEANUP_RESULT", cleanupResult, 1)
            let service = ProtectionService()
            service.run(arguments: ["blackout"])
            try await waitUntil { service.state == .waiting }
            service.disable()
            try await waitUntil {
                if case .failed = service.state { return true }
                return false
            }

            let defaults = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
            var hideCalls = 0
            let model = makeModel(
                defaults: defaults,
                displays: displays,
                quiesceProtection: { completion in
                    service.disableForDisplayHide(completion: completion)
                },
                hideDisplay: { _, _ in hideCalls += 1 }
            )
            model.setHideEnabled(true, for: displays[1])
            model.setHideSource(Self.mainUUID, for: Self.targetUUID)
            var request: DisplayHideRequest?
            model.onRequestHide = { request = $0 }
            model.requestHide(targetUUID: Self.targetUUID)
            model.confirmHide(try XCTUnwrap(request), acknowledged: true)
            try await waitUntil { !model.hideOperation.isBusy }

            XCTAssertEqual(hideCalls, 0, "cleanup \(cleanupResult) retained after ordinary disable must block Hide")
            XCTAssertTrue(model.protectionQuiescenceFailure?.localizedCaseInsensitiveContains("cleanup") == true)
            XCTAssertEqual(model.notice?.title, "Hide not started")
        }
    }

    func testHideQuiescesBeforeBackendAndRefusesDuplicateOrCleanupFailure() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var completion: ((Bool, String?) -> Void)?
        var quiesceCalls = 0
        var hideCalls = 0
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            quiesceProtection: { callback in
                quiesceCalls += 1
                completion = callback
            },
            hideDisplay: { _, _ in hideCalls += 1 }
        )
        model.setHideEnabled(true, for: displays[1])
        model.setHideSource(Self.mainUUID, for: Self.targetUUID)
        let protectedSelection = model.preferences.selectedDisplayUUIDs
        var request: DisplayHideRequest?
        model.onRequestHide = { request = $0 }
        model.requestHide(targetUUID: Self.targetUUID)
        let confirmation = try XCTUnwrap(request)

        model.confirmHide(confirmation, acknowledged: false)
        XCTAssertEqual(quiesceCalls, 0)
        XCTAssertEqual(hideCalls, 0)
        XCTAssertEqual(model.notice?.title, "Hide canceled")
        model.confirmHide(confirmation, acknowledged: true)
        model.confirmHide(confirmation, acknowledged: true)
        XCTAssertEqual(quiesceCalls, 1)
        XCTAssertEqual(hideCalls, 0)
        XCTAssertTrue(model.hideOperation.isBusy)
        let delegate = AppDelegate()
        delegate.model = model
        XCTAssertTrue(delegate.makeMenu().items.contains { $0.title == "Hiding…" })

        completion?(false, "brightness restore failed")
        try await waitUntil { !model.hideOperation.isBusy }
        XCTAssertEqual(hideCalls, 0)
        XCTAssertNil(model.handoffStatus?.journalID)
        XCTAssertTrue(model.protectionQuiescenceFailure?.contains("brightness restore failed") == true)
        XCTAssertEqual(model.preferences.selectedDisplayUUIDs, protectedSelection)
        XCTAssertFalse(model.preferences.isEnabled)
        XCTAssertEqual(model.notice?.title, "Hide not started")
    }

    func testConfirmedIdentityChangeAtLockedBackendRefusesBeforeJournalOrWriter() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-hide-identity-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryStore(url: directory.appendingPathComponent("current.json"))
        let operationStore = RecoveryStore(url: directory.appendingPathComponent("operation"))
        var backendDisplays = displays
        var captureCalls = 0
        var writerCalls = 0
        var hideRequest: DisplayHideRequest?
        var quiesceCompletion: ((Bool, String?) -> Void)?
        let mirror = MirrorController(
            records: { backendDisplays },
            operationLock: { operationStore },
            engine: RecoveryEngine(
                capture: {
                    captureCalls += 1
                    throw NSError(domain: "UnexpectedCapture", code: 1)
                },
                apply: { _ in writerCalls += 1 },
                convergencePause: {}
            ),
            transaction: MirrorTransaction(
                begin: { writerCalls += 1; return OpaquePointer(bitPattern: 1)! },
                stage: { _, _, _ in writerCalls += 1 },
                complete: { _, _ in writerCalls += 1 },
                cancel: { _ in }
            )
        )
        let backend = DisplayHideController(
            store: store,
            mirror: mirror,
            operationLock: { operationStore }
        )
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            quiesceProtection: { quiesceCompletion = $0 },
            hideDisplay: { target, source in
                backendDisplays[1] = Self.display(
                    index: 2, id: 202, uuid: Self.targetUUID,
                    name: "Target", main: false, serial: 999
                )
                try backend.hide(target: target, source: source)
            }
        )
        model.setHideEnabled(true, for: displays[1])
        model.setHideSource(Self.mainUUID, for: Self.targetUUID)
        model.onRequestHide = { hideRequest = $0 }
        model.requestHide(targetUUID: Self.targetUUID)
        model.confirmHide(try XCTUnwrap(hideRequest), acknowledged: true)
        XCTAssertNotNil(quiesceCompletion, "the app has validated the confirmed identities before cleanup begins")

        quiesceCompletion?(true, nil)
        try await waitUntil { !model.hideOperation.isBusy }

        XCTAssertEqual(captureCalls, 0, "identity refusal happens before fresh capture")
        XCTAssertEqual(writerCalls, 0, "no transaction or writer begins for a changed target")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path), "no recovery journal is created")
        XCTAssertTrue(model.notice?.message.localizedCaseInsensitiveContains("target identity changed") == true, model.notice?.message ?? "missing notice")
    }

    func testBackendRefusalBeforeCaptureKeepsNoJournalAndNoFalseSuccess() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(handoffStatus(.none, target: nil, source: nil))
        var hideCalls = 0
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            status: { box.value },
            hideDisplay: { _, _ in
                hideCalls += 1
                throw NSError(domain: "FakeMirrorWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "fake preflight refusal; no capture"])
            }
        )
        model.setHideEnabled(true, for: displays[1])
        model.setHideSource(Self.mainUUID, for: Self.targetUUID)
        var request: DisplayHideRequest?
        model.onRequestHide = { request = $0 }
        model.requestHide(targetUUID: Self.targetUUID)
        model.confirmHide(try XCTUnwrap(request), acknowledged: true)

        try await waitUntil { !model.hideOperation.isBusy }
        XCTAssertEqual(hideCalls, 1)
        XCTAssertEqual(model.handoffStatus?.state, DisplayHandoffStatus.State.none)
        XCTAssertFalse(model.protectionPausedForDisplayRecovery)
        XCTAssertEqual(model.notice?.title, "Could not hide the desktop")
        XCTAssertTrue(model.notice?.message.contains("no capture") == true)
    }

    func testPartialHideFailureKeepsRecoveryAndBlocksAnotherHide() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let recovery = handoffStatus(.recovery, target: displays[1], source: displays[0], journalID: "fake-journal", canShow: false, reason: "fake writer interrupted; journal retained")
        let box = StatusBox(handoffStatus(.none, target: nil, source: nil))
        var hideCalls = 0
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            status: { box.value },
            quiesceProtection: { $0(true, nil) },
            hideDisplay: { _, _ in
                hideCalls += 1
                box.value = recovery
                throw NSError(domain: "FakeMirrorWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "fake writer interrupted; journal retained"])
            }
        )
        model.setHideEnabled(true, for: displays[1])
        model.setHideSource(Self.mainUUID, for: Self.targetUUID)
        var request: DisplayHideRequest?
        model.onRequestHide = { request = $0 }
        model.requestHide(targetUUID: Self.targetUUID)
        model.confirmHide(try XCTUnwrap(request), acknowledged: true)

        try await waitUntil { !model.hideOperation.isBusy }
        XCTAssertEqual(hideCalls, 1)
        XCTAssertEqual(model.handoffStatus?.state, .recovery)
        XCTAssertEqual(model.handoffStatus?.journalID, "fake-journal")
        XCTAssertTrue(model.protectionPausedForDisplayRecovery)
        XCTAssertThrowsError(try model.makeHideRequest(targetUUID: Self.targetUUID))
        XCTAssertEqual(model.notice?.title, "Could not hide the desktop")
        XCTAssertTrue(model.notice?.message.contains("journal retained") == true)
    }

    func testShowUsesConfirmedJournalAndRetainsFailureWithoutFalseSuccess() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let hidden = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "captured-journal", canShow: true)
        let box = StatusBox(hidden)
        var shownJournalIDs: [String] = []
        var showFails = true
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            status: { box.value },
            quiesceProtection: { $0(true, nil) },
            showDisplay: { journalID in
                shownJournalIDs.append(journalID)
                if showFails {
                    throw NSError(domain: "FakeRecoveryWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "fake restore mismatch; journal retained"])
                }
                box.value = self.handoffStatus(.none, target: nil, source: nil)
            }
        )
        try await waitUntil { !model.protectionQuiescencePending }

        var request: DisplayHandoffStatus?
        model.onRequestShow = { request = $0 }
        model.requestShow()
        let confirmation = try XCTUnwrap(request)
        model.confirmShow(confirmation, acknowledged: false)
        XCTAssertTrue(shownJournalIDs.isEmpty)
        XCTAssertEqual(model.notice?.title, "Show canceled")
        model.confirmShow(confirmation, acknowledged: true)
        try await waitUntil { !model.hideOperation.isBusy }

        XCTAssertEqual(shownJournalIDs, ["captured-journal"])
        XCTAssertEqual(model.handoffStatus?.state, .hidden)
        XCTAssertTrue(model.protectionPausedForDisplayRecovery)
        XCTAssertEqual(model.notice?.title, "Could not show the journaled desktop")
        XCTAssertTrue(model.notice?.message.contains("fake restore mismatch") == true)

        showFails = false
        model.requestShow()
        model.confirmShow(try XCTUnwrap(request), acknowledged: true)
        try await waitUntil {
            !model.hideOperation.isBusy && model.handoffStatus?.state == DisplayHandoffStatus.State.none
        }
        XCTAssertEqual(shownJournalIDs, ["captured-journal", "captured-journal"])
        XCTAssertFalse(model.protectionPausedForDisplayRecovery)
        XCTAssertEqual(model.notice?.title, "Desktop restored")
    }

    func testLifecycleAndConfirmationTextKeepActionsExplicitAndOLEDWarningVisible() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(handoffStatus(.none, target: nil, source: nil))
        let model = makeModel(defaults: defaults, displays: displays, status: { box.value })
        model.setHideEnabled(true, for: displays[1])
        model.setHideSource(Self.mainUUID, for: Self.targetUUID)
        model.setDisplayLifecycleTransitioning(true)
        XCTAssertThrowsError(try model.makeHideRequest(targetUUID: Self.targetUUID))
        model.setDisplayLifecycleTransitioning(false)

        let request = try model.makeHideRequest(targetUUID: Self.targetUUID)
        let hideText = DisplayOperationConfirmation.hideMessage(request, journalPath: "/tmp/synthetic/current.json")
        XCTAssertTrue(hideText.contains("Target: Target"))
        XCTAssertTrue(hideText.contains("Explicit mirror source: Main OLED"))
        XCTAssertTrue(hideText.contains("Recovery journal: /tmp/synthetic/current.json"))
        XCTAssertTrue(hideText.contains("While hidden, PanelCtl cannot black out Main OLED or any other display."))
        XCTAssertTrue(hideText.contains("An OLED source stays lit until you Show or macOS display sleep turns it off."))

        let showText = DisplayOperationConfirmation.showMessage(
            handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "journal", canShow: true)
        )
        XCTAssertTrue(showText.contains("Journaled target: Target"))
        XCTAssertTrue(showText.contains("Captured mirror source: Main OLED"))
        XCTAssertTrue(showText.contains("Restoring the layout may affect other captured displays"))
        XCTAssertTrue(showText.contains("Recovery journal:"))

        box.value = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "lifecycle-journal", canShow: true)
        model.refreshHandoffStatus()
        model.setDisplayLifecycleTransitioning(true)
        XCTAssertThrowsError(try model.makeShowRequest())
        model.setDisplayLifecycleTransitioning(false)
        try await waitUntil { !model.protectionQuiescencePending }
        XCTAssertNoThrow(try model.makeShowRequest())
    }

    func testNativeSettingsFixtureRetainsMissingRecoveryIdentityAndFreezesEditing() throws {
        let defaults = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName(defaults))
            NSApp.windows.filter { $0.title == "PanelCtl Settings" }.forEach { $0.close() }
        }
        let recovery = handoffStatus(
            .recovery,
            target: displays[1],
            source: displays[0],
            journalID: "unavailable-fixture-journal",
            canShow: false,
            reason: "The journaled target is unavailable. Reconnect the exact display and Refresh.",
            observationState: .unavailable
        )
        let model = makeModel(
            defaults: defaults,
            displays: [displays[0], displays[2]],
            status: { recovery }
        )
        XCTAssertEqual(model.handoffStatus?.state, .recovery)
        XCTAssertFalse(model.handoffStatus?.canShow ?? true)
        let savedTarget = try XCTUnwrap(model.hideDisplayConfigurations.first {
            $0.target.uuid == Self.targetUUID
        })
        XCTAssertEqual(model.observedDesktopState(for: savedTarget), "Unavailable")
        XCTAssertFalse(model.identityIsCurrent(savedTarget.target))

        let controller = SettingsWindowController(model: model)
        controller.present()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 680, height: 1200))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let controls = nativeControls(in: try XCTUnwrap(window.contentView))
        let sourcePicker = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityLabel() == "Mirror source for Target"
        })
        XCTAssertFalse(sourcePicker.isEnabled, "The missing target remains visible by saved identity but cannot be edited or rebound")
    }

    func testNativeConfirmationRequiresAccessibleAcknowledgementAndDefaultsToCancel() throws {
        let confirmation = DisplayOperationConfirmation.prepareConfirmation(
            title: "Hide Target?",
            message: "Target and source identities",
            actionTitle: "Hide desktop"
        )

        XCTAssertEqual(confirmation.alert.alertStyle, .warning)
        XCTAssertEqual(confirmation.alert.buttons.map(\.title), ["Cancel", "Hide desktop"])
        XCTAssertTrue(confirmation.alert.window.defaultButtonCell === confirmation.cancelButton.cell)
        XCTAssertFalse(confirmation.actionButton.isEnabled)
        XCTAssertEqual(
            confirmation.acknowledgement.accessibilityLabel(),
            DisplayOperationConfirmation.recoveryAcknowledgement
        )
        let acknowledgementLabel = try XCTUnwrap(
            confirmation.alert.accessoryView?.subviews.compactMap { $0 as? NSTextField }.first
        )
        XCTAssertEqual(acknowledgementLabel.stringValue, DisplayOperationConfirmation.recoveryAcknowledgement)
        XCTAssertEqual(acknowledgementLabel.accessibilityLabel(), DisplayOperationConfirmation.recoveryAcknowledgement)

        confirmation.acknowledgement.performClick(nil)
        XCTAssertEqual(confirmation.acknowledgement.state, .on)
        XCTAssertTrue(confirmation.actionButton.isEnabled)
        confirmation.acknowledgement.performClick(nil)
        XCTAssertEqual(confirmation.acknowledgement.state, .off)
        XCTAssertFalse(confirmation.actionButton.isEnabled)
    }

    func testNativeMenuArrowEventsReachShowAction() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let hidden = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "keyboard-menu-journal", canShow: true)
        let model = makeModel(defaults: defaults, displays: displays, status: { hidden })
        var requestedJournalID: String?
        model.onRequestShow = { requestedJournalID = $0.journalID }
        let originalFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let delegate = AppDelegate()
        delegate.model = model
        let menu = delegate.makeMenu()
        let showItem = try XCTUnwrap(menu.items.first { $0.title == "Show Target…" })

        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 320, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        window.contentView = hostView
        window.orderFront(nil)
        let down = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{f701}",
            charactersIgnoringModifiers: "\u{f701}",
            isARepeat: false,
            keyCode: 125
        ))
        let enter = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))

        var arrowCount = 0
        var reachedShowItem = false
        var menuClosed = false
        let timeout = DispatchWorkItem { if !menuClosed { menu.cancelTracking() } }
        func navigateByArrow() {
            guard !menuClosed else { return }
            if menu.highlightedItem === showItem {
                reachedShowItem = true
                NSApp.postEvent(enter, atStart: false)
                return
            }
            guard arrowCount < menu.numberOfItems * 2 else {
                menu.cancelTracking()
                return
            }
            arrowCount += 1
            NSApp.postEvent(down, atStart: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { navigateByArrow() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { navigateByArrow() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
        Self.retainedNativeMenuFixtures = [delegate, menu, showItem, window, hostView, down, enter]
        XCTAssertTrue(menu.popUp(positioning: nil, at: NSPoint(x: 20, y: 20), in: hostView))
        menuClosed = true
        timeout.cancel()
        window.orderOut(nil)

        XCTAssertGreaterThan(arrowCount, 0, "the menu must receive actual Arrow Down key events")
        XCTAssertTrue(reachedShowItem, "arrow navigation must highlight Show Target before Return")
        XCTAssertEqual(requestedJournalID, "keyboard-menu-journal")
        XCTAssertEqual(
            NSWorkspace.shared.frontmostApplication?.processIdentifier,
            originalFrontmostPID,
            "the app-local keyboard fixture must not activate the XCTest host"
        )
    }

    func testNativeEscapeEventCancelsConfirmationWithoutAction() throws {
        let applicationState = try activateForegroundNativeKeyboardFixture()
        defer {
            NSApp.setActivationPolicy(applicationState.activationPolicy)
            applicationState.previouslyFrontmost?.activate(options: [.activateAllWindows])
        }
        let confirmation = DisplayOperationConfirmation.prepareConfirmation(
            title: "Show Target?",
            message: "Synthetic confirmation fixture; no backend is connected.",
            actionTitle: "Show desktop"
        )
        var injectionWindowNumber: Int?
        var inputFailure: String?
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let timeout = DispatchWorkItem { NSApp.stopModal(withCode: .alertFirstButtonReturn) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let modalWindow = NSApp.modalWindow,
                  let source = CGEventSource(stateID: .hidSystemState),
                  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false) else {
                inputFailure = "Could not create an Escape event targeted at the XCTest PID."
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
                return
            }
            injectionWindowNumber = modalWindow.windowNumber
            keyDown.postToPid(currentPID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { keyUp.postToPid(currentPID) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
        let start = ProcessInfo.processInfo.systemUptime
        let response = confirmation.alert.runModal()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        timeout.cancel()

        XCTAssertNotNil(injectionWindowNumber)
        XCTAssertNil(inputFailure)
        XCTAssertEqual(response, .alertFirstButtonReturn)
        XCTAssertFalse(confirmation.acknowledgement.state == .on)
        XCTAssertLessThan(elapsed, 1.5, "Escape must dismiss the real alert window before the safety timeout")
    }

    func testNativeShowCompletionAndFailureFocusTheirSettingsNotice() async throws {
        let applicationState = try activateForegroundNativeKeyboardFixture(requiresCGEventPostPermission: false)
        defer {
            NSApp.setActivationPolicy(applicationState.activationPolicy)
            applicationState.previouslyFrontmost?.activate(options: [.activateAllWindows])
        }
        for succeeds in [true, false] {
            let defaults = try makeDefaults()
            defer {
                defaults.removePersistentDomain(forName: suiteName(defaults))
                NSApp.windows.filter { $0.title == "PanelCtl Settings" }.forEach { $0.close() }
            }
            let hidden = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "focus-journal", canShow: true)
            let box = StatusBox(hidden)
            var showCalls = 0
            let model = makeModel(
                defaults: defaults,
                displays: displays,
                status: { box.value },
                showDisplay: { _ in
                    showCalls += 1
                    if succeeds {
                        box.value = self.handoffStatus(.none, target: nil, source: nil)
                    } else {
                        throw NSError(domain: "FakeRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: "offline verification failure"])
                    }
                }
            )
            let controller = SettingsWindowController(model: model)
            controller.present()
            model.requestDisplayRecoveryFocus()
            let window = try XCTUnwrap(controller.window)
            window.setContentSize(NSSize(width: 680, height: 1200))
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            let sourcePicker = try XCTUnwrap(nativeControls(in: try XCTUnwrap(window.contentView)).compactMap { $0 as? NSPopUpButton }.first {
                $0.accessibilityLabel() == "Mirror source for Target"
            })
            XCTAssertTrue(window.makeFirstResponder(sourcePicker))

            model.confirmShow(hidden, acknowledged: true)
            try await waitUntil { model.notice != nil && !model.hideOperation.isBusy }
            try await Task.sleep(nanoseconds: 100_000_000)

            let expectedTitle = succeeds ? "Desktop restored" : "Could not show the journaled desktop"
            XCTAssertEqual(model.notice?.title, expectedTitle)
            XCTAssertEqual(showCalls, 1)
            XCTAssertTrue(succeeds
                ? model.handoffStatus?.state == DisplayHandoffStatus.State.none
                : model.handoffStatus?.state == DisplayHandoffStatus.State.hidden)
            let noticeSheet = try XCTUnwrap(window.attachedSheet, "completion and failure notices must present a native Settings sheet")
            XCTAssertTrue(noticeSheet.isKeyWindow, "focus must move into the completion/error notice")
            XCTAssertNotNil(noticeSheet.firstResponder)
            guard let returnDown = NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: noticeSheet.windowNumber,
                    context: nil,
                    characters: "\r",
                    charactersIgnoringModifiers: "\r",
                    isARepeat: false,
                    keyCode: 36
                  ),
                  let returnUp = NSEvent.keyEvent(
                    with: .keyUp,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime + 0.04,
                    windowNumber: noticeSheet.windowNumber,
                    context: nil,
                    characters: "\r",
                    charactersIgnoringModifiers: "\r",
                    isARepeat: false,
                    keyCode: 36
                  ) else {
                XCTFail("Could not create app-local Return events for the focused notice")
                continue
            }
            NSApp.sendEvent(returnDown)
            NSApp.sendEvent(returnUp)
            try await waitUntil { window.attachedSheet == nil }
            XCTAssertTrue(window.isKeyWindow)
            XCTAssertTrue(window.firstResponder === sourcePicker, "dismissal restores focus to the setting that had focus before the notice")
        }
    }

    func testNativeLongRecoveryContentFitsScrollableMinimumWidthSettings() throws {
        let defaults = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName(defaults))
            NSApp.windows.filter { $0.title == "PanelCtl Settings" }.forEach { $0.close() }
        }
        let longName = String(repeating: "VeryLongMonitorName-", count: 8)
        let target = Self.display(index: 2, id: 202, uuid: Self.targetUUID, name: longName, main: false)
        let source = Self.display(index: 1, id: 101, uuid: Self.mainUUID, name: "Main OLED", main: true)
        let longError = String(repeating: "Recovery identity/mode mismatch; reconnect the exact display and review the captured journal. ", count: 30)
        let recovery = handoffStatus(
            .recovery,
            target: target,
            source: source,
            journalID: "long-content-journal",
            canShow: false,
            reason: longError
        )
        var hidePreferences = DisplayHidePreferences()
        hidePreferences[Self.targetUUID] = DisplayHideConfiguration(
            target: DisplayIdentitySnapshot(target),
            enabled: true,
            source: DisplayIdentitySnapshot(source)
        )
        defaults.set(try JSONEncoder().encode(hidePreferences), forKey: "displayHidePreferences")
        let model = makeModel(defaults: defaults, displays: [source, target], status: { recovery })
        XCTAssertEqual(model.hideDisplayConfigurations.map(\.target.name), [longName])
        let controller = SettingsWindowController(model: model)
        controller.present()
        model.requestDisplayRecoveryFocus()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 440, height: 560))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let root = try XCTUnwrap(window.contentView)
        XCTAssertGreaterThan(root.fittingSize.width, 0)
        XCTAssertGreaterThan(root.fittingSize.height, 0)
        let scrollView = try XCTUnwrap(nativeViews(in: root).compactMap { $0 as? NSScrollView }.last)
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: documentHeight))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        root.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let controls = nativeControls(in: root)
        let controlSummary = controls.map {
            String(describing: type(of: $0)) + ": " + ($0.accessibilityLabel() ?? "unlabeled")
        }
        let sourcePicker = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityLabel() == "Mirror source for \(longName)"
        }, "Native controls: \(controlSummary)")
        XCTAssertFalse(sourcePicker.isEnabled)
        XCTAssertGreaterThan(sourcePicker.frame.width, 0)
        XCTAssertLessThanOrEqual(root.bounds.width, 440)
        XCTAssertLessThanOrEqual(sourcePicker.frame.width, root.bounds.width)
        XCTAssertTrue(sourcePicker.itemTitles.contains { $0.contains(Self.mainUUID) && $0.contains("Display ID 101") })
    }

    func testNativeMenuAndSettingsFixtureExposeRecoveryAndKeyboardAccessibility() throws {
        let defaults = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName(defaults))
            NSApp.windows.filter { $0.title == "PanelCtl Settings" }.forEach { $0.close() }
        }
        let hidden = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "fixture-journal", canShow: true)
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            status: { hidden },
            quiesceProtection: { $0(true, nil) }
        )
        let delegate = AppDelegate()
        delegate.model = model

        let menu = delegate.makeMenu()
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Hide a desktop · Experimental"))
        XCTAssertTrue(titles.contains("Show Target…"))
        XCTAssertTrue(titles.contains("Desktop hidden by PanelCtl · input unknown"))
        let settingsItem = try XCTUnwrap(menu.items.first { $0.title == "Settings…" })
        XCTAssertEqual(settingsItem.keyEquivalent, ",")
        XCTAssertEqual(menu.items.firstIndex { $0.title == "Hide a desktop · Experimental" }, menu.items.firstIndex { $0.title == "Show Target…" }.map { $0 - 1 })

        model.setShowMenuBarIcon(false)
        XCTAssertFalse(model.showMenuBarIcon)
        XCTAssertTrue(delegate.makeMenu().items.contains { $0.title == "Show Target…" }, "recovery remains available even when the status icon preference is off")

        let controller = SettingsWindowController(model: model)
        var window = try XCTUnwrap(controller.window)
        controller.present()
        XCTAssertTrue(window.autorecalculatesKeyViewLoop)
        window.contentView?.frame = NSRect(x: 0, y: 0, width: 680, height: 620)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(window.contentView?.fittingSize.width ?? 0, 0)
        XCTAssertGreaterThan(window.contentView?.fittingSize.height ?? 0, 0)
        XCTAssertFalse(try XCTUnwrap(window.contentView).subviews.isEmpty)

        let focusRequest = model.displayRecoveryFocusRequest
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertGreaterThan(model.displayRecoveryFocusRequest, focusRequest)
        let recoveryWindow = try XCTUnwrap(NSApp.windows.first {
            $0.title == "PanelCtl Settings" && $0 !== controller.window
        })
        window = recoveryWindow
        XCTAssertTrue(window.isVisible)
        window.setContentSize(NSSize(width: 680, height: 1200))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.recalculateKeyViewLoop()
        let controls = nativeControls(in: try XCTUnwrap(window.contentView))
        let controlSummary = controls.map {
            "\(type(of: $0)): \($0.accessibilityLabel() ?? "") \(($0 as? NSPopUpButton)?.itemTitles ?? [])"
        }
        let sourcePicker = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityLabel() == "Mirror source for Target"
        }, "Native controls: \(controlSummary)")
        XCTAssertTrue(sourcePicker.itemTitles.contains {
            $0.contains(Self.mainUUID) && $0.contains("Display ID 101")
        })
        let previousKeyView = try XCTUnwrap(sourcePicker.previousKeyView)
        let nextKeyView = try XCTUnwrap(sourcePicker.nextKeyView)
        XCTAssertFalse(previousKeyView === sourcePicker)
        XCTAssertFalse(nextKeyView === sourcePicker)
        XCTAssertTrue(window.makeFirstResponder(sourcePicker))
        let firstKeyView = window.firstResponder
        window.selectNextKeyView(nil)
        XCTAssertFalse(window.firstResponder === firstKeyView, "Tab advances through the Settings key-view loop")
    }

    private func writeRearmHelper(in directory: URL) throws -> URL {
        let helper = directory.appendingPathComponent("fake-panelctl")
        let script = """
        #!/bin/bash
        rearm="${PANELCTL_REARM_ON_START:-0}"
        printf 'launch:%s\\n' "$rearm" >> "$PANELCTL_TEST_LOG"
        trap 'printf "{\\"state\\":\\"stopped\\",\\"blackedOutDisplayIDs\\":[],\\"cleanupSucceeded\\":true}\\n"; exit 0' TERM
        if [[ "$rearm" == "1" ]]; then
            printf '{"state":"waiting_for_input","blackedOutDisplayIDs":[]}\\n'
        elif [[ -e "$PANELCTL_TEST_STALE_IDLE" ]]; then
            printf 'immediate-blackout\\n' >> "$PANELCTL_TEST_ACTION_LOG"
            printf '{"state":"blacked_out","blackedOutDisplayIDs":[202]}\\n'
        else
            printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        fi
        while true; do /bin/sleep 0.02; done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        setenv("PANELCTL_TEST_LOG", directory.appendingPathComponent("launches.log").path, 1)
        return helper
    }

    private func nativeViews(in root: NSView) -> [NSView] {
        var views: [NSView] = []
        func visit(_ view: NSView) {
            views.append(view)
            view.subviews.forEach(visit)
        }
        visit(root)
        return views
    }

    private func nativeControls(in root: NSView) -> [NSControl] {
        nativeViews(in: root).compactMap { $0 as? NSControl }
    }

    private func makeModel(
        defaults: UserDefaults,
        displays: [DisplayRecord],
        idleSecondsProvider: @escaping () -> TimeInterval? = { nil },
        status: @escaping () -> DisplayHandoffStatus? = { nil },
        quiesceProtection: @escaping ProtectionQuiesce = { $0(true, nil) },
        useManagedProtectionService: Bool = false,
        hideDisplay: @escaping (DisplayHideIdentity, DisplayHideIdentity) throws -> Void = { _, _ in },
        showDisplay: @escaping (String) throws -> Void = { _ in }
    ) -> AppModel {
        let fallback = handoffStatus(.none, target: nil, source: nil)
        return AppModel(
            defaults: defaults,
            displayProvider: { displays },
            idleSecondsProvider: idleSecondsProvider,
            isDisplayMirrored: { _ in false },
            inspectHandoff: { status() ?? fallback },
            hideDisplay: hideDisplay,
            showDisplay: showDisplay,
            quiesceProtection: useManagedProtectionService ? nil : quiesceProtection
        )
    }

    private func handoffStatus(
        _ state: DisplayHandoffStatus.State,
        target: DisplayRecord?,
        source: DisplayRecord?,
        journalID: String? = nil,
        canShow: Bool = false,
        reason: String? = nil,
        observationState: DisplayHideObservedState? = nil
    ) -> DisplayHandoffStatus {
        let targetIdentity = target.map(displayIdentity)
        let sourceIdentity = source.map(displayIdentity)
        var observations: [DisplayHideObservation] = []
        if let targetIdentity {
            var observedState: DisplayHideObservedState = switch state {
            case .hidden: .hiddenByPanelCtl
            case .recovery: .recoveryNeeded
            case .unsupported: .unsupportedRecovery
            case .busy: .unknown
            case .none: .separate
            }
            if let observationState { observedState = observationState }
            observations.append(DisplayHideObservation(
                identity: targetIdentity,
                state: observedState,
                source: sourceIdentity,
                detail: reason,
                isJournalTarget: state != .none
            ))
        }
        let handoffTarget = targetIdentity.map(DisplayHandoffIdentity.init)
        let handoffSource = sourceIdentity.map(DisplayHandoffIdentity.init)
        return DisplayHandoffStatus(
            state: state,
            target: handoffTarget,
            source: handoffSource,
            journalPath: "/tmp/panelctl-display-hide-fixture/current.json",
            journalID: journalID,
            reason: reason,
            canShow: canShow,
            recoveryCommand: state == .none ? nil : "panelctl recovery restore --journal '/tmp/panelctl-display-hide-fixture/current.json'",
            observations: observations
        )
    }

    private func displayIdentity(_ display: DisplayRecord) -> DisplayHideIdentity {
        DisplayHideIdentity(
            uuid: display.uuid ?? "unavailable-\(display.id)",
            displayID: display.id,
            name: display.name,
            vendor: display.vendor,
            model: display.model,
            serial: display.serial
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = suiteName(nil)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func suiteName(_: UserDefaults?) -> String {
        "panelctl-display-hide-app-\(ProcessInfo.processInfo.processIdentifier)"
    }

    private func waitForLogLines(_ count: Int, at log: URL) async throws -> [String] {
        for _ in 0..<150 {
            if let data = try? Data(contentsOf: log),
               let contents = String(data: data, encoding: .utf8) {
                let lines = contents.split(separator: "\n").map(String.init)
                if lines.count >= count { return lines }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(count) helper log lines")
        return []
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for display hide state")
    }

    private static func display(index: Int, id: UInt32, uuid: String, name: String, main: Bool,
                                serial: UInt32? = nil) -> DisplayRecord {
        DisplayRecord(
            index: index,
            id: id,
            uuid: uuid,
            name: name,
            active: true,
            online: true,
            asleep: false,
            builtin: false,
            main: main,
            vendor: UInt32(index),
            model: UInt32(index * 10),
            serial: serial ?? UInt32(index * 100),
            bounds: DisplayBounds(CGRect(x: (index - 1) * 1920, y: 0, width: 1920, height: 1080)),
            pixelWidth: 1920,
            pixelHeight: 1080
        )
    }
}

private final class StatusBox {
    var value: DisplayHandoffStatus
    init(_ value: DisplayHandoffStatus) { self.value = value }
}
