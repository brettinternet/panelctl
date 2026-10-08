import XCTest
import CoreGraphics
import AppKit
@testable import PanelCtlApp
@testable import PanelCtlCore

@MainActor
final class ProtectionRuleRunOnceTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    private let firstUUID = "00000000-0000-0000-0000-00000000000A"
    private let secondUUID = "00000000-0000-0000-0000-00000000000B"

    func testHiddenDisplayRunOnceUsesSafeOverlayAndResumesTimer() async throws {
        let cases: [(Bool, FollowUpAction, Bool)] = [
            (false, .sleepDisplays, false), (true, .sleepDisplays, false),
            (false, .untilActivity, false), (true, .restore, true)
        ]
        for (enabled, followUp, snoozed) in cases {
            try await withHelper(mode: "hold") { log in
                var selected = rule(id: UUID(), name: "OLED", displayUUID: firstUUID, enabled: enabled)
                selected.settings.selectedDisplayUUIDs.insert(secondUUID)
                selected.settings.followUpAction = followUp
                selected.settings.hardwareDimmingEnabled = true
                selected.settings.deferBlackoutWhileCameraInUse = true
                let preferences = AutomationPreferences(isEnabled: enabled, rules: [selected])
                let status = hiddenStatus()
                let (model, defaults, suite, journals) = try makeModel(
                    preferences: preferences,
                    snoozeUntil: snoozed ? fixedNow.addingTimeInterval(600) : nil,
                    inspectHandoff: { status }
                )
                defer {
                    defaults.removePersistentDomain(forName: suite)
                    try? FileManager.default.removeItem(at: journals)
                }
                try await wait { !model.protectionQuiescencePending }
                if enabled && !snoozed {
                    try await wait { launchLines(at: log).contains { $0.contains("--watch") } }
                }
                let response = await model.runProtectionRule(id: selected.id)
                XCTAssertEqual(response.outcome, .done, response.summary)
                let line = try XCTUnwrap(launchLines(at: log).first { $0.contains("--panelctl-run-once") })
                guard case .blackout(let options) = try CLIParser.parse(line.split(separator: " ").map(String.init)) else {
                    return XCTFail("Expected blackout command")
                }
                XCTAssertNoThrow(try BlackoutController.validateOptions(options))
                XCTAssertEqual(options.selectors, [firstUUID])
                XCTAssertEqual(options.hiddenMirrorSourceUUIDs, [firstUUID])
                XCTAssertEqual(options.ruleID, selected.id)
                XCTAssertTrue(options.runOnce)
                XCTAssertFalse(options.watch)
                XCTAssertNil(options.idleAfter)
                XCTAssertNil(options.sleepAfter)
                XCTAssertNil(options.hardwareBrightnessPercent)
                XCTAssertFalse(options.keepDisplaysAwake)
                XCTAssertFalse(options.deferPlayback)
                XCTAssertFalse(options.deferCamera)
                XCTAssertEqual(options.timeout, followUp == .untilActivity ? 86_400 : 60)
                XCTAssertEqual(options.mode, .blocking)
                XCTAssertEqual(options.overlayOpacityPercent, 100)
                XCTAssertEqual(model.handoffStatus, status)
                XCTAssertEqual(model.automationPreferences, preferences)
                XCTAssertTrue(try model.restoreBlackout())
                try await wait { model.controlRunningRule == nil }
                if enabled && !snoozed {
                    try await wait { launchLines(at: log).filter { $0.contains("--watch") }.count == 2 }
                } else {
                    XCTAssertFalse(launchLines(at: log).contains { $0.contains("--watch") })
                }
                XCTAssertEqual(model.handoffStatus, status, "Restore must not Show hidden displays")
                await shutdown(model)
            }
        }
    }

    func testHiddenDisplayRunOnceRefusesUnverifiedRecovery() async throws {
        for status in [hiddenStatus(verified: false), hiddenStatus(state: .recovery), hiddenStatus(sourceID: 99)] {
            try await withHelper(mode: "hold") { log in
                let selected = rule(id: UUID(), name: "OLED", displayUUID: firstUUID, enabled: false)
                let (model, defaults, suite, journals) = try makeModel(
                    preferences: AutomationPreferences(isEnabled: false, rules: [selected]),
                    inspectHandoff: { status }
                )
                defer {
                    defaults.removePersistentDomain(forName: suite)
                    try? FileManager.default.removeItem(at: journals)
                }
                try await wait { !model.protectionQuiescencePending }
                let response = await model.runProtectionRule(id: selected.id)
                XCTAssertEqual(response.outcome, .recoveryNeeded, response.summary)
                XCTAssertTrue(launchLines(at: log).isEmpty)
                XCTAssertEqual(model.handoffStatus, status)
                await shutdown(model)
            }
        }
    }

    private func hiddenStatus(
        verified: Bool = true, state: DisplayHandoffStatus.State = .hidden, sourceID: UInt32 = 1
    ) -> DisplayHandoffStatus {
        func identity(_ id: UInt32, _ uuid: String) -> DisplayHandoffIdentity {
            DisplayHandoffIdentity(DisplayHideIdentity(
                uuid: uuid, displayID: id, name: "Display", vendor: 0, model: 0, serial: 0
            ))
        }
        return DisplayHandoffStatus(
            state: state, target: identity(2, secondUUID), source: identity(sourceID, firstUUID),
            journalPath: "/tmp/no-run-rule-recovery.json", journalID: "hidden-fixture",
            canShow: true, mirrorTopologyVerified: verified
        )
    }

    func testSettingsCommandKeepsStableIdentityAfterRenameAndReorder() async throws {
        try await withHelper(mode: "hold") { _ in
            let selected = rule(id: UUID(), name: "Original", displayUUID: firstUUID, enabled: false)
            let other = rule(id: UUID(), name: "Other", displayUUID: secondUUID, enabled: false)
            let (model, defaults, suite, journals) = try makeModel(
                preferences: AutomationPreferences(isEnabled: false, rules: [selected, other])
            )
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: journals)
            }
            let command = try XCTUnwrap(model.protectionRuleCommandLine(id: selected.id))
            XCTAssertEqual(command, AppControlCommand.runRule.commandLine(
                executable: try ProtectionService.helperExecutableURL().path, ruleID: selected.id
            ))
            var renamed = selected
            renamed.name = "Renamed 'rule'"
            model.automationPreferences.rules = [other, renamed]
            XCTAssertEqual(model.protectionRuleCommandLine(id: selected.id), command)
            XCTAssertTrue(command.hasSuffix(" app run-rule --rule \(selected.id.uuidString)"))
            await shutdown(model)
        }
    }

    func testMenuDispatchRunsOnlySelectedDisabledRuleAndPreventsRestart() async throws {
        try await withHelper(mode: "hold") { log in
            var selected = rule(id: UUID(), name: "Selected", displayUUID: firstUUID, enabled: false)
            selected.settings.mode = .working
            let other = rule(id: UUID(), name: "Other", displayUUID: secondUUID, enabled: false)
            let preferences = AutomationPreferences(isEnabled: true, rules: [other, selected])
            let snooze = fixedNow.addingTimeInterval(600)
            let (model, defaults, suite, journals) = try makeModel(preferences: preferences, snoozeUntil: snooze)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: journals)
            }
            let missing = UUID()
            let priorRefusal = await model.runProtectionRule(id: missing)
            XCTAssertEqual(priorRefusal.outcome, .refused)
            XCTAssertEqual(model.protectionRuleRunStatus(id: missing), "Last attempt: \(priorRefusal.summary)")
            let delegate = AppDelegate()
            delegate.model = model
            let submenu = try XCTUnwrap(delegate.makeMenu().items.first { $0.title == "Run rule" }?.submenu)
            XCTAssertEqual(submenu.items.map(\.title), ["Other (Off)", "Selected (Off)"])
            let entry = try XCTUnwrap(submenu.items.last)
            XCTAssertTrue(entry.isEnabled)
            XCTAssertEqual(entry.representedObject as? UUID, selected.id)
            XCTAssertEqual(entry.action, #selector(AppDelegate.runRuleFromMenu(_:)))
            delegate.runRuleFromMenu(entry)
            try await wait { model.protectionRuleRunResults[selected.id] != nil }
            XCTAssertEqual(model.protectionRuleRunResults[selected.id]?.outcome, .done)
            XCTAssertEqual(model.controlRunningRule?.id, selected.id)
            XCTAssertEqual(model.protectionRuleRunStatus(id: selected.id), "Running once — Restore ends this run.")
            XCTAssertEqual(model.protectionRuleRunStatus(id: missing), model.protectionRuleRunBlocker(id: missing))
            XCTAssertTrue(model.protectionRuleRunStatus(id: missing)?.contains("Another one-shot") == true)
            let activeMenu = try XCTUnwrap(delegate.makeMenu().items.first { $0.title == "Run rule" }?.submenu)
            XCTAssertEqual(activeMenu.items.last?.title, "Selected (Off) — Running once")
            XCTAssertFalse(try XCTUnwrap(activeMenu.items.last).isEnabled)
            let repeated = await model.runProtectionRule(id: selected.id)
            XCTAssertEqual(repeated.outcome, .busy)
            XCTAssertEqual(launchLines(at: log).count, 1)
            XCTAssertEqual(model.automationPreferences, preferences)
            XCTAssertEqual(model.snoozedUntil, snooze)
            XCTAssertNil(model.protectionRuleRunResults[other.id])
            XCTAssertTrue(try model.restoreBlackout())
            try await wait { model.controlRunningRule == nil }
            XCTAssertNil(model.protectionRuleRunBlocker(id: selected.id))
            XCTAssertEqual(model.protectionRuleRunStatus(id: selected.id), "Last attempt: \(repeated.summary)")
            await shutdown(model)
        }
    }

    func testSettingsRunPresentsSameRefusalAndFailureAsCLI() async throws {
        try await withHelper(mode: "fail") { _ in
            let selected = rule(id: UUID(), name: "Selected", displayUUID: firstUUID, enabled: false)
            let preferences = AutomationPreferences(isEnabled: false, rules: [selected])
            let (model, defaults, suite, journals) = try makeModel(preferences: preferences)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: journals)
            }
            let missing = UUID()
            let cli = await model.handleProtectionRuleControlRequest(AppControlRequest(command: .runRule, ruleID: missing))
            let ui = await model.runProtectionRule(id: missing)
            XCTAssertEqual(ui.outcome, cli.outcome)
            XCTAssertEqual(ui.summary, cli.summary)
            XCTAssertEqual(model.protectionRuleRunStatus(id: missing), "Last attempt: \(cli.summary)")
            let failed = await model.runProtectionRule(id: selected.id)
            XCTAssertEqual(failed.outcome, .failed)
            XCTAssertEqual(model.protectionRuleRunResults[selected.id]?.summary, failed.summary)
            XCTAssertEqual(model.protectionRuleRunStatus(id: selected.id), "Last attempt: \(failed.summary)")
            XCTAssertEqual(model.automationPreferences, preferences)
            await shutdown(model)
        }
    }

    func testEnabledRuleRunsOnceInIsolationThenAutomaticSchedulingResumes() async throws {
        try await withHelper(mode: "finish") { log in
            let first = rule(id: UUID(), name: "First", displayUUID: firstUUID, enabled: true)
            let second = rule(id: UUID(), name: "Second", displayUUID: secondUUID, enabled: true)
            let preferences = AutomationPreferences(isEnabled: true, rules: [first, second])
            let (model, defaults, suite, journals) = try makeModel(preferences: preferences)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: journals)
            }
            try await wait { launchLines(at: log).count == 2 }
            try await wait { model.runtimeState == .waiting }

            let response = await model.handleProtectionRuleControlRequest(
                AppControlRequest(command: .runRule, ruleID: first.id)
            )
            XCTAssertEqual(response.outcome, .done)
            XCTAssertEqual(response.runningRule?.id, first.id)
            XCTAssertEqual(model.automationPreferences, preferences)
            try await wait {
                model.controlRunningRule == nil &&
                    launchLines(at: log).filter { $0.contains("--panelctl-rule \(first.id.uuidString)") && $0.contains("--watch") }.count == 2
            }
            let lines = launchLines(at: log)
            let oneShotLine = try XCTUnwrap(lines.first { $0.contains("--panelctl-rule \(first.id.uuidString)") && $0.contains("--panelctl-run-once") })
            XCTAssertTrue(oneShotLine.contains("--ignore-playback"), "manual one-shot matches manual-command deferral behavior")
            XCTAssertFalse(oneShotLine.contains("--defer-camera"))
            XCTAssertTrue(oneShotLine.contains("--timeout 60"), "the saved follow-up is preserved")
            XCTAssertEqual(lines.filter { $0.contains("--panelctl-rule \(second.id.uuidString)") && $0.contains("--watch") }.count, 1)
            XCTAssertFalse(lines.contains { $0.contains("--panelctl-rule \(second.id.uuidString)") && $0.contains("--panelctl-run-once") })
            XCTAssertEqual(
                try JSONDecoder().decode(AutomationPreferences.self, from: XCTUnwrap(defaults.data(forKey: "automationRules"))),
                preferences
            )
            await shutdown(model)
        }
    }

    func testDisabledRuleRunsWhileSnoozedWithoutChangingPreferencesOrSnooze() async throws {
        try await withHelper(mode: "hold") { log in
            let disabled = rule(id: UUID(), name: "Disabled rule", displayUUID: firstUUID, enabled: false)
            let preferences = AutomationPreferences(isEnabled: true, rules: [disabled])
            let snoozeExpiry = fixedNow.addingTimeInterval(600)
            let (model, defaults, suite, journals) = try makeModel(preferences: preferences, snoozeUntil: snoozeExpiry)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: journals)
            }

            let request = Task {
                await model.handleProtectionRuleControlRequest(
                    AppControlRequest(command: .runRule, ruleID: disabled.id)
                )
            }
            try await wait { model.controlRunningRule?.id == disabled.id }
            let response = await request.value
            XCTAssertEqual(response.outcome, .done)
            XCTAssertEqual(response.runningRule?.id, disabled.id)
            XCTAssertEqual(model.controlRuleStatuses.first?.state, "running-once")
            XCTAssertEqual(model.snoozedUntil, snoozeExpiry)
            XCTAssertEqual(model.automationPreferences, preferences)
            XCTAssertEqual(defaults.object(forKey: "snoozedUntil") as? Date, snoozeExpiry)
            XCTAssertEqual(
                try JSONDecoder().decode(AutomationPreferences.self, from: XCTUnwrap(defaults.data(forKey: "automationRules"))),
                preferences
            )
            XCTAssertTrue(try model.restoreBlackout(), "Restore must stop a one-shot even while automation is snoozed")
            try await wait { model.controlRunningRule == nil }
            XCTAssertEqual(launchLines(at: log).count, 1, "disabled and snoozed settings must not re-arm a watcher")
            await shutdown(model)
        }
    }

    func testSnoozeExpiryKeepsLiveOneShotJournalOwnedAndResumesSibling() async throws {
        try await withHelper(mode: "hold") { log in
            let first = rule(id: UUID(), name: "One shot", displayUUID: firstUUID, enabled: true)
            let sibling = rule(id: UUID(), name: "Sibling", displayUUID: secondUUID, enabled: true)
            let preferences = AutomationPreferences(isEnabled: true, rules: [first, sibling])
            let snoozeExpiry = fixedNow.addingTimeInterval(600)
            var currentNow = fixedNow
            var liveJournalIsLocked = false
            let verifyJournal: (UUID?) -> Bool = { id in
                guard id == first.id else { return true }
                return !liveJournalIsLocked
            }
            let (model, defaults, suite, journals) = try makeModel(
                preferences: preferences,
                snoozeUntil: snoozeExpiry,
                nowProvider: { currentNow },
                verifyJournal: verifyJournal
            )
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: journals)
            }
            try FileManager.default.createDirectory(
                at: journals.appendingPathComponent(first.id.uuidString, isDirectory: true),
                withIntermediateDirectories: true
            )

            let request = Task {
                await model.handleProtectionRuleControlRequest(
                    AppControlRequest(command: .runRule, ruleID: first.id)
                )
            }
            let response = await request.value
            XCTAssertEqual(response.outcome, .done)
            XCTAssertEqual(model.controlRunningRule?.id, first.id)
            liveJournalIsLocked = true
            XCTAssertFalse(verifyJournal(first.id), "the live helper's journal cannot be externally verified")

            currentNow = snoozeExpiry.addingTimeInterval(1)
            model.refreshCountdown()
            try await wait {
                launchLines(at: log).contains {
                    $0.contains("--panelctl-rule \(sibling.id.uuidString)") && $0.contains("--watch")
                }
            }
            XCTAssertNil(model.protectionQuiescenceFailure, "the managed one-shot owns its unverifyable journal")
            XCTAssertEqual(model.controlRunningRule?.id, first.id, "reconciliation must retain the one-shot helper")
            XCTAssertEqual(model.automationPreferences, preferences)
            XCTAssertNil(model.snoozedUntil)

            XCTAssertTrue(try model.restoreBlackout())
            try await wait { model.controlRunningRule == nil }
            await shutdown(model)
        }
    }

    func testDisabledPersistentBlockingOneShotKeepsEscapeFocusAndRestores() async throws {
        for (hidden, snoozed) in [(false, false), (true, false), (true, true)] {
            try await withHelper(mode: "hold") { log in
                var disabled = rule(id: UUID(), name: "Disabled blocker", displayUUID: firstUUID, enabled: snoozed)
                disabled.settings.keepBlackoutOnInput = true
                disabled.settings.mode = hidden ? .working : .blocking
                let preferences = AutomationPreferences(isEnabled: snoozed, rules: [disabled])
                let (model, defaults, suite, journals) = try makeModel(
                    preferences: preferences,
                    snoozeUntil: snoozed ? fixedNow.addingTimeInterval(600) : nil,
                    inspectHandoff: hidden ? { self.hiddenStatus() } : nil
                )
                try await wait { !model.protectionQuiescencePending }
                defer {
                    defaults.removePersistentDomain(forName: suite)
                    try? FileManager.default.removeItem(at: journals)
                }

                let response = await model.handleProtectionRuleControlRequest(
                    AppControlRequest(command: .runRule, ruleID: disabled.id)
                )
                XCTAssertEqual(response.outcome, .done)
                try await wait { model.blackedOutDisplayIDs == [1] }
                let blockingIDs = model.automationBlockingDisplayIDs
                XCTAssertEqual(blockingIDs, [1], "effective blocking mode owns focus even when the saved Dim rule is disabled or snoozed")
                XCTAssertEqual(model.effectiveBlackoutMode(for: disabled), .blocking)
                XCTAssertTrue(launchLines(at: log).contains { $0.contains("--keep-blackout-on-input") })

                var escape: (() -> Void)?
                let focus = BlackoutFocusController(operations: BlackoutFocusOperations(
                    currentProcessIdentifier: 7,
                    frontmostApplication: { nil },
                    makeProxyWindow: { callback in
                        escape = callback
                        return BlackoutFocusWindow(show: {}, close: {})
                    },
                    requestActivation: {},
                    panelIsActive: { true },
                    mouseLocation: { CGPoint(x: 50, y: 50) },
                    hideCursor: { .success },
                    showCursor: { .success },
                    schedule: { $0() },
                    activationTimeout: 0
                )) {
                    (try? model.restoreBlackout()) ?? false
                }
                let displayFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
                focus.enter(targetFrames: blockingIDs.contains(1) ? [displayFrame] : [])
                XCTAssertTrue(focus.isEngaged, "focus proxy must cover the one-shot's blocking display")
                escape?()
                try await wait { model.controlRunningRule == nil }
                XCTAssertEqual(launchLines(at: log).filter { $0.contains("--panelctl-run-once") }.count, 1)
                focus.shutdown()
                XCTAssertEqual(model.effectiveBlackoutMode(for: disabled), disabled.settings.mode)
                XCTAssertEqual(model.automationPreferences, preferences)
                await shutdown(model)
            }
        }
    }

    func testGloballyDisabledAutomationCanRunOnceWithoutRearming() async throws {
        try await withHelper(mode: "finish") { log in
            let enabled = rule(id: UUID(), name: "Enabled rule", displayUUID: firstUUID, enabled: true)
            let preferences = AutomationPreferences(isEnabled: false, rules: [enabled])
            let (model, defaults, suite, journals) = try makeModel(preferences: preferences)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: journals)
            }

            let response = await model.handleProtectionRuleControlRequest(
                AppControlRequest(command: .runRule, ruleID: enabled.id)
            )
            XCTAssertEqual(response.outcome, .done)
            try await wait { model.controlRunningRule == nil }
            XCTAssertEqual(model.automationPreferences, preferences)
            XCTAssertEqual(launchLines(at: log).filter { $0.contains("--panelctl-run-once") }.count, 1)
            XCTAssertEqual(launchLines(at: log).filter { $0.contains("--watch") }.count, 0)
            await shutdown(model)
        }
    }

    func testNewConflictingAutomaticRuleWaitsUntilOneShotCleanup() async throws {
        try await withHelper(mode: "hold") { log in
            let selected = rule(id: UUID(), name: "One shot", displayUUID: firstUUID, enabled: false)
            let competing = rule(id: UUID(), name: "Competing", displayUUID: firstUUID, enabled: false)
            let preferences = AutomationPreferences(isEnabled: true, rules: [selected, competing])
            let (model, defaults, suite, journals) = try makeModel(preferences: preferences)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: journals)
            }
            let request = Task {
                await model.handleProtectionRuleControlRequest(
                    AppControlRequest(command: .runRule, ruleID: selected.id)
                )
            }
            let response = await request.value
            XCTAssertEqual(response.outcome, .done)
            model.setProtectionRuleEnabled(true, id: competing.id)
            XCTAssertEqual(launchLines(at: log).filter { $0.contains("--watch") }.count, 0)
            XCTAssertTrue(try model.restoreBlackout())
            try await wait {
                model.controlRunningRule == nil &&
                    launchLines(at: log).contains { $0.contains("--panelctl-rule \(competing.id.uuidString)") && $0.contains("--watch") }
            }
            let lines = launchLines(at: log)
            XCTAssertEqual(lines.filter { $0.contains("--panelctl-run-once") }.count, 1)
            XCTAssertEqual(lines.filter { $0.contains("--panelctl-rule \(competing.id.uuidString)") && $0.contains("--watch") }.count, 1)
            await shutdown(model)
        }
    }

    func testDisjointUntimedRuleCannotCombineWithUntimedOneShotToCoverEveryDisplay() async throws {
        try await withHelper(mode: "hold") { log in
            var selected = rule(id: UUID(), name: "One shot", displayUUID: firstUUID, enabled: false)
            selected.settings.followUpAction = .untilActivity
            var other = rule(id: UUID(), name: "Other display", displayUUID: secondUUID, enabled: false)
            other.settings.followUpAction = .untilActivity
            let preferences = AutomationPreferences(isEnabled: true, rules: [selected, other])
            let (model, defaults, suite, journals) = try makeModel(preferences: preferences)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: journals)
            }
            let otherWatchCount = {
                self.launchLines(at: log).filter {
                    $0.contains("--panelctl-rule \(other.id.uuidString)") && $0.contains("--watch")
                }.count
            }

            let response = await model.handleProtectionRuleControlRequest(
                AppControlRequest(command: .runRule, ruleID: selected.id)
            )
            XCTAssertEqual(response.outcome, .done)
            model.setProtectionRuleEnabled(true, id: other.id)
            let enabled = try XCTUnwrap(model.automationPreferences.rules.first { $0.id == other.id })
            XCTAssertTrue(enabled.isEnabled)
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(otherWatchCount(), 0, "the untimed rules together would cover every display")
            XCTAssertTrue(model.protectionRuleRowStatus(for: enabled).headline.contains("running once"))

            XCTAssertTrue(try model.restoreBlackout())
            try await wait { model.controlRunningRule == nil && otherWatchCount() == 1 }
            var expected = preferences
            expected.rules[1].isEnabled = true
            XCTAssertEqual(model.automationPreferences, expected)
            await shutdown(model)
        }
    }

    func testDeletingRuleDuringOneShotEndsTheRun() async throws {
        try await withHelper(mode: "hold") { log in
            var selected = rule(id: UUID(), name: "Deleted while running", displayUUID: firstUUID, enabled: false)
            selected.settings.mode = .blocking
            selected.settings.followUpAction = .untilActivity
            selected.settings.keepBlackoutOnInput = true
            let preferences = AutomationPreferences(isEnabled: true, rules: [selected])
            let (model, defaults, suite, journals) = try makeModel(preferences: preferences)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: journals)
            }

            let response = await model.handleProtectionRuleControlRequest(
                AppControlRequest(command: .runRule, ruleID: selected.id)
            )
            XCTAssertEqual(response.outcome, .done)
            try await wait { model.automationBlockingDisplayIDs == [1] }

            model.deleteProtectionRule(id: selected.id)
            XCTAssertTrue(model.automationPreferences.rules.isEmpty)
            try await wait { model.controlRunningRule == nil && model.blackedOutDisplayIDs.isEmpty }
            XCTAssertTrue(model.automationBlockingDisplayIDs.isEmpty)
            XCTAssertEqual(launchLines(at: log).filter { $0.contains("--panelctl-run-once") }.count, 1)
            await shutdown(model)
        }
    }

    func testActiveSelectedRuleIsRefusedWithoutRestartingItsTimer() async throws {
        try await withHelper(mode: "active-watch") { log in
            let selected = rule(id: UUID(), name: "Already active", displayUUID: firstUUID, enabled: true)
            let preferences = AutomationPreferences(isEnabled: true, rules: [selected])
            let (model, defaults, suite, journals) = try makeModel(preferences: preferences)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: journals)
            }
            try await wait { model.runtimeState == .blackedOut }
            let originalLines = launchLines(at: log)

            let response = await model.handleProtectionRuleControlRequest(
                AppControlRequest(command: .runRule, ruleID: selected.id)
            )
            XCTAssertEqual(response.outcome, .busy)
            XCTAssertTrue(response.summary.contains("already active"))
            XCTAssertEqual(launchLines(at: log), originalLines, "refusal cannot restart the timer or launch a helper")
            XCTAssertEqual(model.runtimeState, .blackedOut)
            await shutdown(model)
        }
    }

    func testUnknownRuleIDIsRefusedWithoutStartingAnyHelper() async throws {
        try await withHelper(mode: "hold") { log in
            let saved = rule(id: UUID(), name: "Saved", displayUUID: firstUUID, enabled: false)
            let preferences = AutomationPreferences(isEnabled: false, rules: [saved])
            let (model, defaults, suite, journals) = try makeModel(preferences: preferences)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: journals)
            }
            let response = await model.handleProtectionRuleControlRequest(
                AppControlRequest(command: .runRule, ruleID: UUID())
            )
            XCTAssertEqual(response.outcome, .refused)
            XCTAssertTrue(response.summary.contains("No saved Automation rule"))
            XCTAssertTrue(launchLines(at: log).isEmpty)
            await shutdown(model)
        }
    }

    func testOverlappingEnabledRuleIsRefusedBeforeAnyHelperLaunch() async throws {
        try await withHelper(mode: "hold") { log in
            let first = rule(id: UUID(), name: "First", displayUUID: firstUUID, enabled: true)
            let second = rule(id: UUID(), name: "Conflicting", displayUUID: firstUUID, enabled: true)
            let preferences = AutomationPreferences(isEnabled: true, rules: [first, second])
            let (model, defaults, suite, journals) = try makeModel(preferences: preferences)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: journals)
            }
            let response = await model.handleProtectionRuleControlRequest(
                AppControlRequest(command: .runRule, ruleID: first.id)
            )
            XCTAssertEqual(response.outcome, .refused)
            XCTAssertTrue(response.summary.contains("Conflicting"))
            XCTAssertTrue(launchLines(at: log).isEmpty)
            await shutdown(model)
        }
    }

    func testAppDispatchAndStatusReportTheRunningRule() async throws {
        try await withHelper(mode: "hold") { log in
            let selected = rule(id: UUID(), name: "Dispatched", displayUUID: firstUUID, enabled: false)
            let preferences = AutomationPreferences(isEnabled: false, rules: [selected])
            let (model, defaults, suite, journals) = try makeModel(preferences: preferences)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: journals)
            }
            let app = AppDelegate()
            app.model = model
            let run = await app.handleControlRequest(
                AppControlRequest(command: .runRule, ruleID: selected.id),
                receivedAt: .now
            )
            XCTAssertEqual(run.outcome, .done)
            XCTAssertEqual(run.runningRule?.id, selected.id)
            let status = await app.handleControlRequest(AppControlRequest(command: .status), receivedAt: .now)
            XCTAssertEqual(status.runningRule?.id, selected.id)
            XCTAssertEqual(status.rules?.first(where: { $0.id == selected.id })?.state, "running-once")
            XCTAssertEqual(launchLines(at: log).count, 1, "status refresh must not restart or duplicate the one-shot")
            XCTAssertTrue(try model.restoreBlackout())
            try await wait { model.controlRunningRule == nil }
            await shutdown(model)
        }
    }

    func testHideIsBusyWhileOneShotOwnsItsSelectedDisplays() async throws {
        try await withHelper(mode: "hold") { log in
            let selected = rule(id: UUID(), name: "Running", displayUUID: firstUUID, enabled: false)
            let preferences = AutomationPreferences(isEnabled: false, rules: [selected])
            let (model, defaults, suite, journals) = try makeModel(preferences: preferences)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: journals)
            }
            let oneShot = Task {
                await model.handleProtectionRuleControlRequest(
                    AppControlRequest(command: .runRule, ruleID: selected.id)
                )
            }
            let oneShotResponse = await oneShot.value
            XCTAssertEqual(oneShotResponse.outcome, .done)
            let repeated = await model.handleProtectionRuleControlRequest(
                AppControlRequest(command: .runRule, ruleID: selected.id)
            )
            XCTAssertEqual(repeated.outcome, .busy)
            XCTAssertEqual(repeated.runningRule?.id, selected.id)
            let hide = await model.handleDisplayControlRequest(
                AppControlRequest(command: .hide, targetUUID: firstUUID)
            )
            XCTAssertEqual(hide.outcome, .busy)
            XCTAssertTrue(hide.summary.contains("running once"))
            XCTAssertTrue(try model.restoreBlackout())
            try await wait { model.controlRunningRule == nil }
            XCTAssertEqual(launchLines(at: log).count, 1)
            await shutdown(model)
        }
    }

    func testFailedOneShotReturnsFailureAndDoesNotReplayTheRun() async throws {
        try await withHelper(mode: "fail") { log in
            let selected = rule(id: UUID(), name: "Fails", displayUUID: firstUUID, enabled: true)
            let preferences = AutomationPreferences(isEnabled: true, rules: [selected])
            let (model, defaults, suite, journals) = try makeModel(preferences: preferences)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: journals)
            }
            try await wait { model.runtimeState == .waiting }

            let response = await model.handleProtectionRuleControlRequest(
                AppControlRequest(command: .runRule, ruleID: selected.id)
            )
            XCTAssertEqual(response.outcome, .failed)
            XCTAssertNotNil(response.error)
            try await wait {
                model.controlRunningRule == nil &&
                    launchLines(at: log).filter { $0.contains("--panelctl-rule \(selected.id.uuidString)") && $0.contains("--watch") }.count == 2
            }
            let lines = launchLines(at: log).filter { $0.contains("--panelctl-rule \(selected.id.uuidString)") }
            XCTAssertEqual(lines.filter { $0.contains("--panelctl-run-once") }.count, 1)
            XCTAssertEqual(lines.filter { $0.contains("--watch") }.count, 2, "normal automatic scheduling may resume, but the one-shot is never replayed")
            await shutdown(model)
        }
    }

    func testRequestsReceivedDuringOneShotStayBusyAfterCleanup() async throws {
        try await withHelper(mode: "hold") { log in
            let selected = rule(id: UUID(), name: "Run once", displayUUID: firstUUID, enabled: false)
            let preferences = AutomationPreferences(isEnabled: false, rules: [selected])
            var currentDisplays = inventory
            let (model, defaults, suite, journals) = try makeModel(
                preferences: preferences,
                displayProvider: { currentDisplays }
            )
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: journals)
            }
            let action = DisplayAction(
                name: "Black out",
                target: DisplayIdentitySnapshot(try XCTUnwrap(currentDisplays.first))
            )
            try model.saveDisplayAction(action)

            let run = Task {
                await model.handleProtectionRuleControlRequest(
                    AppControlRequest(command: .runRule, ruleID: selected.id)
                )
            }
            let started = await run.value
            XCTAssertEqual(started.outcome, .done)
            let receivedDuringOneShot = ContinuousClock.now
            XCTAssertEqual(model.controlRunningRule?.id, selected.id)
            XCTAssertTrue(try model.restoreBlackout())
            try await wait { model.controlRunningRule == nil }

            let repeatedRun = await model.handleProtectionRuleControlRequest(
                AppControlRequest(command: .runRule, ruleID: selected.id),
                receivedAt: receivedDuringOneShot
            )
            XCTAssertEqual(repeatedRun.outcome, .busy, "a run-rule request received during the completed run is never replayed")
            XCTAssertEqual(launchLines(at: log).filter { $0.contains("--panelctl-run-once") }.count, 1)

            currentDisplays = []
            for command in [AppControlCommand.hide, .show, .toggleHide] {
                let response = await model.handleDisplayControlRequest(
                    AppControlRequest(command: command, targetUUID: firstUUID),
                    receivedAt: receivedDuringOneShot
                )
                XCTAssertEqual(response.outcome, .busy, "\(command) received during a one-shot must not execute after cleanup")
            }
            let actionResponse = await model.handleDisplayControlRequest(
                AppControlRequest(command: .runAction, actionID: action.id),
                receivedAt: receivedDuringOneShot
            )
            XCTAssertEqual(actionResponse.outcome, .busy, "an Action received during a one-shot must not run after cleanup")
            XCTAssertEqual(launchLines(at: log).filter { $0.contains("--panelctl-run-once") }.count, 1)
            await shutdown(model)
        }
    }

    private func rule(id: UUID, name: String, displayUUID: String, enabled: Bool) -> ProtectionRule {
        var settings = ProtectionPreferences()
        settings.selectedDisplayUUIDs = [displayUUID]
        settings.didChooseDisplays = true
        settings.followUpAction = .restore
        settings.followUpSeconds = 60
        return ProtectionRule(id: id, name: name, isEnabled: enabled, settings: settings)
    }

    private func makeModel(
        preferences: AutomationPreferences,
        snoozeUntil: Date? = nil,
        nowProvider: (() -> Date)? = nil,
        displayProvider: (() -> [DisplayRecord])? = nil,
        verifyJournal: ((UUID?) -> Bool)? = nil,
        inspectHandoff: (() -> DisplayHandoffStatus)? = nil
    ) throws -> (AppModel, UserDefaults, String, URL) {
        let suite = "panelctl-run-rule-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(try JSONEncoder().encode(preferences), forKey: "automationRules")
        if let snoozeUntil { defaults.set(snoozeUntil, forKey: "snoozedUntil") }
        let journals = temporaryDirectory()
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
        let coordinator = ProtectionCoordinator(
            verifyJournal: verifyJournal ?? { _ in true },
            ruleJournalDirectory: journals,
            removeDeletedDirectories: false,
            serviceFactory: { id in
                ProtectionService(
                    cleanupRuleID: id,
                    cleanupIsVerified: { true },
                    displaysAreAsleep: { false }
                )
            }
        )
        let model = AppModel(
            defaults: defaults,
            displayProvider: displayProvider ?? { self.inventory },
            now: nowProvider ?? { self.fixedNow },
            idleSecondsProvider: { nil },
            isDisplayMirrored: { _ in false },
            inspectHandoff: inspectHandoff ?? { DisplayHandoffStatus(state: .none, journalPath: "/tmp/no-run-rule-recovery.json") },
            protectionCoordinator: coordinator
        )
        return (model, defaults, suite, journals)
    }

    private var inventory: [DisplayRecord] {
        [display(1, firstUUID), display(2, secondUUID)]
    }

    private func display(_ id: UInt32, _ uuid: String) -> DisplayRecord {
        DisplayRecord(
            index: Int(id), id: id, uuid: uuid, name: "Display \(id)",
            active: true, online: true, asleep: false, builtin: false, main: id == 1,
            vendor: 0, model: 0, serial: 0,
            bounds: DisplayBounds(CGRect(x: Double((id - 1) * 100), y: 0, width: 100, height: 100)),
            pixelWidth: 100, pixelHeight: 100
        )
    }

    private func withHelper(mode: String, body: (URL) async throws -> Void) async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("fake-panelctl")
        let log = directory.appendingPathComponent("launches.log")
        let script = """
        #!/bin/bash
        args=" $* "
        printf '%s\\n' "$*" >> "$PANELCTL_TEST_RUN_RULE_LOG"
        finish() {
            echo '{"state":"stopped","blackedOutDisplayIDs":[],"cleanupSucceeded":true}'
            exit 0
        }
        trap finish TERM
        if [[ "$args" == *" --watch "* ]]; then
            if [[ "$PANELCTL_TEST_RUN_RULE_MODE" == "active-watch" ]]; then
                printf '{"state":"blacked_out","blackedOutDisplayIDs":[1]}\\n'
            else
                printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
            fi
            while true; do /bin/sleep 0.02; done
        fi
        if [[ "$PANELCTL_TEST_RUN_RULE_MODE" == "fail" ]]; then
            printf '{"state":"stopped","blackedOutDisplayIDs":[],"cleanupSucceeded":true}\\n'
            exit 2
        fi
        printf '{"state":"blacked_out","blackedOutDisplayIDs":[1]}\\n'
        if [[ "$PANELCTL_TEST_RUN_RULE_MODE" == "finish" ]]; then
            /bin/sleep 0.08
            printf '{"state":"stopped","blackedOutDisplayIDs":[],"cleanupSucceeded":true}\\n'
            exit 0
        fi
        while true; do /bin/sleep 0.02; done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        setenv("PANELCTL_HELPER", helper.path, 1)
        setenv("PANELCTL_TEST_RUN_RULE_LOG", log.path, 1)
        setenv("PANELCTL_TEST_RUN_RULE_MODE", mode, 1)
        defer {
            unsetenv("PANELCTL_HELPER")
            unsetenv("PANELCTL_TEST_RUN_RULE_LOG")
            unsetenv("PANELCTL_TEST_RUN_RULE_MODE")
            try? FileManager.default.removeItem(at: directory)
        }
        try await body(log)
    }

    private func launchLines(at log: URL) -> [String] {
        (try? String(contentsOf: log, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).map(String.init) ?? []
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("panelctl-run-rule-\(UUID().uuidString)", isDirectory: true)
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for the one-shot helper")
    }

    private func shutdown(_ model: AppModel) async {
        await withCheckedContinuation { continuation in
            model.shutdown { continuation.resume() }
        }
    }
}
