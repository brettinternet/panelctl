import XCTest
import CoreGraphics
@testable import PanelCtlApp
@testable import PanelCtlCore

final class AutomationRulesTests: XCTestCase {
    @MainActor
    func testVersionedMigrationPreservesLegacySettingsAndLeavesLegacyPayloadAlone() async throws {
        let legacy = Data(#"{"isEnabled":false,"idleSeconds":420,"followUpAction":"restore","followUpSeconds":37,"keepDisplaysAwake":false,"allDisplays":false,"selectedDisplayUUIDs":["00000000-0000-0000-0000-000000000001"],"didChooseDisplays":true,"blackoutEmptyDisplays":true,"mode":"working","workingOverlayEnabled":false,"workingOverlayOpacityPercent":48,"dimDisplaysDuringBlackout":true,"keepBlackoutOnInput":true,"deferBlackoutDuringPlayback":false,"deferBlackoutWhileCameraInUse":true}"#.utf8)
        let suite = "panelctl-rules-migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(legacy, forKey: "blackoutPreferences")
        let coordinator = makeCoordinator(directory: temporaryDirectory())
        let model = AppModel(
            defaults: defaults,
            displayProvider: { self.inventory },
            inspectHandoff: { DisplayHandoffStatus(state: .none, journalPath: "/tmp/no-display-recovery.json") },
            protectionCoordinator: coordinator
        )
        let savedData = try XCTUnwrap(defaults.data(forKey: "automationRules"))
        let migrated = try JSONDecoder().decode(AutomationPreferences.self, from: savedData)
        XCTAssertEqual(migrated.version, AutomationPreferences.currentVersion)
        XCTAssertFalse(migrated.isEnabled)
        XCTAssertFalse(migrated.keepDisplaysAwake)
        let rule = try XCTUnwrap(migrated.rules.first)
        XCTAssertEqual(rule.name, "Display protection")
        XCTAssertTrue(rule.isEnabled)
        XCTAssertEqual(rule.settings.idleSeconds, 420)
        XCTAssertEqual(rule.settings.followUpAction, .restore)
        XCTAssertEqual(rule.settings.followUpSeconds, 37)
        XCTAssertEqual(rule.settings.selectedDisplayUUIDs, ["00000000-0000-0000-0000-000000000001"])
        XCTAssertTrue(rule.settings.blackoutEmptyDisplays)
        XCTAssertEqual(rule.settings.mode, .working)
        XCTAssertFalse(rule.settings.workingOverlayEnabled)
        XCTAssertEqual(rule.settings.workingOverlayOpacityPercent, 48)
        XCTAssertTrue(rule.settings.hardwareDimmingEnabled)
        XCTAssertEqual(rule.settings.hardwareBrightnessPercent, 0)
        XCTAssertTrue(rule.settings.keepBlackoutOnInput)
        XCTAssertFalse(rule.settings.deferBlackoutDuringPlayback)
        XCTAssertTrue(rule.settings.deferBlackoutWhileCameraInUse)
        let persistedLegacy = try XCTUnwrap(defaults.data(forKey: "blackoutPreferences"))
        XCTAssertEqual(persistedLegacy, legacy)

        let secondModel = AppModel(
            defaults: defaults,
            displayProvider: { self.inventory },
            inspectHandoff: { DisplayHandoffStatus(state: .none, journalPath: "/tmp/no-display-recovery.json") },
            protectionCoordinator: makeCoordinator(directory: temporaryDirectory())
        )
        XCTAssertEqual(secondModel.automationPreferences, migrated, "relaunch uses the versioned key, not a second migration")
        XCTAssertEqual(
            try JSONDecoder().decode(AutomationPreferences.self, from: XCTUnwrap(defaults.data(forKey: "automationRules"))),
            migrated
        )
        let relaunchLegacy = try XCTUnwrap(defaults.data(forKey: "blackoutPreferences"))
        XCTAssertEqual(relaunchLegacy, legacy)
        await withCheckedContinuation { continuation in
            model.shutdown { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            secondModel.shutdown { continuation.resume() }
        }
    }

    @MainActor
    func testFirstRunCreatesDisplayProtectionUsingInitialExternalDisplay() async throws {
        let suite = "panelctl-rules-first-run-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(
            defaults: defaults,
            displayProvider: { self.inventory },
            inspectHandoff: { DisplayHandoffStatus(state: .none, journalPath: "/tmp/no-display-recovery.json") },
            protectionCoordinator: makeCoordinator(directory: temporaryDirectory())
        )
        let rule = try XCTUnwrap(model.automationPreferences.rules.first)
        XCTAssertEqual(rule.name, "Display protection")
        XCTAssertTrue(rule.isEnabled)
        XCTAssertFalse(model.automationPreferences.isEnabled)
        XCTAssertEqual(rule.settings.selectedDisplayUUIDs, ["00000000-0000-0000-0000-00000000000A"])
        XCTAssertTrue(rule.settings.didChooseDisplays)
        XCTAssertNotNil(defaults.data(forKey: "automationRules"))
        XCTAssertNil(defaults.data(forKey: "blackoutPreferences"))
        await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
    }

    func testLegacyEnabledMasterAndGlobalSleepSettingMigrateSeparatelyFromRuleEnablement() throws {
        let legacy = Data(#"{"isEnabled":true,"keepDisplaysAwake":true,"didChooseDisplays":true,"allDisplays":true,"selectedDisplayUUIDs":[],"idleSeconds":90,"followUpAction":"sleepDisplays","followUpSeconds":15,"dimDisplaysDuringBlackout":true}"#.utf8)
        let migrated = AutomationPreferences.migrate(legacyData: legacy, displays: inventory)
        XCTAssertTrue(migrated.isEnabled)
        XCTAssertTrue(migrated.keepDisplaysAwake)
        let rule = try XCTUnwrap(migrated.rules.first)
        XCTAssertTrue(rule.isEnabled)
        XCTAssertFalse(rule.settings.isEnabled, "the legacy master switch moves to the rule-set level")
        XCTAssertTrue(rule.settings.keepDisplaysAwake)
        XCTAssertTrue(rule.settings.allDisplays)
        XCTAssertEqual(rule.settings.idleSeconds, 90)
        XCTAssertEqual(rule.settings.followUpAction, .sleepDisplays)
        XCTAssertTrue(rule.settings.hardwareDimmingEnabled)
        XCTAssertEqual(rule.settings.hardwareBrightnessPercent, 0)
        XCTAssertNotNil(try JSONDecoder().decode(ProtectionPreferences.self, from: legacy))
    }

    func testRuleValidatorRejectsCaseInsensitiveAndAllDisplayConflicts() throws {
        let firstUUID = inventory[0].uuid!
        var firstSettings = ProtectionPreferences()
        firstSettings.selectedDisplayUUIDs = [firstUUID.lowercased()]
        var conflictingSettings = ProtectionPreferences()
        conflictingSettings.selectedDisplayUUIDs = [firstUUID.uppercased()]
        let first = ProtectionRule(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: "Primary dimming", isEnabled: true, settings: firstSettings
        )
        let second = ProtectionRule(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            name: "Desk dimming", isEnabled: true, settings: conflictingSettings
        )
        let conflictSet = AutomationPreferences(isEnabled: true, rules: [first, second])
        let firstResult = ProtectionRuleValidator.validate(first, in: conflictSet, displays: inventory)
        let secondResult = ProtectionRuleValidator.validate(second, in: conflictSet, displays: inventory)
        XCTAssertTrue(firstResult.blockingReason?.contains("Display 1") == true)
        XCTAssertTrue(firstResult.blockingReason?.contains("Desk dimming") == true)
        XCTAssertTrue(secondResult.blockingReason?.contains("Primary dimming") == true)
        XCTAssertNil(firstResult.arguments)
        XCTAssertNil(secondResult.arguments)

        var disabled = second
        disabled.isEnabled = false
        let alternatives = AutomationPreferences(isEnabled: true, rules: [first, disabled])
        XCTAssertNil(ProtectionRuleValidator.validate(first, in: alternatives, displays: inventory).blockingReason)

        var allSettings = ProtectionPreferences()
        allSettings.allDisplays = true
        let allRule = ProtectionRule(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
            name: "All displays", isEnabled: true, settings: allSettings
        )
        let allConflict = AutomationPreferences(isEnabled: true, rules: [allRule, first])
        XCTAssertTrue(ProtectionRuleValidator.validate(allRule, in: allConflict, displays: inventory)
            .blockingReason?.contains("Primary dimming") == true)
        XCTAssertTrue(ProtectionRuleValidator.validate(first, in: allConflict, displays: inventory)
            .blockingReason?.contains("All displays") == true)
    }

    func testRuleValidatorCountsSiblingAndHiddenDisplaysForCombinedSafety() throws {
        let uuids = inventory.prefix(2).compactMap(\.uuid)
        var firstSettings = ProtectionPreferences()
        firstSettings.selectedDisplayUUIDs = [uuids[0]]
        firstSettings.followUpAction = .untilActivity
        var secondSettings = ProtectionPreferences()
        secondSettings.selectedDisplayUUIDs = [uuids[1]]
        secondSettings.followUpAction = .untilActivity
        let first = ProtectionRule(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            name: "Screen one", isEnabled: true, settings: firstSettings
        )
        var second = ProtectionRule(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            name: "Desk dimming", isEnabled: true, settings: secondSettings
        )
        let set = AutomationPreferences(isEnabled: true, rules: [first, second])
        let blocked = ProtectionRuleValidator.validate(first, in: set, displays: Array(inventory.prefix(2)))
        XCTAssertTrue(blocked.blockingReason?.contains("With “Desk dimming”") == true)
        XCTAssertTrue(blocked.blockingReason?.contains("Choose Restore or Sleep") == true)

        second.isEnabled = false
        let single = AutomationPreferences(isEnabled: true, rules: [first, second])
        let runnable = ProtectionRuleValidator.validate(first, in: single, displays: Array(inventory.prefix(2)))
        XCTAssertTrue(runnable.isRunnable)
        XCTAssertTrue(runnable.arguments?.contains("--panelctl-rule") == true)
        XCTAssertFalse(runnable.arguments?.contains("--panelctl-other-rule-display") == true)

        let hiddenCovered = ProtectionRuleValidator.validate(
            first, in: set, displays: Array(inventory.prefix(3)), hiddenUUIDs: [inventory[2].uuid!]
        )
        XCTAssertTrue(hiddenCovered.blockingReason?.contains("With “Desk dimming”") == true)
    }

    func testRuleNameRenameTrimsAndRejectsEmptyOrDuplicateNames() throws {
        let first = ProtectionRule(name: "First")
        let second = ProtectionRule(name: "Second")
        var set = AutomationPreferences(rules: [first, second])
        try set.renameRule(id: second.id, to: "  Desk  ")
        XCTAssertEqual(set.rule(namedID: second.id)?.name, "Desk")
        XCTAssertThrowsError(try set.renameRule(id: second.id, to: " first ")) {
            XCTAssertEqual($0 as? ProtectionConfigurationError, .duplicateRuleName("first"))
        }
        XCTAssertThrowsError(try set.renameRule(id: second.id, to: " \n ")) {
            XCTAssertEqual($0 as? ProtectionConfigurationError, .invalidRuleName)
        }
    }

    @MainActor
    func testCoordinatorRestartsEveryHelperForEffectiveRuleSetChangeAndFansOutControl() async throws {
        let helper = try makeHelper(cleanup: false)
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent()) }
        setenv("PANELCTL_HELPER", helper.path, 1)
        let log = helper.deletingLastPathComponent().appendingPathComponent("events.log")
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        defer { unsetenv("PANELCTL_HELPER"); unsetenv("PANELCTL_TEST_LOG") }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = makeCoordinator(directory: directory)
        var firstSettings = ProtectionPreferences()
        firstSettings.selectedDisplayUUIDs = [inventory[0].uuid!]
        firstSettings.idleSeconds = 120
        var secondSettings = ProtectionPreferences()
        secondSettings.selectedDisplayUUIDs = [inventory[1].uuid!]
        secondSettings.idleSeconds = 300
        let first = ProtectionRule(name: "First", isEnabled: true, settings: firstSettings)
        let second = ProtectionRule(name: "Second", isEnabled: true, settings: secondSettings)
        var set = AutomationPreferences(isEnabled: true, rules: [first, second])
        func effectiveArguments(_ preferences: AutomationPreferences) -> ([UUID: ProtectionRuleValidation], [UUID: [String]]) {
            var results: [UUID: ProtectionRuleValidation] = [:]
            var arguments: [UUID: [String]] = [:]
            for rule in preferences.rules {
                let result = ProtectionRuleValidator.validate(rule, in: preferences, displays: inventory)
                results[rule.id] = result
                if rule.isEnabled, let values = result.arguments { arguments[rule.id] = values }
            }
            return (results, arguments)
        }
        let (validations, arguments) = effectiveArguments(set)
        XCTAssertTrue(validations.values.allSatisfy(\.isRunnable))
        coordinator.reconcile(ruleSet: set, validations: validations, arguments: arguments)
        try await waitForLogLines(2, at: log)
        XCTAssertTrue(coordinator.hasManagedProcess)
        XCTAssertTrue(try coordinator.sendControl(.blackoutNow))
        try await waitForLogLines(4, at: log)
        try await waitUntil { coordinator.blackedOutDisplayIDs == [1] }
        XCTAssertTrue(try coordinator.sendControl(.restore))
        try await waitForLogLines(6, at: log)

        set.rules[0].settings.idleSeconds = 150
        let (changedValidations, changedArguments) = effectiveArguments(set)
        coordinator.reconcile(ruleSet: set, validations: changedValidations, arguments: changedArguments)
        try await waitForLogLines(10, at: log)
        let afterRestart = try String(contentsOf: log, encoding: .utf8).components(separatedBy: .newlines).filter { !$0.isEmpty }
        let launches = afterRestart.filter { $0.hasPrefix("launch:") }
        XCTAssertEqual(launches.count, 4)
        XCTAssertEqual(afterRestart.filter { $0 == "term" }.count, 2)
        XCTAssertEqual(launches.filter { $0.contains("--idle-after 120") }.count, 1)
        XCTAssertEqual(launches.filter { $0.contains("--idle-after 300") }.count, 2)
        XCTAssertEqual(launches.filter { $0.contains("--idle-after 150") }.count, 1)
        XCTAssertEqual(launches.filter { $0.contains("--panelctl-rule \(first.id.uuidString)") }.count, 2)
        XCTAssertEqual(launches.filter { $0.contains("--panelctl-rule \(second.id.uuidString)") }.count, 2)
        var disabledSettings = ProtectionPreferences()
        disabledSettings.selectedDisplayUUIDs = [inventory[2].uuid!]
        set.rules.append(ProtectionRule(name: "Disabled", isEnabled: false, settings: disabledSettings))
        let (disabledValidations, disabledArguments) = effectiveArguments(set)
        coordinator.reconcile(ruleSet: set, validations: disabledValidations, arguments: disabledArguments)
        try await Task.sleep(nanoseconds: 80_000_000)
        let afterDisabledEdit = try String(contentsOf: log, encoding: .utf8).components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(afterDisabledEdit.filter { $0.hasPrefix("launch:") }.count, 4)
        await withCheckedContinuation { continuation in coordinator.shutdown { continuation.resume() } }
    }

    @MainActor
    func testAggregateStatusAndMasterControlsCoverMultipleEnabledRules() async throws {
        let helper = try makeHelper(cleanup: false)
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent()) }
        let log = helper.deletingLastPathComponent().appendingPathComponent("events.log")
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_LOG", log.path, 1)
        defer { unsetenv("PANELCTL_HELPER"); unsetenv("PANELCTL_TEST_LOG") }
        let suite = "panelctl-rules-aggregate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var quickSettings = ProtectionPreferences()
        quickSettings.selectedDisplayUUIDs = [inventory[0].uuid!]
        quickSettings.idleSeconds = 120
        quickSettings.mode = .working
        var quietSettings = ProtectionPreferences()
        quietSettings.selectedDisplayUUIDs = [inventory[1].uuid!]
        quietSettings.idleSeconds = 300
        let quick = ProtectionRule(name: "Quick dimming", isEnabled: true, settings: quickSettings)
        let quiet = ProtectionRule(name: "Quiet blackout", isEnabled: true, settings: quietSettings)
        let set = AutomationPreferences(isEnabled: true, rules: [quick, quiet])
        defaults.set(try JSONEncoder().encode(set), forKey: "automationRules")
        let coordinatorDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: coordinatorDirectory) }
        let model = AppModel(
            defaults: defaults,
            displayProvider: { self.inventory },
            idleSecondsProvider: { 0 },
            inspectHandoff: { DisplayHandoffStatus(state: .none, journalPath: "/tmp/no-display-recovery.json") },
            protectionCoordinator: makeCoordinator(directory: coordinatorDirectory)
        )
        try await waitUntil { model.controlRuleStatuses.count == 2 && model.controlRuleStatuses.allSatisfy { $0.state == "waiting" } }
        let delegate = AppDelegate()
        delegate.model = model
        let status = await delegate.handleControlRequest(
            AppControlRequest(command: .status), receivedAt: .now
        )
        XCTAssertTrue(status.enabled, "top-level enabled reflects the master switch")
        XCTAssertEqual(status.state, "waiting")
        XCTAssertEqual(status.rules?.map(\.id), [quick.id, quiet.id])
        XCTAssertEqual(status.rules?.map(\.name), ["Quick dimming", "Quiet blackout"])
        XCTAssertEqual(status.rules?.map(\.state), ["waiting", "waiting"])
        XCTAssertEqual(status.nextAction, "dim", "top-level timer reports the soonest enabled rule")
        XCTAssertEqual(status.secondsRemaining, 120)
        XCTAssertTrue(status.summary.contains("2 rules"))

        _ = await delegate.handleControlRequest(AppControlRequest(command: .disable), receivedAt: .now)
        XCTAssertFalse(model.automationPreferences.isEnabled)
        XCTAssertTrue(model.automationPreferences.rules.allSatisfy(\.isEnabled), "master disable leaves per-rule flags unchanged")
        _ = await delegate.handleControlRequest(AppControlRequest(command: .enable), receivedAt: .now)
        try await waitUntil { model.controlRuleStatuses.allSatisfy { $0.state == "waiting" } }
        _ = await delegate.handleControlRequest(
            AppControlRequest(command: .snooze, durationSeconds: 60), receivedAt: .now
        )
        XCTAssertTrue(model.automationPreferences.isEnabled)
        XCTAssertTrue(model.automationPreferences.rules.allSatisfy(\.isEnabled))
        XCTAssertTrue(model.controlRuleStatuses.allSatisfy { $0.state == "snoozed" })
        _ = await delegate.handleControlRequest(AppControlRequest(command: .resume), receivedAt: .now)
        try await waitUntil { model.controlRuleStatuses.allSatisfy { $0.state == "waiting" } }

        await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
    }

    @MainActor
    func testUnresolvedDeletedRuleJournalBlocksAndRetryRemovesOnlyVerifiedEmptyDirectory() async throws {
        let helper = try makeHelper(cleanup: true)
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent()) }
        setenv("PANELCTL_HELPER", helper.path, 1)
        defer { unsetenv("PANELCTL_HELPER") }
        let journalDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: journalDirectory) }
        let deletedID = UUID()
        let deletedDirectory = journalDirectory.appendingPathComponent(deletedID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: deletedDirectory, withIntermediateDirectories: true)
        try Data("journal evidence".utf8).write(to: deletedDirectory.appendingPathComponent("blackout-luminance.json"))
        var deletedJournalVerified = false
        let coordinator = ProtectionCoordinator(
            verifyJournal: { id in
                guard let id else { return true }
                return id != deletedID || deletedJournalVerified
            },
            ruleJournalDirectory: journalDirectory,
            serviceFactory: { id in
                ProtectionService(
                    cleanupRuleID: id,
                    cleanupIsVerified: { id != deletedID || deletedJournalVerified }
                )
            }
        )
        var settings = ProtectionPreferences()
        settings.selectedDisplayUUIDs = [inventory[0].uuid!]
        let rule = ProtectionRule(name: "Current", isEnabled: true, settings: settings)
        let set = AutomationPreferences(isEnabled: true, rules: [rule])
        coordinator.reconcile(
            ruleSet: set,
            validations: [:],
            arguments: [rule.id: ["blackout", "current"]]
        )
        XCTAssertFalse(coordinator.hasManagedProcess)
        XCTAssertEqual(coordinator.runtimeState(for: rule.id, automationEnabled: true, snoozedUntil: nil)
            .errorMessage, "Automation cleanup couldn’t confirm brightness was restored.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: deletedDirectory.path))

        var firstRetry: Bool?
        coordinator.retryCleanup { succeeded, _ in firstRetry = succeeded }
        try await waitUntil { firstRetry != nil }
        XCTAssertFalse(firstRetry ?? true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: deletedDirectory.path), "unverified journals are retained")

        deletedJournalVerified = true
        var secondRetry: Bool?
        coordinator.retryCleanup { succeeded, _ in secondRetry = succeeded }
        try await waitUntil { secondRetry != nil }
        XCTAssertTrue(secondRetry ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedDirectory.path), "verified empty deleted-rule directory is removed")
        await withCheckedContinuation { continuation in coordinator.shutdown { continuation.resume() } }
    }

    private var inventory: [DisplayRecord] {
        [
            display(1, "00000000-0000-0000-0000-00000000000a"),
            display(2, "00000000-0000-0000-0000-00000000000b"),
            display(3, "00000000-0000-0000-0000-00000000000c")
        ]
    }

    private func display(_ index: Int, _ uuid: String) -> DisplayRecord {
        DisplayRecord(
            index: index, id: UInt32(index), uuid: uuid, name: "Display \(index)",
            active: true, online: true, asleep: false, builtin: false, main: index == 1,
            vendor: 0, model: 0, serial: 0,
            bounds: DisplayBounds(CGRect(x: Double((index - 1) * 100), y: 0, width: 100, height: 100)),
            pixelWidth: 100, pixelHeight: 100
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("panelctl-rules-\(UUID().uuidString)", isDirectory: true)
    }

    @MainActor
    private func makeCoordinator(directory: URL) -> ProtectionCoordinator {
        ProtectionCoordinator(
            verifyJournal: { _ in true },
            ruleJournalDirectory: directory,
            removeDeletedDirectories: false,
            serviceFactory: { id in ProtectionService(cleanupRuleID: id, cleanupIsVerified: { true }) }
        )
    }

    private func makeHelper(cleanup: Bool) throws -> URL {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("fake-panelctl")
        let body: String
        if cleanup {
            body = """
            #!/bin/bash
            if [[ "$PANELCTL_CLEANUP_ONLY" == "1" ]]; then
                printf '{"state":"stopped","blackedOutDisplayIDs":[],"cleanupSucceeded":true}\\n'
                exit 0
            fi
            printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
            trap 'printf "term\\n" >> "$PANELCTL_TEST_LOG"; exit 0' TERM
            while IFS= read -r command; do printf 'command:%s\\n' "$command" >> "$PANELCTL_TEST_LOG"; done
            """
        } else {
            body = """
            #!/bin/bash
            printf 'launch:%s\\n' "$*" >> "$PANELCTL_TEST_LOG"
            printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
            trap 'printf "term\\n" >> "$PANELCTL_TEST_LOG"; exit 0' TERM
            while IFS= read -r command; do
                printf 'command:%s\\n' "$command" >> "$PANELCTL_TEST_LOG"
                if [[ "$command" == "blackout-now" ]]; then
                    printf '{"state":"blacked_out","blackedOutDisplayIDs":[1]}\\n'
                elif [[ "$command" == "restore" ]]; then
                    printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
                fi
            done
            """
        }
        try Data(body.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return helper
    }

    private func waitForLogLines(_ expected: Int, at url: URL) async throws {
        for _ in 0..<200 {
            let lines = (try? String(contentsOf: url, encoding: .utf8))?
                .components(separatedBy: .newlines).filter { !$0.isEmpty } ?? []
            if lines.count >= expected { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(expected) helper events")
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}
