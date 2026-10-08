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
        _ = NSApplication.shared
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
        let blackoutTrigger = directory.appendingPathComponent("blackout-trigger")
        let helper = try writeHiddenOverlayHelper(
            in: directory, log: log, initiallyWaiting: true, blackoutTrigger: blackoutTrigger
        )
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
        try await waitUntil { model.runtimeState == .waiting }
        var lines = try await waitForLogLines(1, at: log)
        let rule = try XCTUnwrap(model.automationPreferences.rules.first)
        let delegate = AppDelegate()
        delegate.model = model
        XCTAssertTrue(model.protectionPausedForDisplayRecovery)
        XCTAssertTrue(model.hiddenMirrorOverlayPolicyEligible)
        XCTAssertEqual(model.effectiveBlackoutMode, .blocking)
        XCTAssertEqual(model.protectionRuleRowStatus(for: rule).text, "Watching for inactivity · Sleep paused while a display is removed; restores overlay instead")
        let waitingMenuTitles = delegate.makeMenu().items.map(\.title)
        XCTAssertTrue(waitingMenuTitles.contains("Run rule"), "manual automation is selected per rule")
        XCTAssertFalse(waitingMenuTitles.contains("Black Out Now"), "manual automation is no longer a broadcast menu action")
        XCTAssertFalse(waitingMenuTitles.contains("Dim Now"))
        XCTAssertTrue(lines[0].contains("--display \(Self.sourceUUID)"))
        XCTAssertTrue(lines[0].contains("--panelctl-hidden-mirror-source \(Self.sourceUUID)"))
        XCTAssertFalse(lines[0].contains(Self.targetUUID))
        XCTAssertFalse(lines[0].contains("--dim-to"))
        XCTAssertFalse(lines[0].contains("--sleep-after"))
        XCTAssertFalse(lines[0].contains("--keep-displays-awake"))

        try Data().write(to: blackoutTrigger)
        try await waitUntil { model.runtimeState == .blackedOut }
        XCTAssertEqual(model.protectionRuleRowStatus(for: rule).text, "Blackout active · Sleep paused while a display is removed; restores overlay instead")
        XCTAssertTrue(model.statusSummary.contains("Mirror source blacked out by automation"))

        let menuTitles = delegate.makeMenu().items.map(\.title)
        XCTAssertTrue(menuTitles.contains("Show Target"), "Show stays reachable over a source overlay")
        XCTAssertTrue(menuTitles.contains("Restore"), "protection Restore stays available over a source overlay")
        XCTAssertTrue(try model.restoreBlackout(), "Restore controls the overlay while the journal remains hidden")
        lines = try await waitForLogLines(2, at: log)
        XCTAssertEqual(lines[1], "command:restore")
        XCTAssertEqual(showCalls, 0, "Restore never invokes Show")
        XCTAssertEqual(model.handoffStatus?.state, .hidden)

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

    func testRemainingDisplaysRunBoundedOverlaysAndPauseOnRecovery() async throws {
        // nil saved selection means All displays with a stale saved selection of main only.
        for (selected, saved) in [([Self.targetUUID, Self.sourceUUID], nil),
                                  ([Self.targetUUID, Self.mainUUID], nil),
                                  ([Self.targetUUID, Self.sourceUUID, Self.mainUUID], nil),
                                  ([Self.targetUUID, Self.sourceUUID, Self.mainUUID], [Self.mainUUID])] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("panelctl-remaining-overlay-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let log = directory.appendingPathComponent("helper.log")
            let helper = try writeHiddenOverlayHelper(in: directory, log: log)
            let defaults = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
            var preferences = ProtectionPreferences()
            preferences.isEnabled = true
            preferences.didChooseDisplays = true
            preferences.selectedDisplayUUIDs = Set(saved ?? selected)
            preferences.allDisplays = saved != nil
            preferences.followUpAction = .sleepDisplays
            defaults.set(try JSONEncoder().encode(preferences), forKey: "blackoutPreferences")
            setenv("PANELCTL_HELPER", helper.path, 1)
            setenv("PANELCTL_TEST_LOG", log.path, 1)
            unsetenv("PANELCTL_REARM_ON_START")
            defer {
                unsetenv("PANELCTL_HELPER")
                unsetenv("PANELCTL_TEST_LOG")
                unsetenv("PANELCTL_REARM_ON_START")
            }
            let box = StatusBox(handoffStatus(.hidden, target: displays[1], source: displays[2],
                                             journalID: "remaining", canShow: true))
            let model = makeModel(defaults: defaults, displays: displays, status: { box.value },
                                  useManagedProtectionService: true,
                                  isDisplayMirrored: { $0 == 202 || $0 == 303 })
            try await waitUntil { model.runtimeState == .blackedOut }
            let line = try await waitForLogLines(1, at: log)[0]
            XCTAssertFalse(line.contains(Self.targetUUID), "removed target is never sent to the helper")
            for uuid in selected where uuid != Self.targetUUID {
                XCTAssertTrue(line.contains("--display \(uuid)"))
            }
            XCTAssertEqual(line.contains("--panelctl-hidden-mirror-source \(Self.sourceUUID)"),
                           selected.contains(Self.sourceUUID))
            XCTAssertFalse(line.contains("--panelctl-hidden-mirror-source \(Self.mainUUID)"))
            XCTAssertTrue(line.contains("--timeout 1800"))
            XCTAssertFalse(line.contains("--sleep-after"))
            XCTAssertFalse(line.contains("--keep-displays-awake"))
            XCTAssertFalse(line.contains("--dim-to"))
            let rule = try XCTUnwrap(model.automationPreferences.rules.first)
            let status = model.protectionRuleRowStatus(for: rule)
            XCTAssertNil(status.blockedReason)
            XCTAssertTrue(status.details.contains { $0.hasPrefix("Skipping 1 unavailable or hidden display") })
            XCTAssertTrue(status.details.contains { $0.hasPrefix("Sleep paused") })
            XCTAssertTrue(model.statusSummary.contains(selected.contains(Self.mainUUID) ? "Main OLED" : "Mirror source"))
            XCTAssertEqual(model.nextAction, "restore overlay")
            XCTAssertTrue(try model.restoreBlackout())

            box.value = handoffStatus(.recovery, target: displays[1], source: displays[2],
                                      journalID: "remaining", reason: "Unverified restoration")
            model.refreshDisplays()
            try await waitUntil { !model.protectionQuiescencePending }
            XCTAssertFalse(model.hiddenMirrorOverlayPolicyEligible)
            XCTAssertNotNil(model.protectionRuleRowStatus(for: rule).blockedReason)
            let stopped = expectation(description: "remaining overlay stopped")
            model.shutdown { stopped.fulfill() }
            await fulfillment(of: [stopped], timeout: 3)
        }
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
        let savedProtectionData = try XCTUnwrap(defaults.data(forKey: "automationRules"))
        XCTAssertEqual(
            try JSONDecoder().decode(AutomationPreferences.self, from: savedProtectionData),
            model.automationPreferences
        )
        XCTAssertNil(defaults.data(forKey: "blackoutPreferences"), "first run persists only the versioned rule set")
        XCTAssertNotNil(defaults.data(forKey: "displayHidePreferences"))

        let reloaded = makeModel(defaults: defaults, displays: displays)
        XCTAssertEqual(reloaded.hidePreferences, model.hidePreferences)
        XCTAssertEqual(reloaded.preferences, protectionBefore)
    }

    func testLegacySavedHideReferencesRemapTargetAndSourceIDsWithoutLosingSettings() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let legacyData = try JSONSerialization.data(withJSONObject: [
            "configurations": [Self.targetUUID: [
                "target": ["uuid": Self.targetUUID, "id": 202, "name": "Target", "vendor": 2, "model": 20, "serial": 200],
                "enabled": true,
                "source": ["uuid": Self.mainUUID, "id": 101, "name": "Main OLED", "vendor": 1, "model": 10, "serial": 100],
                "awayInput": 17,
                "returnInput": 15
            ]]
        ])
        defaults.set(legacyData, forKey: "displayHidePreferences")
        let remapped = [
            Self.display(index: 1, id: 1101, uuid: Self.mainUUID, name: "Main OLED", main: true),
            Self.display(index: 2, id: 2202, uuid: Self.targetUUID, name: "Target", main: false),
            Self.display(index: 3, id: 3303, uuid: Self.sourceUUID, name: "Mirror source", main: false)
        ]
        let box = StatusBox(handoffStatus(.none, target: nil, source: nil))
        var writtenTarget: DisplayHideIdentity?
        var writtenSource: DisplayHideIdentity?
        let model = makeModel(
            defaults: defaults,
            displays: remapped,
            status: { box.value },
            hideDisplay: { target, source, _ in
                writtenTarget = target
                writtenSource = source
                box.value = self.handoffStatus(.hidden, target: remapped[1], source: remapped[0], journalID: "remapped-hide", canShow: true)
                return .notRequested
            }
        )

        let configuration = try XCTUnwrap(model.hidePreferences[Self.targetUUID])
        XCTAssertTrue(configuration.enabled)
        XCTAssertEqual(configuration.source?.uuid, Self.mainUUID)
        XCTAssertEqual(configuration.awayInput, 17)
        XCTAssertEqual(configuration.returnInput, 15)
        let request = try model.makeHideRequest(targetUUID: Self.targetUUID)
        XCTAssertEqual(request.target.id, 2202)
        XCTAssertEqual(request.source.id, 1101)

        let result = try await hideAndWait(model)
        XCTAssertTrue(result.succeeded, result.message)
        XCTAssertEqual(writtenTarget?.displayID, 2202)
        XCTAssertEqual(writtenSource?.displayID, 1101)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model.hidePreferences)) as? [String: Any]
        let rows = try XCTUnwrap(encoded?["configurations"] as? [String: Any])
        let saved = try XCTUnwrap(rows[Self.targetUUID] as? [String: Any])
        XCTAssertNil((saved["target"] as? [String: Any])?["id"])
        XCTAssertNil((saved["source"] as? [String: Any])?["id"])
    }

    func testReportedMonitorIDRemappingPreservesLegacyActionsAndHideSetup() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let specs: [(String, String, UInt32, UInt32, UInt32, UInt32)] = [
            ("A8D3635B-35EC-4171-BBE2-95FB8CF76111", "AW3425DW", 2, 1, 41613, 809650259),
            ("09084682-3C42-4455-AAB8-126A7431125B", "DELL S2721DGF", 1, 4, 16857, 1094800204),
            ("1FC57E99-DE7C-4DAF-B896-3B512CEE064F", "AW3423DW", 5, 2, 41444, 809906515)
        ]
        let records = specs.enumerated().map { index, spec in
            DisplayRecord(index: index + 1, id: spec.3, uuid: spec.0, name: spec.1,
                          active: true, online: true, asleep: false, builtin: false, main: index == 2,
                          vendor: 4268, model: spec.4, serial: spec.5,
                          bounds: DisplayBounds(CGRect(x: index * 1920, y: 0, width: 1920, height: 1080)),
                          pixelWidth: 1920, pixelHeight: 1080)
        }
        let legacyIdentities: [[String: Any]] = specs.map {
            ["uuid": $0.0, "name": $0.1, "id": $0.2, "vendor": 4268, "model": $0.4, "serial": $0.5]
        }
        var configurations: [String: Any] = [:]
        for index in 0..<2 {
            configurations[specs[index].0.lowercased()] = [
                "target": legacyIdentities[index], "source": legacyIdentities[2], "enabled": true,
                "awayInput": index == 0 ? 15 : 17, "returnInput": index == 0 ? 17 : 15
            ]
        }
        defaults.set(try JSONSerialization.data(withJSONObject: ["configurations": configurations]),
                     forKey: "displayHidePreferences")
        let actionIDs = [UUID(), UUID()]
        let actions: [[String: Any]] = ["removeFromDesktop", "show"].enumerated().map { actionIndex, effect in
            let steps: [[String: Any]] = (0..<2).map { index in
                ["target": legacyIdentities[index], "effect": effect,
                 "reviewedRemoval": ["removeEnabled": true, "sourceUUID": specs[2].0.lowercased(),
                                     "awayInput": index == 0 ? 15 : 17]]
            }
            return ["id": actionIDs[actionIndex].uuidString, "name": "PC displays \(effect)", "steps": steps]
        }
        defaults.set(try JSONSerialization.data(withJSONObject: ["version": 2, "actions": actions]),
                     forKey: AppModel.displayActionsKey)
        defaults.set(true, forKey: "experimentalFeaturesEnabled")
        let model = makeModel(defaults: defaults, displays: records)
        XCTAssertEqual(model.displayActions.actions.map(\.id), actionIDs)
        for index in 0..<2 {
            let request = try model.makeHideRequest(targetUUID: specs[index].0)
            XCTAssertEqual(request.target.id, specs[index].3)
            XCTAssertEqual(request.source.id, 2)
            XCTAssertEqual(request.awayInput, index == 0 ? 15 : 17)
        }
        for action in model.displayActions.actions {
            XCTAssertNil(model.displayActionRunBlocker(for: action), action.name)
            XCTAssertEqual(action.steps.compactMap { $0.target?.uuid }, Array(specs.prefix(2)).map { $0.0 })
        }
    }

    func testSavedHideSourceMissingDuplicateOrChangedIdentityRefusesWithoutWrites() async throws {
        let cases: [(String, (inout [DisplayRecord]) -> Void, String)] = [
            ("missing", { $0.removeAll { $0.uuid == Self.sourceUUID } }, "missing"),
            ("duplicate", { $0.append(Self.display(index: 5, id: 505, uuid: Self.sourceUUID, name: "Duplicate source", main: false)) }, "ambiguous"),
            ("changed", { records in
                records.removeAll { $0.uuid == Self.sourceUUID }
                records.append(Self.display(index: 3, id: 303, uuid: Self.sourceUUID, name: "Changed source", main: false, serial: 999))
            }, "identity changed")
        ]
        for (name, change, reason) in cases {
            let defaults = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
            let inventory = HideDisplayInventoryBox(displays)
            var writerCalls = 0
            let model = makeModel(
                defaults: defaults,
                displays: displays,
                displayProvider: { inventory.value },
                hideDisplay: { _, _, _ in writerCalls += 1; return .notRequested }
            )
            model.setHideEnabled(true, for: displays[1])
            model.setHideSource(Self.sourceUUID, for: Self.targetUUID)
            change(&inventory.value)
            model.refreshDisplays()

            let result = try await hideAndWait(model)
            XCTAssertFalse(result.succeeded, name)
            XCTAssertTrue(result.message.localizedCaseInsensitiveContains(reason), result.message)
            XCTAssertEqual(writerCalls, 0, "\(name) source refusal happens before the fake display writer")
        }
    }

    func testDisplayIDChangeAfterHideRequestCaptureRefusesBeforeFakeWriter() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let inventory = HideDisplayInventoryBox(displays)
        var quiescenceCompletion: ((Bool, String?) -> Void)?
        var writerCalls = 0
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            displayProvider: { inventory.value },
            quiesceProtection: { quiescenceCompletion = $0 },
            hideDisplay: { _, _, _ in writerCalls += 1; return .notRequested }
        )
        model.setHideEnabled(true, for: displays[1])
        var result: DisplayOperationResult?
        model.hide(targetUUID: Self.targetUUID) { result = $0 }
        XCTAssertNotNil(quiescenceCompletion)
        inventory.value[1] = Self.display(index: 2, id: 2202, uuid: Self.targetUUID, name: "Target", main: false)
        quiescenceCompletion?(true, nil)
        try await waitUntil { result != nil }

        XCTAssertFalse(try XCTUnwrap(result).succeeded)
        XCTAssertEqual(writerCalls, 0, "a pending request keeps the captured ID even though a new operation may resolve the new ID")
        XCTAssertTrue(try XCTUnwrap(result?.message).contains("displays or Hide settings changed"))
    }

    func testSavedReturnInputUsesStableHardwareIdentityButShowKeepsJournalID() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var preferences = DisplayHidePreferences()
        preferences[Self.targetUUID] = DisplayHideConfiguration(
            target: DisplayIdentitySnapshot(uuid: Self.targetUUID, id: 999, name: "Old presentation name",
                                            vendor: displays[1].vendor, model: displays[1].model, serial: displays[1].serial),
            enabled: true, awayInput: 17, returnInput: 15
        )
        defaults.set(try JSONEncoder().encode(preferences), forKey: "displayHidePreferences")
        let box = StatusBox(handoffStatus(.hidden, target: displays[1], source: displays[0], journalID: "strict-journal", canShow: true))
        var shownJournalID: String?
        var shownInput: UInt8?
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            status: { box.value },
            showDisplay: { journalID, input in
                shownJournalID = journalID
                shownInput = input
                box.value = self.handoffStatus(.none, target: nil, source: nil)
                return .notRequested
            }
        )
        try await waitUntil { !model.protectionQuiescencePending }
        let request = try model.makeShowRequest()
        XCTAssertEqual(request.returnInput, 15, "the saved input belongs to the exact stable hardware reference, not its legacy ID or name")
        XCTAssertEqual(request.status.target?.id, 202, "Show remains bound to the journal's captured ID")
        let result = try await showAndWait(model)
        XCTAssertTrue(result.succeeded, result.message)
        XCTAssertEqual(shownJournalID, "strict-journal")
        XCTAssertEqual(shownInput, 15)
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
        try requireInteractiveUI()
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

        // A later recovery problem must not be hidden by acknowledging an old input result.
        box.value = handoffStatus(.recovery, target: displays[1], source: displays[0],
                                  reason: "Reconnect the captured display.")
        model.refreshDisplays()
        XCTAssertFalse(model.canDismissInputWarning(for: Self.targetUUID))
        model.dismissInputWarning(for: Self.targetUUID)
        XCTAssertEqual(model.displayResults[Self.targetKey], shownResult)
        XCTAssertNotNil(model.displayRecoveryProblem)

        box.value = handoffStatus(.none, target: nil, source: nil)
        model.refreshDisplays()
        XCTAssertTrue(model.canDismissInputWarning(for: Self.targetUUID))
        model.dismissInputWarning(for: Self.targetUUID.uppercased())
        let dismissed = try XCTUnwrap(model.displayResults[Self.targetKey])
        XCTAssertTrue(dismissed.inputWarningDismissed)
        XCTAssertFalse(dismissed.needsAttention)
        XCTAssertNil(dismissed.menuLine)
        XCTAssertNil(dismissed.undoInputCommand)
        XCTAssertEqual(dismissed.inputOutcome, shownResult.inputOutcome)
        XCTAssertEqual(model.controlDisplayOutcome, .partial, "acknowledgement is not successful DDC")
        XCTAssertEqual(model.controlDisplayStatuses.first { $0.targetUUID.lowercased() == Self.targetKey }?.lastInputOutcome,
                       shownResult.inputOutcome)
        model.dismissInputWarning(for: Self.targetUUID)
        model.refreshDisplays()
        XCTAssertEqual(model.displayResults[Self.targetKey], dismissed)
        XCTAssertFalse(model.canDismissInputWarning(for: Self.targetUUID))
        XCTAssertEqual(awayInputs, [0x11])
        XCTAssertEqual(returnInputs, [0x0F], "dismissal never invokes a display operation")
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
        XCTAssertTrue(result.message.contains("fake post-Show inspection failure"), result.message)
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
        let retainedResult = model.displayResults[Self.targetKey]
        XCTAssertFalse(model.canDismissInputWarning(for: Self.targetUUID))
        model.dismissInputWarning(for: Self.targetUUID)
        XCTAssertEqual(model.displayResults[Self.targetKey], retainedResult)
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
            XCTAssertThrowsError(try model.makeHideRequest(targetUUID: uuid), "recovery attention blocks new removals") { error in
                XCTAssertTrue(error.localizedDescription.contains("Display recovery needs attention"))
            }
        }
        let other = try XCTUnwrap(model.displayTiles.first { $0.id == Self.sourceUUID.lowercased() })
        XCTAssertEqual(other.action, .hide)
        XCTAssertTrue(other.actionBlocker?.contains("Display recovery needs attention") == true,
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

    func testSleepWakeRehidesTwoDisplaySessionEndToEndAcrossFreshCoreCaptures() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-app-wake-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalStore = RecoveryStore(url: directory.appendingPathComponent("current.json"))
        let operationStore = RecoveryStore(url: directory.appendingPathComponent("operation"))
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let baseline = try appRecoverySnapshot(capturedAt: savedAt)
        let firstHidden = try appRecoverySnapshot(capturedAt: savedAt.addingTimeInterval(1), mirroredIDs: [202])
        var fakeTopology = try appRecoverySnapshot(capturedAt: savedAt.addingTimeInterval(2), mirroredIDs: [202, 303])
        let removals = [
            PublicMirrorRemoval(target: baseline.displays[1], source: baseline.displays[0],
                                beforeOperation: baseline, state: .mirrored),
            PublicMirrorRemoval(target: baseline.displays[2], source: baseline.displays[0],
                                beforeOperation: firstHidden, state: .mirrored)
        ]
        var journal = RecoveryJournal(snapshot: baseline,
                                      publicMirrorSession: PublicMirrorSession(baseline: baseline, removals: removals))
        journal.state = .mirrored
        try journalStore.lock()
        try journalStore.create(journal)
        journalStore.unlock()

        var pendingTarget: UInt32?
        var stagedTargets: [UInt32] = []
        var commits = 0
        var ddcCalls = 0
        let transaction = MirrorTransaction(
            begin: { OpaquePointer(bitPattern: 1)! },
            stage: { _, targetID, sourceID in
                guard sourceID == 101 else { throw RecoveryError.unsafe("unexpected mirror source") }
                pendingTarget = targetID
                stagedTargets.append(targetID)
            },
            complete: { _, _ in
                guard pendingTarget != nil else {
                    throw RecoveryError.unsafe("fake mirror transaction had no staged target")
                }
                fakeTopology = try self.appRecoverySnapshot(
                    capturedAt: Date(), mirroredIDs: Set(stagedTargets)
                )
                pendingTarget = nil
                commits += 1
            },
            cancel: { _ in }
        )
        let mirror = MirrorController(
            records: { self.appDisplayRecords(fakeTopology) },
            operationLock: { operationStore },
            engine: RecoveryEngine(capture: { fakeTopology }, apply: { _ in
                throw RecoveryError.unsafe("wake resume must use the public mirror transaction")
            }, convergencePause: {}),
            preflightModes: { _ in },
            transaction: transaction
        )
        var handoff = HandoffController(mirror: mirror)
        handoff.select = { _, _, _, _, _ in
            ddcCalls += 1
            throw RecoveryError.unsafe("wake resume must not select a monitor input")
        }
        let core = DisplayHideController(store: journalStore, mirror: mirror,
                                         operationLock: { operationStore }, handoff: handoff)
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let model = AppModel(
            defaults: defaults,
            displayProvider: { self.appDisplayRecords(fakeTopology) },
            inspectHandoff: {
                guard let status = try? core.inspect() else {
                    return DisplayHandoffStatus(state: .recovery, journalPath: journalStore.url.path,
                                                inspectionFailure: "synthetic core inspection failed")
                }
                return DisplayHandoff.handoffStatus(from: status)
            },
            hideDisplay: { _, _, _ in
                throw RecoveryError.unsafe("automatic resume must use the guarded core expectation path")
            },
            sleepResumeHideDisplay: { target, source, expected in
                try core.hide(target: target, source: source, awayInput: nil, wakeExpectation: expected)
            },
            quiesceProtection: { $0(true, nil) },
            displayWakeSettleDelay: 0.01
        )
        model.refreshHandoffStatus()
        try await waitUntil { !model.protectionQuiescencePending }
        XCTAssertEqual(model.handoffStatus?.state, DisplayHandoffStatus.State.hidden)
        model.beginDisplaySleepTransition()

        // A fresh independent capture differs only in diagnostic capture timestamps.
        fakeTopology = try appRecoverySnapshot(capturedAt: Date(timeIntervalSince1970: 1_800_000_000))
        model.displayWakeObserved(screensAwake: true)
        try await waitUntil { !model.displayLifecycleTransitioning }

        let final = try core.inspect()
        XCTAssertEqual(final.journal?.state, RecoveryState.mirrored.rawValue)
        XCTAssertEqual(final.removals.filter { $0.isUnresolved }.count, 2)
        XCTAssertEqual(stagedTargets, [202, 303])
        XCTAssertEqual(commits, 2)
        XCTAssertEqual(ddcCalls, 0)
    }

    func testSleepWakeRehidesExactRestoredTwoDisplaySessionOnceWithoutDDC() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let first = sleepRemoval(id: "entry-target", target: displays[1], source: displays[2], resolved: false)
        let second = sleepRemoval(id: "entry-main", target: displays[0], source: displays[2], resolved: false)
        let initial = multiHandoffStatus([first, second], observations: [], journalID: "sleep-journal",
                                         state: .hidden, baselineIdentity: "exact-baseline")
        let restored = multiHandoffStatus([
            sleepRemoval(id: first.id, target: displays[1], source: displays[2], resolved: true),
            sleepRemoval(id: second.id, target: displays[0], source: displays[2], resolved: true)
        ], observations: [], journalID: "sleep-journal", state: DisplayHandoffStatus.State.none,
           baselineIdentity: "exact-baseline")
        let box = StatusBox(initial)
        var applied: [DisplayHandoffRemoval] = []
        var inputChoices: [UInt8?] = []
        let model = makeModel(
            defaults: defaults, displays: displays, status: { box.value },
            hideDisplay: { target, source, input in
                inputChoices.append(input)
                guard let removal = [first, second].first(where: {
                    $0.target.uuid.caseInsensitiveCompare(target.uuid) == .orderedSame &&
                        $0.source.uuid.caseInsensitiveCompare(source.uuid) == .orderedSame
                }) else { throw RecoveryError.unsafe("unexpected resume identity") }
                applied.append(removal)
                box.value = self.multiHandoffStatus(
                    applied.map { self.sleepRemoval(id: $0.id, target: $0.target, source: $0.source, resolved: false) },
                    observations: [], journalID: "resumed-journal", state: .hidden,
                    baselineIdentity: "exact-baseline"
                )
                return .notRequested
            },
            displayWakeSettleDelay: 0.02
        )
        try await waitUntil { !model.protectionQuiescencePending }

        model.beginDisplaySleepTransition()
        box.value = restored
        model.displayWakeObserved(screensAwake: false)
        model.displayWakeObserved(screensAwake: true)
        // Duplicate and out-of-order wake events reset the settle window, not the intent.
        model.displayWakeObserved(screensAwake: false)
        model.displayWakeObserved(screensAwake: true)
        try await waitUntil { !model.displayLifecycleTransitioning }

        XCTAssertEqual(applied.map { $0.target.uuid }, [Self.targetUUID, Self.mainUUID])
        XCTAssertEqual(inputChoices, [nil, nil], "wake recovery never replays configured DDC input changes")
        XCTAssertEqual(model.handoffStatus?.state, DisplayHandoffStatus.State.hidden)
        XCTAssertEqual(model.handoffStatus?.removals.filter { $0.isUnresolved }.count, 2)
        XCTAssertNil(model.displayResults[Self.targetKey])
        model.displayWakeObserved(screensAwake: true)
        XCTAssertEqual(applied.count, 2, "a duplicate wake after settlement cannot replay Hide")
    }

    func testSleepResumeDoesNotRehideEntriesAlreadyRestoredBeforeSleep() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let active = sleepRemoval(id: "active-entry", target: displays[1], source: displays[2], resolved: false)
        let alreadyRestored = sleepRemoval(id: "restored-entry", target: displays[0], source: displays[2], resolved: true)
        let baseline = multiHandoffStatus([active, alreadyRestored], observations: [], journalID: "partial-journal",
                                          state: .hidden, baselineIdentity: "exact-baseline")
        let restored = multiHandoffStatus([
            sleepRemoval(id: active.id, target: displays[1], source: displays[2], resolved: true),
            alreadyRestored
        ], observations: [], journalID: "partial-journal", state: DisplayHandoffStatus.State.none,
           baselineIdentity: "exact-baseline")
        let box = StatusBox(baseline)
        var applied: [DisplayHandoffRemoval] = []
        let model = makeModel(
            defaults: defaults, displays: displays, status: { box.value },
            hideDisplay: { target, source, _ in
                guard let removal = [active, alreadyRestored].first(where: {
                    $0.target.uuid.caseInsensitiveCompare(target.uuid) == .orderedSame &&
                        $0.source.uuid.caseInsensitiveCompare(source.uuid) == .orderedSame
                }) else { throw RecoveryError.unsafe("unexpected resume identity") }
                applied.append(removal)
                box.value = self.multiHandoffStatus([active], observations: [], journalID: "resumed-journal",
                                                     state: .hidden, baselineIdentity: "exact-baseline")
                return .notRequested
            }, displayWakeSettleDelay: 0.01
        )
        try await waitUntil { !model.protectionQuiescencePending }
        model.beginDisplaySleepTransition()
        box.value = restored
        model.displayWakeObserved(screensAwake: true)
        try await waitUntil { !model.displayLifecycleTransitioning }

        XCTAssertEqual(applied.map { $0.id }, [active.id])
    }

    func testExplicitShowCancelsPendingSleepResume() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let mirrored = sleepRemoval(id: "show-entry", target: displays[1], source: displays[2], resolved: false)
        let restored = sleepRemoval(id: mirrored.id, target: displays[1], source: displays[2], resolved: true)
        let box = StatusBox(multiHandoffStatus([mirrored], observations: [], journalID: "show-sleep-journal",
                                               state: .hidden, baselineIdentity: "exact-baseline"))
        var hideCalls = 0
        var showCalls = 0
        let model = makeModel(
            defaults: defaults, displays: displays, status: { box.value },
            hideDisplay: { _, _, _ in hideCalls += 1; return .notRequested },
            showDisplay: { _, _ in showCalls += 1; return .notRequested },
            displayWakeSettleDelay: 0.02
        )
        try await waitUntil { !model.protectionQuiescencePending }
        model.beginDisplaySleepTransition()
        box.value = multiHandoffStatus([restored], observations: [], journalID: "show-sleep-journal",
                                       state: DisplayHandoffStatus.State.none, baselineIdentity: "exact-baseline")
        model.displayWakeObserved(screensAwake: true)
        model.show(targetUUID: Self.targetUUID)
        try await waitUntil { !model.displayLifecycleTransitioning }

        XCTAssertEqual(hideCalls, 0)
        XCTAssertEqual(showCalls, 0, "the explicit request during settle is refused, not replayed later")
    }

    func testSleepResumeRefusesChangedDisplayIDAndKeepsManualRecoveryVisible() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let mirrored = sleepRemoval(id: "changed-entry", target: displays[1], source: displays[2], resolved: false)
        let restored = sleepRemoval(id: mirrored.id, target: displays[1], source: displays[2], resolved: true)
        let box = StatusBox(multiHandoffStatus([mirrored], observations: [], journalID: "changed-journal",
                                               state: .hidden, baselineIdentity: "exact-baseline"))
        var currentDisplays = displays
        var hideCalls = 0
        let model = makeModel(
            defaults: defaults, displays: displays, displayProvider: { currentDisplays }, status: { box.value },
            hideDisplay: { _, _, _ in hideCalls += 1; return .notRequested }, displayWakeSettleDelay: 0.01
        )
        try await waitUntil { !model.protectionQuiescencePending }
        model.beginDisplaySleepTransition()
        currentDisplays[1] = Self.display(index: 2, id: 999, uuid: Self.targetUUID, name: "Target", main: false)
        box.value = multiHandoffStatus([restored], observations: [], journalID: "changed-journal",
                                       state: DisplayHandoffStatus.State.none, baselineIdentity: "exact-baseline")
        model.displayWakeObserved(screensAwake: true)
        try await waitUntil { !model.displayLifecycleTransitioning }

        XCTAssertEqual(hideCalls, 0)
        XCTAssertTrue(model.displayResults[Self.targetKey]?.message.contains("exact journal") == true)
        XCTAssertTrue(model.displayResults[Self.targetKey]?.inputNeedsAttention == true)
    }

    func testSleepResumeRefusesChangedBaselineIdentity() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let mirrored = sleepRemoval(id: "baseline-entry", target: displays[1], source: displays[2], resolved: false)
        let restored = sleepRemoval(id: mirrored.id, target: displays[1], source: displays[2], resolved: true)
        let box = StatusBox(multiHandoffStatus([mirrored], observations: [], journalID: "baseline-journal",
                                               state: .hidden, baselineIdentity: "saved-baseline"))
        var hideCalls = 0
        let model = makeModel(
            defaults: defaults, displays: displays, status: { box.value },
            hideDisplay: { _, _, _ in hideCalls += 1; return .notRequested }, displayWakeSettleDelay: 0.01
        )
        try await waitUntil { !model.protectionQuiescencePending }
        model.beginDisplaySleepTransition()
        box.value = multiHandoffStatus([restored], observations: [], journalID: "baseline-journal",
                                       state: DisplayHandoffStatus.State.none, baselineIdentity: "changed-baseline")
        model.displayWakeObserved(screensAwake: true)
        try await waitUntil { !model.displayLifecycleTransitioning }

        XCTAssertEqual(hideCalls, 0)
        XCTAssertTrue(model.displayResults[Self.targetKey]?.message.contains("baseline") == true)
    }

    func testUnrelatedDisplayChangeDoesNotRehideAResolvedSleepJournal() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let mirrored = sleepRemoval(id: "unrelated-entry", target: displays[1], source: displays[2], resolved: false)
        let restored = sleepRemoval(id: mirrored.id, target: displays[1], source: displays[2], resolved: true)
        let box = StatusBox(multiHandoffStatus([mirrored], observations: [], journalID: "unrelated-journal",
                                               state: .hidden, baselineIdentity: "exact-baseline"))
        var hideCalls = 0
        let model = makeModel(
            defaults: defaults, displays: displays, status: { box.value },
            hideDisplay: { _, _, _ in hideCalls += 1; return .notRequested }, displayWakeSettleDelay: 0.01
        )
        try await waitUntil { !model.protectionQuiescencePending }
        box.value = multiHandoffStatus([restored], observations: [], journalID: "unrelated-journal",
                                       state: DisplayHandoffStatus.State.none, baselineIdentity: "exact-baseline")
        model.displayConfigurationChanged(restartWatcher: true)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(hideCalls, 0)
        XCTAssertFalse(model.displayLifecycleTransitioning)
    }

    func testFailedSleepResumeLeavesRecoveryAndDoesNotRetry() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let mirrored = sleepRemoval(id: "failed-entry", target: displays[1], source: displays[2], resolved: false)
        let restored = sleepRemoval(id: mirrored.id, target: displays[1], source: displays[2], resolved: true)
        let box = StatusBox(multiHandoffStatus([mirrored], observations: [], journalID: "failed-journal",
                                               state: .hidden, baselineIdentity: "exact-baseline"))
        var hideCalls = 0
        let model = makeModel(
            defaults: defaults, displays: displays, status: { box.value }, hideDisplay: { _, _, _ in
                hideCalls += 1
                box.value = self.multiHandoffStatus([
                    self.sleepRemoval(id: mirrored.id, target: self.displays[1], source: self.displays[2], resolved: false,
                                      state: "needsAttention", canShow: false, topologyVerified: false)
                ], observations: [], journalID: "failed-journal", state: .recovery,
                   baselineIdentity: "exact-baseline")
                throw RecoveryError.unsafe("fake guarded Hide refusal")
            }, displayWakeSettleDelay: 0.01
        )
        try await waitUntil { !model.protectionQuiescencePending }
        model.beginDisplaySleepTransition()
        box.value = multiHandoffStatus([restored], observations: [], journalID: "failed-journal",
                                       state: DisplayHandoffStatus.State.none, baselineIdentity: "exact-baseline")
        model.displayWakeObserved(screensAwake: true)
        try await waitUntil { !model.displayLifecycleTransitioning }
        model.displayWakeObserved(screensAwake: true)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(hideCalls, 1, "a refused reapply has a one-attempt budget")
        XCTAssertEqual(model.handoffStatus?.state, DisplayHandoffStatus.State.recovery)
        XCTAssertTrue(model.displayResults[Self.targetKey]?.message.contains("fake guarded Hide refusal") == true)
    }

    func testSystemWakeWithoutScreensWakeDoesNotResumeEarly() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let mirrored = sleepRemoval(id: "system-entry", target: displays[1], source: displays[2], resolved: false)
        let box = StatusBox(multiHandoffStatus([mirrored], observations: [], journalID: "system-journal",
                                               state: .hidden, baselineIdentity: "exact-baseline"))
        var hideCalls = 0
        let model = makeModel(
            defaults: defaults, displays: displays, status: { box.value },
            hideDisplay: { _, _, _ in hideCalls += 1; return .notRequested }, displayWakeSettleDelay: 0.01
        )
        try await waitUntil { !model.protectionQuiescencePending }
        model.beginDisplaySleepTransition()
        model.displayWakeObserved(screensAwake: false)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(hideCalls, 0)
        XCTAssertTrue(model.displayLifecycleTransitioning)
    }

    func testSleepAgainDuringWakeDebounceKeepsIntentUntilFreshWake() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let mirrored = sleepRemoval(id: "second-sleep-entry", target: displays[1], source: displays[2], resolved: false)
        let restored = sleepRemoval(id: mirrored.id, target: displays[1], source: displays[2], resolved: true)
        let box = StatusBox(multiHandoffStatus([mirrored], observations: [], journalID: "second-sleep-journal",
                                               state: .hidden, baselineIdentity: "stable-baseline"))
        var hideCalls = 0
        let model = makeModel(
            defaults: defaults, displays: displays, status: { box.value },
            sleepResumeHideDisplay: { _, _, _ in
                hideCalls += 1
                box.value = self.multiHandoffStatus([mirrored], observations: [], journalID: "second-sleep-journal",
                                                    state: .hidden, baselineIdentity: "stable-baseline")
                return .notRequested
            }, displayWakeSettleDelay: 0.05
        )
        try await waitUntil { !model.protectionQuiescencePending }
        model.beginDisplaySleepTransition()
        box.value = multiHandoffStatus([restored], observations: [], journalID: "second-sleep-journal",
                                       state: DisplayHandoffStatus.State.none, baselineIdentity: "stable-baseline")
        model.displayWakeObserved(screensAwake: true)
        try await Task.sleep(nanoseconds: 15_000_000)

        model.beginDisplaySleepTransition()
        model.refreshHandoffStatus()
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(hideCalls, 0, "the first wake settlement is cancelled by a second sleep")
        XCTAssertTrue(model.displayLifecycleTransitioning, "the lifecycle gate stays closed while screens sleep")

        model.displayWakeObserved(screensAwake: true)
        try await waitUntil { !model.displayLifecycleTransitioning }
        XCTAssertEqual(hideCalls, 1, "the original intent is consumed only after a fresh screen wake")
    }

    func testRecoveryTileOffersGuardedRestoreForManualRecovery() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let failed = sleepRemoval(id: "recovery-entry", target: displays[1], source: displays[2], resolved: false,
                                  state: "needsAttention", canShow: false, topologyVerified: false)
        let box = StatusBox(multiHandoffStatus([failed], observations: [], journalID: "recovery-journal",
                                               state: .recovery, baselineIdentity: "exact-baseline"))
        var showCalls = 0
        let model = makeModel(
            defaults: defaults, displays: displays, status: { box.value },
            quiesceProtection: { $0(true, nil) },
            showDisplay: { _, _ in
                showCalls += 1
                throw RecoveryError.unsafe("strict topology check refused")
            }
        )
        try await waitUntil { !model.protectionQuiescencePending }
        let tile = try XCTUnwrap(model.displayTiles.first { $0.id == Self.targetKey })
        XCTAssertEqual(tile.status, .needsRecovery)
        XCTAssertEqual(tile.action, .show)
        XCTAssertNil(try model.makeShowRequest(targetUUID: Self.targetUUID).returnInput)
        let result = try await showAndWait(model)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(showCalls, 1)
        XCTAssertEqual(model.handoffStatus?.state, .recovery)
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

    func testExternalMirrorFollowerStaysVisibleWithoutUnresolvedRecovery() throws {
        for restoredJournal in [false, true] {
            let defaults = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
            let main = displays[0]
            let follower = Self.display(index: 2, id: 202, uuid: Self.targetUUID,
                                        name: "External mirror", main: false, x: 0, active: false)
            let inactive = Self.display(index: 3, id: 303, uuid: Self.sourceUUID,
                                        name: "Inactive", main: false, active: false)
            let offline = Self.display(index: 4, id: 404, uuid: Self.replacementUUID,
                                       name: "Offline", main: false, online: false)
            var connected = [main, follower, inactive, offline]
            var mirroredIDs: Set<UInt32> = [main.id, follower.id, offline.id]
            let status = restoredJournal ? multiHandoffStatus(
                [sleepRemoval(id: "restored", target: follower, source: main, resolved: true)],
                observations: [], journalID: "previous-session"
            ) : handoffStatus(.none, target: nil, source: nil)
            let model = makeModel(
                defaults: defaults, displays: [], displayProvider: { connected }, status: { status },
                isDisplayMirrored: { mirroredIDs.contains($0) },
                hideDisplay: { _, _, _ in XCTFail("External mirrors must not be changed"); return .notRequested },
                showDisplay: { _, _ in XCTFail("Restored journals must not authorize Show"); return .notRequested }
            )
            let tile = try XCTUnwrap(model.displayTiles.first { $0.id == Self.targetKey })
            XCTAssertEqual(Set(model.displayTiles.map(\.id)), [Self.mainUUID.lowercased(), Self.targetKey])
            XCTAssertEqual(tile.status, .mirrored)
            XCTAssertEqual(tile.action, .hide)
            XCTAssertEqual(tile.actionBlocker,
                           "macOS is mirroring this display. Turn off mirroring in System Settings \u{2192} Displays first.")
            XCTAssertNil(model.displayRecoveryProblem)
            XCTAssertFalse(model.activeDisplays.contains { $0.id == follower.id },
                           "Visibility must not make a mirror follower eligible for automation")
            XCTAssertEqual(model.controlDisplayStatuses.first { $0.targetUUID == Self.targetUUID }?.observedState,
                           "mirrored-externally")

            // System Settings unmirrors it; the same tile becomes an ordinary desktop.
            mirroredIDs = []
            connected = [main, displays[1]]
            model.refreshDisplays()
            let separate = try XCTUnwrap(model.displayTiles.first { $0.id == Self.targetKey })
            XCTAssertEqual(separate.status, .on)
            XCTAssertEqual(separate.action, .hide)
            XCTAssertNil(separate.actionBlocker)
        }
    }

    func testHealthyRemovalSessionKeepsPerDisplayActionsAndOtherHideSetupEditable() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let main = displays[0]
        let firstTarget = Self.display(index: 2, id: 202, uuid: Self.targetUUID, name: "First", main: false, active: false)
        let secondTarget = Self.display(index: 3, id: 303, uuid: Self.sourceUUID, name: "Second", main: false, active: false)
        let survivor = Self.display(index: 4, id: 404, uuid: Self.replacementUUID, name: "Survivor", main: false)
        let first = DisplayHandoffRemoval(
            id: "entry-one", target: handoffIdentity(firstTarget), source: handoffIdentity(main),
            state: "mirrored", isUnresolved: true, canShow: true, reason: nil, topologyVerified: true
        )
        let second = DisplayHandoffRemoval(
            id: "entry-two", target: handoffIdentity(secondTarget), source: handoffIdentity(main),
            state: "mirrored", isUnresolved: true, canShow: true, reason: nil, topologyVerified: true
        )
        let observations = [
            observation(firstTarget, state: .hiddenByPanelCtl, source: main, journalTarget: true),
            observation(secondTarget, state: .hiddenByPanelCtl, source: main, journalTarget: true),
            observation(main, state: .separate), observation(survivor, state: .separate)
        ]
        let status = multiHandoffStatus([first, second], observations: observations, journalID: "shared-session")
        let model = makeModel(
            defaults: defaults, displays: [main, firstTarget, secondTarget, survivor], status: { status },
            isDisplayMirrored: { $0 == main.id || $0 == firstTarget.id || $0 == secondTarget.id }
        )
        spin { !model.protectionQuiescencePending }

        XCTAssertEqual(model.displayTiles.first { $0.id == Self.targetKey }?.status, .hidden)
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.sourceUUID.lowercased() }?.status, .hidden)
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.targetKey }?.action, .show)
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.sourceUUID.lowercased() }?.action, .show)
        XCTAssertTrue(model.hideConfigurationFrozen, "disconnect remains blocked for the unresolved session")
        XCTAssertFalse(model.hideConfigurationFrozen(for: Self.replacementUUID))
        model.setHideEnabled(true, for: survivor)
        model.setHideSource(Self.mainUUID, for: Self.replacementUUID)
        let configuration = try XCTUnwrap(model.hideConfiguration(for: Self.replacementUUID))
        XCTAssertTrue(configuration.enabled)
        XCTAssertEqual(configuration.source?.uuid, Self.mainUUID)
        XCTAssertNil(model.hideReadiness(for: configuration), "healthy removals do not block another Hide")
        XCTAssertEqual(model.controlDisplayStatuses.first { $0.targetUUID == Self.targetUUID }?.recoveryNeeded, false)
        XCTAssertEqual(model.controlDisplayStatuses.first { $0.targetUUID == Self.sourceUUID }?.recoveryNeeded, false)
    }

    func testDisconnectedRemovalKeepsItsOwnRecoveryStateBesideHealthyRemoval() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let main = displays[0]
        let firstTarget = Self.display(index: 2, id: 202, uuid: Self.targetUUID, name: "Connected target", main: false, active: false)
        let disconnectedTarget = Self.display(index: 3, id: 303, uuid: Self.sourceUUID, name: "Disconnected target", main: false, active: false)
        let healthy = DisplayHandoffRemoval(
            id: "healthy-entry", target: handoffIdentity(firstTarget), source: handoffIdentity(main),
            state: "mirrored", isUnresolved: true, canShow: true, reason: nil, topologyVerified: true
        )
        let disconnected = DisplayHandoffRemoval(
            id: "disconnected-entry", target: handoffIdentity(disconnectedTarget), source: handoffIdentity(main),
            state: "needsAttention", isUnresolved: true, canShow: false,
            reason: "Reconnect the exact target.", topologyVerified: false
        )
        let observations = [
            observation(firstTarget, state: .hiddenByPanelCtl, source: main, journalTarget: true),
            observation(disconnectedTarget, state: .unavailable, source: main, journalTarget: true),
            observation(main, state: .separate)
        ]
        let status = multiHandoffStatus(
            [healthy, disconnected], observations: observations, journalID: "one-disconnected",
            state: .recovery
        )
        let model = makeModel(defaults: defaults, displays: [main, firstTarget], status: { status })

        let healthyTile = try XCTUnwrap(model.displayTiles.first { $0.id == Self.targetKey })
        let disconnectedTile = try XCTUnwrap(model.displayTiles.first { $0.id == Self.sourceUUID.lowercased() })
        XCTAssertEqual(healthyTile.status, .hidden)
        XCTAssertEqual(healthyTile.action, .show)
        XCTAssertEqual(disconnectedTile.status, .needsRecovery)
        XCTAssertNil(disconnectedTile.display)
        XCTAssertEqual(model.controlDisplayStatuses.first { $0.targetUUID == Self.sourceUUID }?.observedState, "unavailable")
        XCTAssertEqual(model.controlDisplayStatuses.first { $0.targetUUID == Self.sourceUUID }?.recoveryNeeded, true)
    }

    func testHiddenMirrorOverlayAllowsIndependentlySelectedVerifiedSources() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let main = displays[0]
        let firstTarget = Self.display(index: 2, id: 202, uuid: Self.targetUUID, name: "First", main: false, active: false)
        let secondTarget = Self.display(index: 3, id: 303, uuid: Self.sourceUUID, name: "Second", main: false, active: false)
        let secondSource = Self.display(index: 4, id: 404, uuid: Self.replacementUUID, name: "Other source", main: false)
        let survivor = Self.display(index: 5, id: 505, uuid: "00000000-0000-0000-0000-000000000005", name: "Survivor", main: false)
        let first = DisplayHandoffRemoval(
            id: "entry-one", target: handoffIdentity(firstTarget), source: handoffIdentity(main),
            state: "mirrored", isUnresolved: true, canShow: true, reason: nil, topologyVerified: true
        )
        let second = DisplayHandoffRemoval(
            id: "entry-two", target: handoffIdentity(secondTarget), source: handoffIdentity(secondSource),
            state: "mirrored", isUnresolved: true, canShow: true, reason: nil, topologyVerified: true
        )
        let observations = [
            observation(firstTarget, state: .hiddenByPanelCtl, source: main, journalTarget: true),
            observation(secondTarget, state: .hiddenByPanelCtl, source: secondSource, journalTarget: true),
            observation(main, state: .separate), observation(secondSource, state: .separate),
            observation(survivor, state: .separate)
        ]
        var preferences = ProtectionPreferences()
        preferences.selectedDisplayUUIDs = [Self.mainUUID]
        defaults.set(try JSONEncoder().encode(preferences), forKey: "blackoutPreferences")
        let box = StatusBox(multiHandoffStatus([first, second], observations: observations, journalID: "distinct-sources"))
        let model = makeModel(
            defaults: defaults, displays: [main, firstTarget, secondTarget, secondSource, survivor], status: { box.value },
            isDisplayMirrored: { [main.id, firstTarget.id, secondTarget.id, secondSource.id].contains($0) }
        )
        try await waitUntil { !model.protectionQuiescencePending }
        XCTAssertEqual(model.selectedHiddenMirrorSources.compactMap(\.uuid), [Self.mainUUID],
                       "each verified source is independently eligible without selecting the other source")
        model.preferences.selectedDisplayUUIDs = [Self.mainUUID, Self.replacementUUID]
        XCTAssertEqual(Set(model.selectedHiddenMirrorSources.compactMap(\.uuid)),
                       Set([Self.mainUUID, Self.replacementUUID]))
    }

    func testShowingOneRemovalLeavesOthersAndAutomationPausedUntilTheLastShow() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let main = displays[0]
        let firstTarget = Self.display(index: 2, id: 202, uuid: Self.targetUUID, name: "First", main: false, active: false)
        let secondTarget = Self.display(index: 3, id: 303, uuid: Self.sourceUUID, name: "Second", main: false, active: false)
        let survivor = Self.display(index: 4, id: 404, uuid: Self.replacementUUID, name: "Survivor", main: false)
        let first = DisplayHandoffRemoval(
            id: "entry-one", target: handoffIdentity(firstTarget), source: handoffIdentity(main),
            state: "mirrored", isUnresolved: true, canShow: true, reason: nil, topologyVerified: true
        )
        let second = DisplayHandoffRemoval(
            id: "entry-two", target: handoffIdentity(secondTarget), source: handoffIdentity(main),
            state: "mirrored", isUnresolved: true, canShow: true, reason: nil, topologyVerified: true
        )
        let bothObservations = [
            observation(firstTarget, state: .hiddenByPanelCtl, source: main, journalTarget: true),
            observation(secondTarget, state: .hiddenByPanelCtl, source: main, journalTarget: true),
            observation(main, state: .separate), observation(survivor, state: .separate)
        ]
        let box = StatusBox(multiHandoffStatus([first, second], observations: bothObservations, journalID: "shared-session"))
        var connected = [main, firstTarget, secondTarget, survivor]
        var showKeys: [String] = []
        let model = makeModel(
            defaults: defaults, displays: [], displayProvider: { connected }, status: { box.value },
            isDisplayMirrored: { id in
                id == main.id || box.value.removals.contains(where: {
                    $0.isUnresolved && $0.target.id == id
                })
            },
            showDisplay: { key, _ in
                showKeys.append(key)
                if key.hasSuffix(Self.targetUUID) {
                    connected = [main, Self.display(index: 2, id: 202, uuid: Self.targetUUID, name: "First", main: false),
                                 secondTarget, survivor]
                    let restored = DisplayHandoffRemoval(
                        id: "entry-one", target: self.handoffIdentity(firstTarget), source: self.handoffIdentity(main),
                        state: "restored", isUnresolved: false, canShow: false, reason: nil, topologyVerified: true
                    )
                    let remainingObservations = [
                        self.observation(Self.display(index: 2, id: 202, uuid: Self.targetUUID, name: "First", main: false), state: .separate),
                        self.observation(secondTarget, state: .hiddenByPanelCtl, source: main, journalTarget: true),
                        self.observation(main, state: .separate), self.observation(survivor, state: .separate)
                    ]
                    box.value = self.multiHandoffStatus([restored, second], observations: remainingObservations, journalID: "shared-session")
                } else {
                    connected = [main, Self.display(index: 2, id: 202, uuid: Self.targetUUID, name: "First", main: false),
                                 Self.display(index: 3, id: 303, uuid: Self.sourceUUID, name: "Second", main: false), survivor]
                    box.value = self.handoffStatus(.none, target: nil, source: nil)
                }
                return .notRequested
            }
        )
        try await waitUntil { !model.protectionQuiescencePending }

        let firstShow = try await showAndWait(model, Self.targetUUID)
        XCTAssertTrue(firstShow.succeeded, firstShow.message)
        XCTAssertEqual(showKeys, ["shared-session|\(Self.targetUUID)"])
        XCTAssertTrue(model.protectionPausedForDisplayRecovery)
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.targetKey }?.status, .on)
        XCTAssertEqual(model.displayTiles.first { $0.id == Self.sourceUUID.lowercased() }?.status, .hidden)

        let finalShow = try await showAndWait(model, Self.sourceUUID)
        XCTAssertTrue(finalShow.succeeded, finalShow.message)
        XCTAssertEqual(showKeys, ["shared-session|\(Self.targetUUID)", "shared-session|\(Self.sourceUUID)"])
        XCTAssertFalse(model.protectionPausedForDisplayRecovery)
    }

    func testNativeHideSetupDefaultsSourceAndDetectsTheMacInput() throws {
        try requireInteractiveUI()
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

    func testNativeMissingJournalTargetStaysSelectedAndKeepsOtherSetupEditable() throws {
        try requireInteractiveUI()
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
        XCTAssertTrue(toggle.isEnabled, "a separate display’s Hide setup stays editable during another display’s recovery")
    }

    func testNativeMenuArrowEventsReachShowAction() throws {
        try requireInteractiveUI()
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
        try requireInteractiveUI()
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
        try requireInteractiveUI()
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
        try requireInteractiveUI()
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
        try requireInteractiveUI()
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
        try requireInteractiveUI()
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
        try requireInteractiveUI()
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

    private func writeHiddenOverlayHelper(
        in directory: URL,
        log: URL,
        initiallyWaiting: Bool = false,
        blackoutTrigger: URL? = nil
    ) throws -> URL {
        let helper = directory.appendingPathComponent("fake-panelctl")
        let initialStatus = initiallyWaiting
            ? "printf '{\"state\":\"waiting\",\"blackedOutDisplayIDs\":[]}\\n'"
            : "printf '{\"state\":\"blacked_out\",\"blackedOutDisplayIDs\":[303]}\\n'"
        let triggeredStatus = blackoutTrigger.map { trigger in
            """
            while [[ ! -e '\(trigger.path)' ]]; do /bin/sleep 0.01; done
            printf '{"state":"blacked_out","blackedOutDisplayIDs":[303]}\\n'
            """
        } ?? ""
        let script = """
        #!/bin/bash
        printf 'launch:%s\\n' "$*" >> "$PANELCTL_TEST_LOG"
        \(initialStatus)
        trap 'printf "stop\\n" >> "$PANELCTL_TEST_LOG"; printf "{\\"state\\":\\"stopped\\",\\"blackedOutDisplayIDs\\":[],\\"cleanupSucceeded\\":true}\\n"; exit 0' TERM
        \(triggeredStatus)
        while IFS= read -r command; do
            printf 'command:%s\\n' "$command" >> "$PANELCTL_TEST_LOG"
            if [[ "$command" == "restore" ]]; then
                printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
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
        XCTAssertEqual(blackout.error, AppControlCommand.blackoutNowMigrationGuidance)
        XCTAssertEqual(blackout.outcome, .refused)
        XCTAssertEqual(hideCalls, 1, "a retired request never changes the selected display")

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

    func testForcedBlackOutStyleOverridesRemovalAndShowOrEscapeRestoresIt() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(handoffStatus(.none, target: nil, source: nil))
        var hideCalls = 0
        var showCalls = 0
        var coveredDisplays = Set<UInt32>()
        let model = makeModel(
            defaults: defaults,
            displays: displays,
            status: { box.value },
            coverDisplays: { desired in coveredDisplays = desired; return [] },
            hideDisplay: { _, _, _ in hideCalls += 1; return .notRequested },
            showDisplay: { _, _ in showCalls += 1; return .notRequested }
        )
        model.setHideEnabled(true, for: displays[1])
        model.setHideSource(nil, for: Self.targetUUID)
        XCTAssertTrue(model.hideRemovesFromDesktop(displays[1]))
        XCTAssertNotNil(model.displayTiles.first { $0.uuid == Self.targetUUID }?.actionBlocker,
                        "incomplete removal setup must not block forced black-out")
        let savedHidePreferences = model.hidePreferences
        let savedHideData = defaults.data(forKey: "displayHidePreferences")
        let path = "\(try AppControlSocket.userTemporaryDirectory())/panelctl-test-\(UUID().uuidString.prefix(8)).sock"
        let delegate = AppDelegate()
        delegate.model = model
        let server = AppControlServer(socketPath: path) { await delegate.handleControlRequest($0, receivedAt: $1) }
        try server.start()
        defer { server.stop() }

        @Sendable func send(_ command: AppControlCommand, style: AppControlHideStyle? = nil) async throws -> AppControlResponse {
            try await Task.detached {
                try AppControlClient(socketPath: path, launch: { XCTFail("Hide and Show must not launch the app") })
                    .execute(command, targetUUID: Self.targetUUID, hideStyle: style)
            }.value
        }

        let forcedHide = try await send(.hide, style: .blackOut)
        XCTAssertEqual(forcedHide.outcome, .done)
        XCTAssertTrue(model.isBlackoutHidden(Self.targetUUID))
        XCTAssertEqual(coveredDisplays, [202])
        XCTAssertEqual(hideCalls, 0, "forced black-out bypasses the saved Remove from desktop operation")
        XCTAssertEqual(model.hidePreferences, savedHidePreferences)
        XCTAssertEqual(defaults.data(forKey: "displayHidePreferences"), savedHideData)

        let shown = try await send(.show)
        XCTAssertEqual(shown.outcome, .done)
        XCTAssertFalse(model.isBlackoutHidden(Self.targetUUID))
        XCTAssertTrue(coveredDisplays.isEmpty)
        XCTAssertEqual(showCalls, 0, "Show reverses the black-out Hide without restoring a removal journal")

        let toggled = try await send(.toggleHide, style: .blackOut)
        XCTAssertEqual(toggled.outcome, .done)
        XCTAssertTrue(model.isBlackoutHidden(Self.targetUUID))
        XCTAssertTrue(model.showHiddenDisplay(at: 202), "Escape on the covered display follows the normal Show path")
        XCTAssertFalse(model.isBlackoutHidden(Self.targetUUID))
        XCTAssertTrue(coveredDisplays.isEmpty)
        XCTAssertEqual(model.hidePreferences, savedHidePreferences)
        XCTAssertEqual(defaults.data(forKey: "displayHidePreferences"), savedHideData)
        XCTAssertEqual(hideCalls, 0)
        XCTAssertEqual(showCalls, 0)
        await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
    }

    func testRetiredBlackoutNowSocketRequestRefusesWithoutChangingAutomationOrSnooze() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("panelctl-retired-blackout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("fake-panelctl")
        let log = directory.appendingPathComponent("helper.log")
        let script = """
        #!/bin/bash
        printf 'launch:%s\\n' "$*" >> "$PANELCTL_TEST_LOG"
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        trap 'exit 0' TERM
        while IFS= read -r command; do printf 'command:%s\\n' "$command" >> "$PANELCTL_TEST_LOG"; done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        defer { unsetenv("PANELCTL_HELPER"); unsetenv("PANELCTL_TEST_LOG") }

        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var settings = ProtectionPreferences()
        settings.didChooseDisplays = true
        settings.selectedDisplayUUIDs = [Self.targetUUID]
        let rule = ProtectionRule(name: "Timed rule", isEnabled: true, settings: settings)
        defaults.set(
            try JSONEncoder().encode(AutomationPreferences(isEnabled: false, rules: [rule])),
            forKey: "automationRules"
        )
        let snoozeExpiry = Date().addingTimeInterval(3_600)
        let model = makeModel(defaults: defaults, displays: displays)
        defaults.set(snoozeExpiry, forKey: "snoozedUntil")
        XCTAssertFalse(model.automationPreferences.isEnabled)
        XCTAssertEqual(model.snoozedUntil, snoozeExpiry)
        let savedAutomation = model.automationPreferences
        let savedAutomationData = defaults.data(forKey: "automationRules")
        let delegate = AppDelegate()
        delegate.model = model
        let path = "\(try AppControlSocket.userTemporaryDirectory())/panelctl-test-\(UUID().uuidString.prefix(8)).sock"
        let server = AppControlServer(socketPath: path) { await delegate.handleControlRequest($0, receivedAt: $1) }
        try server.start()
        defer { server.stop() }

        let response = try await Task.detached {
            try AppControlClient(socketPath: path, launch: { XCTFail("the live socket must handle this request") })
                .execute(.blackoutNow)
        }.value
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.outcome, .refused)
        XCTAssertEqual(response.exitCode, 1)
        XCTAssertEqual(response.summary, AppControlCommand.blackoutNowMigrationGuidance)
        XCTAssertEqual(response.error, AppControlCommand.blackoutNowMigrationGuidance)
        XCTAssertEqual(model.automationPreferences, savedAutomation)
        XCTAssertEqual(defaults.data(forKey: "automationRules"), savedAutomationData)
        XCTAssertEqual(model.snoozedUntil, snoozeExpiry)
        XCTAssertEqual(defaults.object(forKey: "snoozedUntil") as? Date, snoozeExpiry)
        XCTAssertEqual(model.runtimeState, .disabled)
        XCTAssertTrue(model.blackedOutDisplayIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "the refused socket command never launches a rule helper")
        await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
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

    private func appRecoverySnapshot(capturedAt: Date, mirroredIDs: Set<UInt32> = []) throws -> RecoverySnapshot {
        let specs: [(id: UInt32, uuid: String, name: String, vendor: UInt32, model: UInt32,
                     serial: UInt32, x: Int32, width: Int, height: Int)] = [
            (101, Self.mainUUID, "Main OLED", 1, 1, 11, 0, 1920, 1080),
            (202, Self.targetUUID, "Target", 2, 2, 22, 1920, 2560, 1440),
            (303, Self.sourceUUID, "Mirror source", 3, 3, 33, 4480, 1920, 1080)
        ]
        let displays: [[String: Any]] = specs.map { spec in
            let hidden = mirroredIDs.contains(spec.id)
            return [
                "uuid": spec.uuid, "id": spec.id, "name": spec.name,
                "vendor": spec.vendor, "model": spec.model, "serial": spec.serial, "builtin": false,
                "main": spec.id == 101, "active": !hidden, "x": spec.x, "y": 0, "rotation": 0,
                "mirrorUUID": hidden ? Self.mainUUID as Any : NSNull(),
                "mode": ["id": Int(spec.id), "width": spec.width, "height": spec.height,
                          "pixelWidth": spec.width, "pixelHeight": spec.height,
                          "refreshRate": 60.0, "flags": 0],
                "identityEvidence": ["source": "syntheticFixture",
                                     "capturedAt": capturedAt.timeIntervalSinceReferenceDate]
            ]
        }
        let payload: [String: Any] = [
            "bootSession": "app-wake-fixture", "osBuild": "fixture-build", "userID": getuid(),
            "hostModel": "synthetic-host", "displays": displays
        ]
        return try JSONDecoder().decode(RecoverySnapshot.self,
                                        from: JSONSerialization.data(withJSONObject: payload))
    }

    private func appDisplayRecords(_ snapshot: RecoverySnapshot) -> [DisplayRecord] {
        snapshot.displays.enumerated().map { index, display in
            DisplayRecord(
                index: index + 1, id: display.id, uuid: display.uuid, name: display.name,
                active: display.active, online: true, asleep: false, builtin: display.builtin,
                main: display.main, vendor: display.vendor, model: display.model, serial: display.serial,
                bounds: DisplayBounds(CGRect(x: CGFloat(display.x), y: CGFloat(display.y),
                                             width: CGFloat(display.mode.width), height: CGFloat(display.mode.height))),
                pixelWidth: display.mode.pixelWidth, pixelHeight: display.mode.pixelHeight
            )
        }
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
        sleepResumeHideDisplay: ((DisplayHideIdentity, DisplayHideIdentity, DisplayHideWakeExpectation) throws -> DisplayInputOutcome)? = nil,
        showDisplay: @escaping (String, UInt8?) throws -> DisplayInputOutcome = { _, _ in .notRequested },
        displayWakeSettleDelay: TimeInterval = 1,
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
            sleepResumeHideDisplay: sleepResumeHideDisplay ?? { target, source, _ in
                try hideDisplay(target, source, nil)
            },
            showDisplay: showDisplay,
            checkDDCInput: checkDDCInput,
            // Black out never draws over a real screen in tests.
            coverDisplays: coverDisplays,
            quiesceProtection: useManagedProtectionService ? nil : quiesceProtection,
            protectionService: protectionService,
            displayWakeSettleDelay: displayWakeSettleDelay
        )
    }

    private func handoffIdentity(_ display: DisplayRecord) -> DisplayHandoffIdentity {
        DisplayHandoffIdentity(DisplayHideIdentity(
            uuid: display.uuid ?? "unavailable-\(display.id)", displayID: display.id,
            name: display.name, vendor: display.vendor, model: display.model, serial: display.serial
        ))
    }

    private func observation(_ display: DisplayRecord, state: DisplayHideObservedState,
                             source: DisplayRecord? = nil, journalTarget: Bool = false) -> DisplayHideObservation {
        DisplayHideObservation(
            identity: DisplayHideIdentity(
                uuid: display.uuid ?? "unavailable-\(display.id)", displayID: display.id,
                name: display.name, vendor: display.vendor, model: display.model, serial: display.serial
            ),
            state: state,
            source: source.map { DisplayHideIdentity(
                uuid: $0.uuid ?? "unavailable-\($0.id)", displayID: $0.id,
                name: $0.name, vendor: $0.vendor, model: $0.model, serial: $0.serial
            ) },
            detail: nil,
            isJournalTarget: journalTarget
        )
    }

    private func sleepRemoval(id: String, target: DisplayRecord, source: DisplayRecord, resolved: Bool,
                              state: String? = nil, canShow: Bool? = nil,
                              topologyVerified: Bool? = nil) -> DisplayHandoffRemoval {
        DisplayHandoffRemoval(
            id: id, target: handoffIdentity(target), source: handoffIdentity(source),
            state: state ?? (resolved ? "restored" : "mirrored"), isUnresolved: !resolved,
            canShow: canShow ?? !resolved, reason: nil,
            topologyVerified: topologyVerified ?? !resolved
        )
    }

    private func sleepRemoval(id: String, target: DisplayHandoffIdentity, source: DisplayHandoffIdentity,
                              resolved: Bool) -> DisplayHandoffRemoval {
        DisplayHandoffRemoval(
            id: id, target: target, source: source, state: resolved ? "restored" : "mirrored",
            isUnresolved: !resolved, canShow: !resolved, reason: nil, topologyVerified: !resolved
        )
    }

    private func multiHandoffStatus(_ removals: [DisplayHandoffRemoval],
                                   observations: [DisplayHideObservation], journalID: String,
                                   state: DisplayHandoffStatus.State? = nil,
                                   baselineIdentity: String? = nil,
                                   observedTopologyIdentity: String? = nil) -> DisplayHandoffStatus {
        let unresolved = removals.filter(\.isUnresolved)
        let primary = unresolved.first ?? removals.first
        return DisplayHandoffStatus(
            state: state ?? (unresolved.isEmpty ? .none : .hidden),
            target: primary?.target, source: primary?.source,
            journalPath: "/tmp/panelctl-multi-display-fixture/current.json",
            journalID: journalID, reason: nil,
            canShow: unresolved.allSatisfy(\.canShow),
            recoveryCommand: "panelctl recovery status --journal '/tmp/panelctl-multi-display-fixture/current.json'",
            observations: observations,
            mirrorTopologyVerified: unresolved.allSatisfy(\.topologyVerified),
            baselineIdentity: baselineIdentity,
            observedTopologyIdentity: observedTopologyIdentity ?? baselineIdentity,
            journalIdentity: "fixture-\(journalID)-\(removals.map(\.state).joined(separator: ","))",
            removals: removals
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
        inspectionFailure: String? = nil,
        baselineIdentity: String? = nil
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
            mirrorTopologyVerified: state == .hidden,
            baselineIdentity: baselineIdentity ?? journalID.map { "baseline-\($0)" }
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

    /// Remove from desktop is the Displays tab's first switch; Hide precedes the Windows section.
    private func removalSwitch(in window: NSWindow) -> NSSwitch? {
        controls(in: window).compactMap { $0 as? NSSwitch }.first
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

private final class HideDisplayInventoryBox {
    var value: [DisplayRecord]
    init(_ value: [DisplayRecord]) { self.value = value }
}
