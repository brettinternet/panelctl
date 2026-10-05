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

    private func dispatchNativeEvents() {
        // XCTest services the run loop but is not an NSApplication event loop.
        // Dispatch pending app-local lifecycle events before asserting focus.
        for _ in 0..<100 {
            guard let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) else { break }
            NSApp.sendEvent(event)
        }
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
        // A package test runner has no application window to activate. Establish
        // a real fixture window before requesting foreground keyboard ownership.
        let activationWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        activationWindow.title = "PanelCtl offline keyboard fixture"
        activationWindow.isReleasedWhenClosed = false
        activationWindow.center()
        activationWindow.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        defer { activationWindow.close() }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let activationDeadline = Date().addingTimeInterval(2)
        while (!application.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier != currentPID),
              Date() < activationDeadline {
            dispatchNativeEvents()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        dispatchNativeEvents()
        guard application.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == currentPID else {
            application.setActivationPolicy(originalActivationPolicy)
            previouslyFrontmost?.activate(options: [.activateAllWindows])
            throw XCTSkip("The opted-in XCTest host did not become frontmost; no keyboard event was posted.")
        }
        return (originalActivationPolicy, previouslyFrontmost)
    }

    private func restoreForegroundNativeKeyboardFixture(
        _ state: (activationPolicy: NSApplication.ActivationPolicy, previouslyFrontmost: NSRunningApplication?)
    ) {
        NSApp.setActivationPolicy(state.activationPolicy)
        state.previouslyFrontmost?.activate(options: [.activateAllWindows])
        // Drain asynchronous deactivation before the next native menu starts
        // tracking; otherwise that stale event immediately cancels its popup.
        let deadline = Date().addingTimeInterval(2)
        while let previous = state.previouslyFrontmost,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != previous.processIdentifier,
              Date() < deadline {
            dispatchNativeEvents()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        dispatchNativeEvents()
    }

    func testHiddenOverlayIsSourceOnlyRestoreOnlyAndQuiescedBeforeShow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-hidden-overlay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("helper.log")
        let helper = try writeHiddenOverlayHelper(in: directory, log: log)
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var preferences = ProtectionPreferences()
        preferences.isEnabled = true
        preferences.didChooseDisplays = true
        preferences.selectedDisplayUUIDs = [Self.sourceUUID]
        preferences.mode = .working
        preferences.hardwareDimmingEnabled = true
        preferences.hardwareBrightnessPercent = 10
        defaults.set(try JSONEncoder().encode(preferences), forKey: "blackoutPreferences")

        setenv("PANELCTL_HELPER", helper.path, 1)
        unsetenv("PANELCTL_REARM_ON_START")
        defer {
            unsetenv("PANELCTL_HELPER")
            unsetenv("PANELCTL_REARM_ON_START")
            unsetenv("PANELCTL_TEST_LOG")
        }
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        let hidden = handoffStatus(.hidden, target: displays[1], source: displays[2], journalID: "overlay-journal", canShow: true)
        let box = StatusBox(hidden)
        var showCalls = 0
        var watcherWasStoppedBeforeShow = false
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            status: { box.value },
            useManagedProtectionService: true,
            showDisplay: { _, _ in
                showCalls += 1
                let lines = try String(contentsOf: log, encoding: .utf8)
                    .split(separator: "\n").map(String.init)
                watcherWasStoppedBeforeShow = lines.contains("stop")
                box.value = self.handoffStatus(.none, target: nil, source: nil)
                return .notRequested
            }
        )
        try await waitUntil { model.runtimeState == .blackedOut }
        var lines = try await waitForLogLines(1, at: log)
        XCTAssertTrue(model.protectionPausedForDisplayRecovery)
        XCTAssertTrue(model.hiddenMirrorOverlayPolicyEligible)
        XCTAssertEqual(model.effectiveBlackoutMode, .blocking)
        XCTAssertTrue(model.statusSummary.contains("overlay blackout on Mirror source"))
        XCTAssertTrue(lines[0].contains("--display \(Self.sourceUUID)"))
        XCTAssertTrue(lines[0].contains("--panelctl-hidden-mirror-source \(Self.sourceUUID)"))
        XCTAssertFalse(lines[0].contains(Self.targetUUID))
        XCTAssertFalse(lines[0].contains("--dim-to"))
        XCTAssertFalse(lines[0].contains("--sleep-after"))
        XCTAssertFalse(lines[0].contains("--keep-displays-awake"))

        let delegate = AppDelegate()
        delegate.model = model
        let menuTitles = delegate.makeMenu().items.map(\.title)
        XCTAssertTrue(menuTitles.contains("Show Target…"), "Show stays reachable over a source overlay")
        XCTAssertTrue(menuTitles.contains("Restore"), "protection Restore stays available over a source overlay")
        XCTAssertTrue(try model.restoreBlackout(), "Restore controls the overlay while the journal remains hidden")
        lines = try await waitForLogLines(2, at: log)
        XCTAssertEqual(lines[1], "command:restore")
        XCTAssertEqual(showCalls, 0, "Restore never invokes Show")
        XCTAssertEqual(model.handoffStatus?.state, .hidden)

        try model.blackoutNow()
        try await waitUntil { model.runtimeState == .blackedOut }
        let request = try model.makeShowRequest()
        model.confirmShow(request, acknowledged: true)
        try await waitUntil { showCalls == 1 && !model.hideOperation.isBusy }
        lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(watcherWasStoppedBeforeShow)
        XCTAssertEqual(lines.filter { $0 == "stop" }.count, 1)
        XCTAssertEqual(showCalls, 1)
        XCTAssertEqual(box.value.state, .none)

        let stopped = expectation(description: "normal watcher stopped")
        model.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
    }

    func testHiddenOverlaySummaryReportsFailedHelperWithHealthyHiddenJournal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-hidden-overlay-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("fake-panelctl")
        let script = """
        #!/bin/bash
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        printf 'synthetic overlay startup failure\\n' >&2
        exit 7
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var preferences = ProtectionPreferences()
        preferences.isEnabled = true
        preferences.didChooseDisplays = true
        preferences.selectedDisplayUUIDs = [Self.sourceUUID]
        defaults.set(try JSONEncoder().encode(preferences), forKey: "blackoutPreferences")

        setenv("PANELCTL_HELPER", helper.path, 1)
        defer { unsetenv("PANELCTL_HELPER") }
        let healthyHidden = handoffStatus(
            .hidden, target: displays[1], source: displays[2], journalID: "healthy-hidden-journal", canShow: true
        )
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            status: { healthyHidden },
            useManagedProtectionService: true
        )
        try await waitUntil {
            if case .failed = model.runtimeState { return true }
            return false
        }

        XCTAssertTrue(model.hiddenMirrorProtectionSummary.contains("automation failed"))
        XCTAssertTrue(model.hiddenMirrorProtectionSummary.contains("synthetic overlay startup failure"))
        XCTAssertFalse(model.hiddenMirrorProtectionSummary.contains("watching"))

        let stopped = expectation(description: "failed overlay service shut down")
        model.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
    }

    func testHiddenOverlaySummaryReportsPausedPlaybackState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-hidden-overlay-paused-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("fake-panelctl")
        let script = """
        #!/bin/bash
        printf '{"state":"waiting_for_playback","blackedOutDisplayIDs":[]}\\n'
        trap 'printf "{\\"state\\":\\"stopped\\",\\"blackedOutDisplayIDs\\":[],\\"cleanupSucceeded\\":true}\\n"; exit 0' TERM
        while true; do /bin/sleep 0.02; done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var preferences = ProtectionPreferences()
        preferences.isEnabled = true
        preferences.didChooseDisplays = true
        preferences.selectedDisplayUUIDs = [Self.sourceUUID]
        defaults.set(try JSONEncoder().encode(preferences), forKey: "blackoutPreferences")

        setenv("PANELCTL_HELPER", helper.path, 1)
        defer { unsetenv("PANELCTL_HELPER") }
        let hidden = handoffStatus(
            .hidden, target: displays[1], source: displays[2], journalID: "paused-hidden-journal", canShow: true
        )
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            status: { hidden },
            useManagedProtectionService: true
        )
        try await waitUntil { model.runtimeState == .waitingForPlayback }
        XCTAssertTrue(model.hiddenMirrorProtectionSummary.contains("automation paused"))
        XCTAssertTrue(model.hiddenMirrorProtectionSummary.contains("media or camera activity"))

        let stopped = expectation(description: "paused overlay service shut down")
        model.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
    }

    func testCrashedWindowOnlyOverlayAllowsRepeatedShowWithoutStoppedAcknowledgement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-hidden-overlay-crash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("fake-panelctl")
        let log = directory.appendingPathComponent("helper.log")
        let script = """
        #!/bin/bash
        printf 'launch\\n' >> "$PANELCTL_TEST_LOG"
        printf '{"state":"blacked_out","blackedOutDisplayIDs":[303]}\\n'
        trap 'kill -KILL $$' TERM
        while true; do /bin/sleep 0.02; done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        defer {
            unsetenv("PANELCTL_HELPER")
            unsetenv("PANELCTL_TEST_LOG")
        }

        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var preferences = ProtectionPreferences()
        preferences.isEnabled = true
        preferences.didChooseDisplays = true
        preferences.selectedDisplayUUIDs = [Self.sourceUUID]
        defaults.set(try JSONEncoder().encode(preferences), forKey: "blackoutPreferences")

        let hidden = handoffStatus(
            .hidden, target: displays[1], source: displays[2], journalID: "crashed-overlay-journal", canShow: true
        )
        let box = StatusBox(hidden)
        var showCalls = 0
        var model: AppModel!
        model = makeModel(
            defaults: defaults,
            displays: displays,
            status: { box.value },
            useManagedProtectionService: true,
            showDisplay: { _, _ in
                showCalls += 1
                if showCalls == 1 {
                    model.preferences.isEnabled = false
                    throw NSError(domain: "FakeShow", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "fake no-write Show refusal"
                    ])
                }
                box.value = self.handoffStatus(.none, target: nil, source: nil)
                return .notRequested
            }
        )
        try await waitUntil { model.runtimeState == .blackedOut }
        XCTAssertTrue(model.hiddenMirrorOverlayPolicyEligible)

        model.confirmShow(try model.makeShowRequest(), acknowledged: true)
        try await waitUntil { showCalls == 1 && !model.hideOperation.isBusy }
        XCTAssertNil(model.protectionQuiescenceFailure, "process death proves that its windows are gone")
        XCTAssertEqual(model.notice?.title, "Could not show the journaled desktop")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count, 1)

        model.confirmShow(try model.makeShowRequest(), acknowledged: true)
        try await waitUntil { showCalls == 2 && !model.hideOperation.isBusy }
        XCTAssertNil(model.protectionQuiescenceFailure, "a second Show is not blocked by a stale cleanup latch")
        XCTAssertEqual(box.value.state, .none)
        XCTAssertEqual(model.notice?.title, "Desktop restored")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count, 1,
                       "no helper restart is required to prove the overlay process terminated")

        let stopped = expectation(description: "overlay service shut down")
        model.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
    }

    func testHiddenOverlayAppPolicyRefusesUnselectedOrUnhealthyState() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var preferences = ProtectionPreferences()
        preferences.isEnabled = true
        preferences.didChooseDisplays = true
        preferences.selectedDisplayUUIDs = [Self.targetUUID]
        defaults.set(try JSONEncoder().encode(preferences), forKey: "blackoutPreferences")

        let hidden = handoffStatus(.hidden, target: displays[1], source: displays[2], journalID: "unselected-source", canShow: true)
        let unselected = makeModel(defaults: defaults, displays: displays, status: { hidden })
        try await waitUntil { !unselected.protectionQuiescencePending }
        XCTAssertNil(unselected.selectedHiddenMirrorSource)
        XCTAssertFalse(unselected.hiddenMirrorOverlayPolicyEligible)
        XCTAssertTrue(unselected.hiddenMirrorProtectionSummary.contains("not in the idle display list"))

        for state in [DisplayHandoffStatus.State.recovery, .busy, .unsupported, .none] {
            let status = handoffStatus(
                state,
                target: displays[1],
                source: displays[2],
                journalID: "refused-\(state)",
                canShow: false,
                observationState: state == .none ? .mirroredExternally : nil
            )
            let model = makeModel(defaults: defaults, displays: displays, status: { status })
            try await waitUntil { !model.protectionQuiescencePending }
            XCTAssertNil(model.verifiedHiddenMirrorSource, "\(state) must not authorize an overlay")
            XCTAssertFalse(model.hiddenMirrorOverlayPolicyEligible)
        }

        let staleSource = Self.display(index: 3, id: 304, uuid: Self.sourceUUID, name: "Changed source", main: false)
        let stale = makeModel(
            defaults: defaults,
            displays: [displays[0], displays[1], staleSource],
            status: { hidden }
        )
        try await waitUntil { !stale.protectionQuiescencePending }
        XCTAssertNil(stale.verifiedHiddenMirrorSource, "a stale source display ID is refused")
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
            hideDisplay: { _, _, _ in
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

    func testInputConfigurationUsesValidatedCodesAndOnlyChecksDDCOnExplicitRequest() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var checkCalls = 0
        let target = displays[1]
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            checkDDCInput: { identity in
                checkCalls += 1
                return DDCInputReading(displayID: identity.displayID, uuid: identity.uuid, current: 15)
            }
        )
        model.setHideEnabled(true, for: target)
        model.setHideSource(Self.mainUUID, for: Self.targetUUID)
        XCTAssertTrue(model.setHideAwayInput("0", for: Self.targetUUID)?.contains("Invalid DDC input code") == true)
        XCTAssertNil(try XCTUnwrap(model.hidePreferences[Self.targetUUID]).awayInput)
        XCTAssertNil(model.setHideAwayInput("hdmi1", for: Self.targetUUID))
        XCTAssertNil(model.setHideReturnInput("dp1", for: Self.targetUUID))
        XCTAssertEqual(checkCalls, 0, "saving input preferences must not open or read DDC")

        let reloaded = makeModel(
            defaults: defaults,
            displays: displays,
            checkDDCInput: { identity in
                checkCalls += 1
                return DDCInputReading(displayID: identity.displayID, uuid: identity.uuid, current: 15)
            }
        )
        let saved = try XCTUnwrap(reloaded.hidePreferences[Self.targetUUID])
        XCTAssertEqual(saved.awayInput, 17)
        XCTAssertEqual(saved.returnInput, 15)
        XCTAssertEqual(checkCalls, 0, "loading input preferences must not open or read DDC")
        XCTAssertTrue(reloaded.ddcInputAvailabilityMessage(for: saved).contains("availability is unknown"))

        reloaded.checkDDCInputAvailability(for: Self.targetUUID)
        XCTAssertEqual(checkCalls, 1, "only the explicit capability check may read DDC")
        XCTAssertTrue(reloaded.ddcInputAvailabilityMessage(for: saved).contains("does not prove switching support"))

        let unavailable = makeModel(
            defaults: defaults,
            displays: displays,
            checkDDCInput: { _ in throw NSError(domain: "FakeDDC", code: 1, userInfo: [NSLocalizedDescriptionKey: "fake DDC unavailable"]) }
        )
        unavailable.checkDDCInputAvailability(for: Self.targetUUID)
        let unavailableMessage = unavailable.ddcInputAvailabilityMessage(for: saved)
        XCTAssertTrue(unavailableMessage.contains("fake DDC unavailable"))
        XCTAssertTrue(unavailableMessage.contains("monitor's input buttons"))
        XCTAssertTrue(unavailableMessage.contains("Hide and Show remain available"))
    }

    func testHideAndShowReportDesktopAndInputResultsSeparately() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let hidden = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "input-journal", canShow: true)
        let box = StatusBox(handoffStatus(.none, target: nil, source: nil))
        var awayInputs: [UInt8?] = []
        var returnInputs: [UInt8?] = []
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            status: { box.value },
            hideDisplay: { _, _, input in
                awayInputs.append(input)
                box.value = hidden
                return DisplayInputOutcome(
                    state: .verified, requestedInput: input, observedInput: input,
                    recoveryCommand: "panelctl ddc-input --display '\(Self.targetUUID)' --set 0x0F"
                )
            },
            showDisplay: { journalID, input in
                XCTAssertEqual(journalID, "input-journal")
                returnInputs.append(input)
                box.value = self.handoffStatus(.none, target: nil, source: nil)
                return DisplayInputOutcome(
                    state: .failed, requestedInput: input,
                    detail: "fake DDC write failure after desktop restore",
                    recoveryCommand: "panelctl ddc-input --display '\(Self.targetUUID)' --set 0x11"
                )
            }
        )
        model.setHideEnabled(true, for: displays[1])
        model.setHideSource(Self.mainUUID, for: Self.targetUUID)
        XCTAssertNil(model.setHideAwayInput("hdmi1", for: Self.targetUUID))
        XCTAssertNil(model.setHideReturnInput("dp1", for: Self.targetUUID))

        var hideRequest: DisplayHideRequest?
        model.onRequestHide = { hideRequest = $0 }
        model.requestHide(targetUUID: Self.targetUUID)
        let confirmation = try XCTUnwrap(hideRequest)
        XCTAssertEqual(confirmation.awayInput, 17)
        XCTAssertEqual(confirmation.returnInput, 15)
        let hideText = DisplayOperationConfirmation.hideMessage(confirmation, journalPath: "/tmp/synthetic/current.json")
        XCTAssertTrue(hideText.contains("Other computer input on Hide: hdmi1 (0x11)"))
        XCTAssertTrue(hideText.contains("Mac input on Show: dp1 (0x0F)"))
        model.confirmHide(confirmation, acknowledged: true)
        try await waitUntil { !model.hideOperation.isBusy }
        XCTAssertEqual(awayInputs, [17])
        XCTAssertTrue(model.notice?.message.contains("Desktop: Target is hidden") == true)
        XCTAssertTrue(model.notice?.message.contains("Monitor input (Other computer): hdmi1 (0x11) selected and verified") == true)
        XCTAssertTrue(model.notice?.message.contains("panelctl ddc-input --display") == true)

        var showRequest: DisplayShowRequest?
        model.onRequestShow = { showRequest = $0 }
        model.requestShow()
        let showConfirmation = try XCTUnwrap(showRequest)
        XCTAssertEqual(showConfirmation.returnInput, 15)
        XCTAssertTrue(DisplayOperationConfirmation.showMessage(showConfirmation).contains("Mac input on Show: dp1 (0x0F)"))
        model.confirmShow(showConfirmation, acknowledged: true)
        try await waitUntil { !model.hideOperation.isBusy && model.handoffStatus?.state == DisplayHandoffStatus.State.none }
        XCTAssertEqual(returnInputs, [15])
        XCTAssertTrue(model.notice?.message.contains("Desktop: The journaled public display layout and modes were restored and verified") == true)
        XCTAssertTrue(model.notice?.message.contains("Monitor input (Mac): Failed") == true)
        XCTAssertTrue(model.notice?.message.contains("fake DDC write failure after desktop restore") == true)
        XCTAssertTrue(model.notice?.message.contains("panelctl ddc-input --display") == true)
    }

    func testHideInspectionFailurePreservesReturnedInputOutcome() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let hiddenStatus = handoffStatus(
            .recovery, target: displays[1], source: displays[0], journalID: "hide-inspection-journal",
            reason: "post-Hide observation failed", inspectionFailure: "fake post-Hide inspection failure"
        )
        let box = StatusBox(handoffStatus(.none, target: nil, source: nil))
        let command = "panelctl ddc-input --display '\(Self.targetUUID)' --set 0x0F"
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            status: { box.value },
            hideDisplay: { _, _, input in
                box.value = hiddenStatus
                return DisplayInputOutcome(
                    state: .verified, requestedInput: input, observedInput: input,
                    recoveryCommand: command
                )
            }
        )
        model.setHideEnabled(true, for: displays[1])
        model.setHideSource(Self.mainUUID, for: Self.targetUUID)
        XCTAssertNil(model.setHideAwayInput("hdmi1", for: Self.targetUUID))
        var request: DisplayHideRequest?
        model.onRequestHide = { request = $0 }
        model.requestHide(targetUUID: Self.targetUUID)
        model.confirmHide(try XCTUnwrap(request), acknowledged: true)
        try await waitUntil { !model.hideOperation.isBusy }

        let message = try XCTUnwrap(model.notice?.message)
        XCTAssertTrue(message.contains("Desktop: Hide backend returned, but current desktop/recovery status could not be confirmed"))
        XCTAssertFalse(message.contains("Desktop: Hide did not complete."))
        XCTAssertTrue(message.contains("Monitor input (Other computer): hdmi1 (0x11) selected and verified"))
        XCTAssertTrue(message.contains(command), "the returned input recovery command survives inspection failure")
    }

    func testShowInspectionFailurePreservesReturnedInputOutcome() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var preferences = DisplayHidePreferences()
        preferences[Self.targetUUID] = DisplayHideConfiguration(
            target: DisplayIdentitySnapshot(displays[1]),
            enabled: true,
            source: DisplayIdentitySnapshot(displays[0]),
            returnInput: 15
        )
        defaults.set(try JSONEncoder().encode(preferences), forKey: "displayHidePreferences")
        let hiddenStatus = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "show-inspection-journal", canShow: true)
        let failedStatus = handoffStatus(
            .recovery, target: displays[1], source: displays[0], journalID: "show-inspection-journal",
            reason: "post-Show observation failed", inspectionFailure: "fake post-Show inspection failure"
        )
        let box = StatusBox(hiddenStatus)
        let command = "panelctl ddc-input --display '\(Self.targetUUID)' --set 0x11"
        var shownInput: UInt8?
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            status: { box.value },
            showDisplay: { journalID, input in
                XCTAssertEqual(journalID, "show-inspection-journal")
                shownInput = input
                box.value = failedStatus
                return DisplayInputOutcome(
                    state: .verified, requestedInput: input, observedInput: input,
                    recoveryCommand: command
                )
            }
        )
        try await waitUntil { !model.protectionQuiescencePending }
        let request = try model.makeShowRequest()
        XCTAssertEqual(request.returnInput, 15)
        model.confirmShow(request, acknowledged: true)
        try await waitUntil { !model.hideOperation.isBusy }

        let message = try XCTUnwrap(model.notice?.message)
        XCTAssertEqual(shownInput, 15)
        XCTAssertTrue(message.contains("Desktop: Show backend returned, but current desktop/recovery status could not be confirmed"))
        XCTAssertFalse(message.contains("Desktop: Show did not complete."))
        XCTAssertTrue(message.contains("Monitor input (Mac): dp1 (0x0F) selected and verified"))
        XCTAssertTrue(message.contains(command), "the returned input recovery command survives inspection failure")
    }

    func testSkippedAndUnverifiedHideOutcomesRemainSeparateFromDesktopSuccess() async throws {
        for (index, state, detail) in [
            (1, DisplayInputOutcome.State.skipped, "fake DDC unavailable; use monitor buttons"),
            (2, DisplayInputOutcome.State.unverified, "readback unavailable")
        ] {
            let defaults = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
            let hidden = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "outcome-\(index)", canShow: true)
            let box = StatusBox(handoffStatus(.none, target: nil, source: nil))
            let model = makeModel(
                defaults: defaults,
                displays: displays,
                status: { box.value },
                hideDisplay: { _, _, input in
                    box.value = hidden
                    return DisplayInputOutcome(
                        state: state, requestedInput: input, detail: detail,
                        recoveryCommand: state == .unverified ? "panelctl ddc-input --display '\(Self.targetUUID)' --set 0x0F" : nil
                    )
                }
            )
            model.setHideEnabled(true, for: displays[1])
            model.setHideSource(Self.mainUUID, for: Self.targetUUID)
            XCTAssertNil(model.setHideAwayInput("hdmi1", for: Self.targetUUID))
            var request: DisplayHideRequest?
            model.onRequestHide = { request = $0 }
            model.requestHide(targetUUID: Self.targetUUID)
            model.confirmHide(try XCTUnwrap(request), acknowledged: true)
            try await waitUntil { !model.hideOperation.isBusy }

            XCTAssertTrue(model.notice?.message.contains("Desktop: Target is hidden") == true)
            let expectedState = state == .skipped ? "Skipped." : "is unverified"
            XCTAssertTrue(model.notice?.message.contains(expectedState) == true)
            XCTAssertTrue(model.notice?.message.contains(detail) == true)
            if state == .unverified {
                XCTAssertTrue(model.notice?.message.contains("panelctl ddc-input --display") == true)
                XCTAssertTrue(model.notice?.message.contains("does not claim it changed") == true)
            } else {
                XCTAssertTrue(model.notice?.message.contains("monitor's input buttons") == true)
            }
        }
    }

    func testAwayInputFailureReportsDesktopFailureAndRecoverySeparately() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let recovery = handoffStatus(.recovery, target: displays[1], source: displays[0], journalID: "retained-input-journal", canShow: false, reason: "journal retained after DDC failure")
        let box = StatusBox(handoffStatus(.none, target: nil, source: nil))
        var hideCalls = 0
        let command = "panelctl ddc-input --display '\(Self.targetUUID)' --set 0x0F"
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            status: { box.value },
            hideDisplay: { _, _, input in
                hideCalls += 1
                box.value = recovery
                throw DisplayHandoffOperationFailure(
                    action: "hide",
                    inputOutcome: DisplayInputOutcome(state: .failed, requestedInput: input, detail: "fake write failed", recoveryCommand: command),
                    message: "Hide stopped before topology change. Input recovery: \(command). Journal kept; panelctl recovery restore --journal '/tmp/current.json'."
                )
            }
        )
        model.setHideEnabled(true, for: displays[1])
        model.setHideSource(Self.mainUUID, for: Self.targetUUID)
        XCTAssertNil(model.setHideAwayInput("hdmi1", for: Self.targetUUID))
        var request: DisplayHideRequest?
        model.onRequestHide = { request = $0 }
        model.requestHide(targetUUID: Self.targetUUID)
        model.confirmHide(try XCTUnwrap(request), acknowledged: true)
        try await waitUntil { !model.hideOperation.isBusy }

        XCTAssertEqual(hideCalls, 1)
        XCTAssertEqual(model.handoffStatus?.state, .recovery)
        XCTAssertTrue(model.notice?.message.contains("Desktop: Hide did not complete") == true)
        XCTAssertTrue(model.notice?.message.contains("Monitor input (Other computer): Failed") == true)
        XCTAssertTrue(model.notice?.message.contains(command) == true)
        XCTAssertTrue(model.notice?.message.contains("panelctl recovery restore --journal") == true)
    }

    func testStaleSavedReturnInputIsActionableButNeverBlocksShow() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var preferences = DisplayHidePreferences()
        let staleTarget = DisplayIdentitySnapshot(
            uuid: Self.targetUUID, id: 202, name: "Target", vendor: 2, model: 20, serial: 999
        )
        preferences[Self.targetUUID] = DisplayHideConfiguration(target: staleTarget, enabled: true, returnInput: 15)
        defaults.set(try JSONEncoder().encode(preferences), forKey: "displayHidePreferences")
        let hidden = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "stale-input-journal", canShow: true)
        let box = StatusBox(hidden)
        var showCalled = false
        var showInput: UInt8?
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            status: { box.value },
            showDisplay: { _, input in
                showCalled = true
                showInput = input
                box.value = self.handoffStatus(.none, target: nil, source: nil)
                return .notRequested
            }
        )
        try await waitUntil { !model.protectionQuiescencePending }
        let request = try model.makeShowRequest()
        XCTAssertNil(request.returnInput)
        XCTAssertTrue(request.returnInputWarning?.contains("different display identity") == true)
        XCTAssertTrue(DisplayOperationConfirmation.showMessage(request).contains("Saved Mac input belongs to a different display identity"))

        model.confirmShow(request, acknowledged: true)
        try await waitUntil { !model.hideOperation.isBusy && model.handoffStatus?.state == DisplayHandoffStatus.State.none }
        XCTAssertTrue(showCalled)
        XCTAssertNil(showInput, "Show proceeds without issuing stale saved DDC input")
        XCTAssertTrue(model.notice?.message.contains("Desktop: The journaled public display layout and modes were restored") == true)
        XCTAssertTrue(model.notice?.message.contains("different display identity") == true)
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

            let overlayArguments = [
                "blackout", "--display", Self.sourceUUID,
                "--panelctl-hidden-mirror-source", Self.sourceUUID,
                "--mode", "blocking", "--overlay-opacity", "100",
                "--idle-after", "60", "--watch", "--timeout", "3600"
            ]
            service.run(arguments: overlayArguments)
            try await waitUntil { service.state == .waiting }
            var overlayCleanupSucceeded: Bool?
            var overlayCleanupFailure: String?
            service.disableForDisplayHide { succeeded, message in
                overlayCleanupSucceeded = succeeded
                overlayCleanupFailure = message
            }
            try await waitUntil { overlayCleanupSucceeded != nil }
            XCTAssertFalse(try XCTUnwrap(overlayCleanupSucceeded))
            XCTAssertTrue(overlayCleanupFailure?.localizedCaseInsensitiveContains("cleanup") == true,
                          "a hardware-free overlay cannot clear a previous brightness cleanup failure")

            let defaults = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
            var hideCalls = 0
            let model = makeModel(
                defaults: defaults,
                displays: displays,
                quiesceProtection: { completion in
                    service.disableForDisplayHide(completion: completion)
                },
                hideDisplay: { _, _, _ in hideCalls += 1; return .notRequested }
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
            hideDisplay: { _, _, _ in hideCalls += 1; return .notRequested }
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
            hideDisplay: { target, source, _ in
                backendDisplays[1] = Self.display(
                    index: 2, id: 202, uuid: Self.targetUUID,
                    name: "Target", main: false, serial: 999
                )
                return try backend.hide(target: target, source: source)
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
            hideDisplay: { _, _, _ in
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
            hideDisplay: { _, _, _ in
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
            showDisplay: { journalID, _ in
                shownJournalIDs.append(journalID)
                if showFails {
                    throw NSError(domain: "FakeRecoveryWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "fake restore mismatch; journal retained"])
                }
                box.value = self.handoffStatus(.none, target: nil, source: nil)
                return .notRequested
            }
        )
        try await waitUntil { !model.protectionQuiescencePending }

        var request: DisplayShowRequest?
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
        XCTAssertTrue(hideText.contains("overlay only to the selected mirror source Main OLED"))
        XCTAssertTrue(hideText.contains("mirrored target is never an overlay target"))
        XCTAssertTrue(hideText.contains("automatic follow-up Sleep"))
        XCTAssertTrue(hideText.contains("hardware qualification is unperformed"))

        let showText = DisplayOperationConfirmation.showMessage(
            handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "journal", canShow: true)
        )
        XCTAssertTrue(showText.contains("Journaled target: Target"))
        XCTAssertTrue(showText.contains("Captured mirror source: Main OLED"))
        XCTAssertTrue(showText.contains("Restoring the layout may affect other captured displays"))
        XCTAssertTrue(showText.contains("overlay is quiesced and verified stopped before Show"))
        XCTAssertTrue(showText.contains("Recovery journal:"))

        box.value = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "lifecycle-journal", canShow: true)
        model.refreshHandoffStatus()
        model.setDisplayLifecycleTransitioning(true)
        XCTAssertThrowsError(try model.makeShowRequest())
        model.setDisplayLifecycleTransitioning(false)
        try await waitUntil { !model.protectionQuiescencePending }
        XCTAssertNoThrow(try model.makeShowRequest())
    }

    func testNativeSettingsInputControlsAreConditionalAccessibleAndOfflineByDefault() throws {
        let defaults = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName(defaults))
            NSApp.windows.filter { $0.identifier == SettingsWindowController.windowIdentifier }.forEach { $0.close() }
        }
        var ddcChecks = 0
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            checkDDCInput: { identity in
                ddcChecks += 1
                return DDCInputReading(displayID: identity.displayID, uuid: identity.uuid, current: 15)
            }
        )
        let controller = SettingsWindowController(model: model)
        controller.present()
        model.requestDisplayRecoveryFocus()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 680, height: 1800))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        var controls = nativeControls(in: try XCTUnwrap(window.contentView))
        XCTAssertFalse(controls.contains { $0.accessibilityLabel() == "Other computer input on Hide for Target" })
        XCTAssertFalse(controls.contains { $0.accessibilityLabel() == "Mac input on Show for Target" })
        XCTAssertEqual(ddcChecks, 0)

        model.setHideEnabled(true, for: displays[1])
        model.setHideSource(Self.mainUUID, for: Self.targetUUID)
        XCTAssertNil(model.setHideAwayInput("hdmi1", for: Self.targetUUID))
        XCTAssertNil(model.setHideReturnInput("dp1", for: Self.targetUUID))
        window.contentView?.layoutSubtreeIfNeeded()
        let inputScrollView = try XCTUnwrap(nativeViews(in: try XCTUnwrap(window.contentView)).compactMap { $0 as? NSScrollView }.last)
        let inputDocumentHeight = inputScrollView.documentView?.frame.height ?? 0
        inputScrollView.contentView.scroll(to: NSPoint(x: 0, y: inputDocumentHeight))
        inputScrollView.reflectScrolledClipView(inputScrollView.contentView)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        controls = nativeControls(in: try XCTUnwrap(window.contentView))
        let nativeSummary = nativeViews(in: try XCTUnwrap(window.contentView)).map {
            "\(type(of: $0)): \($0.accessibilityLabel() ?? "") \(($0 as? NSTextField)?.stringValue ?? "") \($0.frame)"
        }
        let awayField = try XCTUnwrap(controls.compactMap { $0 as? NSTextField }.first {
            $0.accessibilityLabel() == "Other computer input on Hide for Target"
        }, "Native controls: \(nativeSummary)")
        let returnField = try XCTUnwrap(controls.compactMap { $0 as? NSTextField }.first {
            $0.accessibilityLabel() == "Mac input on Show for Target"
        })
        XCTAssertEqual(awayField.stringValue, "hdmi1")
        XCTAssertEqual(returnField.stringValue, "dp1")
        let saved = try XCTUnwrap(model.hidePreferences[Self.targetUUID])
        XCTAssertTrue(model.ddcInputAvailabilityMessage(for: saved).contains("You can check explicitly"))
        XCTAssertEqual(ddcChecks, 0, "rendering and saving native Settings controls performs no DDC query")
    }

    func testNativeSettingsFixtureRetainsMissingRecoveryIdentityAndFreezesEditing() throws {
        let defaults = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName(defaults))
            NSApp.windows.filter { $0.identifier == SettingsWindowController.windowIdentifier }.forEach { $0.close() }
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
        model.onRequestShow = { requestedJournalID = $0.status.journalID }
        dispatchNativeEvents()
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
        defer { restoreForegroundNativeKeyboardFixture(applicationState) }
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
            keyDown.flags = []
            keyUp.flags = []
            keyDown.postToPid(currentPID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { keyUp.postToPid(currentPID) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
        let start = ProcessInfo.processInfo.systemUptime
        let response = confirmation.runModal()
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
        defer { restoreForegroundNativeKeyboardFixture(applicationState) }
        for succeeds in [true, false] {
            let defaults = try makeDefaults()
            defer {
                defaults.removePersistentDomain(forName: suiteName(defaults))
                NSApp.windows.filter { $0.identifier == SettingsWindowController.windowIdentifier }.forEach { $0.close() }
            }
            let hidden = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "focus-journal", canShow: true)
            let box = StatusBox(hidden)
            var showCalls = 0
            let model = makeModel(
                defaults: defaults,
                displays: displays,
                status: { box.value },
                showDisplay: { _, _ in
                    showCalls += 1
                    if succeeds {
                        box.value = self.handoffStatus(.none, target: nil, source: nil)
                        return .notRequested
                    }
                    throw NSError(domain: "FakeRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: "offline verification failure"])
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
            try await waitUntil {
                self.dispatchNativeEvents()
                return window.attachedSheet?.isKeyWindow == true
            }
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
            // Sheet detachment precedes the end of AppKit's dismissal animation
            // and restoration of key-window status.
            try await waitUntil {
                self.dispatchNativeEvents()
                return window.attachedSheet == nil && window.isKeyWindow
            }
            XCTAssertTrue(window.isKeyWindow)
            XCTAssertTrue(window.firstResponder === sourcePicker, "dismissal restores focus to the setting that had focus before the notice")
        }
    }

    func testNativeLongRecoveryContentFitsScrollableMinimumWidthSettings() throws {
        let defaults = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName(defaults))
            NSApp.windows.filter { $0.identifier == SettingsWindowController.windowIdentifier }.forEach { $0.close() }
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
            NSApp.windows.filter { $0.identifier == SettingsWindowController.windowIdentifier }.forEach { $0.close() }
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
        XCTAssertTrue(titles.contains("Desktop hidden by PanelCtl · input unknown; target black on Mac input"))
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
            $0.identifier == SettingsWindowController.windowIdentifier && $0 !== controller.window
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
        // Tab only reaches this frozen picker with Full Keyboard Access; tab
        // switching by keyboard is covered in SettingsWindowTests.
    }

    private func writeHiddenOverlayHelper(in directory: URL, log: URL) throws -> URL {
        let helper = directory.appendingPathComponent("fake-panelctl")
        let script = """
        #!/bin/bash
        printf 'launch:%s\\n' "$*" >> "$PANELCTL_TEST_LOG"
        printf '{"state":"blacked_out","blackedOutDisplayIDs":[303]}\\n'
        trap 'printf "stop\\n" >> "$PANELCTL_TEST_LOG"; printf "{\\"state\\":\\"stopped\\",\\"blackedOutDisplayIDs\\":[],\\"cleanupSucceeded\\":true}\\n"; exit 0' TERM
        while IFS= read -r command; do
            printf 'command:%s\\n' "$command" >> "$PANELCTL_TEST_LOG"
            if [[ "$command" == "restore" ]]; then
                printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
            elif [[ "$command" == "blackout-now" ]]; then
                printf '{"state":"blacked_out","blackedOutDisplayIDs":[303]}\\n'
            fi
        done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        return helper
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

    func testHeadlessControlSocketPreservesConfirmationAndReportsObservedResults() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(handoffStatus(.none, target: nil, source: nil))
        var hideCalls = 0
        var showCalls = 0
        var cleanup: ((Bool, String?) -> Void)?
        let model = makeModel(
            defaults: defaults, displays: displays, status: { box.value },
            quiesceProtection: { cleanup = $0 },
            hideDisplay: { _, _, _ in
                hideCalls += 1
                box.value = self.handoffStatus(.hidden, target: self.displays[1], source: self.displays[0], journalID: "script-journal", canShow: true)
                return DisplayInputOutcome(state: .skipped, requestedInput: 17, detail: "Use monitor buttons")
            },
            showDisplay: { _, _ in
                showCalls += 1
                box.value = self.handoffStatus(.none, target: nil, source: nil)
                return DisplayInputOutcome(state: .failed, requestedInput: 15, detail: "Input readback mismatch")
            }
        )
        model.setHideEnabled(true, for: displays[1])
        model.setHideSource(Self.mainUUID, for: Self.targetUUID)
        XCTAssertNil(model.setHideAwayInput("17", for: Self.targetUUID))
        XCTAssertNil(model.setHideReturnInput("15", for: Self.targetUUID))
        model.onRequestHide = { _ in XCTFail("headless requests must not open a dialog") }
        model.onRequestShow = { _ in XCTFail("headless requests must not open a dialog") }
        let delegate = AppDelegate()
        delegate.model = model
        let path = "\(try AppControlSocket.userTemporaryDirectory())/panelctl-test-\(UUID().uuidString.prefix(8)).sock"
        let server = AppControlServer(socketPath: path) { delegate.handleControlRequest($0) }
        try server.start()
        defer { server.stop() }
        let target = Self.targetUUID
        @Sendable func send(_ command: AppControlCommand, uuid: String? = target) async throws -> AppControlResponse {
            try await Task.detached {
                let client = try AppControlClient(socketPath: path, launch: { XCTFail("must not launch") })
                return try client.execute(command, targetUUID: uuid)
            }.value
        }
        let initial = try await send(.status, uuid: nil)
        XCTAssertNil(initial.outcome)
        XCTAssertNil(initial.displays?.first { $0.targetUUID == target }?.lastInputOutcome)
        XCTAssertEqual(initial.displays?.first { $0.targetUUID == target }?.observedState, "separate")
        async let first = send(.hide)
        async let second = send(.hide)
        let duplicates = try await [first, second]
        XCTAssertEqual(duplicates.map(\.outcome), [.confirmationRequired, .confirmationRequired])
        XCTAssertEqual(duplicates.map(\.exitCode), [4, 4])
        XCTAssertEqual(hideCalls, 0)
        let shown = try await send(.show)
        XCTAssertEqual(shown.outcome, .noOp)
        let reply1 = try await send(.hide, uuid: Self.replacementUUID)
        XCTAssertEqual(reply1.outcome, .refused)

        // Only explicit UI consent can perform the fake operation. Concurrent
        // socket requests observe busy and never replay it.
        model.confirmHide(try model.makeHideRequest(targetUUID: target), acknowledged: true)
        let busy = try await send(.hide)
        XCTAssertEqual(busy.outcome, .busy)
        XCTAssertEqual(busy.displays?.first { $0.targetUUID == target }?.operation, "hiding")
        cleanup?(true, nil)
        try await waitUntil { !model.hideOperation.isBusy }
        XCTAssertEqual(hideCalls, 1)
        let hidden = try await send(.hide)
        XCTAssertEqual(hidden.outcome, .noOp)
        XCTAssertEqual(hidden.displays?.first { $0.targetUUID == target }?.observedState, "hidden-by-panelctl")
        XCTAssertEqual(hidden.displays?.first { $0.targetUUID == target }?.lastInputOutcome?.state, .skipped)
        let reply2 = try await send(.status, uuid: nil)
        XCTAssertEqual(reply2.exitCode, 5)
        let reply3 = try await send(.hide, uuid: Self.sourceUUID)
        XCTAssertEqual(reply3.outcome, .recoveryNeeded)
        let reply4 = try await send(.blackoutNow, uuid: nil)
        XCTAssertFalse(reply4.ok)
        _ = try await send(.disable, uuid: nil)
        XCTAssertFalse(model.preferences.isEnabled)
        let reply5 = try await send(.show)
        XCTAssertEqual(reply5.outcome, .confirmationRequired)
        model.snooze(for: 60)
        let reply6 = try await send(.show)
        XCTAssertEqual(reply6.outcome, .confirmationRequired)
        XCTAssertEqual(showCalls, 0)

        model.confirmShow(try model.makeShowRequest(), acknowledged: true)
        cleanup?(true, nil)
        try await waitUntil { !model.hideOperation.isBusy }
        XCTAssertEqual(showCalls, 1)
        let reply7 = try await send(.show)
        XCTAssertEqual(reply7.outcome, .noOp)
        let reply8 = try await send(.show)
        XCTAssertEqual(reply8.outcome, .noOp)
        let partial = try await send(.status, uuid: nil)
        XCTAssertEqual(partial.outcome, .partial)
        XCTAssertEqual(partial.exitCode, 5)
        XCTAssertEqual(partial.displays?.first { $0.targetUUID == target }?.lastInputOutcome?.state, .failed)
        XCTAssertEqual(showCalls, 1, "a duplicate Show must not repeat DDC")
        // Journal remains visibly mirrored after a serial change, but its
        // identity validation refuses Show. Hidden observation alone is not health.
        box.value = handoffStatus(.hidden, target: displays[1], source: displays[0],
                                  journalID: "changed-identity", canShow: false,
                                  reason: "Captured target identity changed (serial mismatch)")
        for command in [AppControlCommand.hide, .show, .status] {
            let staleJournal = try await send(command, uuid: command == .status ? nil : target)
            XCTAssertEqual(staleJournal.outcome, .recoveryNeeded)
            XCTAssertEqual(staleJournal.exitCode, 6)
            XCTAssertEqual(staleJournal.displays?.first { $0.targetUUID == target }?.recoveryNeeded, true)
        }
        XCTAssertEqual(hideCalls, 1, "stale journal must not write")
        XCTAssertEqual(showCalls, 1, "stale journal must not write")
        box.value = handoffStatus(.recovery, target: displays[1], source: displays[0], journalID: "unresolved", reason: "target unavailable")
        let reply9 = try await send(.show)
        XCTAssertEqual(reply9.exitCode, 6)
        let recovery = try await send(.status, uuid: nil)
        XCTAssertEqual(recovery.outcome, .recoveryNeeded)
        XCTAssertEqual(recovery.displays?.first { $0.targetUUID == target }?.recoveryNeeded, true)
        XCTAssertEqual(hideCalls, 1)
        XCTAssertEqual(showCalls, 1)
    }

    func testOversizedStatusDoesNotMisreportCompletedProtectionToggle() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var saved = DisplayHidePreferences()
        for _ in 0..<40 {
            let identity = DisplayIdentitySnapshot(uuid: UUID().uuidString, id: 202, name: "Saved target",
                                                   vendor: 1, model: 2, serial: 3)
            saved[identity.uuid] = DisplayHideConfiguration(target: identity)
        }
        defaults.set(try JSONEncoder().encode(saved), forKey: "displayHidePreferences")
        let hidden = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "overflow", canShow: true)
        let model = makeModel(defaults: defaults, displays: displays, status: { hidden })
        let delegate = AppDelegate()
        delegate.model = model
        XCTAssertFalse(model.preferences.isEnabled)
        let path = "\(try AppControlSocket.userTemporaryDirectory())/panelctl-test-\(UUID().uuidString.prefix(8)).sock"
        var toggleCount = 0
        let server = AppControlServer(socketPath: path) { request in
            if request.command == .toggle { toggleCount += 1 }
            return delegate.handleControlRequest(request)
        }
        try server.start()
        defer { server.stop() }
        let status = try await Task.detached {
            try AppControlClient(socketPath: path, launch: {}).execute(.status)
        }.value
        XCTAssertFalse(status.ok, "fixture must exceed the status message limit")
        XCTAssertEqual(status.outcome, .refused)
        let toggled = try await Task.detached {
            try AppControlClient(socketPath: path, launch: {}).execute(.toggle)
        }.value
        XCTAssertTrue(toggled.ok)
        XCTAssertEqual(toggled.exitCode, 0)
        XCTAssertTrue(toggled.enabled)
        XCTAssertNil(toggled.displays, "legacy mutation responses do not attach unrelated display evidence")
        XCTAssertTrue(model.preferences.isEnabled)
        XCTAssertEqual(toggleCount, 1)
    }

    func testHeadlessRefusesStaleIdentityUnknownJournalAndLifecycle() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let model = makeModel(defaults: defaults, displays: displays)
        model.setHideEnabled(true, for: displays[1])
        model.setHideSource(Self.mainUUID, for: Self.targetUUID)
        let changed = Self.display(index: 2, id: 202, uuid: Self.targetUUID, name: "Replacement", main: false, serial: 999)
        let stale = makeModel(defaults: defaults, displays: [displays[0], changed])
        for command in [AppControlCommand.hide, .show] {
            let request = AppControlRequest(command: command, targetUUID: Self.targetUUID)
            XCTAssertEqual(stale.handleDisplayControlRequest(request).outcome, .refused)
            model.setDisplayLifecycleTransitioning(true)
            XCTAssertEqual(model.handleDisplayControlRequest(request).outcome, .refused)
            model.setDisplayLifecycleTransitioning(false)
        }
        let unknown = makeModel(defaults: defaults, displays: displays, status: {
            self.handoffStatus(.recovery, target: nil, source: nil, inspectionFailure: "unreadable journal")
        })
        XCTAssertEqual(unknown.handleDisplayControlRequest(AppControlRequest(command: .show, targetUUID: Self.targetUUID)).outcome, .recoveryNeeded)
        XCTAssertEqual(model.handleDisplayControlRequest(AppControlRequest(command: .show)).outcome, .refused)
    }

    private func makeModel(
        defaults: UserDefaults,
        displays: [DisplayRecord],
        idleSecondsProvider: @escaping () -> TimeInterval? = { nil },
        status: @escaping () -> DisplayHandoffStatus? = { nil },
        quiesceProtection: @escaping ProtectionQuiesce = { $0(true, nil) },
        useManagedProtectionService: Bool = false,
        hideDisplay: @escaping (DisplayHideIdentity, DisplayHideIdentity, UInt8?) throws -> DisplayInputOutcome = { _, _, _ in .notRequested },
        showDisplay: @escaping (String, UInt8?) throws -> DisplayInputOutcome = { _, _ in .notRequested },
        checkDDCInput: @escaping (DisplayHideIdentity) throws -> DDCInputReading = { _ in
            DDCInputReading(displayID: 0, uuid: "", current: 1)
        }
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
            checkDDCInput: checkDDCInput,
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
        observationState: DisplayHideObservedState? = nil,
        inspectionFailure: String? = nil
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
            observations: observations,
            inspectionFailure: inspectionFailure,
            mirrorTopologyVerified: state == .hidden
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
        // Hide fixtures exercise the experimental path; gating has its own tests.
        defaults.set(true, forKey: "experimentalFeaturesEnabled")
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
