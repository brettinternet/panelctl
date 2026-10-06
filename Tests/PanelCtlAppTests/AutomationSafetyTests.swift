import XCTest
@testable import PanelCtlApp
@testable import PanelCtlCore

@MainActor
final class AutomationSafetyTests: XCTestCase {
    private let sourceAUUID = "00000000-0000-0000-0000-00000000000a"
    private let sourceBUUID = "00000000-0000-0000-0000-00000000000b"
    private let thirdUUID = "00000000-0000-0000-0000-00000000000c"
    private var defaultsSuiteNames: [ObjectIdentifier: String] = [:]

    func testCoordinatorIgnoresOwnedLiveJournalLockAndVerifiesCleanStop() async throws {
        let fixture = try makeLockedJournalCoordinator()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        defer { fixture.dimming.stop() }
        setenv("PANELCTL_HELPER", fixture.helper.path, 1)
        setenv("PANELCTL_TEST_LOG", fixture.log.path, 1)
        defer { unsetenv("PANELCTL_HELPER"); unsetenv("PANELCTL_TEST_LOG") }

        fixture.coordinator.reconcile(
            ruleSet: fixture.ruleSet,
            validations: [:],
            arguments: [fixture.rule.id: ["blackout", "--panelctl-rule", fixture.rule.id.uuidString]]
        )
        try await waitForLogLines(1, at: fixture.log)
        fixture.dimming.start()
        XCTAssertFalse(fixture.verifyRuleJournal(), "the live dimming lock makes external verification fail")
        XCTAssertNil(fixture.coordinator.unresolvedCleanupFailure, "the active rule owns its journal lock")

        fixture.dimming.stop()
        var stopped: Bool?
        fixture.coordinator.disableForDisplayHide { succeeded, _ in stopped = succeeded }
        try await waitUntil { stopped != nil }
        XCTAssertTrue(stopped ?? false, "all journals are checked strictly after helper quiescence")
        XCTAssertNil(fixture.coordinator.unresolvedCleanupFailure)
        await withCheckedContinuation { continuation in fixture.coordinator.shutdown { continuation.resume() } }
    }

    func testCoordinatorFailsClosedWhenOwnedJournalStillCannotVerifyAfterStop() async throws {
        let fixture = try makeLockedJournalCoordinator()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        defer { fixture.dimming.stop() }
        setenv("PANELCTL_HELPER", fixture.helper.path, 1)
        setenv("PANELCTL_TEST_LOG", fixture.log.path, 1)
        defer { unsetenv("PANELCTL_HELPER"); unsetenv("PANELCTL_TEST_LOG") }

        fixture.coordinator.reconcile(
            ruleSet: fixture.ruleSet,
            validations: [:],
            arguments: [fixture.rule.id: ["blackout", "--panelctl-rule", fixture.rule.id.uuidString]]
        )
        try await waitForLogLines(1, at: fixture.log)
        fixture.dimming.start()
        fixture.dimming.dim([fixture.target], to: 10)
        XCTAssertFalse(fixture.verifyRuleJournal())
        XCTAssertNil(fixture.coordinator.unresolvedCleanupFailure, "an owned live journal is not a cleanup failure")

        var stopped: Bool?
        var failure: String?
        fixture.coordinator.disableForDisplayHide { succeeded, message in
            stopped = succeeded
            failure = message
        }
        try await waitUntil { stopped != nil }
        XCTAssertFalse(stopped ?? true, "quiescence must retain strict post-stop verification")
        XCTAssertNotNil(failure)
        XCTAssertNotNil(fixture.coordinator.unresolvedCleanupFailure)

        fixture.dimming.stop()
        XCTAssertTrue(fixture.dimming.retryCleanup(), "fake luminance writer cleans only the fixture journal")
        await withCheckedContinuation { continuation in fixture.coordinator.shutdown { continuation.resume() } }
    }

    func testJournalDiscoveryFailureBlocksAutomationAndHideDespiteCleanLegacyJournal() async throws {
        let directory = try makeDirectory("panelctl-discovery-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let orphanID = UUID()
        let orphanDirectory = directory.appendingPathComponent(orphanID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphanDirectory, withIntermediateDirectories: true)
        let orphanJournal = orphanDirectory.appendingPathComponent("blackout-luminance.json")
        try Data("unresolved orphan evidence".utf8).write(to: orphanJournal)

        let displaySet = displays
        var settings = ProtectionPreferences()
        settings.selectedDisplayUUIDs = [sourceAUUID]
        let rule = ProtectionRule(name: "Current rule", isEnabled: true, settings: settings)
        let preferences = AutomationPreferences(isEnabled: true, rules: [rule])
        let defaults = try makeDefaults("discovery")
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        defaults.set(try JSONEncoder().encode(preferences), forKey: "automationRules")
        let coordinator = ProtectionCoordinator(
            verifyJournal: { _ in true },
            ruleJournalDirectory: directory,
            discoverRuleIDs: { throw CocoaError(.fileReadNoPermission) },
            serviceFactory: { id in
                ProtectionService(cleanupRuleID: id, cleanupIsVerified: { true }, displaysAreAsleep: { false })
            }
        )
        let model = AppModel(
            defaults: defaults,
            displayProvider: { displaySet },
            inspectHandoff: { DisplayHandoffStatus(state: .none, journalPath: "/tmp/no-display-recovery.json") },
            protectionCoordinator: coordinator
        )
        XCTAssertNotNil(model.protectionQuiescenceFailure, "an unreadable existing Automation directory is not an empty one")
        if case .failed = model.runtimeState {} else { XCTFail("automation should stay blocked") }
        let configuration = DisplayHideConfiguration(
            target: DisplayIdentitySnapshot(displaySet[0]),
            enabled: true,
            source: DisplayIdentitySnapshot(displaySet[1])
        )
        if case .protectionCleanup = model.hideReadiness(for: configuration) {} else {
            XCTFail("Hide must be blocked by unresolved journal discovery")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanJournal.path), "the orphan is never removed on discovery failure")
        await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
    }

    func testRestoreAndDisableCancelBlackoutNowQueuedDuringRestartAll() async throws {
        for cancelByRestore in [true, false] {
            let directory = try makeDirectory("panelctl-pending-control")
            defer { try? FileManager.default.removeItem(at: directory) }
            let log = directory.appendingPathComponent("events.log")
            let helper = try writeHelper(in: directory, script: delayedWaitingHelperScript)
            setenv("PANELCTL_HELPER", helper.path, 1)
            setenv("PANELCTL_TEST_LOG", log.path, 1)
            defer { unsetenv("PANELCTL_HELPER"); unsetenv("PANELCTL_TEST_LOG") }
            let defaults = try makeDefaults("pending")
            defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
            let displaySet = [displays[0]]
            var settings = ProtectionPreferences()
            settings.selectedDisplayUUIDs = [sourceAUUID]
            let rule = ProtectionRule(name: "One rule", isEnabled: true, settings: settings)
            defaults.set(
                try JSONEncoder().encode(AutomationPreferences(isEnabled: true, rules: [rule])),
                forKey: "automationRules"
            )
            let model = AppModel(
                defaults: defaults,
                displayProvider: { displaySet },
                inspectHandoff: { DisplayHandoffStatus(state: .none, journalPath: "/tmp/no-display-recovery.json") },
                protectionCoordinator: makeCoordinator(directory: directory)
            )
            try await waitForLogLines(1, at: log)
            model.refreshDisplays(restartWatcher: true)
            try await waitUntil { model.runtimeState == .stopping }
            try model.blackoutNow()
            if cancelByRestore {
                XCTAssertTrue(try model.restoreBlackout(), "a queued request is controllable during restart")
            } else {
                model.setProtectionEnabled(false)
                XCTAssertFalse(model.automationPreferences.isEnabled)
            }

            if cancelByRestore {
                try await waitForLogLines(3, at: log)
            } else {
                try await waitUntil { !model.protectionQuiescencePending }
            }
            let events = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            XCTAssertFalse(events.contains("command:blackout-now"), "replacement helper must not replay a canceled request")
            await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
        }
    }

    func testOneRuleCleanupFailureStopsSiblingHelpers() async throws {
        let directory = try makeDirectory("panelctl-sibling-cleanup-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("events.log")
        let helper = try writeHelper(in: directory, script: """
        #!/bin/bash
        case " $* " in
            *"--display \(sourceAUUID) "*)
                printf 'failing-launch\\n' >> "$PANELCTL_TEST_LOG"
                printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
                /bin/sleep 0.3
                printf '{"state":"stopped","blackedOutDisplayIDs":[],"cleanupSucceeded":false}\\n'
                exit 1 ;;
        esac
        printf 'sibling-launch\\n' >> "$PANELCTL_TEST_LOG"
        trap 'printf "sibling-stopped\\n" >> "$PANELCTL_TEST_LOG"; printf "{\\\"state\\\":\\\"stopped\\\",\\\"blackedOutDisplayIDs\\\":[],\\\"cleanupSucceeded\\\":true}\\n"; exit 0' TERM
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        while :; do /bin/sleep 0.05; done
        """)
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        defer { unsetenv("PANELCTL_HELPER"); unsetenv("PANELCTL_TEST_LOG") }
        let defaults = try makeDefaults("sibling-cleanup")
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let rules = [rule("Failing", uuid: sourceAUUID, mode: .working), rule("Sibling", uuid: sourceBUUID, mode: .blocking)]
        defaults.set(
            try JSONEncoder().encode(AutomationPreferences(isEnabled: true, rules: rules)),
            forKey: "automationRules"
        )
        let model = AppModel(
            defaults: defaults,
            displayProvider: { self.displays },
            inspectHandoff: { DisplayHandoffStatus(state: .none, journalPath: "/tmp/no-display-recovery.json") },
            protectionCoordinator: makeCoordinator(directory: directory)
        )
        try await waitUntil { model.protectionQuiescenceFailure != nil }
        try await waitUntil {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("sibling-stopped")
        }
        XCTAssertNotNil(model.protectionQuiescenceFailure, "cleanup failure stays blocking")
        await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
    }

    func testRetryAutomationRelaunchesHelperThatExitedWithUnchangedArguments() async throws {
        let directory = try makeDirectory("panelctl-retry-failed-helper")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("events.log")
        let helper = try writeHelper(in: directory, script: """
        #!/bin/bash
        printf 'launch\\n' >> "$PANELCTL_TEST_LOG"
        if [[ $(/usr/bin/grep -c launch "$PANELCTL_TEST_LOG") -eq 1 ]]; then echo boom >&2; exit 2; fi
        trap 'printf "{\\\"state\\\":\\\"stopped\\\",\\\"blackedOutDisplayIDs\\\":[],\\\"cleanupSucceeded\\\":true}\\n"; exit 0' TERM
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        while :; do /bin/sleep 0.05; done
        """)
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        defer { unsetenv("PANELCTL_HELPER"); unsetenv("PANELCTL_TEST_LOG") }
        let defaults = try makeDefaults("retry-failed")
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        defaults.set(
            try JSONEncoder().encode(AutomationPreferences(isEnabled: true, rules: [rule("One", uuid: sourceAUUID, mode: .blocking)])),
            forKey: "automationRules"
        )
        let model = AppModel(
            defaults: defaults,
            displayProvider: { [self.displays[0]] },
            inspectHandoff: { DisplayHandoffStatus(state: .none, journalPath: "/tmp/no-display-recovery.json") },
            protectionCoordinator: makeCoordinator(directory: directory)
        )
        try await waitUntil { if case .failed = model.runtimeState { return true }; return false }
        XCTAssertNil(model.protectionQuiescenceFailure)
        model.retryProtection()
        try await waitForLogLines(2, at: log)
        try await waitUntil { model.runtimeState == .waiting }
        await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
    }

    func testBlockingFocusMembershipAndRestoreFanOutFollowEachRule() async throws {
        let helperDirectory = try makeDirectory("panelctl-rule-focus-helper")
        defer { try? FileManager.default.removeItem(at: helperDirectory) }
        let helper = try writeHelper(in: helperDirectory, script: perDisplayBlackoutHelperScript)
        defer { unsetenv("PANELCTL_HELPER"); unsetenv("PANELCTL_TEST_LOG") }
        let enabledCases: [(String, [ProtectionRule], Set<UInt32>, Int)] = [
            ("working-first", [rule("Working", uuid: sourceAUUID, mode: .working), rule("Blocking", uuid: sourceBUUID, mode: .blocking)], [2], 2),
            ("blocking-first", [rule("Blocking", uuid: sourceAUUID, mode: .blocking), rule("Working", uuid: sourceBUUID, mode: .working)], [1], 2),
            ("disabled-first", [rule("Disabled working", uuid: sourceAUUID, mode: .working, enabled: false), rule("Blocking", uuid: sourceBUUID, mode: .blocking)], [2], 1)
        ]

        for (suffix, rules, expectedFocusIDs, enabledCount) in enabledCases {
            let directory = try makeDirectory("panelctl-rule-focus-\(suffix)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let log = directory.appendingPathComponent("events.log")
            setenv("PANELCTL_HELPER", helper.path, 1)
            setenv("PANELCTL_TEST_LOG", log.path, 1)
            let defaults = try makeDefaults(suffix)
            defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
            defaults.set(
                try JSONEncoder().encode(AutomationPreferences(isEnabled: true, rules: rules)),
                forKey: "automationRules"
            )
            let model = AppModel(
                defaults: defaults,
                displayProvider: { self.displays },
                inspectHandoff: { DisplayHandoffStatus(state: .none, journalPath: "/tmp/no-display-recovery.json") },
                protectionCoordinator: makeCoordinator(directory: directory)
            )
            let expectedBlackedOutIDs: Set<UInt32> = enabledCount == 1 ? [2] : [1, 2]
            try await waitUntil { model.blackedOutDisplayIDs == expectedBlackedOutIDs }
            XCTAssertEqual(model.automationBlockingDisplayIDs, expectedFocusIDs, "focus follows each rule's actual blocking treatment")
            XCTAssertTrue(try model.restoreBlackout(), "Escape restoration acts on the complete rule set")
            try await waitUntil {
                ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                    .components(separatedBy: "command:restore").count - 1 == enabledCount
            }
            await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
        }
        unsetenv("PANELCTL_HELPER")
        unsetenv("PANELCTL_TEST_LOG")
    }

    func testPartialVerifiedMirrorSourceSelectionLaunchesOnlySelectedOverlay() async throws {
        let directory = try makeDirectory("panelctl-partial-source-selection")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("events.log")
        let helper = try writeHelper(in: directory, script: perDisplayBlackoutHelperScript)
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        defer { unsetenv("PANELCTL_HELPER"); unsetenv("PANELCTL_TEST_LOG") }
        let defaults = try makeDefaults("partial-source")
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var settings = ProtectionPreferences()
        settings.selectedDisplayUUIDs = [sourceAUUID]
        let preferences = AutomationPreferences(isEnabled: true, rules: [ProtectionRule(name: "Partial", isEnabled: true, settings: settings)])
        defaults.set(try JSONEncoder().encode(preferences), forKey: "automationRules")
        let sources = Array(displays.prefix(2))
        let hidden = hiddenStatus(for: sources)
        let model = AppModel(
            defaults: defaults,
            displayProvider: { sources },
            inspectHandoff: { hidden },
            protectionCoordinator: makeCoordinator(directory: directory)
        )
        try await waitUntil { !model.protectionQuiescencePending }
        XCTAssertEqual(model.verifiedHiddenMirrorSources.count, 2)
        XCTAssertEqual(model.selectedHiddenMirrorSources.compactMap(\.uuid), [sourceAUUID])
        XCTAssertTrue(model.hiddenMirrorOverlayPolicyEligible)
        try await waitUntil { model.blackedOutDisplayIDs == [1] }
        let launches = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n").filter { $0.hasPrefix("launch:") }
        XCTAssertEqual(launches.count, 1)
        XCTAssertTrue(launches[0].contains("--display \(sourceAUUID)"))
        XCTAssertFalse(launches[0].contains(sourceBUUID), "unselected verified source remains untouched")
        await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
    }

    func testSiblingSourceCoverageMakesOverlayCountdownAbsoluteAndArgumentsComplete() async throws {
        let directory = try makeDirectory("panelctl-sibling-source-coverage")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("events.log")
        let helper = try writeHelper(in: directory, script: perDisplayBlackoutHelperScript)
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        defer { unsetenv("PANELCTL_HELPER"); unsetenv("PANELCTL_TEST_LOG") }
        let defaults = try makeDefaults("sibling-sources")
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var firstSettings = ProtectionPreferences()
        firstSettings.selectedDisplayUUIDs = [sourceAUUID]
        firstSettings.mode = .working
        firstSettings.followUpAction = .restore
        firstSettings.followUpSeconds = 900
        var secondSettings = ProtectionPreferences()
        secondSettings.selectedDisplayUUIDs = [sourceBUUID]
        secondSettings.mode = .working
        secondSettings.followUpAction = .restore
        secondSettings.followUpSeconds = 900
        let rules = [
            ProtectionRule(name: "Source A", isEnabled: true, settings: firstSettings),
            ProtectionRule(name: "Source B", isEnabled: true, settings: secondSettings)
        ]
        defaults.set(
            try JSONEncoder().encode(AutomationPreferences(isEnabled: true, rules: rules)),
            forKey: "automationRules"
        )
        let sources = Array(displays.prefix(2))
        let hidden = hiddenStatus(for: sources)
        var current = Date(timeIntervalSince1970: 1_800_000_000)
        var idle: TimeInterval = 0
        let model = AppModel(
            defaults: defaults,
            displayProvider: { sources },
            now: { current },
            idleSecondsProvider: { idle },
            inspectHandoff: { hidden },
            protectionCoordinator: makeCoordinator(directory: directory)
        )
        try await waitUntil { model.blackedOutDisplayIDs == [1, 2] }
        XCTAssertEqual(model.selectedHiddenMirrorSources.count, 2)
        XCTAssertFalse(model.hiddenMirrorOverlayResetsLimitOnInput, "the sibling overlay covers the other verified source")
        let launches = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n").map(String.init).filter { $0.hasPrefix("launch:") }
        XCTAssertEqual(launches.count, 2)
        for launch in launches {
            let arguments = launch.replacingOccurrences(of: "launch:", with: "").components(separatedBy: " ")
            guard case .blackout(let options) = try CLIParser.parse(arguments) else {
                return XCTFail("overlay helper arguments should parse")
            }
            XCTAssertEqual(options.otherRuleDisplayUUIDs.count, 1)
            XCTAssertNotEqual(options.otherRuleDisplayUUIDs.first?.lowercased(), options.hiddenMirrorSourceUUID?.lowercased())
        }
        XCTAssertEqual(model.secondsRemaining, 900)
        current.addTimeInterval(100)
        idle = 0
        XCTAssertEqual(model.secondsRemaining, 800, "input cannot extend either all-source absolute restore deadline")
        current.addTimeInterval(100)
        XCTAssertEqual(model.secondsRemaining, 700)
        await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
    }

    func testHiddenDisplayTakesPrecedenceOverSiblingCoverageInGeneratedArguments() throws {
        var settings = ProtectionPreferences()
        settings.selectedDisplayUUIDs = [sourceAUUID]
        let arguments = try settings.commandArguments(
            for: displays,
            hiddenDisplayUUIDs: [sourceBUUID],
            otherRuleDisplayUUIDs: [sourceBUUID, thirdUUID],
            ruleID: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        )
        guard case .blackout(let options) = try CLIParser.parse(arguments) else {
            return XCTFail("generated rule arguments should parse")
        }
        XCTAssertEqual(options.hiddenDisplayUUIDs, [sourceBUUID])
        XCTAssertEqual(options.otherRuleDisplayUUIDs, [thirdUUID], "a hidden sibling target has one authoritative coverage flag")
    }

    func testMissingDisplayRefreshSettlesUntilTopologyChanges() async throws {
        let directory = try makeDirectory("panelctl-waiting-refresh")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try makeDefaults("waiting-refresh")
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var settings = ProtectionPreferences()
        settings.selectedDisplayUUIDs = [thirdUUID]
        let rule = ProtectionRule(name: "Missing display", isEnabled: true, settings: settings)
        defaults.set(
            try JSONEncoder().encode(AutomationPreferences(isEnabled: true, rules: [rule])),
            forKey: "automationRules"
        )
        var refreshCount = 0
        let model = AppModel(
            defaults: defaults,
            displayProvider: { refreshCount += 1; return [self.displays[0]] },
            inspectHandoff: { DisplayHandoffStatus(state: .none, journalPath: "/tmp/no-display-recovery.json") },
            protectionCoordinator: makeCoordinator(directory: directory)
        )
        try await waitUntil {
            if case .waitingForDisplays = model.runtimeState { return true }
            return false
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let settledRefreshCount = refreshCount
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(refreshCount, settledRefreshCount, "unchanged waiting callbacks must not poll inventory indefinitely")
        XCTAssertLessThanOrEqual(settledRefreshCount, 2, "at most one entry refresh follows the initial inventory")
        await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
    }

    private var displays: [DisplayRecord] {
        [
            record(id: 1, uuid: sourceAUUID, name: "Source A"),
            record(id: 2, uuid: sourceBUUID, name: "Source B"),
            record(id: 3, uuid: thirdUUID, name: "Display C")
        ]
    }

    private func record(id: UInt32, uuid: String, name: String) -> DisplayRecord {
        DisplayRecord(
            index: Int(id), id: id, uuid: uuid, name: name,
            active: true, online: true, asleep: false, builtin: false, main: id == 1,
            vendor: 1, model: 2, serial: 3,
            bounds: DisplayBounds(CGRect(x: Double(id * 100), y: 0, width: 100, height: 100)),
            pixelWidth: 100, pixelHeight: 100
        )
    }

    private func rule(
        _ name: String,
        uuid: String,
        mode: BlackoutMode,
        enabled: Bool = true
    ) -> ProtectionRule {
        var settings = ProtectionPreferences()
        settings.selectedDisplayUUIDs = [uuid]
        settings.mode = mode
        return ProtectionRule(name: name, isEnabled: enabled, settings: settings)
    }

    private func hiddenStatus(for sources: [DisplayRecord]) -> DisplayHandoffStatus {
        let removals = sources.enumerated().map { index, source in
            let targetIdentity = DisplayHideIdentity(
                uuid: String(format: "50000000-0000-0000-0000-%012d", index + 1),
                displayID: UInt32(100 + index), name: "Removed target \(index + 1)",
                vendor: 1, model: 2, serial: UInt32(index + 10)
            )
            let sourceIdentity = DisplayHideIdentity(
                uuid: source.uuid ?? "", displayID: source.id, name: source.name,
                vendor: source.vendor, model: source.model, serial: source.serial
            )
            return DisplayHandoffRemoval(
                id: "removal-\(index)",
                target: DisplayHandoffIdentity(targetIdentity),
                source: DisplayHandoffIdentity(sourceIdentity),
                state: "mirrored", isUnresolved: true, canShow: true,
                reason: nil, topologyVerified: true
            )
        }
        return DisplayHandoffStatus(
            state: .hidden,
            target: removals.first?.target,
            source: removals.first?.source,
            journalPath: "/tmp/verified-hidden-sources.json",
            journalID: "verified-hidden-sources",
            canShow: true,
            mirrorTopologyVerified: true,
            removals: removals
        )
    }

    private func makeLockedJournalCoordinator() throws -> (
        directory: URL,
        log: URL,
        helper: URL,
        rule: ProtectionRule,
        ruleSet: AutomationPreferences,
        dimming: BlackoutDimming,
        target: BlackoutScreenTarget,
        coordinator: ProtectionCoordinator,
        verifyRuleJournal: () -> Bool
    ) {
        let directory = try makeDirectory("panelctl-live-journal")
        let id = UUID()
        let journalDirectory = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        let journalURL = journalDirectory.appendingPathComponent("blackout-luminance.json")
        let display = record(id: 1, uuid: sourceAUUID, name: "Fixture display")
        let dimming = BlackoutDimming(
            journalURL: journalURL,
            records: { [display] },
            read: { uuid in DDCLuminanceReading(displayID: 1, uuid: uuid, current: 50, maximum: 100) },
            set: { uuid, value in
                DDCLuminanceWriteResult(
                    displayID: 1, uuid: uuid, original: 50,
                    requested: value, observed: value, maximum: 100
                )
            }
        )
        let verifyRuleJournal = { BlackoutDimming(journalURL: journalURL).cleanupIsVerified() }
        let service = ProtectionService(
            cleanupRuleID: id,
            cleanupIsVerified: verifyRuleJournal,
            displaysAreAsleep: { false }
        )
        let rule = ProtectionRule(name: "Locked journal", isEnabled: true, settings: ProtectionPreferences())
        var identifiedRule = rule
        identifiedRule = ProtectionRule(id: id, name: rule.name, isEnabled: true, settings: rule.settings)
        let ruleSet = AutomationPreferences(isEnabled: true, rules: [identifiedRule])
        let target = BlackoutScreenTarget(id: 1, uuid: sourceAUUID, selector: sourceAUUID)
        let coordinator = ProtectionCoordinator(
            initialService: service,
            verifyJournal: { journalID in journalID == id ? verifyRuleJournal() : true },
            ruleJournalDirectory: directory,
            removeDeletedDirectories: false,
            serviceFactory: { ruleID in
                ProtectionService(
                    cleanupRuleID: ruleID,
                    cleanupIsVerified: { ruleID == id ? verifyRuleJournal() : true },
                    displaysAreAsleep: { false }
                )
            }
        )
        let helper = try writeHelper(in: directory, script: waitingHelperScript)
        return (
            directory, directory.appendingPathComponent("events.log"), helper,
            identifiedRule, ruleSet, dimming, target, coordinator, verifyRuleJournal
        )
    }

    private func makeCoordinator(directory: URL) -> ProtectionCoordinator {
        ProtectionCoordinator(
            verifyJournal: { _ in true },
            ruleJournalDirectory: directory,
            removeDeletedDirectories: false,
            serviceFactory: { id in
                ProtectionService(
                    cleanupRuleID: id,
                    cleanupIsVerified: { true },
                    displaysAreAsleep: { false }
                )
            }
        )
    }

    private func makeDefaults(_ suffix: String) throws -> UserDefaults {
        let name = "panelctl-automation-safety-\(suffix)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaultsSuiteNames[ObjectIdentifier(defaults)] = name
        return defaults
    }

    private func suiteName(_ defaults: UserDefaults) -> String {
        defaultsSuiteNames[ObjectIdentifier(defaults)]!
    }

    private func makeDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeHelper(in directory: URL, script: String) throws -> URL {
        let helper = directory.appendingPathComponent("fake-panelctl")
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return helper
    }

    private func waitForLogLines(_ count: Int, at url: URL) async throws {
        try await waitUntil {
            ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .split(separator: "\n").count >= count
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<250 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for a fake/offline automation state")
    }

    private var waitingHelperScript: String {
        """
        #!/bin/bash
        printf 'launch:%s\\n' "$*" >> "$PANELCTL_TEST_LOG"
        trap 'printf "stopped\\n" >> "$PANELCTL_TEST_LOG"; printf "{\\\"state\\\":\\\"stopped\\\",\\\"blackedOutDisplayIDs\\\":[],\\\"cleanupSucceeded\\\":true}\\n"; exit 0' TERM
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        while :; do /bin/sleep 0.05; done
        """
    }

    private var delayedWaitingHelperScript: String {
        """
        #!/bin/bash
        printf 'launch:%s\\n' "$*" >> "$PANELCTL_TEST_LOG"
        trap 'printf "stopped\\n" >> "$PANELCTL_TEST_LOG"; /bin/sleep 0.15; printf "{\\\"state\\\":\\\"stopped\\\",\\\"blackedOutDisplayIDs\\\":[],\\\"cleanupSucceeded\\\":true}\\n"; exit 0' TERM
        printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        while :; do /bin/sleep 0.05; done
        """
    }

    private var perDisplayBlackoutHelperScript: String {
        """
        #!/bin/bash
        printf 'launch:%s\\n' "$*" >> "$PANELCTL_TEST_LOG"
        trap 'printf "stopped\\n" >> "$PANELCTL_TEST_LOG"; printf "{\\\"state\\\":\\\"stopped\\\",\\\"blackedOutDisplayIDs\\\":[],\\\"cleanupSucceeded\\\":true}\\n"; exit 0' TERM
        display_id=0
        case " $* " in
            *"--display \(sourceAUUID) "*) display_id=1 ;;
            *"--display \(sourceBUUID) "*) display_id=2 ;;
            *"--display \(thirdUUID) "*) display_id=3 ;;
        esac
        printf '{"state":"blacked_out","blackedOutDisplayIDs":[%s]}\\n' "$display_id"
        while IFS= read -r command; do
            printf 'command:%s\\n' "$command" >> "$PANELCTL_TEST_LOG"
            if [[ "$command" == "restore" ]]; then printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'; fi
        done
        """
    }
}
