import AppKit
import Darwin
import XCTest
@testable import PanelCtlApp
@testable import PanelCtlCore

@MainActor
final class DisplayHideAppTests: XCTestCase {
    // Keep AppKit's tracked-menu objects alive past XCTest's per-scope memory checker.
    private static var retainedNativeMenuFixtures: [AnyObject] = []
    private static let mainUUID = "00000000-0000-0000-0000-000000000001"
    private nonisolated static let targetUUID = "00000000-0000-0000-0000-000000000002"
    private static let sourceUUID = "00000000-0000-0000-0000-000000000003"
    private static let replacementUUID = "00000000-0000-0000-0000-000000000004"
    private static let targetKey = targetUUID.lowercased()
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
        XCTAssertTrue(menuTitles.contains("Show Target"), "Show stays reachable over a source overlay")
        XCTAssertTrue(menuTitles.contains("Restore"), "protection Restore stays available over a source overlay")
        XCTAssertTrue(try model.restoreBlackout(), "Restore controls the overlay while the journal remains hidden")
        lines = try await waitForLogLines(2, at: log)
        XCTAssertEqual(lines[1], "command:restore")
        XCTAssertEqual(showCalls, 0, "Restore never invokes Show")
        XCTAssertEqual(model.handoffStatus?.state, .hidden)

        try model.blackoutNow()
        try await waitUntil { model.runtimeState == .blackedOut }
        let shown = try await showAndWait(model)
        XCTAssertTrue(shown.succeeded)
        lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(watcherWasStoppedBeforeShow)
        XCTAssertEqual(lines.filter { $0 == "stop" }.count, 1)
        XCTAssertEqual(showCalls, 1)
        XCTAssertEqual(box.value.state, .none)

        let stopped = expectation(description: "normal watcher stopped")
        model.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
    }

    func testSourceOverlayCountsBlackedOutDisplaysAsCovered() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-hidden-overlay-blackout-\(UUID().uuidString)", isDirectory: true)
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
        preferences.keepBlackoutOnInput = true
        defaults.set(try JSONEncoder().encode(preferences), forKey: "blackoutPreferences")
        setenv("PANELCTL_HELPER", helper.path, 1)
        defer {
            unsetenv("PANELCTL_HELPER")
            unsetenv("PANELCTL_TEST_LOG")
        }
        let hidden = handoffStatus(.hidden, target: displays[1], source: displays[2], journalID: "overlay-journal", canShow: true)
        // macOS doesn't list a hardware mirror target as active.
        let mirroredTarget = Self.display(index: 2, id: 202, uuid: Self.targetUUID, name: "Target", main: false, active: false)
        let current = [displays[0], mirroredTarget, displays[2]]
        let mirroredIDs: Set<UInt32> = [202, 303]
        var coverRequests: [Set<UInt32>] = []
        var helperWasStoppedWhenSourceCovered: Bool?
        var failSourceCover = false
        let model = makeModel(
            defaults: defaults,
            displays: current,
            status: { hidden },
            useManagedProtectionService: true,
            isDisplayMirrored: { mirroredIDs.contains($0) },
            coverDisplays: { ids in
                coverRequests.append(ids)
                if ids.contains(303) {
                    helperWasStoppedWhenSourceCovered =
                        (try? String(contentsOf: log, encoding: .utf8))?.contains("stop") == true
                }
                return failSourceCover ? ids : []
            }
        )
        try await waitUntil { model.runtimeState == .blackedOut }
        var lines = try await waitForLogLines(1, at: log)
        XCTAssertFalse(lines[0].contains("--panelctl-hidden-display"))
        XCTAssertTrue(model.hiddenMirrorOverlayResetsLimitOnInput, "input extends the limit while Main OLED stays usable")

        // Blacking out the last other display makes the source overlay's limit absolute.
        model.hide(targetUUID: Self.mainUUID)
        XCTAssertTrue(model.isBlackoutHidden(Self.mainUUID))
        XCTAssertFalse(model.hiddenMirrorOverlayResetsLimitOnInput)
        try await waitUntil {
            (try? String(contentsOf: log, encoding: .utf8))?.contains("--panelctl-hidden-display \(Self.mainUUID)") == true
        }
        lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        let relaunch = try XCTUnwrap(lines.last { $0.hasPrefix("launch:") })
        XCTAssertTrue(relaunch.contains("--display \(Self.sourceUUID) --panelctl-hidden-mirror-source \(Self.sourceUUID) --panelctl-hidden-display \(Self.mainUUID)"), relaunch)
        XCTAssertTrue(relaunch.contains("--keep-blackout-on-input"))

        let launchCountAfterMainHide = lines.filter { $0.hasPrefix("launch:") }.count
        model.show(targetUUID: Self.mainUUID)
        try await waitUntil {
            (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n")
                .filter { $0.hasPrefix("launch:") }.count == launchCountAfterMainHide + 1
        }
        lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertFalse(try XCTUnwrap(lines.last { $0.hasPrefix("launch:") }).contains("--panelctl-hidden-display"))
        let launchCountBeforeFailure = lines.filter { $0.hasPrefix("launch:") }.count
        failSourceCover = true
        let failedHide = try await hideAndWait(model, Self.sourceUUID)
        XCTAssertFalse(failedHide.succeeded)
        XCTAssertFalse(model.isBlackoutHidden(Self.sourceUUID))
        XCTAssertEqual(coverRequests.last, [])
        try await waitUntil {
            (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n")
                .filter { $0.hasPrefix("launch:") }.count == launchCountBeforeFailure + 1
        }
        failSourceCover = false
        lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        let launchCountBeforeHide = lines.filter { $0.hasPrefix("launch:") }.count
        let sourceHide = try await hideAndWait(model, Self.sourceUUID)
        XCTAssertTrue(sourceHide.succeeded, sourceHide.message)
        XCTAssertTrue(model.isBlackoutHidden(Self.sourceUUID))
        XCTAssertFalse(model.hiddenMirrorOverlayPolicyEligible)
        XCTAssertEqual(coverRequests.last, [303], "Hide takes sole cover ownership after the automation overlay stops")
        XCTAssertEqual(helperWasStoppedWhenSourceCovered, true,
                       "the automation overlay is stopped before Hide draws its own cover")
        try await waitUntil {
            (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").contains("stop") == true
        }
        lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.filter { $0.hasPrefix("launch:") }.count, launchCountBeforeHide,
                       "the helper doesn't restart or double-cover a source Hide owns")
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.targetKey }?.status, .hidden,
                       "the source's manual Hide leaves the removal intact")

        let sourceShow = try await showAndWait(model, Self.sourceUUID)
        XCTAssertTrue(sourceShow.succeeded)
        XCTAssertFalse(model.isBlackoutHidden(Self.sourceUUID))
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.targetKey }?.status, .hidden)
        try await waitUntil {
            (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n")
                .filter { $0.hasPrefix("launch:") }.count == launchCountBeforeHide + 1
        }

        let stopped = expectation(description: "overlay watcher stopped")
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
        while kill -0 "$PPID" 2>/dev/null; do /bin/sleep 0.02; done
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
        while kill -0 "$PPID" 2>/dev/null; do /bin/sleep 0.02; done
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

        let failed = try await showAndWait(model)
        XCTAssertEqual(showCalls, 1)
        XCTAssertNil(model.protectionQuiescenceFailure, "process death proves that its windows are gone")
        XCTAssertFalse(failed.succeeded)
        XCTAssertTrue(failed.message.contains("fake no-write Show refusal"))
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count, 1)

        let shown = try await showAndWait(model)
        XCTAssertEqual(showCalls, 2)
        XCTAssertNil(model.protectionQuiescenceFailure, "a second Show is not blocked by a stale cleanup latch")
        XCTAssertEqual(box.value.state, .none)
        XCTAssertTrue(shown.succeeded)
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
        let result = try await hideAndWait(model)
        XCTAssertEqual(hideAttempts, 1)

        let restartedLaunches = try await waitForLogLines(2, at: launchesPath)
        XCTAssertEqual(restartedLaunches, ["launch:0", "launch:1"])
        try await waitUntil { model.runtimeState == .waitingForInput }
        XCTAssertFalse(FileManager.default.fileExists(atPath: actionLog.path), "pre-capture refusal must not reuse stale idle")
        XCTAssertTrue(result.message.contains("preflight refusal"))

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
        XCTAssertTrue(model.displayTiles.allSatisfy { $0.action == .hide && $0.actionBlocker == nil },
                      "every display offers Hide")
        XCTAssertFalse(displays.contains(where: model.hideRemovesFromDesktop), "Hide blacks out until removal is set up")
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

    func testRemovalDefaultsToTheMainDisplayAsMirrorSource() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let model = makeModel(defaults: defaults, displays: displays)

        XCTAssertNil(model.removalIneligibleReason(for: displays[1]))
        XCTAssertNil(model.removalIneligibleReason(for: displays[0]), "an external main display can be a removal target")
        model.setHideEnabled(true, for: displays[1])
        XCTAssertEqual(model.hidePreferences[Self.targetUUID]?.source?.uuid, Self.mainUUID)
        XCTAssertEqual(try model.makeHideRequest(targetUUID: Self.targetUUID).source.uuid, Self.mainUUID)

        // A chosen source survives turning removal off and on again.
        model.setHideSource(Self.sourceUUID, for: Self.targetUUID)
        model.setHideEnabled(false, for: displays[1])
        model.setHideEnabled(true, for: displays[1])
        XCTAssertEqual(model.hidePreferences[Self.targetUUID]?.source?.uuid, Self.sourceUUID)
        XCTAssertEqual(model.sourceChoices(for: try XCTUnwrap(model.hideConfiguration(for: Self.targetUUID))).compactMap(\.uuid),
                       [Self.mainUUID, Self.sourceUUID], "the target is never its own source")

        model.setHideEnabled(true, for: displays[0])
        let mainConfiguration = try XCTUnwrap(model.hideConfiguration(for: Self.mainUUID))
        XCTAssertNil(mainConfiguration.source, "a new main-target setup requires an explicit source")
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.mainUUID }?.actionBlocker,
                       "Choose a display to mirror onto.")
        XCTAssertThrowsError(try model.makeHideRequest(targetUUID: Self.mainUUID)) {
            XCTAssertTrue($0.localizedDescription.contains("Choose a display to mirror onto"))
        }
        XCTAssertEqual(model.sourceChoices(for: mainConfiguration).compactMap(\.uuid),
                       [Self.targetUUID, Self.sourceUUID], "the main target is never its own source")
        model.setHideSource(Self.targetUUID, for: Self.mainUUID)
        XCTAssertEqual(try model.makeHideRequest(targetUUID: Self.mainUUID).source.uuid, Self.targetUUID)
        XCTAssertEqual(model.hideConfiguration(for: Self.targetUUID)?.source?.uuid, Self.sourceUUID,
                       "enabling a main target leaves the other target's saved source unchanged")
    }

    func testNativeMainTargetSetupRequiresSourceAndUsesTheSharedHideControls() throws {
        let defaults = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName(defaults))
            closeSettingsWindows()
        }
        let model = makeModel(defaults: defaults, displays: displays)
        let controller = SettingsWindowController(model: model)
        controller.present()
        controller.selectDisplay(uuid: Self.mainUUID)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 680, height: 1200))
        settle(window)

        let toggle = try XCTUnwrap(removalSwitch(in: window), controlSummary(window))
        XCTAssertEqual(toggle.state, .off)
        XCTAssertTrue(toggle.isEnabled, "an external main display can be configured for removal")
        toggle.performClick(nil)
        settle(window)

        let configuration = try XCTUnwrap(model.hideConfiguration(for: Self.mainUUID))
        XCTAssertTrue(configuration.enabled)
        XCTAssertNil(configuration.source)
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.mainUUID }?.actionBlocker,
                       "Choose a display to mirror onto.")
        XCTAssertThrowsError(try model.makeHideRequest(targetUUID: Self.mainUUID))
        XCTAssertEqual(model.sourceChoices(for: configuration).compactMap(\.uuid),
                       [Self.targetUUID, Self.sourceUUID])
        XCTAssertNil(window.attachedSheet, "main-target setup needs no confirmation dialog")
    }

    func testMacInputIsDetectedReadOnlyAndBecomesTheReturnInput() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var checkCalls = 0
        var current: UInt8 = 0x0F
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            checkDDCInput: { identity in
                checkCalls += 1
                return DDCInputReading(displayID: identity.displayID, uuid: identity.uuid, current: current)
            }
        )
        model.detectMacInput(for: Self.targetUUID)
        XCTAssertEqual(checkCalls, 0, "nothing is read before removal is turned on")
        model.setHideEnabled(true, for: displays[1])
        model.setHideSwitchInput(0x11, for: Self.targetUUID)
        XCTAssertEqual(checkCalls, 0, "choosing an input never reads DDC")
        XCTAssertEqual(model.hidePreferences[Self.targetUUID]?.awayInput, 0x11)
        XCTAssertNil(model.hidePreferences[Self.targetUUID]?.returnInput, "the Mac input is detected, never guessed")

        model.detectMacInput(for: Self.targetUUID)
        XCTAssertEqual(checkCalls, 1)
        XCTAssertEqual(model.macInputDetections[Self.targetKey], .detected(0x0F))
        XCTAssertEqual(model.hidePreferences[Self.targetUUID]?.returnInput, 0x0F)
        XCTAssertEqual(try model.makeHideRequest(targetUUID: Self.targetUUID).awayInput, 0x11)

        // The monitor showing the input Hide switches to says nothing about the
        // Mac, even after Hide is set to switch somewhere else.
        current = 0x11
        model.detectMacInput(for: Self.targetUUID)
        XCTAssertEqual(model.macInputDetections[Self.targetKey], .onSwitchInput(0x11))
        XCTAssertEqual(model.hidePreferences[Self.targetUUID]?.returnInput, 0x0F)
        model.setHideSwitchInput(0x12, for: Self.targetUUID)
        XCTAssertEqual(model.hidePreferences[Self.targetUUID]?.returnInput, 0x0F, "an untrusted reading never becomes the Mac input")
        model.setHideSwitchInput(0x11, for: Self.targetUUID)

        let reloaded = makeModel(defaults: defaults, displays: displays, checkDDCInput: { _ in
            XCTFail("loading settings never reads DDC")
            return DDCInputReading(displayID: 0, uuid: "", current: 0)
        })
        XCTAssertEqual(reloaded.hidePreferences[Self.targetUUID]?.awayInput, 0x11)
        XCTAssertEqual(reloaded.hidePreferences[Self.targetUUID]?.returnInput, 0x0F)

        // A failed or mismatched read is explained, keeps the last detected input
        // and never blocks Hide.
        for (failure, expected) in [
            ({ (_: DisplayHideIdentity) throws -> DDCInputReading in
                throw NSError(domain: "FakeDDC", code: 1, userInfo: [NSLocalizedDescriptionKey: "fake DDC unavailable"])
            }, "fake DDC unavailable."),
            ({ (_: DisplayHideIdentity) throws -> DDCInputReading in
                throw DDCError.requestFailed(-536870212)
            }, "DDC I2C request failed (IOReturn -536870212)."),
            ({ (identity: DisplayHideIdentity) throws -> DDCInputReading in
                DDCInputReading(displayID: identity.displayID, uuid: identity.uuid, current: 0)
            }, "didn\u{2019}t report its current input"),
            ({ (identity: DisplayHideIdentity) throws -> DDCInputReading in
                DDCInputReading(displayID: identity.displayID + 1, uuid: identity.uuid, current: 0x0F)
            }, "answered as a different display")
        ] {
            let failing = makeModel(defaults: defaults, displays: displays, checkDDCInput: failure)
            failing.detectMacInput(for: Self.targetUUID)
            guard case .unavailable(let message) = failing.macInputDetections[Self.targetKey] else {
                return XCTFail("expected an unavailable detection")
            }
            XCTAssertTrue(message.contains(expected), message)
            XCTAssertEqual(failing.hidePreferences[Self.targetUUID]?.returnInput, 0x0F)
            XCTAssertNoThrow(try failing.makeHideRequest(targetUUID: Self.targetUUID))
        }

        // Turning switching off keeps the Mac input for when it is turned back
        // on; Show ignores it meanwhile (see testMacInputIsNotReadWhileTheDisplayIsHidden).
        model.setHideSwitchInput(nil, for: Self.targetUUID)
        XCTAssertNil(model.hidePreferences[Self.targetUUID]?.awayInput)
        XCTAssertEqual(model.hidePreferences[Self.targetUUID]?.returnInput, 0x0F)
        model.setHideSwitchInput(0x0F, for: Self.targetUUID)
        XCTAssertNil(model.hidePreferences[Self.targetUUID]?.returnInput, "Show never switches back to the input Hide switches to")
        XCTAssertEqual(checkCalls, 2)
    }

    func testTheMacInputStaysKnownWhenHideIsSetToSwitchToIt() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var checkCalls = 0
        let model = makeModel(defaults: defaults, displays: displays, checkDDCInput: { identity in
            checkCalls += 1
            return DDCInputReading(displayID: identity.displayID, uuid: identity.uuid, current: 0x0F)
        })
        model.setHideEnabled(true, for: displays[1])
        XCTAssertNil(model.macInput(for: Self.targetUUID))

        // Read before an input is chosen, so the other computer's input is easy to pick.
        model.detectMacInput(for: Self.targetUUID)
        XCTAssertEqual(model.macInputDetections[Self.targetKey], .detected(0x0F))
        XCTAssertEqual(model.macInput(for: Self.targetUUID), 0x0F)

        // Choosing the Mac's own input keeps it known, but Show never switches to it.
        model.setHideSwitchInput(0x0F, for: Self.targetUUID)
        XCTAssertEqual(model.macInput(for: Self.targetUUID), 0x0F)
        XCTAssertNil(model.hidePreferences[Self.targetUUID]?.returnInput)

        model.setHideSwitchInput(0x11, for: Self.targetUUID)
        XCTAssertEqual(model.hidePreferences[Self.targetUUID]?.returnInput, 0x0F)
        XCTAssertEqual(checkCalls, 1, "choosing inputs never reads DDC")
    }

    func testMacInputIsNotReadWhileTheDisplayIsHidden() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var preferences = DisplayHidePreferences()
        preferences[Self.targetUUID] = DisplayHideConfiguration(
            target: DisplayIdentitySnapshot(displays[1]), enabled: true,
            source: DisplayIdentitySnapshot(displays[0]), awayInput: 0x11, returnInput: 0x0F
        )
        defaults.set(try JSONEncoder().encode(preferences), forKey: "displayHidePreferences")
        let hidden = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "frozen", canShow: true)
        let model = makeModel(defaults: defaults, displays: displays, status: { hidden }, checkDDCInput: { _ in
            XCTFail("a hidden display shows the other computer; reading it would replace the Mac input")
            return DDCInputReading(displayID: 0, uuid: "", current: 0)
        })
        try await waitUntil { !model.protectionQuiescencePending }
        model.detectMacInput(for: Self.targetUUID)
        model.setHideSwitchInput(nil, for: Self.targetUUID)
        XCTAssertEqual(model.hidePreferences[Self.targetUUID]?.returnInput, 0x0F, "settings are frozen while hidden")
        XCTAssertEqual(model.showReturnInputNote, "Show switches the monitor back to DisplayPort 1.")
        XCTAssertEqual(try model.makeShowRequest().returnInput, 0x0F)

        // A Mac input kept while switching is off isn't used: Show switches back only when Hide switched.
        preferences[Self.targetUUID]?.awayInput = nil
        defaults.set(try JSONEncoder().encode(preferences), forKey: "displayHidePreferences")
        let unswitched = makeModel(defaults: defaults, displays: displays, status: { hidden }, checkDDCInput: { _ in
            XCTFail("a hidden display is never read")
            return DDCInputReading(displayID: 0, uuid: "", current: 0)
        })
        try await waitUntil { !unswitched.protectionQuiescencePending }
        XCTAssertNil(unswitched.showReturnInputNote)
        XCTAssertNil(try unswitched.makeShowRequest().returnInput)
    }

    func testHideAndShowReportDesktopAndInputResultsInline() async throws {
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
            },
            checkDDCInput: { identity in
                DDCInputReading(displayID: identity.displayID, uuid: identity.uuid, current: 0x0F)
            }
        )
        model.setHideEnabled(true, for: displays[1])
        model.setHideSwitchInput(0x11, for: Self.targetUUID)
        model.detectMacInput(for: Self.targetUUID)

        let hiddenResult = try await hideAndWait(model)
        XCTAssertEqual(awayInputs, [0x11])
        XCTAssertEqual(model.displayResults[Self.targetKey], hiddenResult)
        XCTAssertTrue(hiddenResult.succeeded)
        XCTAssertEqual(hiddenResult.message, "Hidden.")
        XCTAssertEqual(hiddenResult.inputMessage, "Switched the monitor to HDMI 1.")
        XCTAssertFalse(hiddenResult.needsAttention)
        XCTAssertEqual(hiddenResult.inputOutcome?.recoveryCommand, "panelctl ddc-input --display '\(Self.targetUUID)' --set 0x0F")
        XCTAssertNil(hiddenResult.undoInputCommand, "a switch that worked needs no undo; Show switches back")
        XCTAssertNil(model.notice, "results never open an alert")
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.targetKey }?.status, .hidden)
        XCTAssertNil(model.displayRecoveryProblem, "a healthy hidden display isn't a recovery problem")
        XCTAssertEqual(model.showReturnInputNote, "Show switches the monitor back to DisplayPort 1.")

        let shownResult = try await showAndWait(model)
        XCTAssertEqual(returnInputs, [0x0F])
        XCTAssertTrue(shownResult.succeeded, "the desktop is back even though the input switch failed")
        XCTAssertEqual(shownResult.message, "Shown.")
        XCTAssertEqual(
            shownResult.inputMessage,
            "Couldn\u{2019}t switch the monitor to DisplayPort 1. fake DDC write failure after desktop restore. Use the monitor\u{2019}s buttons."
        )
        XCTAssertTrue(shownResult.needsAttention)
        XCTAssertEqual(shownResult.undoInputCommand, "panelctl ddc-input --display '\(Self.targetUUID)' --set 0x11")
        XCTAssertEqual(shownResult.menuLine, shownResult.inputMessage)
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.targetKey }?.status, .on)
        XCTAssertEqual(model.controlDisplayOutcome, .partial)
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
        model.setHideSwitchInput(0x11, for: Self.targetUUID)
        let result = try await hideAndWait(model)

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.message.contains("couldn\u{2019}t confirm the display is hidden"), result.message)
        XCTAssertEqual(result.inputMessage, "Switched the monitor to HDMI 1.")
        XCTAssertEqual(result.inputOutcome?.recoveryCommand, command, "the returned input outcome survives inspection failure")
        XCTAssertEqual(result.undoInputCommand, command, "the monitor switched but the display isn\u{2019}t hidden, so the way back is offered")
        XCTAssertNotNil(model.displayRecoveryProblem)
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.targetKey }?.status, .needsRecovery)
        XCTAssertNil(model.pageRecoveryProblem, "the display that needs recovery shows the problem")
    }

    func testShowInspectionFailurePreservesReturnedInputOutcome() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var preferences = DisplayHidePreferences()
        preferences[Self.targetUUID] = DisplayHideConfiguration(
            target: DisplayIdentitySnapshot(displays[1]),
            enabled: true,
            source: DisplayIdentitySnapshot(displays[0]),
            awayInput: 17,
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
        XCTAssertEqual(try model.makeShowRequest().returnInput, 15)
        let result = try await showAndWait(model)

        XCTAssertEqual(shownInput, 15)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.message.contains("post-Show observation failed"), result.message)
        XCTAssertEqual(result.inputMessage, "Switched the monitor to DisplayPort 1.")
        XCTAssertEqual(result.inputOutcome?.recoveryCommand, command, "the returned input outcome survives inspection failure")
        XCTAssertNotNil(model.displayRecoveryProblem)
    }

    func testSkippedAndUnverifiedHideOutcomesRemainSeparateFromDesktopSuccess() async throws {
        for (index, state, detail) in [
            (1, DisplayInputOutcome.State.skipped, "DDC is unavailable"),
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
            model.setHideSwitchInput(0x11, for: Self.targetUUID)
            let result = try await hideAndWait(model)

            XCTAssertTrue(result.succeeded)
            XCTAssertEqual(result.message, "Hidden.")
            XCTAssertTrue(result.inputNeedsAttention)
            XCTAssertEqual(result.menuLine, result.inputMessage)
            XCTAssertEqual(result.undoInputCommand, state == .unverified
                ? "panelctl ddc-input --display '\(Self.targetUUID)' --set 0x0F" : nil)
            XCTAssertEqual(result.inputMessage, state == .skipped
                ? "Couldn\u{2019}t switch the monitor input. \(detail). Use the monitor\u{2019}s buttons."
                : "Asked the monitor to switch to HDMI 1 but couldn\u{2019}t confirm it. Check the monitor and use its buttons if needed.")
            XCTAssertEqual(model.controlDisplayOutcome, .partial)
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
        model.setHideSwitchInput(0x11, for: Self.targetUUID)
        let result = try await hideAndWait(model)

        XCTAssertEqual(hideCalls, 1)
        XCTAssertEqual(model.handoffStatus?.state, .recovery)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.message.contains("panelctl recovery restore --journal"), result.message)
        XCTAssertEqual(result.inputMessage, "Couldn\u{2019}t switch the monitor to HDMI 1. fake write failed. Use the monitor\u{2019}s buttons.")
        XCTAssertEqual(result.inputOutcome?.recoveryCommand, command)
        XCTAssertEqual(result.undoInputCommand, command)
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.targetKey }?.status, .needsRecovery)
        XCTAssertEqual(model.displayRecoveryProblem, "journal retained after DDC failure")
    }

    func testStaleSavedReturnInputIsActionableButNeverBlocksShow() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var preferences = DisplayHidePreferences()
        let staleTarget = DisplayIdentitySnapshot(
            uuid: Self.targetUUID, id: 202, name: "Target", vendor: 2, model: 20, serial: 999
        )
        preferences[Self.targetUUID] = DisplayHideConfiguration(target: staleTarget, enabled: true, awayInput: 17, returnInput: 15)
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
        let warning = "the saved input belongs to a different display."
        XCTAssertEqual(request.returnInputWarning, warning)
        XCTAssertEqual(model.showReturnInputNote, "Show won\u{2019}t switch the monitor input: \(warning)")

        let result = try await showAndWait(model)
        XCTAssertTrue(showCalled)
        XCTAssertNil(showInput, "Show proceeds without issuing stale saved DDC input")
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.inputMessage, "Didn\u{2019}t switch the monitor input: \(warning)")
        XCTAssertTrue(result.inputNeedsAttention)
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
        XCTAssertTrue(reloaded.hideReadinessMessage(for: saved)?.contains("won\u{2019}t apply its settings to a different display") == true)
        XCTAssertThrowsError(try reloaded.makeHideRequest(targetUUID: Self.targetUUID))
        XCTAssertNil(reloaded.hidePreferences[Self.replacementUUID])
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
        while kill -0 "$PPID" 2>/dev/null; do /bin/sleep 0.02; done
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
            let service = ProtectionService(cleanupIsVerified: { false })
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
            let result = try await hideAndWait(model)

            XCTAssertEqual(hideCalls, 0, "cleanup \(cleanupResult) retained after ordinary disable must block Hide")
            XCTAssertTrue(model.protectionQuiescenceFailure?.localizedCaseInsensitiveContains("cleanup") == true)
            XCTAssertFalse(result.succeeded)
            XCTAssertTrue(result.message.contains("didn\u{2019}t change the display"), result.message)
        }
    }

    func testCleanupRetryAfterHideFailureWorksWithAutomationOffAndSurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-cleanup-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("fake-panelctl")
        try Data("""
        #!/bin/bash
        if [[ "$PANELCTL_CLEANUP_ONLY" == "1" ]]; then
            printf '{"state":"stopped","blackedOutDisplayIDs":[],"cleanupSucceeded":%s}\\n' "$PANELCTL_TEST_RETRY_RESULT"
            exit 0
        fi
        trap 'printf "{\\"state\\":\\"stopped\\",\\"blackedOutDisplayIDs\\":[],\\"cleanupSucceeded\\":false}\\n"; exit 0' TERM
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        while kill -0 "$PPID" 2>/dev/null; do /bin/sleep 0.02; done
        """.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_RETRY_RESULT", "false", 1)
        defer {
            unsetenv("PANELCTL_HELPER")
            unsetenv("PANELCTL_TEST_RETRY_RESULT")
        }
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let service = ProtectionService(cleanupIsVerified: { true })
        let model = makeModel(defaults: defaults, displays: displays,
                              useManagedProtectionService: true, protectionService: service)
        model.setHideEnabled(true, for: displays[1])
        service.run(arguments: ["blackout"])
        try await waitUntil { service.state == .waiting }
        let result = try await hideAndWait(model)
        XCTAssertFalse(result.succeeded)
        XCTAssertNotNil(model.protectionQuiescenceFailure)
        XCTAssertFalse(model.statusSummary.contains("desktop is hidden"))
        XCTAssertNil(model.handoffStatus?.journalID)
        XCTAssertFalse(model.preferences.isEnabled)
        let delegate = AppDelegate()
        delegate.model = model
        XCTAssertTrue(try XCTUnwrap(delegate.makeMenu().items.first {
            $0.title == "Retry Automation Cleanup"
        }).isEnabled)

        model.retryProtection()
        try await waitUntil { !model.protectionQuiescencePending }
        XCTAssertNotNil(model.protectionQuiescenceFailure, "failed retry keeps Hide blocked")
        XCTAssertNotNil(model.hideReadinessMessage(for: try XCTUnwrap(model.hideConfiguration(for: Self.targetUUID))))
        let relaunched = makeModel(defaults: defaults, displays: displays, useManagedProtectionService: true)
        XCTAssertNotNil(relaunched.protectionQuiescenceFailure, "relaunch must not erase unresolved evidence")
        setenv("PANELCTL_TEST_RETRY_RESULT", "true", 1)
        relaunched.retryProtection()
        try await waitUntil { !relaunched.protectionQuiescencePending }
        XCTAssertNil(relaunched.protectionQuiescenceFailure)
        XCTAssertNil(defaults.string(forKey: "automationCleanupFailure"))
        XCTAssertFalse(relaunched.preferences.isEnabled, "cleanup-only retry never enables automation")
        XCTAssertNil(relaunched.hideReadinessMessage(for: try XCTUnwrap(relaunched.hideConfiguration(for: Self.targetUUID))))
        let again = makeModel(defaults: defaults, displays: displays)
        XCTAssertNil(again.protectionQuiescenceFailure)
    }

    func testShowCleanupFailureCanBeRetriedWithoutRunningAutomation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-show-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("fake-panelctl")
        try Data("""
        #!/bin/bash
        if [[ "$PANELCTL_CLEANUP_ONLY" == "1" ]]; then
            printf '{"state":"stopped","blackedOutDisplayIDs":[],"cleanupSucceeded":true}\\n'
            exit 0
        fi
        trap 'exit 0' TERM
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        while kill -0 "$PPID" 2>/dev/null; do /bin/sleep 0.02; done
        """.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        setenv("PANELCTL_HELPER", helper.path, 1)
        defer { unsetenv("PANELCTL_HELPER") }
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var verified = true
        let service = ProtectionService(cleanupIsVerified: { verified })
        let box = StatusBox(handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "show-cleanup", canShow: true))
        var showCalls = 0
        let model = makeModel(defaults: defaults, displays: displays, status: { box.value },
                              useManagedProtectionService: true, protectionService: service,
                              showDisplay: { _, _ in showCalls += 1; return .notRequested })
        try await waitUntil { !model.protectionQuiescencePending }
        service.run(arguments: ["blackout"])
        try await waitUntil { service.state == .waiting }
        verified = false
        var result: DisplayOperationResult?
        model.show(targetUUID: Self.targetUUID) { result = $0 }
        try await waitUntil { result != nil }
        XCTAssertFalse(try XCTUnwrap(result).succeeded)
        XCTAssertEqual(showCalls, 0)
        XCTAssertNotNil(model.protectionQuiescenceFailure)
        XCTAssertEqual(model.handoffStatus?.journalID, "show-cleanup")
        verified = true
        model.retryAutomationCleanup()
        try await waitUntil { !model.protectionQuiescencePending }
        XCTAssertNil(model.protectionQuiescenceFailure)
        XCTAssertEqual(showCalls, 0, "cleanup does not silently retry Show")
        XCTAssertEqual(model.handoffStatus?.journalID, "show-cleanup")
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
        let protectedSelection = model.preferences.selectedDisplayUUIDs
        var result: DisplayOperationResult?
        model.hide(targetUUID: Self.targetUUID) { result = $0 }
        var duplicate: DisplayOperationResult?
        model.hide(targetUUID: Self.targetUUID) { duplicate = $0 }
        XCTAssertEqual(quiesceCalls, 1, "Hide runs at once, with no confirmation")
        XCTAssertEqual(hideCalls, 0, "automation stops before the backend runs")
        XCTAssertTrue(model.hideOperation.isBusy)
        XCTAssertEqual(duplicate?.succeeded, false, "a second Hide is refused, not queued")
        XCTAssertNil(model.displayResults[Self.targetKey], "a refused duplicate never replaces the running Hide's result")
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.targetKey }?.status, .hiding)
        let delegate = AppDelegate()
        delegate.model = model
        let hiding = try XCTUnwrap(delegate.makeMenu().items.first { $0.title == "Target" })
        XCTAssertFalse(hiding.isEnabled)
        if #available(macOS 14.4, *) {
            XCTAssertEqual(hiding.subtitle, "Hiding\u{2026}")
        }

        completion?(false, "brightness restore failed")
        try await waitUntil { result != nil }
        XCTAssertEqual(hideCalls, 0)
        XCTAssertNil(model.handoffStatus?.journalID)
        XCTAssertTrue(model.protectionQuiescenceFailure?.contains("brightness restore failed") == true)
        XCTAssertEqual(model.preferences.selectedDisplayUUIDs, protectedSelection)
        XCTAssertFalse(model.preferences.isEnabled)
        XCTAssertEqual(result?.succeeded, false)
        XCTAssertTrue(result?.message.contains("brightness restore failed") == true)
        XCTAssertEqual(model.displayResults[Self.targetKey], result)
        XCTAssertNil(model.notice, "failures appear inline, not in an alert")
        let configuration = try XCTUnwrap(model.hideConfiguration(for: Self.targetUUID))
        XCTAssertTrue(model.hideReadinessMessage(for: configuration)?.contains("Automation cleanup needs attention") == true,
                      "the cleanup failure blocks another Hide until it clears")
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
        var result: DisplayOperationResult?
        model.hide(targetUUID: Self.targetUUID) { result = $0 }
        XCTAssertNotNil(quiesceCompletion, "the app validated the identities before cleanup began")

        quiesceCompletion?(true, nil)
        try await waitUntil { result != nil }

        XCTAssertEqual(captureCalls, 0, "identity refusal happens before fresh capture")
        XCTAssertEqual(writerCalls, 0, "no transaction or writer begins for a changed target")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path), "no recovery journal is created")
        let message = try XCTUnwrap(result?.message)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("target identity changed"), message)
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
        let result = try await hideAndWait(model)

        XCTAssertEqual(hideCalls, 1)
        XCTAssertEqual(model.handoffStatus?.state, DisplayHandoffStatus.State.none)
        XCTAssertFalse(model.protectionPausedForDisplayRecovery)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.message.contains("no capture"), result.message)
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.targetKey }?.status, .on)
        XCTAssertNil(model.displayRecoveryProblem)

        // Changing the settings clears a failure that described the old ones.
        model.setHideSource(Self.sourceUUID, for: Self.targetUUID)
        XCTAssertNil(model.displayResults[Self.targetKey])
    }

    func testSettingsEditsKeepAFailedHideThatSwitchedTheMonitor() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let command = "panelctl ddc-input --display '\(Self.targetUUID)' --set 0x0F"
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            status: { self.handoffStatus(.none, target: nil, source: nil) },
            hideDisplay: { _, _, input in
                throw DisplayHandoffOperationFailure(
                    action: "hide",
                    inputOutcome: DisplayInputOutcome(
                        state: .verified, requestedInput: input, observedInput: input, recoveryCommand: command
                    ),
                    message: "fake mirror failure; layout unchanged"
                )
            }
        )
        model.setHideEnabled(true, for: displays[1])
        model.setHideSwitchInput(0x11, for: Self.targetUUID)
        let result = try await hideAndWait(model)
        XCTAssertFalse(model.hideConfigurationFrozen)
        XCTAssertEqual(result.undoInputCommand, command)

        model.setHideSwitchInput(0x12, for: Self.targetUUID)
        model.setHideSource(Self.sourceUUID, for: Self.targetUUID)
        XCTAssertEqual(model.displayResults[Self.targetKey], result, "the monitor is still switched, so the undo command stays")
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
        model.setHideEnabled(true, for: displays[2])
        let result = try await hideAndWait(model)

        XCTAssertEqual(hideCalls, 1)
        XCTAssertEqual(model.handoffStatus?.state, .recovery)
        XCTAssertEqual(model.handoffStatus?.journalID, "fake-journal")
        XCTAssertTrue(model.protectionPausedForDisplayRecovery)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.message.contains("journal retained"), result.message)
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.targetKey }?.status, .needsRecovery)
        XCTAssertEqual(model.displayRecoveryProblem, "fake writer interrupted; journal retained")
        for uuid in [Self.targetUUID, Self.sourceUUID] {
            XCTAssertThrowsError(try model.makeHideRequest(targetUUID: uuid), "one removed display at a time") { error in
                XCTAssertTrue(error.localizedDescription.contains("Only one display can be removed at a time"))
            }
        }
        let other = try XCTUnwrap(model.displayTiles.first { $0.id == Self.sourceUUID.lowercased() })
        XCTAssertEqual(other.action, .hide)
        XCTAssertTrue(other.actionBlocker?.contains("Only one display can be removed at a time") == true,
                      other.actionBlocker ?? "no blocker")
        let delegate = AppDelegate()
        delegate.model = model
        let items = delegate.makeMenu().items
        let hideOther = try XCTUnwrap(items.first { $0.title == "Hide Mirror source" })
        XCTAssertFalse(hideOther.isEnabled, "a Hide that can't run is dimmed")
        XCTAssertEqual(hideOther.toolTip, other.actionBlocker)
        XCTAssertFalse(items.contains { $0.title == "Hide Target" })
    }

    func testBlackOutAndRemovalStayOffEachOthersDisplays() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(handoffStatus(.none, target: nil, source: nil))
        let model = makeModel(defaults: defaults, displays: displays, status: { box.value })
        model.setHideEnabled(true, for: displays[1])
        model.setHideSource(Self.sourceUUID, for: Self.targetUUID)
        XCTAssertTrue(model.hideRemovesFromDesktop(displays[1]))
        XCTAssertFalse(model.hideRemovesFromDesktop(displays[2]))

        // Removal never mirrors onto a blacked-out display.
        model.hide(targetUUID: Self.sourceUUID)
        XCTAssertTrue(model.isBlackoutHidden(Self.sourceUUID))
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.targetKey }?.actionBlocker,
                       "The display it mirrors onto is hidden. Show it first.")
        model.show(targetUUID: Self.sourceUUID)
        XCTAssertNil(model.displayTiles.first { $0.id == Self.targetKey }?.actionBlocker)

        // Black out leaves a removed display alone, which doesn't count as visible.
        box.value = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "fixture-journal", canShow: true)
        model.refreshHandoffStatus()
        spin { !model.protectionQuiescencePending }
        XCTAssertEqual(model.blackoutReadiness(for: displays[1])?.localizedDescription,
                       "PanelCtl removed this display from the desktop. Show it first.")
        model.hide(targetUUID: Self.sourceUUID)
        XCTAssertTrue(model.isBlackoutHidden(Self.sourceUUID), "another display can still be blacked out")
        XCTAssertEqual(model.blackoutReadiness(for: displays[0])?.localizedDescription,
                       "PanelCtl keeps at least one display visible, so it won\u{2019}t hide this one.")
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

        // A stale action for another display never shows the journaled one.
        let wrongDisplay = try await showAndWait(model, Self.sourceUUID)
        XCTAssertFalse(wrongDisplay.succeeded)
        XCTAssertTrue(wrongDisplay.message.contains("isn\u{2019}t hidden by PanelCtl"), wrongDisplay.message)
        XCTAssertTrue(shownJournalIDs.isEmpty)

        let failed = try await showAndWait(model)
        XCTAssertEqual(shownJournalIDs, ["captured-journal"])
        XCTAssertEqual(model.handoffStatus?.state, .hidden)
        XCTAssertTrue(model.protectionPausedForDisplayRecovery)
        XCTAssertFalse(failed.succeeded)
        XCTAssertTrue(failed.message.contains("fake restore mismatch"), failed.message)
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.targetKey }?.status, .hidden,
                       "a failed Show leaves the display hidden, with Show still available")

        showFails = false
        let shown = try await showAndWait(model)
        XCTAssertEqual(shownJournalIDs, ["captured-journal", "captured-journal"])
        XCTAssertEqual(model.handoffStatus?.state, DisplayHandoffStatus.State.none)
        XCTAssertFalse(model.protectionPausedForDisplayRecovery)
        XCTAssertTrue(shown.succeeded)
        XCTAssertEqual(shown.message, "Shown.")
        XCTAssertNil(model.notice)
    }

    func testDisplayTransitionsBlockHideAndShow() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(handoffStatus(.none, target: nil, source: nil))
        let model = makeModel(defaults: defaults, displays: displays, status: { box.value })
        model.setHideEnabled(true, for: displays[1])
        model.setDisplayLifecycleTransitioning(true)
        XCTAssertThrowsError(try model.makeHideRequest(targetUUID: Self.targetUUID)) { error in
            XCTAssertEqual(error as? DisplayHideError, .sleeping)
        }
        model.setDisplayLifecycleTransitioning(false)
        XCTAssertNoThrow(try model.makeHideRequest(targetUUID: Self.targetUUID))

        box.value = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "lifecycle-journal", canShow: true)
        model.refreshHandoffStatus()
        model.setDisplayLifecycleTransitioning(true)
        XCTAssertThrowsError(try model.makeShowRequest())
        model.setDisplayLifecycleTransitioning(false)
        try await waitUntil { !model.protectionQuiescencePending }
        XCTAssertNoThrow(try model.makeShowRequest())
    }

    func testDisplayTilesFollowArrangementAndShowEachState() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let left = Self.display(index: 4, id: 404, uuid: Self.replacementUUID, name: "Dell", main: false, x: -1920)
        let main = displays[0]
        let right = Self.display(index: 2, id: 202, uuid: Self.targetUUID, name: "Dell", main: false)
        let asleep = Self.display(index: 3, id: 303, uuid: Self.sourceUUID, name: "Sleepy", main: false, asleep: true)
        let offline = Self.display(index: 5, id: 505, uuid: "00000000-0000-0000-0000-000000000005",
                                   name: "Offline", main: false, online: false)
        let box = StatusBox(handoffStatus(.none, target: nil, source: nil))
        var connected = [right, offline, asleep, main, left]
        let model = makeModel(defaults: defaults, displays: [], displayProvider: { connected }, status: { box.value })

        // Left to right, numbering identical names as macOS does.
        var tiles = model.displayTiles
        XCTAssertEqual(tiles.map(\.name), ["Dell (1)", "Main OLED", "Dell (2)", "Sleepy"])
        XCTAssertEqual(tiles.map(\.status), [.on, .on, .on, .asleep])
        XCTAssertEqual(tiles.map(\.isMain), [false, true, false, false])
        XCTAssertEqual(tiles[2].id, Self.targetKey)

        // A display hidden by mirroring shares its source's origin and follows it.
        let mirrored = Self.display(index: 2, id: 202, uuid: Self.targetUUID, name: "Dell", main: false, x: 0)
        connected = [mirrored, asleep, main, left]
        box.value = handoffStatus(.hidden, target: right, source: main, journalID: "tiles", canShow: true)
        model.refreshDisplays()
        tiles = model.displayTiles
        XCTAssertEqual(tiles.map(\.id), [Self.replacementUUID.lowercased(), Self.mainUUID.lowercased(), Self.targetKey, Self.sourceUUID.lowercased()])
        XCTAssertEqual(tiles.map(\.status), [.on, .on, .hidden, .asleep])
        XCTAssertNil(model.displayRecoveryProblem)

        // A journaled display that is gone stays listed, last, by its saved name.
        connected = [asleep, main, left]
        box.value = handoffStatus(.recovery, target: right, source: main, journalID: "tiles", reason: "Reconnect Dell.")
        model.refreshDisplays()
        tiles = model.displayTiles
        XCTAssertEqual(tiles.map(\.name), ["Dell (1)", "Main OLED", "Sleepy", "Dell (2)"])
        XCTAssertEqual(tiles.last?.status, .needsRecovery)
        XCTAssertNil(tiles.last?.display)
        XCTAssertEqual(model.displayRecoveryProblem, "Reconnect Dell.")

        // Inspection failures are problems even without a journal.
        box.value = handoffStatus(.none, target: nil, source: nil, inspectionFailure: "unreadable journal")
        model.refreshDisplays()
        XCTAssertEqual(model.displayRecoveryProblem, "Couldn\u{2019}t check display recovery: unreadable journal")
    }

    func testNativeHideSetupDefaultsSourceAndDetectsTheMacInput() throws {
        let defaults = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName(defaults))
            closeSettingsWindows()
        }
        var ddcChecks = 0
        let model = makeModel(defaults: defaults, displays: displays, checkDDCInput: { identity in
            ddcChecks += 1
            return DDCInputReading(displayID: identity.displayID, uuid: identity.uuid, current: 0x0F)
        })
        let controller = SettingsWindowController(model: model)
        controller.present()
        controller.selectDisplay(uuid: Self.targetUUID)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 680, height: 1200))
        settle(window)
        let toggle = try XCTUnwrap(removalSwitch(in: window), controlSummary(window))
        XCTAssertEqual(toggle.state, .off)
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.targetKey }?.action, .hide)
        XCTAssertFalse(model.hideRemovesFromDesktop(displays[1]), "Hide blacks out until removal is on")

        toggle.performClick(nil)
        settle(window)
        let configuration = try XCTUnwrap(model.hideConfiguration(for: Self.targetUUID))
        XCTAssertTrue(configuration.enabled)
        XCTAssertEqual(configuration.source?.uuid, Self.mainUUID, "the main display is the default mirror source")
        XCTAssertEqual(model.sourceChoices(for: configuration).map(\.uuid), [Self.mainUUID, Self.sourceUUID])
        XCTAssertNil(configuration.awayInput, "no input switch by default")
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.targetKey }?.action, .hide)
        XCTAssertNil(model.displayTiles.first { $0.id == Self.targetKey }?.actionBlocker)
        XCTAssertTrue(model.hideRemovesFromDesktop(displays[1]))

        // The setup shows the Mac's input before an input is chosen, read once when shown.
        spin { ddcChecks > 0 }
        XCTAssertEqual(ddcChecks, 1, "showing the setup reads the Mac input")
        XCTAssertEqual(model.macInputDetections[Self.targetKey], .detected(0x0F))
        XCTAssertEqual(model.hidePreferences[Self.targetUUID]?.returnInput, 0x0F)

        model.setHideSource(Self.sourceUUID, for: Self.targetUUID)
        XCTAssertEqual(model.hideConfiguration(for: Self.targetUUID)?.source?.uuid, Self.sourceUUID)

        model.setHideSwitchInput(0x11, for: Self.targetUUID)
        settle(window)
        XCTAssertEqual(model.hidePreferences[Self.targetUUID]?.returnInput, 0x0F)
        XCTAssertEqual(ddcChecks, 1, "choosing an input or redrawing doesn't read again")
        XCTAssertNil(controls(in: window).compactMap { $0 as? NSTextField }.first { $0.isEditable },
                     "a named input needs no code field")

        // A code without a name is edited under Other….
        model.setHideSwitchInput(0x2A, for: Self.targetUUID)
        settle(window)
        let field = try XCTUnwrap(controls(in: window).compactMap { $0 as? NSTextField }.first { $0.isEditable },
                                  controlSummary(window))
        XCTAssertEqual(field.stringValue, "0x2A")

        // Editing the code to something that isn't one turns switching off
        // instead of leaving the last code armed.
        for invalid in ["", "zz", "0"] {
            try replaceText(of: field, in: window, with: invalid)
            settle(window)
            XCTAssertNil(model.hideConfiguration(for: Self.targetUUID)?.awayInput, "\"\(invalid)\" switches nothing")
            XCTAssertNil(try model.makeHideRequest(targetUUID: Self.targetUUID).awayInput)
        }
        try replaceText(of: field, in: window, with: "0x1B")
        settle(window)
        XCTAssertEqual(model.hideConfiguration(for: Self.targetUUID)?.awayInput, 0x1B)
        XCTAssertEqual(model.hidePreferences[Self.targetUUID]?.returnInput, 0x0F, "the Mac input survives the edit")
        XCTAssertEqual(ddcChecks, 1)
        XCTAssertNil(window.attachedSheet)
    }

    /// Replaces a text field's contents through its field editor, as typing does.
    private func replaceText(of field: NSTextField, in window: NSWindow, with text: String) throws {
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        if text.isEmpty {
            editor.delete(nil)
        } else {
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
    }

    func testNativeMissingJournalTargetStaysSelectedAndFreezesSetup() throws {
        let defaults = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName(defaults))
            closeSettingsWindows()
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
        let model = makeModel(defaults: defaults, displays: [displays[0], displays[2]], status: { recovery })
        XCTAssertTrue(model.hideConfigurationFrozen)
        let savedTarget = try XCTUnwrap(model.hideDisplayConfigurations.first { $0.target.uuid == Self.targetUUID })
        XCTAssertEqual(model.controlDisplayStatuses.first { $0.targetUUID == Self.targetUUID }?.observedState, "unavailable")
        XCTAssertFalse(model.identityIsCurrent(savedTarget.target))
        let target = try XCTUnwrap(model.displayTiles.last)
        XCTAssertEqual(target.id, Self.targetKey)
        XCTAssertEqual(target.status, .needsRecovery)
        XCTAssertNil(target.action, "Show needs a restorable journal")
        XCTAssertEqual(model.tile(selecting: nil)?.id, Self.targetKey, "the display that needs recovery is selected by default")
        XCTAssertEqual(model.tile(selecting: Self.sourceUUID.lowercased())?.id, Self.sourceUUID.lowercased())
        XCTAssertEqual(model.tile(selecting: "gone")?.id, Self.targetKey)

        let controller = SettingsWindowController(model: model)
        controller.present()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 680, height: 1200))
        settle(window)
        XCTAssertNil(removalSwitch(in: window), "a journal target has no removal setup")
        XCTAssertTrue(controls(in: window).compactMap { $0 as? NSPopUpButton }.isEmpty)

        controller.selectDisplay(uuid: Self.sourceUUID)
        settle(window)
        let toggle = try XCTUnwrap(removalSwitch(in: window), controlSummary(window))
        XCTAssertFalse(toggle.isEnabled, "settings stay frozen until recovery finishes")
    }

    func testNativeMenuArrowEventsReachShowAction() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "keyboard-menu-journal", canShow: true))
        var shownJournalIDs: [String] = []
        let model = makeModel(defaults: defaults, displays: displays, status: { box.value }, showDisplay: { journalID, _ in
            shownJournalIDs.append(journalID)
            box.value = self.handoffStatus(.none, target: nil, source: nil)
            return .notRequested
        })
        spin { !model.protectionQuiescencePending }
        dispatchNativeEvents()
        let originalFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let delegate = AppDelegate()
        delegate.model = model
        let menu = delegate.makeMenu()
        let showItem = try XCTUnwrap(menu.items.first { $0.title == "Show Target" })

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
        spin { !shownJournalIDs.isEmpty && !model.hideOperation.isBusy }
        XCTAssertEqual(shownJournalIDs, ["keyboard-menu-journal"], "the menu item shows the display without a confirmation")
        XCTAssertEqual(model.displayResults[Self.targetKey]?.succeeded, true)
        XCTAssertEqual(
            NSWorkspace.shared.frontmostApplication?.processIdentifier,
            originalFrontmostPID,
            "the app-local keyboard fixture must not activate the XCTest host"
        )
    }

    func testNativeShowRunsWithoutDialogsAndResultsStayInline() async throws {
        for succeeds in [true, false] {
            let defaults = try makeDefaults()
            defer {
                defaults.removePersistentDomain(forName: suiteName(defaults))
                closeSettingsWindows()
            }
            let hidden = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "inline-journal", canShow: true)
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
            try await waitUntil { !model.protectionQuiescencePending }
            let target = try XCTUnwrap(model.displayTiles.first { $0.id == Self.targetKey })
            XCTAssertEqual(target.status, .hidden)
            XCTAssertEqual(target.action, .show)
            XCTAssertNil(target.actionBlocker)
            let controller = SettingsWindowController(model: model)
            controller.present()
            let window = try XCTUnwrap(controller.window)
            settle(window)

            // The Show button runs this directly.
            let result = try await showAndWait(model)
            settle(window)

            XCTAssertEqual(showCalls, 1)
            XCTAssertEqual(result.succeeded, succeeds)
            XCTAssertEqual(model.displayResults[Self.targetKey], result)
            XCTAssertNil(window.attachedSheet, "results appear inline, not in a sheet")
            XCTAssertNil(model.notice)
            let after = try XCTUnwrap(model.displayTiles.first { $0.id == Self.targetKey })
            if succeeds {
                XCTAssertEqual(after.status, .on)
            } else {
                XCTAssertTrue(result.message.contains("offline verification failure"), result.message)
                XCTAssertTrue(result.needsAttention)
                XCTAssertEqual(after.action, .show, "Show stays available to retry")
                XCTAssertNil(after.actionBlocker)
            }
        }
    }

    func testNativeLongContentFitsMinimumWidthSettings() throws {
        let defaults = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName(defaults))
            closeSettingsWindows()
        }
        let longName = String(repeating: "VeryLongMonitorName-", count: 8)
        let main = Self.display(index: 1, id: 101, uuid: Self.mainUUID, name: longName, main: true)
        let target = Self.display(index: 2, id: 202, uuid: Self.targetUUID, name: longName, main: false)
        let other = Self.display(index: 3, id: 303, uuid: Self.sourceUUID, name: longName, main: false)
        let longError = String(repeating: "Recovery identity/mode mismatch; reconnect the exact display and review the captured journal. ", count: 12)
        let box = StatusBox(handoffStatus(.none, target: nil, source: nil))
        let model = makeModel(defaults: defaults, displays: [main, target, other], status: { box.value })
        model.setHideEnabled(true, for: target)
        model.setHideSwitchInput(0x2A, for: Self.targetUUID)
        let controller = SettingsWindowController(model: model)
        controller.present()
        controller.selectDisplay(uuid: Self.targetUUID)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 440, height: 560))
        settle(window)

        XCTAssertEqual(window.contentLayoutRect.width, 440, "long names never widen the window")
        let field = try XCTUnwrap(controls(in: window).compactMap { $0 as? NSTextField }.first { $0.isEditable },
                                  controlSummary(window))
        assertInsideContent(field, of: window)
        try assertInsideContent(XCTUnwrap(removalSwitch(in: window)), of: window)

        box.value = handoffStatus(.recovery, target: target, source: main, journalID: "long-content-journal",
                                  canShow: false, reason: longError)
        model.refreshDisplays()
        settle(window)
        XCTAssertEqual(window.contentLayoutRect.width, 440, "a long recovery reason wraps instead")
        XCTAssertEqual(model.displayRecoveryProblem, longError)
    }

    func testNativeMenuAndSettingsKeepShowReachableForAHiddenDisplay() throws {
        let defaults = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName(defaults))
            closeSettingsWindows()
        }
        let hidden = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "fixture-journal", canShow: true)
        let model = makeModel(defaults: defaults, displays: displays, status: { hidden })
        spin { !model.protectionQuiescencePending }
        let delegate = AppDelegate()
        delegate.model = model

        let menu = delegate.makeMenu()
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Show Target"))
        XCTAssertFalse(titles.contains("Review Display Recovery\u{2026}"), "a healthy hidden display isn't a recovery problem")
        XCTAssertTrue(titles.contains("Hide Mirror source"), "another display can still be blacked out")
        let settingsItem = try XCTUnwrap(menu.items.first { $0.title == "Settings\u{2026}" })
        XCTAssertEqual(settingsItem.keyEquivalent, ",")
        model.setShowMenuBarIcon(false)
        XCTAssertTrue(delegate.makeMenu().items.contains { $0.title == "Show Target" },
                      "Show stays available when the status icon preference is off")
        model.setExperimentalFeaturesEnabled(false)
        XCTAssertTrue(delegate.makeMenu().items.contains { $0.title == "Show Target" },
                      "Show stays available without the Experimental flag")

        // Reopening shows Displays with the hidden display selected; no banner.
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        let window = try XCTUnwrap(NSApp.windows.first {
            $0.identifier == SettingsWindowController.windowIdentifier && $0.isVisible
        })
        let controller = try XCTUnwrap(window.windowController as? SettingsWindowController)
        XCTAssertEqual(controller.selectedTab, .displays)
        XCTAssertEqual(model.tile(selecting: controller.selectedDisplayID)?.id, Self.targetKey)
        XCTAssertEqual(model.tile(selecting: controller.selectedDisplayID)?.action, .show)
        XCTAssertNil(model.displayRecoveryProblem, "no banner for a healthy hidden display")
    }

    func testQuitWhileHiddenWarnsAndKeepsRunningWhenShowFails() throws {
        let defaults = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName(defaults))
            closeSettingsWindows()
        }
        let hidden = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "quit-journal", canShow: true)
        var showCalls = 0
        let model = makeModel(defaults: defaults, displays: displays, status: { hidden }, showDisplay: { _, _ in
            showCalls += 1
            throw NSError(domain: "FakeMirrorWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "fake restore failure"])
        })
        spin { !model.protectionQuiescencePending }
        let delegate = AppDelegate()
        delegate.model = model
        try withExtendedLifetime(delegate) {
            // Cancel keeps PanelCtl running and the display hidden.
            let cancelled = answerModalAlert("Cancel") { delegate.applicationShouldTerminate(.shared) }
            XCTAssertEqual(cancelled.reply, .terminateCancel)
            XCTAssertTrue(cancelled.texts.contains("Target is still hidden"), "\(cancelled.texts)")
            XCTAssertEqual(Set(cancelled.buttons), ["Cancel", "Show and Quit", "Quit Anyway"])
            XCTAssertEqual(showCalls, 0)

            // Show and Quit shows without asking again; a failed Show keeps
            // PanelCtl running and opens the display with the result.
            let showing = answerModalAlert("Show and Quit") { delegate.applicationShouldTerminate(.shared) }
            XCTAssertEqual(showing.reply, .terminateCancel)
            spin { model.displayResults[Self.targetKey] != nil }
            XCTAssertEqual(showCalls, 1)
            XCTAssertEqual(model.displayResults[Self.targetKey]?.succeeded, false)
            let window = try XCTUnwrap(NSApp.windows.first {
                $0.identifier == SettingsWindowController.windowIdentifier && $0.isVisible
            })
            let controller = try XCTUnwrap(window.windowController as? SettingsWindowController)
            XCTAssertEqual(controller.selectedTab, .displays)
            XCTAssertEqual(controller.selectedDisplayID, Self.targetKey)
        }
    }

    /// Runs `body`, clicking the button titled `answer` in the app-modal alert it shows.
    private func answerModalAlert<Reply>(
        _ answer: String, _ body: () -> Reply
    ) -> (reply: Reply, texts: [String], buttons: [String]) {
        var texts: [String] = []
        var buttons: [String] = []
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard let window = NSApplication.shared.modalWindow, let content = window.contentView else { return }
            timer.invalidate()
            func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
            let all = views(content)
            texts = all.compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty }
            let controls = all.compactMap { $0 as? NSButton }.filter { !$0.title.isEmpty }
            buttons = controls.map(\.title)
            guard let button = controls.first(where: { $0.title == answer }) else {
                XCTFail("No \(answer) button in \(buttons)")
                NSApplication.shared.abortModal()
                return
            }
            button.performClick(nil)
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        let reply = body()
        XCTAssertFalse(buttons.isEmpty, "an alert was shown")
        return (reply, texts, buttons)
    }

    func testRecoveryProblemOpensItsDisplayFromReopenAndMenu() throws {
        let defaults = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName(defaults))
            closeSettingsWindows()
        }
        let recovery = handoffStatus(
            .recovery, target: displays[1], source: displays[0], journalID: "problem-journal",
            canShow: false, reason: "The captured display mode changed."
        )
        let model = makeModel(defaults: defaults, displays: displays, status: { recovery })
        spin { !model.protectionQuiescencePending }
        XCTAssertEqual(model.displayRecoveryProblem, "The captured display mode changed.")
        let delegate = AppDelegate()
        delegate.model = model
        let menu = delegate.makeMenu()
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Review Display Recovery\u{2026}"))
        XCTAssertFalse(titles.contains("Show Target"), "Show needs a restorable journal")

        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        let window = try XCTUnwrap(NSApp.windows.first {
            $0.identifier == SettingsWindowController.windowIdentifier && $0.isVisible
        })
        let controller = try XCTUnwrap(window.windowController as? SettingsWindowController)
        XCTAssertEqual(controller.selectedTab, .displays)
        XCTAssertEqual(controller.selectedDisplayID, Self.targetKey, "Settings opens on the display that needs recovery")

        controller.selectDisplay(uuid: Self.mainUUID)
        controller.select(.automation)
        let review = try XCTUnwrap(menu.items.firstIndex { $0.title == "Review Display Recovery\u{2026}" })
        menu.performActionForItem(at: review)
        XCTAssertEqual(controller.selectedTab, .displays)
        XCTAssertEqual(controller.selectedDisplayID, Self.targetKey, "review selects the affected display")
        XCTAssertNil(model.pageRecoveryProblem, "the display shows the problem")
    }

    func testRecoveryJournalWithoutATargetDisplayIsShownAboveTheDisplays() throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: "experimentalFeaturesEnabled")
        defer {
            defaults.removePersistentDomain(forName: suiteName(defaults))
            closeSettingsWindows()
        }
        // A `recovery capture` journal names no hidden display.
        let unsupported = DisplayHandoffStatus(
            state: .unsupported,
            journalPath: "/tmp/panelctl-capture-fixture/current.json",
            journalID: "capture-journal",
            reason: "An unfinished recovery journal needs review."
        )
        let model = makeModel(defaults: defaults, displays: displays, status: { unsupported })
        spin { !model.protectionQuiescencePending }
        XCTAssertFalse(model.experimentalFeaturesEnabled, "recovery doesn't need Experimental features")
        XCTAssertFalse(model.displayTiles.contains { $0.status == .needsRecovery })
        XCTAssertEqual(model.pageRecoveryProblem, "An unfinished recovery journal needs review.")

        let delegate = AppDelegate()
        delegate.model = model
        let menu = delegate.makeMenu()
        let review = try XCTUnwrap(menu.items.firstIndex { $0.title == "Review Display Recovery\u{2026}" })
        menu.performActionForItem(at: review)
        let window = try XCTUnwrap(NSApp.windows.first {
            $0.identifier == SettingsWindowController.windowIdentifier && $0.isVisible
        })
        let controller = try XCTUnwrap(window.windowController as? SettingsWindowController)
        XCTAssertEqual(controller.selectedTab, .displays)
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
        while kill -0 "$PPID" 2>/dev/null; do /bin/sleep 0.02; done
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

    func testScriptsHideAndShowThroughTheControlSocket() async throws {
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
                return DisplayInputOutcome(state: .verified, requestedInput: 17)
            },
            showDisplay: { _, _ in
                showCalls += 1
                box.value = self.handoffStatus(.none, target: nil, source: nil)
                return DisplayInputOutcome(state: .failed, requestedInput: 15, detail: "Input readback mismatch")
            },
            checkDDCInput: { identity in
                DDCInputReading(displayID: identity.displayID, uuid: identity.uuid, current: 15)
            }
        )
        model.setHideEnabled(true, for: displays[1])
        model.setHideSwitchInput(17, for: Self.targetUUID)
        model.detectMacInput(for: Self.targetUUID)
        let delegate = AppDelegate()
        delegate.model = model
        let path = "\(try AppControlSocket.userTemporaryDirectory())/panelctl-test-\(UUID().uuidString.prefix(8)).sock"
        let server = AppControlServer(socketPath: path) { await delegate.handleControlRequest($0, receivedAt: $1) }
        try server.start()
        defer { server.stop() }
        let target = Self.targetUUID
        @Sendable func send(_ command: AppControlCommand, uuid: String? = target) async throws -> AppControlResponse {
            try await Task.detached {
                let client = try AppControlClient(socketPath: path, launch: { XCTFail("must not launch") })
                return try client.execute(command, targetUUID: uuid)
            }.value
        }
        func targetStatus(_ response: AppControlResponse) -> AppControlDisplayStatus? {
            response.displays?.first { $0.targetUUID == target }
        }
        let initial = try await send(.status, uuid: nil)
        XCTAssertNil(initial.outcome)
        XCTAssertEqual(initial.displays?.map(\.targetUUID), [Self.mainUUID, target, Self.sourceUUID],
                       "status lists every display, including ones only Black out can hide")
        XCTAssertEqual(targetStatus(initial)?.observedState, "separate")
        XCTAssertNil(targetStatus(initial)?.lastInputOutcome)

        // The reply comes when Hide finishes; a request meanwhile is busy.
        async let toggled = send(.toggleHide)
        try await waitUntil { model.hideOperation.isBusy }
        let busy = try await send(.hide)
        XCTAssertEqual(busy.outcome, .busy)
        XCTAssertEqual(busy.exitCode, 1)
        XCTAssertEqual(targetStatus(busy)?.operation, "hiding")
        cleanup?(true, nil)
        let hidden = try await toggled
        XCTAssertEqual(hidden.outcome, .done)
        XCTAssertEqual(hidden.exitCode, 0)
        XCTAssertTrue(hidden.ok)
        XCTAssertEqual(hidden.summary, "Hidden.")
        XCTAssertEqual(hidden.detail, "Switched the monitor to HDMI 1.")
        XCTAssertEqual(hidden.displays?.map(\.targetUUID), [target], "a Hide reports only its display")
        XCTAssertEqual(targetStatus(hidden)?.observedState, "hidden-by-panelctl")
        XCTAssertEqual(targetStatus(hidden)?.lastInputOutcome?.state, .verified)
        XCTAssertEqual(hideCalls, 1)
        let again = try await send(.hide)
        XCTAssertEqual(again.outcome, .noOp)
        XCTAssertEqual(again.exitCode, 0)
        XCTAssertEqual(again.summary, "Target is already hidden.")
        let unknown = try await send(.hide, uuid: Self.replacementUUID)
        XCTAssertEqual(unknown.outcome, .refused)
        let blackout = try await send(.blackoutNow, uuid: nil)
        XCTAssertFalse(blackout.ok)
        XCTAssertEqual(hideCalls, 1, "an already hidden display isn\u{2019}t hidden again")

        // Show works while automation is off.
        _ = try await send(.disable, uuid: nil)
        XCTAssertFalse(model.preferences.isEnabled)
        async let shown = send(.toggleHide)
        try await waitUntil { model.hideOperation.isBusy }
        cleanup?(true, nil)
        let partial = try await shown
        XCTAssertEqual(partial.outcome, .partial)
        XCTAssertEqual(partial.exitCode, 5)
        XCTAssertFalse(partial.ok)
        XCTAssertEqual(partial.summary, "Shown.")
        XCTAssertEqual(partial.error, partial.detail)
        XCTAssertTrue(partial.detail?.contains("Input readback mismatch") == true)
        XCTAssertEqual(targetStatus(partial)?.observedState, "separate")
        XCTAssertEqual(showCalls, 1)
        let shownAgain = try await send(.show)
        XCTAssertEqual(shownAgain.outcome, .noOp)
        XCTAssertEqual(shownAgain.summary, "Target isn\u{2019}t hidden.")
        XCTAssertEqual(showCalls, 1, "a repeated Show doesn\u{2019}t switch the input again")
        let status = try await send(.status, uuid: nil)
        XCTAssertEqual(status.outcome, .partial)
        XCTAssertEqual(status.exitCode, 5)
        XCTAssertEqual(targetStatus(status)?.lastInputOutcome?.state, .failed)

        // A journal that fails its identity check needs recovery, whatever the command.
        box.value = handoffStatus(.hidden, target: displays[1], source: displays[0],
                                  journalID: "changed-identity", canShow: false,
                                  reason: "Captured target identity changed (serial mismatch)")
        for command in [AppControlCommand.hide, .show, .toggleHide, .status] {
            let staleJournal = try await send(command, uuid: command == .status ? nil : target)
            XCTAssertEqual(staleJournal.outcome, .recoveryNeeded)
            XCTAssertEqual(staleJournal.exitCode, 6)
            XCTAssertEqual(targetStatus(staleJournal)?.recoveryNeeded, true)
        }
        let otherHide = try await send(.hide, uuid: Self.mainUUID)
        XCTAssertEqual(otherHide.exitCode, 6, "no other display hides during recovery")
        box.value = handoffStatus(.recovery, target: displays[1], source: displays[0], journalID: "unresolved", reason: "target unavailable")
        let unrestorable = try await send(.show)
        XCTAssertEqual(unrestorable.exitCode, 6)
        let recovery = try await send(.status, uuid: nil)
        XCTAssertEqual(recovery.outcome, .recoveryNeeded)
        XCTAssertEqual(hideCalls, 1, "recovery never writes")
        XCTAssertEqual(showCalls, 1, "recovery never writes")
    }

    func testScriptToggleThatWaitedBehindAHideIsBusy() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let path = "\(try AppControlSocket.userTemporaryDirectory())/panelctl-test-\(UUID().uuidString.prefix(8)).sock"
        @Sendable func toggle() throws -> AppControlResponse {
            try AppControlClient(socketPath: path, launch: { XCTFail("must not launch") })
                .execute(.toggleHide, targetUUID: Self.targetUUID)
        }
        let box = StatusBox(handoffStatus(.none, target: nil, source: nil))
        var hideCalls = 0
        var showCalls = 0
        var waited: Task<AppControlResponse, Error>?
        let model = makeModel(
            defaults: defaults, displays: displays, status: { box.value },
            hideDisplay: { _, _, _ in
                hideCalls += 1
                // Hide holds the main thread, as DDC readback does, while a second toggle arrives.
                waited = Task.detached { try toggle() }
                Thread.sleep(forTimeInterval: 0.5)
                box.value = self.handoffStatus(.hidden, target: self.displays[1], source: self.displays[0], journalID: "held", canShow: true)
                return .notRequested
            },
            showDisplay: { _, _ in
                showCalls += 1
                box.value = self.handoffStatus(.none, target: nil, source: nil)
                return .notRequested
            }
        )
        model.setHideEnabled(true, for: displays[1])
        let delegate = AppDelegate()
        delegate.model = model
        let server = AppControlServer(socketPath: path) { await delegate.handleControlRequest($0, receivedAt: $1) }
        try server.start()
        defer { server.stop() }
        let first = try await Task.detached { try toggle() }.value
        XCTAssertEqual(first.outcome, .done)
        let second = try await XCTUnwrap(waited).value
        XCTAssertEqual(second.outcome, .busy, "a toggle that waited doesn\u{2019}t undo the first")
        XCTAssertEqual(second.exitCode, 1)
        XCTAssertEqual([hideCalls, showCalls], [1, 0])
        XCTAssertEqual(model.displayTiles.first { $0.uuid == Self.targetUUID }?.status, .hidden)
        let next = try await Task.detached { try toggle() }.value
        XCTAssertEqual(next.outcome, .done, "a request sent after the Hide runs")
        XCTAssertEqual(showCalls, 1)
    }

    func testScriptsCanOnlyShowDuringRecovery() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        defaults.set(false, forKey: "experimentalFeaturesEnabled")
        let box = StatusBox(handoffStatus(.none, target: nil, source: nil))
        let model = makeModel(defaults: defaults, displays: displays, status: { box.value })
        let recovery = handoffStatus(.recovery, target: displays[1], source: displays[0], journalID: "unresolved", reason: "target unavailable")
        func send(_ command: AppControlCommand) async -> AppControlResponse {
            await model.handleDisplayControlRequest(AppControlRequest(command: command, targetUUID: Self.sourceUUID))
        }
        for command in [AppControlCommand.show, .toggleHide] {
            box.value = handoffStatus(.none, target: nil, source: nil)
            let hidden = await send(.hide)
            XCTAssertEqual(hidden.outcome, .done)
            box.value = recovery
            let hideAgain = await send(.hide)
            XCTAssertEqual(hideAgain.outcome, .recoveryNeeded, "even a Hide that changes nothing")
            XCTAssertEqual(hideAgain.exitCode, 6)
            let shown = await send(command)
            XCTAssertEqual(shown.outcome, .done)
            XCTAssertEqual(shown.summary, "Shown.")
            XCTAssertFalse(model.isBlackoutHidden(Self.sourceUUID))
        }
    }

    func testScriptsBlackOutByDefaultAndNeverRestartAHide() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        defaults.set(false, forKey: "experimentalFeaturesEnabled")
        let model = makeModel(defaults: defaults, displays: displays, hideDisplay: { _, _, _ in
            XCTFail("Remove from desktop needs Experimental features")
            return .notRequested
        })
        model.setHideEnabled(true, for: displays[1])
        func send(_ command: AppControlCommand, _ uuid: String = Self.targetUUID) async -> AppControlResponse {
            await model.handleDisplayControlRequest(AppControlRequest(command: command, targetUUID: uuid))
        }
        let hidden = await send(.toggleHide)
        XCTAssertEqual(hidden.outcome, .done)
        XCTAssertEqual(hidden.summary, "Hidden.")
        XCTAssertNil(hidden.detail, "Black out doesn\u{2019}t switch inputs")
        XCTAssertTrue(model.isBlackoutHidden(Self.targetUUID))
        XCTAssertEqual(hidden.displays?.first { $0.targetUUID == Self.targetUUID }?.observedState, "hidden-by-panelctl")
        let again = await send(.hide)
        XCTAssertEqual(again.outcome, .noOp)
        let shown = await send(.toggleHide)
        XCTAssertEqual(shown.outcome, .done)
        XCTAssertEqual(shown.summary, "Shown.")
        XCTAssertFalse(model.isBlackoutHidden(Self.targetUUID))
        let shownAgain = await send(.show)
        XCTAssertEqual(shownAgain.outcome, .noOp)
        XCTAssertEqual(shownAgain.exitCode, 0)

        // PanelCtl keeps one display visible.
        let first = await send(.hide)
        let second = await send(.hide, Self.sourceUUID)
        XCTAssertEqual([first.outcome, second.outcome], [.done, .done])
        let last = await send(.hide, Self.mainUUID)
        XCTAssertEqual(last.outcome, .refused)
        XCTAssertEqual(last.exitCode, 1)
        XCTAssertEqual(last.summary, "PanelCtl keeps at least one display visible, so it won\u{2019}t hide this one.")
        XCTAssertFalse(model.isBlackoutHidden(Self.mainUUID))

        // Hides never start from wake or startup.
        let targetShown = await send(.show)
        XCTAssertEqual(targetShown.outcome, .done)
        model.setDisplayLifecycleTransitioning(true)
        let waking = await send(.hide)
        XCTAssertEqual(waking.outcome, .refused)
        model.setDisplayLifecycleTransitioning(false)
        XCTAssertFalse(model.isBlackoutHidden(Self.targetUUID), "a refused request doesn\u{2019}t run later")
        XCTAssertTrue(model.isBlackoutHidden(Self.sourceUUID))
        let relaunched = makeModel(defaults: defaults, displays: displays)
        XCTAssertFalse(relaunched.isBlackoutHidden(Self.sourceUUID), "relaunching doesn\u{2019}t hide a display again")
    }

    func testOversizedStatusDoesNotMisreportCompletedProtectionToggle() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        // Status lists every display, so enough of them exceed the message limit.
        let many = displays + (4...40).map { index in
            Self.display(index: index, id: UInt32(400 + index), uuid: UUID().uuidString, name: "Extra \(index)", main: false)
        }
        let hidden = handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "overflow", canShow: true)
        let model = makeModel(defaults: defaults, displays: many, status: { hidden })
        let delegate = AppDelegate()
        delegate.model = model
        XCTAssertFalse(model.preferences.isEnabled)
        let path = "\(try AppControlSocket.userTemporaryDirectory())/panelctl-test-\(UUID().uuidString.prefix(8)).sock"
        var toggleCount = 0
        let server = AppControlServer(socketPath: path) { request, receivedAt in
            if request.command == .toggle { toggleCount += 1 }
            return await delegate.handleControlRequest(request, receivedAt: receivedAt)
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

    func testScriptsRefuseChangedIdentityUnreadableJournalAndTransitions() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let model = makeModel(defaults: defaults, displays: displays)
        model.setHideEnabled(true, for: displays[1])
        model.setHideSource(Self.mainUUID, for: Self.targetUUID)
        let changed = Self.display(index: 2, id: 202, uuid: Self.targetUUID, name: "Replacement", main: false, serial: 999)
        let stale = makeModel(defaults: defaults, displays: [displays[0], changed])
        let staleHide = await stale.handleDisplayControlRequest(AppControlRequest(command: .hide, targetUUID: Self.targetUUID))
        XCTAssertEqual(staleHide.outcome, .refused)
        let staleShow = await stale.handleDisplayControlRequest(AppControlRequest(command: .show, targetUUID: Self.targetUUID))
        XCTAssertEqual(staleShow.outcome, .noOp)
        model.setDisplayLifecycleTransitioning(true)
        for command in [AppControlCommand.hide, .show, .toggleHide] {
            let waking = await model.handleDisplayControlRequest(AppControlRequest(command: command, targetUUID: Self.targetUUID))
            XCTAssertEqual(waking.outcome, .refused)
        }
        model.setDisplayLifecycleTransitioning(false)
        let unknown = makeModel(defaults: defaults, displays: displays, status: {
            self.handoffStatus(.recovery, target: nil, source: nil, inspectionFailure: "unreadable journal")
        })
        let unreadable = await unknown.handleDisplayControlRequest(AppControlRequest(command: .show, targetUUID: Self.targetUUID))
        XCTAssertEqual(unreadable.outcome, .recoveryNeeded)
        let missingDisplay = await model.handleDisplayControlRequest(AppControlRequest(command: .show))
        XCTAssertEqual(missingDisplay.outcome, .refused)
    }

    private func makeModel(
        defaults: UserDefaults,
        displays: [DisplayRecord],
        displayProvider: (() -> [DisplayRecord])? = nil,
        idleSecondsProvider: @escaping () -> TimeInterval? = { nil },
        status: @escaping () -> DisplayHandoffStatus? = { nil },
        quiesceProtection: @escaping ProtectionQuiesce = { $0(true, nil) },
        useManagedProtectionService: Bool = false,
        protectionService: ProtectionService? = nil,
        isDisplayMirrored: @escaping (UInt32) -> Bool = { _ in false },
        coverDisplays: @escaping @MainActor (Set<UInt32>) -> Set<UInt32> = { _ in [] },
        hideDisplay: @escaping (DisplayHideIdentity, DisplayHideIdentity, UInt8?) throws -> DisplayInputOutcome = { _, _, _ in .notRequested },
        showDisplay: @escaping (String, UInt8?) throws -> DisplayInputOutcome = { _, _ in .notRequested },
        checkDDCInput: @escaping (DisplayHideIdentity) throws -> DDCInputReading = { _ in
            DDCInputReading(displayID: 0, uuid: "", current: 1)
        }
    ) -> AppModel {
        let fallback = handoffStatus(.none, target: nil, source: nil)
        return AppModel(
            defaults: defaults,
            displayProvider: displayProvider ?? { displays },
            idleSecondsProvider: idleSecondsProvider,
            isDisplayMirrored: isDisplayMirrored,
            inspectHandoff: { status() ?? fallback },
            hideDisplay: hideDisplay,
            showDisplay: showDisplay,
            checkDDCInput: checkDDCInput,
            // Black out never draws over a real screen in tests.
            coverDisplays: coverDisplays,
            quiesceProtection: useManagedProtectionService ? nil : quiesceProtection,
            protectionService: protectionService
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

    /// Runs the main run loop until the condition holds or two seconds pass.
    private func spin(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func hideAndWait(_ model: AppModel, _ uuid: String = targetUUID) async throws -> DisplayOperationResult {
        var result: DisplayOperationResult?
        model.hide(targetUUID: uuid) { result = $0 }
        try await waitUntil { result != nil }
        return try XCTUnwrap(result)
    }

    private func showAndWait(_ model: AppModel, _ uuid: String = targetUUID) async throws -> DisplayOperationResult {
        var result: DisplayOperationResult?
        model.show(targetUUID: uuid) { result = $0 }
        try await waitUntil { result != nil }
        return try XCTUnwrap(result)
    }

    // MARK: Native Settings

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func closeSettingsWindows() {
        NSApp.windows.filter { $0.identifier == SettingsWindowController.windowIdentifier }.forEach { $0.close() }
    }

    // SwiftUI builds its accessibility tree only for a connected assistive
    // client and draws buttons and pickers itself, so tests reach only the
    // AppKit controls it renders: switches and text fields.

    private func controls(in window: NSWindow) -> [NSControl] {
        window.contentView.map(nativeControls) ?? []
    }

    /// The Displays tab's only switch: Remove from desktop.
    private func removalSwitch(in window: NSWindow) -> NSSwitch? {
        let switches = controls(in: window).compactMap { $0 as? NSSwitch }
        return switches.count == 1 ? switches[0] : nil
    }

    private func controlSummary(_ window: NSWindow) -> String {
        controls(in: window).map {
            "\(type(of: $0)) enabled=\($0.isEnabled) frame=\($0.convert($0.bounds, to: nil))"
        }.joined(separator: "\n")
    }

    /// Asserts that the control is drawn inside the window's content width.
    private func assertInsideContent(_ control: NSControl, of window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        let frame = control.convert(control.bounds, to: nil)
        XCTAssertGreaterThanOrEqual(frame.minX, -1, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, window.contentLayoutRect.width + 1, file: file, line: line)
    }

    private static func display(index: Int, id: UInt32, uuid: String, name: String, main: Bool,
                                serial: UInt32? = nil, x: Int? = nil, asleep: Bool = false,
                                online: Bool = true, active: Bool? = nil) -> DisplayRecord {
        DisplayRecord(
            index: index,
            id: id,
            uuid: uuid,
            name: name,
            active: active ?? online,
            online: online,
            asleep: asleep,
            builtin: false,
            main: main,
            vendor: UInt32(index),
            model: UInt32(index * 10),
            serial: serial ?? UInt32(index * 100),
            bounds: DisplayBounds(CGRect(x: x ?? (index - 1) * 1920, y: 0, width: 1920, height: 1080)),
            pixelWidth: 1920,
            pixelHeight: 1080
        )
    }
}

private final class StatusBox {
    var value: DisplayHandoffStatus
    init(_ value: DisplayHandoffStatus) { self.value = value }
}
