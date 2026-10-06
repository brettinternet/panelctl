import XCTest
import CoreGraphics
@testable import PanelCtlApp
@testable import PanelCtlCore

@MainActor
final class DisplayActionAppTests: XCTestCase {
    private let mainUUID = "00000000-0000-0000-0000-000000000101"
    private let targetUUID = "00000000-0000-0000-0000-000000000102"
    private let sourceUUID = "00000000-0000-0000-0000-000000000103"
    private let alternateUUID = "00000000-0000-0000-0000-000000000104"

    private var displays: [DisplayRecord] {
        [
            display(index: 1, id: 101, uuid: mainUUID, name: "Main display", main: true),
            display(index: 2, id: 202, uuid: targetUUID, name: "Target display", main: false),
            display(index: 3, id: 303, uuid: sourceUUID, name: "Mirror source", main: false),
            display(index: 4, id: 404, uuid: alternateUUID, name: "Alternate source", main: false)
        ]
    }

    func testIdleActionEditorDoesNotTreatNewOrExistingActionAsRunning() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let model = makeModel(defaults: defaults)
        let draft = model.makeNewDisplayAction(selectedDisplayID: targetUUID)
        XCTAssertNil(model.runningDisplayAction)
        XCTAssertNil(model.displayActionValidation(for: draft))

        for existingID: UUID? in [nil, draft.id] {
            let editor = DisplayActionEditor(
                model: model, navigation: SettingsNavigation(), action: draft,
                existingID: existingID, isNew: existingID == nil
            )
            XCTAssertFalse(editor.editingActionIsRunning, "An idle editor must not disable Save as if its Action were running")
        }
    }

    func testNewActionDefaultsToUniqueNameWithoutSavingDraft() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let model = makeModel(defaults: defaults)
        let draft = model.makeNewDisplayAction(selectedDisplayID: targetUUID)
        XCTAssertEqual(draft.name, "New Action")
        XCTAssertEqual(draft.target?.uuid, targetUUID)
        XCTAssertEqual(draft.effect, .blackOut)
        XCTAssertNil(model.displayActionValidation(for: draft))
        XCTAssertTrue(model.displayActions.actions.isEmpty)
        XCTAssertEqual(model.makeNewDisplayAction().name, "New Action")
        XCTAssertNil(model.makeNewDisplayAction().target)

        var first = draft
        first.name = "new action"
        try model.saveDisplayAction(first)
        let second = model.makeNewDisplayAction(selectedDisplayID: targetUUID)
        XCTAssertEqual(second.name, "New Action 2")
        XCTAssertNil(model.displayActionValidation(for: second))
        try model.saveDisplayAction(second)
        XCTAssertEqual(model.makeNewDisplayAction().name, "New Action 3")
        XCTAssertEqual(model.displayActions.actions.count, 2)
    }

    func testActionsPersistVersionedAndRenameKeepsStableIDAndCommand() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(noneStatus())
        let model = makeModel(defaults: defaults, box: box)
        var draft = model.makeNewDisplayAction(selectedDisplayID: targetUUID)
        draft.name = "Hand off"
        draft.effect = .removeFromDesktop
        try model.saveDisplayAction(draft)
        let saved = try XCTUnwrap(model.displayActions.actions.first)
        XCTAssertEqual(saved.reviewedRemoval, ReviewedRemovalSetup(removeEnabled: true, sourceUUID: mainUUID, awayInput: 0x11))

        var renamed = saved
        renamed.name = "Work display handoff"
        try model.saveDisplayAction(renamed, replacing: saved.id)
        XCTAssertEqual(model.displayActions.actions.first?.id, saved.id)
        XCTAssertEqual(model.displayActions.actions.first?.name, "Work display handoff")
        XCTAssertEqual(
            AppControlCommand.runAction.commandLine(executable: "/bundle/panelctl", actionID: saved.id),
            "/bundle/panelctl app run-action --action \(saved.id.uuidString)"
        )

        let persisted = try XCTUnwrap(defaults.data(forKey: AppModel.displayActionsKey))
        let decoded = try JSONDecoder().decode(DisplayActionSet.self, from: persisted)
        XCTAssertEqual(decoded.version, DisplayActionSet.currentVersion)
        XCTAssertEqual(decoded.actions.first?.id, saved.id)
        XCTAssertEqual(decoded.actions.first?.name, "Work display handoff")
        let reloaded = makeModel(defaults: defaults, box: box)
        XCTAssertEqual(reloaded.displayActions, decoded)
    }

    func testRemovalReviewDetectsEveryReviewedFieldButIgnoresReturnInput() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let model = makeModel(defaults: defaults)
        let action = try saveRemovalAction(on: model)

        model.setHideEnabled(false, for: try XCTUnwrap(displays.first { $0.uuid == targetUUID }))
        model.setHideSource(alternateUUID, for: targetUUID)
        model.setHideSwitchInput(0x12, for: targetUUID)
        let change = try XCTUnwrap(model.displayActionReviewChange(for: action))
        XCTAssertTrue(change.message.contains("Remove from desktop On → Off"))
        XCTAssertTrue(change.message.contains("Mirror onto Main display → Alternate source"))
        XCTAssertTrue(change.message.contains("Switch monitor to HDMI 1 → HDMI 2"))
        XCTAssertTrue(model.displayActionRunBlocker(for: action)?.contains("Step 1:") == true)
        XCTAssertEqual(model.displayActionStatus(for: action), model.displayActionRunBlocker(for: action))
        var unreviewed = action
        unreviewed.reviewedRemoval = nil
        XCTAssertTrue(model.displayActionStatus(for: unreviewed).hasPrefix("Step 1:"))

        model.setHideEnabled(true, for: try XCTUnwrap(displays.first { $0.uuid == targetUUID }))
        var reviewedAgain = action
        try model.saveDisplayAction(reviewedAgain, replacing: action.id)
        reviewedAgain = try XCTUnwrap(model.displayActions.actions.first)
        XCTAssertNil(model.displayActionReviewChange(for: reviewedAgain))

        model.detectMacInput(for: targetUUID)
        XCTAssertNil(model.displayActionReviewChange(for: reviewedAgain), "read-only return-input detection is not a reviewed setup field")
    }

    func testConfiguredRemoveNeverFallsBackWhenExperimentalFeaturesAreOff() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var mirrorWrites = 0
        var coverRequests: [Set<UInt32>] = []
        let model = makeModel(
            defaults: defaults,
            hide: { _, _, _ in mirrorWrites += 1; return .notRequested },
            cover: { coverRequests.append($0); return [] }
        )
        let removal = try saveRemovalAction(on: model)
        model.setExperimentalFeaturesEnabled(false)
        let refusal = await run(model, id: removal.id)
        XCTAssertEqual(refusal.outcome, .refused)
        XCTAssertTrue(refusal.error?.contains("Experimental features") == true)
        XCTAssertEqual(mirrorWrites, 0)
        XCTAssertFalse(coverRequests.contains([202]), "a refused Remove action is not converted to Black out")

        var blackOut = DisplayAction(name: "Black out target", target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == targetUUID })))
        try model.saveDisplayAction(blackOut)
        blackOut = try XCTUnwrap(model.displayActions.actions.first { $0.id == blackOut.id })
        let result = await run(model, id: blackOut.id)
        XCTAssertEqual(result.outcome, .done)
        XCTAssertEqual(mirrorWrites, 0)
        XCTAssertTrue(coverRequests.contains([202]), "Black out uses the explicitly requested style despite removal setup")
    }

    func testRepeatedHideAndShowRequestsAreNoOpsWithoutAnotherInputWrite() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(noneStatus())
        var hideWrites = 0
        var showWrites = 0
        let model = makeModel(
            defaults: defaults,
            box: box,
            hide: { _, _, input in
                hideWrites += 1
                box.value = self.hiddenStatus()
                return DisplayInputOutcome(state: .verified, requestedInput: input, observedInput: input)
            },
            show: { _, input in
                showWrites += 1
                box.value = self.noneStatus()
                return DisplayInputOutcome(state: .verified, requestedInput: input, observedInput: input)
            }
        )
        let removal = try saveRemovalAction(on: model)
        let hideResult = await run(model, id: removal.id)
        let repeatedHideResult = await run(model, id: removal.id)
        XCTAssertEqual(hideResult.outcome, .done)
        XCTAssertEqual(repeatedHideResult.outcome, .noOp)
        XCTAssertEqual(hideWrites, 1)

        var show = DisplayAction(name: "Show target", target: removal.target, effect: .show)
        try model.saveDisplayAction(show)
        show = try XCTUnwrap(model.displayActions.actions.first { $0.id == show.id })
        let showResult = await run(model, id: show.id)
        let repeatedShowResult = await run(model, id: show.id)
        XCTAssertEqual(showResult.outcome, .done)
        XCTAssertEqual(repeatedShowResult.outcome, .noOp)
        XCTAssertEqual(showWrites, 1)
    }

    func testRepeatedShowPreservesPartialInputEvidenceWarningAndRecoveryCommand() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(hiddenStatus())
        let undoCommand = "panelctl ddc-input --display '\(targetUUID)' --set 0x11"
        var showWrites = 0
        let model = makeModel(
            defaults: defaults,
            box: box,
            show: { _, input in
                showWrites += 1
                box.value = self.noneStatus()
                return DisplayInputOutcome(
                    state: .failed, requestedInput: input, detail: "fake return-input failure",
                    recoveryCommand: undoCommand
                )
            }
        )
        await settleQuiescence(model)
        var action = DisplayAction(
            name: "Show target",
            target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == targetUUID })),
            effect: .show
        )
        try model.saveDisplayAction(action)
        action = try XCTUnwrap(model.displayActions.actions.first { $0.id == action.id })

        let first = await run(model, id: action.id)
        XCTAssertEqual(first.outcome, .partial)
        XCTAssertEqual(showWrites, 1)
        let retained = try XCTUnwrap(model.displayResults[targetUUID.lowercased()])
        XCTAssertTrue(retained.needsAttention)
        XCTAssertTrue(retained.inputMessage?.contains("fake return-input failure") == true)
        XCTAssertEqual(retained.undoInputCommand, undoCommand)
        XCTAssertEqual(retained.inputOutcome?.state, .failed)
        XCTAssertEqual(model.controlDisplayOutcome, .partial)
        XCTAssertEqual(
            model.controlDisplayStatuses.first { $0.targetUUID.caseInsensitiveCompare(targetUUID) == .orderedSame }?.lastInputOutcome,
            retained.inputOutcome
        )

        let repeated = await run(model, id: action.id)
        XCTAssertEqual(repeated.outcome, .noOp)
        XCTAssertEqual(showWrites, 1, "a repeated Show never sends a second input write")
        XCTAssertEqual(model.displayResults[targetUUID.lowercased()], retained, "a no-op preserves the warning and undo command")
        XCTAssertEqual(model.controlDisplayOutcome, .partial, "status retains the input outcome")
        XCTAssertEqual(
            model.controlDisplayStatuses.first { $0.targetUUID.caseInsensitiveCompare(targetUUID) == .orderedSame }?.lastInputOutcome,
            retained.inputOutcome
        )
        XCTAssertEqual(repeated.displays?.first?.lastInputOutcome, retained.inputOutcome)
    }

    func testRemoveRepeatWithUnverifiedTopologyRequiresRecoveryWithoutWriting() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let status = unverifiedRemovalStatus()
        let box = StatusBox(status)
        var hideWrites = 0
        let model = makeModel(
            defaults: defaults,
            box: box,
            hide: { _, _, _ in hideWrites += 1; return .notRequested }
        )
        await settleQuiescence(model)
        let action = try saveRemovalAction(on: model)

        let repeated = await run(model, id: action.id)
        XCTAssertEqual(repeated.outcome, .recoveryNeeded)
        XCTAssertTrue(repeated.error?.localizedCaseInsensitiveContains("recovery") == true)
        XCTAssertEqual(hideWrites, 0)
        XCTAssertTrue(box.value.hasUnresolvedJournal, "the unresolved journal remains available for recovery")
        XCTAssertEqual(model.handoffStatus?.removal(for: targetUUID)?.topologyVerified, false)
    }

    func testShowActionWithUnreadableUnknownJournalRequiresRecovery() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(unreadableStatus())
        var showWrites = 0
        let model = makeModel(
            defaults: defaults,
            box: box,
            show: { _, _ in showWrites += 1; return .notRequested }
        )
        await settleQuiescence(model)
        var action = DisplayAction(
            name: "Show target",
            target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == targetUUID })),
            effect: .show
        )
        try model.saveDisplayAction(action)
        action = try XCTUnwrap(model.displayActions.actions.first { $0.id == action.id })

        let response = await run(model, id: action.id)
        XCTAssertEqual(response.outcome, .recoveryNeeded)
        XCTAssertTrue(response.error?.localizedCaseInsensitiveContains("unreadable journal") == true, response.error ?? "missing error")
        XCTAssertEqual(showWrites, 0)
        XCTAssertEqual(model.handoffStatus?.state, .recovery)
        XCTAssertEqual(model.handoffStatus?.inspectionFailure, "unreadable journal")
    }

    func testStyleMismatchAndMissingTargetRefuseWithoutAWriter() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(hiddenStatus())
        let inventory = DisplayRecordsBox(displays)
        var hideWrites = 0
        var showWrites = 0
        var coverWrites = 0
        let model = makeModel(
            defaults: defaults,
            box: box,
            displayProvider: { inventory.value },
            hide: { _, _, _ in hideWrites += 1; return .notRequested },
            show: { _, _ in showWrites += 1; return .notRequested },
            cover: { ids in coverWrites += ids.count; return [] }
        )
        await settleQuiescence(model)
        var blackOut = DisplayAction(name: "Black out", target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == targetUUID })))
        try model.saveDisplayAction(blackOut)
        blackOut = try XCTUnwrap(model.displayActions.actions.first { $0.id == blackOut.id })
        let styleMismatch = await run(model, id: blackOut.id)
        XCTAssertEqual(styleMismatch.outcome, .refused)
        XCTAssertEqual(hideWrites, 0)
        XCTAssertEqual(coverWrites, 0)

        box.value = noneStatus()
        model.refreshHandoffStatus()
        let removal = try saveRemovalAction(on: model)
        model.setHideEnabled(false, for: try XCTUnwrap(displays.first { $0.uuid == targetUUID }))
        let staleReview = await run(model, id: removal.id)
        XCTAssertEqual(staleReview.outcome, .refused)
        XCTAssertEqual(hideWrites, 0)

        inventory.value.removeAll { $0.uuid == targetUUID }
        model.refreshDisplays()
        XCTAssertTrue(model.displayActionRunBlocker(for: removal)?.contains("Unavailable") == true)
        let missingTarget = await run(model, id: removal.id)
        XCTAssertEqual(missingTarget.outcome, .refused)
        XCTAssertEqual(showWrites, 0)
    }

    func testShowUsesOutstandingRecoveryAfterSetupChangesAndExperimentalOff() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(hiddenStatus())
        var showWrites = 0
        let model = makeModel(
            defaults: defaults,
            box: box,
            show: { _, input in
                showWrites += 1
                box.value = self.noneStatus()
                return DisplayInputOutcome(state: .verified, requestedInput: input, observedInput: input)
            }
        )
        let show = DisplayAction(
            name: "Show target",
            target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == targetUUID })),
            effect: .show
        )
        await settleQuiescence(model)
        try model.saveDisplayAction(show)
        model.setHideEnabled(false, for: try XCTUnwrap(displays.first { $0.uuid == targetUUID }))
        model.setExperimentalFeaturesEnabled(false)
        let result = await run(model, id: show.id)
        XCTAssertEqual(result.outcome, .done)
        XCTAssertEqual(showWrites, 1)
        XCTAssertEqual(box.value.state, .none)
    }

    func testCleanupFailureAndContentionDoNotStartTheWriter() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var writes = 0
        var delayedQuiescence: ((Bool, String?) -> Void)?
        let failedModel = makeModel(
            defaults: defaults,
            hide: { _, _, _ in writes += 1; return .notRequested },
            quiesce: { $0(false, "fixture cleanup failed") }
        )
        let failedAction = try saveRemovalAction(on: failedModel)
        let cleanupFailure = await run(failedModel, id: failedAction.id)
        XCTAssertEqual(cleanupFailure.outcome, .failed)
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(failedModel.protectionQuiescenceFailure?.contains("fixture cleanup failed") == true)

        let otherDefaults = try makeDefaults()
        defer { otherDefaults.removePersistentDomain(forName: suiteName(otherDefaults)) }
        let busyModel = makeModel(
            defaults: otherDefaults,
            hide: { _, _, _ in writes += 1; return .notRequested },
            quiesce: { delayedQuiescence = $0 }
        )
        let busyAction = try saveRemovalAction(on: busyModel)
        busyModel.runDisplayAction(id: busyAction.id)
        XCTAssertEqual(busyModel.hideOperation, .idle, "the run-level lease starts before its single quiescence, not by faking a display operation")
        XCTAssertEqual(busyModel.runningDisplayAction?.id, busyAction.id)
        let contended = await run(busyModel, id: busyAction.id)
        XCTAssertEqual(contended.outcome, .busy)
        XCTAssertNil(busyModel.displayActionResults[busyAction.id], "contention must not replace an in-flight action result")
        XCTAssertEqual(writes, 0)
        delayedQuiescence?(false, "fixture cleanup failed")
    }

    func testPartialInputOutcomeIsReturnedAndDisplayedSeparatelyFromDesktopResult() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(noneStatus())
        let model = makeModel(
            defaults: defaults,
            box: box,
            hide: { _, _, input in
                box.value = self.hiddenStatus()
                return DisplayInputOutcome(state: .unverified, requestedInput: input, detail: "readback was unavailable")
            }
        )
        let action = try saveRemovalAction(on: model)
        let response = await run(model, id: action.id)
        XCTAssertEqual(response.outcome, .partial)
        XCTAssertEqual(response.summary, "Hidden.")
        XCTAssertTrue(response.detail?.contains("couldn’t confirm") == true)
        XCTAssertTrue(model.displayResults[targetUUID.lowercased()]?.message.contains("Hidden") == true)
        XCTAssertEqual(model.displayActionResults[action.id]?.outcome, .partial)
    }

    func testDeletingActionLeavesDisplayShowAndRecoveryAvailable() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(hiddenStatus())
        var showWrites = 0
        let model = makeModel(
            defaults: defaults,
            box: box,
            show: { _, _ in showWrites += 1; box.value = self.noneStatus(); return .notRequested }
        )
        await settleQuiescence(model)
        let removal = try saveRemovalAction(on: model)
        model.deleteDisplayAction(id: removal.id)
        XCTAssertTrue(model.displayActions.actions.isEmpty)
        XCTAssertEqual(model.displayTiles.first { $0.uuid == targetUUID }?.action, .show)
        let shown = await awaitShow(model)
        XCTAssertTrue(shown.succeeded)
        XCTAssertEqual(showWrites, 1)
    }

    func testRunActionControlRequestRefusesUnknownIDsAndRunsKnownIDsOnce() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(noneStatus())
        var writes = 0
        let model = makeModel(
            defaults: defaults,
            box: box,
            hide: { _, _, _ in writes += 1; box.value = self.hiddenStatus(); return .notRequested }
        )
        let unknown = AppControlRequest(command: .runAction, actionID: UUID())
        let refused = await awaitControl(model, unknown)
        XCTAssertEqual(refused.outcome, .refused)
        XCTAssertTrue(refused.error?.contains("No saved display action") == true)
        let action = try saveBlackOutAction(on: model)
        let request = AppControlRequest(command: .runAction, actionID: action.id)
        let result = await awaitControl(model, request)
        XCTAssertEqual(result.outcome, .done)
        XCTAssertEqual(result.displays?.first?.targetUUID, targetUUID)
        XCTAssertEqual(writes, 0, "Black out is fake-backed by a cover, not the topology writer")
    }

    func testEightStepNoOpAndLongBlockerRepliesRetainEvidenceThroughServerEncoding() async throws {
        for blocked in [false, true] {
            let defaults = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
            if blocked { defaults.set(String(repeating: "cleanup failure ", count: 200), forKey: "automationCleanupFailure") }
            let records = (0..<8).map { index in
                display(
                    index: index + 1, id: UInt32(index + 1000), uuid: UUID().uuidString,
                    name: String(repeating: "N", count: 512), main: false
                )
            }
            let model = makeModel(defaults: defaults, displayProvider: { records })
            let action = DisplayAction(name: blocked ? "Blocked eight-step Action" : "Eight long-name no-ops", steps: records.map {
                DisplayActionStep(target: DisplayIdentitySnapshot($0), effect: blocked ? .blackOut : .show)
            })
            try model.saveDisplayAction(action)

            let socketPath = "\(try AppControlSocket.userTemporaryDirectory())/panelctl-task46-\(UUID().uuidString.prefix(8)).sock"
            let server = AppControlServer(socketPath: socketPath) { request, receivedAt in
                await model.handleDisplayControlRequest(request, receivedAt: receivedAt)
            }
            try server.start()
            defer { server.stop() }
            let response = try await Task.detached {
                try AppControlClient(socketPath: socketPath, launch: { XCTFail("run-action must not launch the app") })
                    .execute(.runAction, actionID: action.id)
            }.value

            XCTAssertEqual(response.steps?.count, 8, "the production server must preserve every step result")
            XCTAssertEqual(response.displays?.count, 8, "the production server must preserve each target status")
            if blocked {
                XCTAssertEqual(response.outcome, .refused)
                XCTAssertEqual(response.steps?.map(\.outcome), [.refused] + Array(repeating: .notRun, count: 7))
                XCTAssertLessThanOrEqual(response.steps?.first?.desktopSummary.utf8.count ?? .max, 64)
            } else {
                XCTAssertEqual(response.outcome, .noOp)
                XCTAssertEqual(response.steps?.map(\.outcome), Array(repeating: .noOp, count: 8))
                XCTAssertTrue(response.steps?.allSatisfy { $0.desktopSummary.utf8.count <= 64 } == true)
            }
        }
    }

    func testStartupWakeReconnectPauseRestoreAndActivityDoNotRunSavedActions() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let action = DisplayAction(name: "Never automatic", target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == targetUUID })))
        defaults.set(try JSONEncoder().encode(DisplayActionSet(actions: [action])), forKey: "displayActions")
        var hideWrites = 0
        var showWrites = 0
        let model = makeModel(
            defaults: defaults,
            hide: { _, _, _ in hideWrites += 1; return .notRequested },
            show: { _, _ in showWrites += 1; return .notRequested }
        )
        model.refreshDisplays(restartWatcher: true)
        model.displayWakeObserved(screensAwake: true)
        model.displayConfigurationChanged(restartWatcher: true)
        XCTAssertEqual(hideWrites, 0)
        XCTAssertEqual(showWrites, 0)
        XCTAssertNil(model.displayActionResults[action.id], "startup, wake and reconnection do not run the saved action")

        let explicitRun = await run(model, id: action.id)
        XCTAssertEqual(explicitRun.outcome, .done)
        XCTAssertEqual(model.displayTiles.first { $0.uuid == targetUUID }?.action, .show)
        model.displayWakeObserved(screensAwake: true)
        model.displayConfigurationChanged(restartWatcher: true)
        XCTAssertFalse(model.showHiddenDisplay(at: 101), "Escape on a different automation cover does not target the manual action")
        model.setProtectionEnabled(false)
        model.snooze(for: 60)
        _ = try model.restoreBlackout()
        XCTAssertEqual(hideWrites, 0)
        XCTAssertEqual(showWrites, 0)
        XCTAssertEqual(model.displayTiles.first { $0.uuid == targetUUID }?.action, .show, "Pause and Restore do not undo the manual Hide")
        XCTAssertEqual(model.displayActions.actions.map(\.id), [action.id])
    }

    func testLegacyActionsUpgradeWithoutDowngradeOverwriteAndUnreadableDataIsPreserved() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let identity = DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == targetUUID }))
        let legacyID = UUID()
        let identityJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any])
        let legacyJSON = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "actions": [[
                "id": legacyID.uuidString, "name": "Legacy action",
                "target": identityJSON, "effect": DisplayActionEffect.removeFromDesktop.rawValue,
                "reviewedRemoval": ["removeEnabled": true, "sourceUUID": mainUUID, "awayInput": 17]
            ]]
        ])
        defaults.set(legacyJSON, forKey: AppModel.legacyDisplayActionsKey)
        let model = makeModel(defaults: defaults)
        let migrated = try XCTUnwrap(model.displayActions.actions.first)
        XCTAssertEqual(migrated.id, legacyID)
        XCTAssertEqual(migrated.name, "Legacy action")
        XCTAssertEqual(migrated.steps.count, 1)
        XCTAssertEqual(migrated.effect, .removeFromDesktop)
        XCTAssertEqual(migrated.reviewedRemoval, ReviewedRemovalSetup(removeEnabled: true, sourceUUID: mainUUID, awayInput: 17))

        var renamed = migrated
        renamed.name = "Legacy action renamed"
        try model.saveDisplayAction(renamed, replacing: legacyID)
        let upgradedBytes = try XCTUnwrap(defaults.data(forKey: AppModel.displayActionsKey))
        let upgraded = try JSONDecoder().decode(DisplayActionSet.self, from: upgradedBytes)
        XCTAssertEqual(upgraded.actions.first?.id, legacyID)
        XCTAssertEqual(upgraded.actions.first?.name, "Legacy action renamed")
        let upgradedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: upgradedBytes) as? [String: Any])
        let actionRows = try XCTUnwrap(upgradedJSON["actions"] as? [[String: Any]])
        let savedSteps = try XCTUnwrap(actionRows.first?["steps"] as? [[String: Any]])
        let savedTarget = try XCTUnwrap(savedSteps.first?["target"] as? [String: Any])
        XCTAssertNil(savedTarget["id"], "numeric IDs from legacy Action snapshots are not persisted as identity")

        defaults.set(legacyJSON, forKey: AppModel.legacyDisplayActionsKey) // simulate an older build writing its key
        XCTAssertEqual(makeModel(defaults: defaults).displayActions, upgraded)

        let newerDefaults = try makeDefaults()
        defer { newerDefaults.removePersistentDomain(forName: suiteName(newerDefaults)) }
        let newerBytes = try JSONSerialization.data(withJSONObject: ["version": 99, "actions": []])
        newerDefaults.set(newerBytes, forKey: AppModel.displayActionsKey)
        newerDefaults.set(legacyJSON, forKey: AppModel.legacyDisplayActionsKey)
        let newerModel = makeModel(defaults: newerDefaults)
        XCTAssertTrue(newerModel.displayActionStorageFailure?.contains("preserved") == true)
        XCTAssertThrowsError(try newerModel.saveDisplayAction(DisplayAction(name: "Must not overwrite")))
        XCTAssertEqual(newerDefaults.data(forKey: AppModel.displayActionsKey), newerBytes)
        XCTAssertEqual(newerDefaults.data(forKey: AppModel.legacyDisplayActionsKey), legacyJSON)

        let corruptDefaults = try makeDefaults()
        defer { corruptDefaults.removePersistentDomain(forName: suiteName(corruptDefaults)) }
        let corruptBytes = Data("{not-json".utf8)
        corruptDefaults.set(corruptBytes, forKey: AppModel.legacyDisplayActionsKey)
        let corruptModel = makeModel(defaults: corruptDefaults)
        XCTAssertNotNil(corruptModel.displayActionStorageFailure)
        XCTAssertThrowsError(try corruptModel.saveDisplayAction(DisplayAction(name: "Must not overwrite")))
        XCTAssertNil(corruptDefaults.data(forKey: AppModel.displayActionsKey))
        XCTAssertEqual(corruptDefaults.data(forKey: AppModel.legacyDisplayActionsKey), corruptBytes)

        for nullEffect in [false, true] {
            let malformedDefaults = try makeDefaults()
            defer { malformedDefaults.removePersistentDomain(forName: suiteName(malformedDefaults)) }
            let malformedID = UUID()
            var malformedAction: [String: Any] = [
                "id": malformedID.uuidString,
                "name": "Malformed legacy action",
                "target": identityJSON
            ]
            if nullEffect { malformedAction["effect"] = NSNull() }
            let malformedBytes = try JSONSerialization.data(withJSONObject: [
                "version": 1,
                "actions": [malformedAction]
            ])
            malformedDefaults.set(malformedBytes, forKey: AppModel.legacyDisplayActionsKey)
            var writerCalls = 0
            let malformedModel = makeModel(
                defaults: malformedDefaults,
                hide: { _, _, _ in writerCalls += 1; return .notRequested },
                cover: { _ in writerCalls += 1; return [] }
            )
            XCTAssertTrue(malformedModel.displayActions.actions.isEmpty)
            XCTAssertTrue(malformedModel.displayActionStorageFailure?.contains("preserved") == true)
            XCTAssertThrowsError(try malformedModel.saveDisplayAction(DisplayAction(name: "Do not overwrite")))
            XCTAssertEqual(malformedDefaults.data(forKey: AppModel.legacyDisplayActionsKey), malformedBytes)
            var runResponse: AppControlResponse?
            malformedModel.runDisplayAction(id: malformedID) { runResponse = $0 }
            XCTAssertEqual(runResponse?.outcome, .refused)
            XCTAssertEqual(writerCalls, 0)
        }
    }

    func testStepCountStableUUIDAndDuplicateValidation() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let model = makeModel(defaults: defaults)
        let steps = (0..<8).map { index in
            DisplayActionStep(target: DisplayIdentitySnapshot(
                uuid: UUID().uuidString, id: UInt32(index + 1000), name: "Offline \(index)",
                vendor: 1, model: 2, serial: UInt32(index)
            ))
        }
        let eightSteps = DisplayAction(name: "Eight steps", steps: steps)
        XCTAssertNil(model.displayActionValidation(for: eightSteps))
        try model.saveDisplayAction(eightSteps)
        XCTAssertEqual(model.displayActions.actions.first?.steps.count, 8)

        var nineSteps = eightSteps
        nineSteps.steps.append(DisplayActionStep(target: DisplayIdentitySnapshot(
            uuid: UUID().uuidString, id: 2000, name: "Ninth", vendor: 1, model: 2, serial: 3
        )))
        XCTAssertTrue(model.displayActionValidation(for: nineSteps, replacing: eightSteps.id)?.contains("1–8") == true)
        XCTAssertThrowsError(try model.saveDisplayAction(nineSteps, replacing: eightSteps.id))

        let repeated = DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == targetUUID }))
        let duplicate = DisplayAction(name: "Duplicate displays", steps: [
            DisplayActionStep(target: repeated), DisplayActionStep(target: repeated, effect: .show)
        ])
        XCTAssertTrue(model.displayActionValidation(for: duplicate)?.localizedCaseInsensitiveContains("only once") == true)
        XCTAssertThrowsError(try model.saveDisplayAction(duplicate))
        let empty = DisplayAction(name: "Empty", steps: [])
        XCTAssertTrue(model.displayActionValidation(for: empty)?.contains("1–8") == true)
        let missing = DisplayAction(name: "Missing", steps: [DisplayActionStep()])
        XCTAssertEqual(model.displayActionValidation(for: missing), "Step 1: Choose a display.")
    }

    func testSaveRejectsOnlyDefinitionTimeConflicts() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let model = makeModel(defaults: defaults)
        let main = DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == mainUUID }))
        let target = DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == targetUUID }))
        let alternate = DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == alternateUUID }))
        let reviewedTarget = model.currentReviewedRemovalSetup(for: targetUUID)

        let hiddenSource = DisplayAction(name: "Remove after blacking out its source", steps: [
            DisplayActionStep(target: main, effect: .blackOut),
            DisplayActionStep(target: target, effect: .removeFromDesktop, reviewedRemoval: reviewedTarget)
        ])
        XCTAssertTrue(model.displayActionValidation(for: hiddenSource)?.contains("Step 2:") == true)
        XCTAssertThrowsError(try model.saveDisplayAction(hiddenSource))

        model.setHideEnabled(true, for: try XCTUnwrap(displays.first { $0.uuid == mainUUID }))
        model.setHideSource(alternateUUID, for: mainUUID)
        let removeMainSetup = model.currentReviewedRemovalSetup(for: mainUUID)
        let hiddenEarlierSource = DisplayAction(name: "Remove earlier mirror source", steps: [
            DisplayActionStep(target: target, effect: .removeFromDesktop, reviewedRemoval: reviewedTarget),
            DisplayActionStep(target: main, effect: .removeFromDesktop, reviewedRemoval: removeMainSetup)
        ])
        XCTAssertTrue(model.displayActionValidation(for: hiddenEarlierSource)?.contains("Step 2:") == true)
        XCTAssertThrowsError(try model.saveDisplayAction(hiddenEarlierSource))

        let stateDependent = DisplayAction(name: "State dependent visibility", steps: [
            DisplayActionStep(target: main, effect: .blackOut),
            DisplayActionStep(target: target, effect: .blackOut),
            DisplayActionStep(target: alternate, effect: .blackOut),
            DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == sourceUUID })), effect: .blackOut)
        ])
        XCTAssertNil(model.displayActionValidation(for: stateDependent), "visible-display checks depend on the current layout and belong at Run time")
        try model.saveDisplayAction(stateDependent)
    }

    func testWholeRunPreflightsProjectedLastVisibleStateBeforeAnyWrite() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var coverRequests: [Set<UInt32>] = []
        var quiesceCount = 0
        let model = AppModel(
            defaults: defaults, displayProvider: { self.displays }, idleSecondsProvider: { nil },
            isDisplayMirrored: { _ in false }, inspectHandoff: { self.noneStatus() },
            coverDisplays: { coverRequests.append($0); return [] },
            quiesceProtection: { completion in quiesceCount += 1; completion(true, nil) }
        )
        let action = DisplayAction(name: "Hide every display", steps: displays.map {
            DisplayActionStep(target: DisplayIdentitySnapshot($0), effect: .blackOut)
        })
        try model.saveDisplayAction(action)
        XCTAssertTrue(model.displayActionRunBlocker(for: action)?.contains("Step 4:") == true)

        let result = await run(model, id: action.id)
        XCTAssertEqual(result.outcome, .refused)
        XCTAssertEqual(result.steps?.map(\.outcome), [.notRun, .notRun, .notRun, .refused])
        XCTAssertTrue(result.error?.contains("Step 4:") == true)
        XCTAssertTrue(coverRequests.isEmpty)
        XCTAssertEqual(quiesceCount, 0, "the run does not stop helpers or write before complete preflight")
    }

    func testNoOpPreflightNeverWritesWhenStateChangesBeforeTheStep() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(noneStatus())
        var armed = false
        var quiesceCount = 0
        let model = AppModel(
            defaults: defaults, displayProvider: { self.displays }, idleSecondsProvider: { nil },
            isDisplayMirrored: { _ in false },
            inspectHandoff: {
                let status = box.value
                // The preflight read sees nothing hidden; the step's fresh read sees a removal.
                if armed { armed = false; box.value = self.hiddenStatus() }
                return status
            },
            showDisplay: { _, _ in
                XCTFail("a step must not write when preflight skipped helper quiescence")
                return .notRequested
            },
            quiesceProtection: { completion in quiesceCount += 1; completion(true, nil) }
        )
        await settleQuiescence(model)
        let before = quiesceCount
        let action = DisplayAction(name: "Show target", steps: [
            DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == targetUUID })), effect: .show)
        ])
        try model.saveDisplayAction(action)
        armed = true

        let result = await run(model, id: action.id)
        XCTAssertEqual(result.outcome, .refused)
        XCTAssertEqual(result.steps?.map(\.outcome), [.refused])
        XCTAssertEqual(quiesceCount, before)
    }

    func testMultiStepShowThenBlackOutRunsInOrderAndQuiescesOnce() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(hiddenStatus())
        var inspections = 0
        var showWrites = 0
        var coverRequests: [Set<UInt32>] = []
        var quiesceCalls = 0
        let model = AppModel(
            defaults: defaults, displayProvider: { self.displays }, idleSecondsProvider: { nil },
            isDisplayMirrored: { _ in false }, inspectHandoff: { inspections += 1; return box.value },
            showDisplay: { _, input in
                showWrites += 1
                box.value = self.noneStatus()
                return DisplayInputOutcome(state: .verified, requestedInput: input, observedInput: input)
            },
            coverDisplays: { coverRequests.append($0); return [] },
            quiesceProtection: { completion in quiesceCalls += 1; completion(true, nil) }
        )
        await settleQuiescence(model)
        XCTAssertFalse(model.protectionQuiescencePending, "initial fake cleanup must settle before this run")
        let action = DisplayAction(name: "Show then black out", steps: [
            DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == targetUUID })), effect: .show),
            DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == sourceUUID })), effect: .blackOut)
        ])
        try model.saveDisplayAction(action)
        let beforeRunInspections = inspections
        let beforeRunQuiescence = quiesceCalls

        let result = await run(model, id: action.id)
        XCTAssertEqual(result.outcome, .done, result.error ?? "missing Action error")
        XCTAssertEqual(result.steps?.map(\.index), [1, 2])
        XCTAssertEqual(result.steps?.map(\.outcome), [.done, .done])
        XCTAssertEqual(result.steps?.map(\.effect), [DisplayActionEffect.show.rawValue, DisplayActionEffect.blackOut.rawValue])
        XCTAssertEqual(showWrites, 1)
        XCTAssertEqual(coverRequests, [[303]])
        XCTAssertEqual(quiesceCalls - beforeRunQuiescence, 1)
        XCTAssertEqual(inspections - beforeRunInspections, 5, "one preflight, one fresh read per step, and Show's existing pre- and post-write verification")
        XCTAssertEqual(result.displays?.map(\.targetUUID).sorted(), [targetUUID, sourceUUID].sorted())
        XCTAssertFalse(model.isRemovedDisplay(targetUUID))
        XCTAssertTrue(model.isBlackoutHidden(sourceUUID))
    }

    func testActionLeaseBlocksCompetingEntryPointsAndKeepsRequestsStaleAfterFinish() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var delayedQuiescence: ((Bool, String?) -> Void)?
        var coverRequests: [Set<UInt32>] = []
        var quiesceCalls = 0
        let model = makeModel(
            defaults: defaults,
            cover: { coverRequests.append($0); return [] },
            quiesce: { completion in quiesceCalls += 1; delayedQuiescence = completion }
        )
        let active = DisplayAction(name: "Leased workflow", steps: [
            DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == targetUUID }))),
            DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == sourceUUID })))
        ])
        try model.saveDisplayAction(active)
        let other = DisplayAction(name: "Editable other Action", target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == alternateUUID })))
        try model.saveDisplayAction(other)
        XCTAssertNil(model.displayActionRunBlocker(for: active), model.displayActionStatus(for: active))
        let staleRequestTime = ContinuousClock.now
        let runFinished = expectation(description: "the leased Action finishes after quiescence")
        var finishedResponse: AppControlResponse?
        model.runDisplayAction(id: active.id) { response in
            finishedResponse = response
            runFinished.fulfill()
        }
        XCTAssertEqual(model.runningDisplayAction?.id, active.id)
        XCTAssertEqual(model.runningDisplayAction?.currentStep, 1)
        XCTAssertEqual(model.runningDisplayAction?.totalSteps, 2)
        for (action, existingID, shouldBlock): (DisplayAction, UUID?, Bool) in [
            (active, active.id, true), (other, other.id, false), (other, nil, false)
        ] {
            let editor = DisplayActionEditor(
                model: model, navigation: SettingsNavigation(), action: action,
                existingID: existingID, isNew: existingID == nil
            )
            XCTAssertEqual(editor.editingActionIsRunning, shouldBlock,
                           "Only editing the running Action should disable Save")
        }
        XCTAssertEqual(quiesceCalls, 1)

        let statusDelegate = AppDelegate()
        statusDelegate.model = model
        let status = await statusDelegate.handleControlRequest(AppControlRequest(command: .status), receivedAt: .now)
        XCTAssertEqual(status.runningAction?.id, active.id)
        XCTAssertEqual(status.runningAction?.currentStep, 1)
        XCTAssertEqual(status.runningAction?.totalSteps, 2)

        let competingHide = await model.handleDisplayControlRequest(
            AppControlRequest(command: .hide, targetUUID: targetUUID)
        )
        XCTAssertEqual(competingHide.outcome, .busy)
        XCTAssertTrue(competingHide.error?.contains("Leased workflow") == true)
        let menuShow = await withCheckedContinuation { continuation in
            model.show(targetUUID: targetUUID) { continuation.resume(returning: $0) }
        }
        XCTAssertFalse(menuShow.succeeded)
        XCTAssertTrue(menuShow.message.contains("Leased workflow"))
        let rejectedOtherRun = await run(model, id: other.id)
        XCTAssertEqual(rejectedOtherRun.outcome, .busy)
        XCTAssertTrue(rejectedOtherRun.error?.contains("Leased workflow") == true)
        XCTAssertNil(model.displayActionResults[active.id], "contending requests cannot overwrite the active result")

        model.prepareDisconnect(targetUUID)
        XCTAssertTrue(model.disconnectFailure?.contains("Leased workflow") == true)
        model.retryAutomationCleanup()
        XCTAssertThrowsError(try model.makeShowRequest(targetUUID: targetUUID)) {
            XCTAssertTrue($0.localizedDescription.contains("Leased workflow"))
        }
        model.deleteDisplayAction(id: active.id)
        XCTAssertNotNil(model.displayActions.actions.first { $0.id == active.id })
        var renamedOther = other
        renamedOther.name = "Other Action remains editable"
        try model.saveDisplayAction(renamedOther, replacing: other.id)
        XCTAssertEqual(model.displayActions.actions.first { $0.id == other.id }?.name, renamedOther.name)
        XCTAssertThrowsError(try model.saveDisplayAction(active, replacing: active.id))
        let menu = statusDelegate.makeMenu()
        XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.title == "Quit PanelCtl" }).isEnabled)
        XCTAssertTrue(coverRequests.isEmpty)

        delayedQuiescence?(true, nil)
        await fulfillment(of: [runFinished], timeout: 2)
        let finished = try XCTUnwrap(finishedResponse)
        XCTAssertEqual(finished.outcome, .done)
        XCTAssertEqual(coverRequests, [[202], [202, 303]])
        let staleAfterFinish = await model.handleDisplayControlRequest(
            AppControlRequest(command: .hide, targetUUID: targetUUID), receivedAt: staleRequestTime
        )
        XCTAssertEqual(staleAfterFinish.outcome, .busy)
        XCTAssertEqual(coverRequests, [[202], [202, 303]], "a request received during the run is never replayed later")
        XCTAssertNil(model.runningDisplayAction)
    }

    func testActionLeaseReplaysDeferredHiddenDisplaySafetyReconciliation() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let inventory = DisplayRecordsBox(displays)
        var quiesceCalls = 0
        var delayedQuiescence: ((Bool, String?) -> Void)?
        var coverRequests: [Set<UInt32>] = []
        let model = makeModel(
            defaults: defaults,
            displayProvider: { inventory.value },
            cover: { ids in coverRequests.append(ids); return [] },
            quiesce: { completion in
                quiesceCalls += 1
                if quiesceCalls == 1 { completion(true, nil) }
                else { delayedQuiescence = completion }
            }
        )
        let hiddenTarget = DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == targetUUID }))
        let keepHidden = DisplayAction(name: "Hide target", target: hiddenTarget)
        try model.saveDisplayAction(keepHidden)
        let initialHide = await run(model, id: keepHidden.id)
        XCTAssertEqual(initialHide.outcome, .done)
        XCTAssertTrue(model.isBlackoutHidden(targetUUID))

        let waiting = DisplayAction(name: "Wait for display change", target: DisplayIdentitySnapshot(
            try XCTUnwrap(displays.first { $0.uuid == sourceUUID })
        ))
        try model.saveDisplayAction(waiting)
        let finished = expectation(description: "interrupted Action releases its lease")
        var response: AppControlResponse?
        model.runDisplayAction(id: waiting.id) { result in response = result; finished.fulfill() }
        XCTAssertEqual(model.runningDisplayAction?.id, waiting.id)
        XCTAssertNotNil(delayedQuiescence)

        inventory.value = [try XCTUnwrap(displays.first { $0.uuid == targetUUID })]
        model.displayConfigurationChanged(restartWatcher: false)
        XCTAssertTrue(model.isBlackoutHidden(targetUUID), "the Action lease defers showing the only remaining display")
        delayedQuiescence?(true, nil)
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertEqual(response?.outcome, .refused)
        XCTAssertFalse(model.isBlackoutHidden(targetUUID), "the deferred last-visible safety check is replayed at lease release")
        XCTAssertTrue(model.displayResults[targetUUID.lowercased()]?.message.contains("no other display was connected") == true)
        XCTAssertEqual(coverRequests.first, [202])
        XCTAssertEqual(coverRequests.last, [])
    }

    func testPreflightRecoveryDiscoveryQuiescesAutomationAfterRefusal() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let recovery = StatusBox(noneStatus())
        var helperRunning = true
        var quiesceCalls = 0
        var displayWrites = 0
        var inputWrites = 0
        let model = makeModel(
            defaults: defaults,
            box: recovery,
            hide: { _, _, _ in inputWrites += 1; return .notRequested },
            show: { _, _ in inputWrites += 1; return .notRequested },
            cover: { _ in displayWrites += 1; return [] },
            quiesce: { completion in quiesceCalls += 1; helperRunning = false; completion(true, nil) }
        )
        let action = try saveBlackOutAction(on: model)
        recovery.value = unreadableStatus()

        let response = await run(model, id: action.id)
        await settleQuiescence(model)
        XCTAssertEqual(response.outcome, .recoveryNeeded)
        XCTAssertEqual(quiesceCalls, 1, "the preflight-discovered recovery transition must stop the existing helper")
        XCTAssertFalse(helperRunning)
        XCTAssertEqual(displayWrites, 0)
        XCTAssertEqual(inputWrites, 0)
        XCTAssertFalse(model.protectionQuiescencePending)
    }

    func testDisplayControlRequestsStayBusyAfterNoOpAndRefusedActions() async throws {
        for refusesWithRecovery in [false, true] {
            let defaults = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
            let recovery = StatusBox(noneStatus())
            var hideWrites = 0
            var showWrites = 0
            var coverRequests: [Set<UInt32>] = []
            let model = makeModel(
                defaults: defaults,
                box: recovery,
                hide: { _, _, _ in hideWrites += 1; return .notRequested },
                show: { _, _ in showWrites += 1; return .notRequested },
                cover: { coverRequests.append($0); return [] }
            )
            if refusesWithRecovery { recovery.value = unreadableStatus() }
            let target = DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == targetUUID }))
            let action = DisplayAction(
                name: refusesWithRecovery ? "Refused Action" : "All no-op Action",
                target: target,
                effect: refusesWithRecovery ? .blackOut : .show
            )
            try model.saveDisplayAction(action)
            let receivedDuringAction = ContinuousClock.now
            let result = await run(model, id: action.id)
            XCTAssertEqual(result.outcome, refusesWithRecovery ? .recoveryNeeded : .noOp)

            for command in [AppControlCommand.hide, .show, .toggleHide] {
                let response = await model.handleDisplayControlRequest(
                    AppControlRequest(command: command, targetUUID: targetUUID),
                    receivedAt: receivedDuringAction
                )
                XCTAssertEqual(response.outcome, .busy, "\(command) received during an Action must not execute afterward")
            }
            XCTAssertEqual(hideWrites, 0)
            XCTAssertEqual(showWrites, 0)
            XCTAssertTrue(coverRequests.isEmpty)
        }
    }

    func testOneStepActionReadinessMatchesTileReadiness() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let records = [try XCTUnwrap(displays.first { $0.uuid == targetUUID })]
        let model = AppModel(
            defaults: defaults, displayProvider: { records }, idleSecondsProvider: { nil },
            isDisplayMirrored: { _ in false }, inspectHandoff: { self.noneStatus() },
            coverDisplays: { _ in [] }, quiesceProtection: { $0(true, nil) }
        )
        let target = DisplayIdentitySnapshot(records[0])
        let action = DisplayAction(name: "Single target", target: target)
        try model.saveDisplayAction(action)
        let tileBlocker = try XCTUnwrap(model.blackoutReadiness(for: records[0])).localizedDescription
        XCTAssertEqual(model.displayActionRunBlocker(for: action), "Step 1: \(tileBlocker)")
    }

    func testLaterStepIdentityFailureReturnsHonestPartialWithEveryTargetStatus() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let inventory = DisplayRecordsBox(displays)
        var coverRequests: [Set<UInt32>] = []
        let model = makeModel(
            defaults: defaults,
            displayProvider: { inventory.value },
            cover: { ids in
                coverRequests.append(ids)
                if ids.contains(202) { inventory.value.removeAll { $0.uuid == self.sourceUUID } }
                return []
            }
        )
        let action = DisplayAction(name: "Stops after a missing target", steps: [
            DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == targetUUID }))),
            DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == sourceUUID })), effect: .show),
            DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == alternateUUID })), effect: .show)
        ])
        try model.saveDisplayAction(action)

        let result = await run(model, id: action.id)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.steps?.map(\.outcome), [.done, .refused, .notRun])
        XCTAssertTrue(result.steps?[1].desktopSummary.localizedCaseInsensitiveContains("changed after") == true)
        XCTAssertEqual(result.displays?.map(\.targetUUID), [targetUUID, sourceUUID, alternateUUID])
        XCTAssertEqual(result.displays?.map(\.observedState), ["hidden-by-panelctl", "unavailable", "separate"])
        XCTAssertEqual(coverRequests, [[202]])
        XCTAssertTrue(model.isBlackoutHidden(targetUUID))
    }

    func testProjectedShowReleasesPanelCtlMirrorSourceForLaterRemoval() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let target = try XCTUnwrap(displays.first { $0.uuid == targetUUID })
        let main = try XCTUnwrap(displays.first { $0.uuid == mainUUID })
        let alternate = try XCTUnwrap(displays.first { $0.uuid == alternateUUID })
        var hidePreferences = DisplayHidePreferences()
        hidePreferences[targetUUID] = DisplayHideConfiguration(
            target: DisplayIdentitySnapshot(target), enabled: true,
            source: DisplayIdentitySnapshot(main), awayInput: 0x11, returnInput: 0x10
        )
        hidePreferences[mainUUID] = DisplayHideConfiguration(
            target: DisplayIdentitySnapshot(main), enabled: true,
            source: DisplayIdentitySnapshot(alternate), awayInput: 0x11, returnInput: 0x10
        )
        defaults.set(try JSONEncoder().encode(hidePreferences), forKey: "displayHidePreferences")

        let initialJournal = verifiedRemovalStatus(target: target, source: main, journalID: "first-removal")
        let status = StatusBox(initialJournal)
        var showWrites = 0
        var hideWrites = 0
        let model = AppModel(
            defaults: defaults,
            displayProvider: { self.displays },
            idleSecondsProvider: { nil },
            isDisplayMirrored: { id in
                status.value.state == .hidden && (id == target.id || id == main.id)
            },
            inspectHandoff: { status.value },
            hideDisplay: { _, _, _ in
                hideWrites += 1
                status.value = self.verifiedRemovalStatus(target: main, source: alternate, journalID: "second-removal")
                return .notRequested
            },
            showDisplay: { _, _ in showWrites += 1; status.value = self.noneStatus(); return .notRequested },
            checkDDCInput: { _ in DDCInputReading(displayID: target.id, uuid: self.targetUUID, current: 0x0F) },
            coverDisplays: { _ in [] },
            quiesceProtection: { $0(true, nil) }
        )
        await settleQuiescence(model)
        let removeB = DisplayActionStep(
            target: DisplayIdentitySnapshot(main), effect: .removeFromDesktop,
            reviewedRemoval: ReviewedRemovalSetup(removeEnabled: true, sourceUUID: alternateUUID, awayInput: 0x11)
        )
        let action = DisplayAction(name: "Restore then remove source", steps: [
            DisplayActionStep(target: DisplayIdentitySnapshot(target), effect: .show),
            removeB
        ])
        try model.saveDisplayAction(action)

        XCTAssertNil(model.displayActionRunBlocker(for: action), "projected Show must release the verified source and its live mirror-set membership")
        let response = await run(model, id: action.id)
        XCTAssertEqual(response.outcome, .done, response.error ?? "missing Action result")
        XCTAssertEqual(response.steps?.map(\.outcome), [.done, .done])
        XCTAssertEqual(showWrites, 1)
        XCTAssertEqual(hideWrites, 1)
        XCTAssertFalse(model.isRemovedDisplay(targetUUID))
        XCTAssertTrue(model.isRemovedDisplay(mainUUID))
    }

    func testPartialInputStopsLaterStepsAndKeepsPerStepEvidence() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(hiddenStatus())
        var showWrites = 0
        var coverRequests: [Set<UInt32>] = []
        let model = makeModel(
            defaults: defaults,
            box: box,
            show: { _, input in
                showWrites += 1
                box.value = self.noneStatus()
                return DisplayInputOutcome(state: .failed, requestedInput: input, detail: "fixture return-input failure")
            },
            cover: { coverRequests.append($0); return [] }
        )
        await settleQuiescence(model)
        let action = DisplayAction(name: "Show then stop", steps: [
            DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == targetUUID })), effect: .show),
            DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == sourceUUID })))
        ])
        try model.saveDisplayAction(action)

        let result = await run(model, id: action.id)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.steps?.map(\.outcome), [.partial, .notRun])
        XCTAssertEqual(result.steps?.first?.inputOutcome, .failed)
        XCTAssertNotNil(result.steps?.first?.inputDetail, "the partial input result remains visible per step")
        XCTAssertEqual(showWrites, 1)
        XCTAssertTrue(coverRequests.isEmpty)
        XCTAssertFalse(model.isRemovedDisplay(targetUUID), "completed Show state remains available after the later step is skipped")
    }

    func testActionTopologyNotificationsContinueAfterVerifiedRemoveAndShow() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(noneStatus())
        var model: AppModel!
        var writes: [String] = []
        model = makeModel(
            defaults: defaults, box: box,
            hide: { _, _, input in
                writes.append("hide")
                model.displayParametersChanged()
                box.value = self.hiddenStatus()
                return DisplayInputOutcome(state: .verified, requestedInput: input)
            },
            show: { _, input in
                writes.append("show")
                model.displayParametersChanged()
                box.value = self.noneStatus()
                return DisplayInputOutcome(state: .verified, requestedInput: input)
            },
            cover: { _ in writes.append("cover"); return [] }
        )
        var lateNotifications = 0
        model.onStatusChange = {
            if model.runningDisplayAction?.currentStep == 2 {
                lateNotifications += 1
                model.displayParametersChanged()
            }
        }
        var remove = try saveRemovalAction(on: model)
        remove.steps.append(DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == sourceUUID }))))
        try model.saveDisplayAction(remove, replacing: remove.id)
        let hidden = await run(model, id: remove.id)
        XCTAssertEqual(hidden.outcome, .done)
        XCTAssertEqual(hidden.steps?.map(\.outcome), [.done, .done])
        XCTAssertEqual(writes.prefix(2), ["hide", "cover"])

        let show = DisplayAction(name: "Show both", steps: remove.steps.map {
            DisplayActionStep(target: $0.target, effect: .show)
        })
        try model.saveDisplayAction(show)
        let shown = await run(model, id: show.id)
        XCTAssertEqual(shown.outcome, .done)
        XCTAssertEqual(shown.steps?.map(\.outcome), [.done, .done])
        XCTAssertFalse(model.isBlackoutHidden(sourceUUID))
        XCTAssertFalse(model.isRemovedDisplay(targetUUID))
        XCTAssertGreaterThanOrEqual(lateNotifications, 2, "late own notifications must not cancel either run")
        model.onStatusChange = nil
    }

    func testSleepDuringTopologyWriteStillStopsAction() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(noneStatus())
        var model: AppModel!
        model = makeModel(defaults: defaults, box: box, hide: { _, _, _ in
            model.displayParametersChanged()
            model.beginDisplaySleepTransition()
            box.value = self.hiddenStatus()
            return .notRequested
        })
        var action = try saveRemovalAction(on: model)
        action.steps.append(DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == sourceUUID }))))
        try model.saveDisplayAction(action, replacing: action.id)
        let result = await run(model, id: action.id)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.steps?.map(\.outcome), [.done, .notRun])
        XCTAssertTrue(result.summary.contains("interrupted after Step 1"))
        XCTAssertTrue(result.summary.contains("sleeping or changing"))
        XCTAssertFalse(model.isBlackoutHidden(sourceUUID))
        XCTAssertTrue(model.isRemovedDisplay(targetUUID))
    }

    func testTopologyNotificationDoesNotBypassFreshIdentityChecks() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(noneStatus())
        let inventory = DisplayRecordsBox(displays)
        var model: AppModel!
        model = makeModel(defaults: defaults, box: box, displayProvider: { inventory.value }, hide: { _, _, _ in
            inventory.value.removeAll { $0.uuid == self.sourceUUID }
            model.displayParametersChanged()
            box.value = self.hiddenStatus()
            return .notRequested
        })
        var action = try saveRemovalAction(on: model)
        action.steps.append(DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == sourceUUID }))))
        try model.saveDisplayAction(action, replacing: action.id)
        let result = await run(model, id: action.id)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.steps?.map(\.outcome), [.done, .refused])
        XCTAssertTrue(result.steps?.last?.desktopSummary.localizedCaseInsensitiveContains("changed after") == true)
        XCTAssertFalse(model.isBlackoutHidden(sourceUUID))
    }

    func testChangedInventoryNotificationBetweenStepsStillInterrupts() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(noneStatus())
        let inventory = DisplayRecordsBox(displays)
        let model = makeModel(defaults: defaults, box: box, displayProvider: { inventory.value }, hide: { _, _, _ in
            box.value = self.hiddenStatus()
            return .notRequested
        })
        var action = try saveRemovalAction(on: model)
        action.steps.append(DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == sourceUUID }))))
        try model.saveDisplayAction(action, replacing: action.id)
        model.onStatusChange = {
            if model.runningDisplayAction?.currentStep == 2 {
                model.onStatusChange = nil
                inventory.value.removeAll { $0.uuid == self.alternateUUID }
                model.displayParametersChanged()
            }
        }
        let result = await run(model, id: action.id)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.steps?.map(\.outcome), [.done, .refused])
        XCTAssertTrue(result.steps?.last?.desktopSummary.contains("interrupted") == true)
        XCTAssertFalse(model.isBlackoutHidden(sourceUUID))
    }

    func testInterruptionAfterFinalSuccessfulStepDoesNotContradictSuccess() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var model: AppModel!
        var interrupted = false
        model = makeModel(defaults: defaults, cover: { _ in
            if !interrupted {
                interrupted = true
                model.displayConfigurationChanged(restartWatcher: true)
            }
            return []
        })
        let action = try saveBlackOutAction(on: model)
        let result = await run(model, id: action.id)
        XCTAssertEqual(result.outcome, .done)
        XCTAssertEqual(result.steps?.map(\.outcome), [.done])
        XCTAssertFalse(result.summary.contains("interrupted"))
        XCTAssertFalse(result.summary.contains("stopped"))
    }

    func testSuccessfulInputDetailsAreNotWarnings() {
        for input in [DisplayInputOutcome.State.verified, .alreadySelected] {
            let step = AppControlActionStepResult(index: 1, targetUUID: targetUUID, effect: "show",
                outcome: .done, desktopSummary: "Shown.", inputOutcome: input, inputDetail: "Successful input result.")
            XCTAssertFalse(DisplayActionPresentation.stepNeedsAttention(step))
        }
        let omitted = AppControlActionStepResult(index: 1, targetUUID: targetUUID, effect: "show",
            outcome: .done, desktopSummary: "Shown.", inputOutcome: .notRequested,
            inputDetail: "Didn’t switch the monitor input: invalid saved input.")
        XCTAssertTrue(DisplayActionPresentation.stepNeedsAttention(omitted))
        let notRequested = AppControlActionStepResult(index: 1, targetUUID: targetUUID, effect: "show",
            outcome: .done, desktopSummary: "Shown.", inputOutcome: .notRequested)
        XCTAssertFalse(DisplayActionPresentation.stepNeedsAttention(notRequested))
        for outcome in [AppControlOutcome.partial, .failed, .refused, .busy, .recoveryNeeded] {
            let step = AppControlActionStepResult(index: 1, targetUUID: targetUUID, effect: "show",
                outcome: outcome, desktopSummary: "Needs attention.")
            XCTAssertTrue(DisplayActionPresentation.stepNeedsAttention(step))
        }
        for input in [DisplayInputOutcome.State.failed, .skipped, .unverified, .notAttempted] {
            let step = AppControlActionStepResult(index: 1, targetUUID: targetUUID, effect: "show",
                outcome: .partial, desktopSummary: "Shown.", inputOutcome: input)
            XCTAssertTrue(DisplayActionPresentation.stepNeedsAttention(step))
        }
    }

    func testDisplayReconfigurationInterruptsAfterCompletedStepWithoutUndoingIt() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var model: AppModel!
        var coverRequests: [Set<UInt32>] = []
        var interrupted = false
        model = makeModel(
            defaults: defaults,
            cover: { ids in
                coverRequests.append(ids)
                if !interrupted {
                    interrupted = true
                    model.displayConfigurationChanged(restartWatcher: true)
                }
                return []
            }
        )
        let action = DisplayAction(name: "Interrupt after first step", steps: [
            DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == targetUUID }))),
            DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == sourceUUID })))
        ])
        try model.saveDisplayAction(action)

        let result = await run(model, id: action.id)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.steps?.map(\.outcome), [.done, .notRun])
        XCTAssertTrue(result.summary.contains("interrupted after Step 1"))
        XCTAssertTrue(result.summary.contains("sleeping or changing"))
        XCTAssertEqual(coverRequests, [[202], [202]], "completion replays deferred hidden-display safety reconciliation after the lifecycle transition")
        XCTAssertTrue(model.isBlackoutHidden(targetUUID), "a completed Hide is not rolled back on lifecycle interruption")
        XCTAssertFalse(model.isBlackoutHidden(sourceUUID))
    }

    func testNoOpRemovalStillRequiresReviewedSetup() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(noneStatus())
        var hideWrites = 0
        let model = makeModel(
            defaults: defaults, box: box,
            hide: { _, _, _ in hideWrites += 1; box.value = self.hiddenStatus(); return .notRequested }
        )
        let action = try saveRemovalAction(on: model)
        let first = await run(model, id: action.id)
        XCTAssertEqual(first.outcome, .done)
        XCTAssertTrue(model.isRemovedDisplay(targetUUID))

        var changedPreferences = model.hidePreferences
        let configuration = try XCTUnwrap(changedPreferences[targetUUID])
        changedPreferences[targetUUID] = DisplayHideConfiguration(
            target: configuration.target,
            enabled: configuration.enabled,
            source: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == alternateUUID })),
            awayInput: configuration.awayInput == 0x12 ? 0x13 : 0x12,
            returnInput: configuration.returnInput
        )
        defaults.set(try JSONEncoder().encode(changedPreferences), forKey: "displayHidePreferences")
        let reloaded = makeModel(defaults: defaults, box: box, hide: { _, _, _ in hideWrites += 1; return .notRequested })
        await settleQuiescence(reloaded)
        let repeated = await run(reloaded, id: action.id)
        XCTAssertEqual(repeated.outcome, .refused)
        XCTAssertTrue(repeated.error?.contains("Step 1:") == true)
        XCTAssertTrue(repeated.error?.localizedCaseInsensitiveContains("setup changed") == true)
        XCTAssertEqual(hideWrites, 1, "a verified Remove no-op still refuses on reviewed-setup drift")
    }

    func testNoOpBlackOutStillChecksCurrentIdentityAndLifecycle() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let inventory = DisplayRecordsBox(displays)
        var coverRequests: [Set<UInt32>] = []
        let model = makeModel(
            defaults: defaults,
            displayProvider: { inventory.value },
            cover: { coverRequests.append($0); return [] }
        )
        let action = try saveBlackOutAction(on: model)
        let first = await run(model, id: action.id)
        XCTAssertEqual(first.outcome, .done)
        let original = try XCTUnwrap(inventory.value.first { $0.uuid == targetUUID })
        inventory.value.removeAll { $0.uuid == targetUUID }
        inventory.value.append(display(index: 2, id: 222, uuid: targetUUID, name: "Replacement target", main: false, serial: 999))
        model.refreshDisplays()
        let coverCountAfterIdentityRefresh = coverRequests.count
        let identityBlocked = await run(model, id: action.id)
        XCTAssertEqual(identityBlocked.outcome, .refused)
        XCTAssertTrue(identityBlocked.error?.localizedCaseInsensitiveContains("identity changed") == true)
        XCTAssertEqual(coverRequests.count, coverCountAfterIdentityRefresh)

        inventory.value.removeAll { $0.uuid == targetUUID }
        inventory.value.append(original)
        model.refreshDisplays()
        let coverCountAfterRestoringIdentity = coverRequests.count
        model.beginDisplaySleepTransition()
        let lifecycleBlocked = await run(model, id: action.id)
        XCTAssertEqual(lifecycleBlocked.outcome, .refused)
        XCTAssertTrue(lifecycleBlocked.error?.localizedCaseInsensitiveContains("sleep") == true)
        XCTAssertEqual(coverRequests.count, coverCountAfterRestoringIdentity)
        model.setDisplayLifecycleTransitioning(false)
    }

    func testPreflightNoOpRemovalCannotBecomeWriteAfterSourceReconnects() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let inventory = DisplayRecordsBox(displays)
        let box = StatusBox(hiddenStatus())
        var pendingCleanup: ((Bool, String?) -> Void)?
        var holdCleanup = false
        var hideWrites = 0
        let model = makeModel(
            defaults: defaults, box: box, displayProvider: { inventory.value },
            hide: { _, _, _ in hideWrites += 1; return .notRequested },
            quiesce: { completion in
                if holdCleanup { pendingCleanup = completion } else { completion(true, nil) }
            }
        )
        await settleQuiescence(model)
        let removal = try saveRemovalAction(on: model)
        let action = DisplayAction(name: "Mixed no-op removal", steps: [
            DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == alternateUUID })), effect: .blackOut),
            try XCTUnwrap(removal.steps.first)
        ])
        try model.saveDisplayAction(action)
        holdCleanup = true
        var result: AppControlResponse?
        model.runDisplayAction(id: action.id) { result = $0 }
        XCTAssertNotNil(pendingCleanup)
        box.value = noneStatus()
        inventory.value.removeAll { $0.uuid == mainUUID }
        inventory.value.append(display(index: 1, id: 1101, uuid: mainUUID, name: "Main", main: true))
        holdCleanup = false
        pendingCleanup?(true, nil)
        for _ in 0..<100 where result == nil { await Task.yield() }
        let response = try XCTUnwrap(result)
        XCTAssertEqual(response.steps?.map(\.outcome), [.done, .refused])
        XCTAssertTrue(response.steps?.last?.desktopSummary.contains("state changed") == true)
        XCTAssertEqual(hideWrites, 0, "a preflight no-op cannot capture a new mirror-source ID inside the running Action")
    }

    func testSavedBlackoutAndShowAllowMatchingZeroSerialButRefuseChangedMetadata() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let inventory = DisplayRecordsBox(displays.filter { $0.uuid != targetUUID } + [
            display(index: 2, id: 202, uuid: targetUUID, name: "No serial", main: false, serial: 0)
        ])
        var covers: [Set<UInt32>] = []
        let model = makeModel(defaults: defaults, displayProvider: { inventory.value }, cover: { covers.append($0); return [] })
        let blackout = try saveBlackOutAction(on: model)
        let show = DisplayAction(name: "Show no serial", steps: [DisplayActionStep(target: blackout.target, effect: .show)])
        try model.saveDisplayAction(show)
        let hidden = await run(model, id: blackout.id)
        XCTAssertEqual(hidden.outcome, .done)
        let shown = await run(model, id: show.id)
        XCTAssertEqual(shown.outcome, .done)
        inventory.value.removeAll { $0.uuid == targetUUID }
        inventory.value.append(display(index: 2, id: 2202, uuid: targetUUID, name: "No serial", main: false, serial: 0))
        let remapped = await run(model, id: blackout.id)
        XCTAssertEqual(remapped.outcome, .done)
        XCTAssertTrue(covers.contains([2202]))
        let restored = await run(model, id: show.id)
        XCTAssertEqual(restored.outcome, .done)
        inventory.value.removeAll { $0.uuid == targetUUID }
        inventory.value.append(display(index: 2, id: 2202, uuid: targetUUID, name: "Different serial", main: false, serial: 999))
        let coverCount = covers.count
        for action in [blackout, show] {
            let refused = await run(model, id: action.id)
            XCTAssertEqual(refused.outcome, .refused)
        }
        XCTAssertEqual(covers.count, coverCount)
    }

    func testSavedActionRemapsNumericDisplayIDForANewRun() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let inventory = DisplayRecordsBox(displays)
        var coverRequests: [Set<UInt32>] = []
        let model = makeModel(
            defaults: defaults,
            displayProvider: { inventory.value },
            cover: { coverRequests.append($0); return [] }
        )
        let action = try saveBlackOutAction(on: model)
        let replacement = display(index: 2, id: 2202, uuid: targetUUID, name: "Renamed target", main: false)
        inventory.value.removeAll { $0.uuid == targetUUID }
        inventory.value.append(replacement)
        model.refreshDisplays()

        let result = await run(model, id: action.id)
        XCTAssertEqual(result.outcome, .done)
        XCTAssertTrue(coverRequests.contains([2202]), "the new operation captures the current numeric display ID")
        XCTAssertFalse(coverRequests.contains([202]), "the persisted reference never supplies an old ID to a writer")
        let savedTarget = try XCTUnwrap(model.displayActions.actions.first?.target)
        XCTAssertTrue(model.identityIsCurrent(savedTarget), "saved identity matching ignores ID and presentation-name changes")
    }

    func testRunningMultiStepActionDoesNotRebindAfterNumericIDChange() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let inventory = DisplayRecordsBox(displays)
        var coverRequests: [Set<UInt32>] = []
        let model = makeModel(
            defaults: defaults,
            displayProvider: { inventory.value },
            cover: { ids in
                coverRequests.append(ids)
                if ids.contains(202) {
                    inventory.value.removeAll { $0.uuid == self.sourceUUID }
                    inventory.value.append(self.display(index: 3, id: 3303, uuid: self.sourceUUID, name: "Mirror source", main: false))
                }
                return []
            }
        )
        let action = DisplayAction(name: "Two displays", steps: [
            DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == targetUUID })), effect: .blackOut),
            DisplayActionStep(target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == sourceUUID })), effect: .blackOut)
        ])
        try model.saveDisplayAction(action)

        let result = await run(model, id: action.id)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.steps?.map(\.outcome), [.done, .refused])
        XCTAssertTrue(result.steps?.last?.desktopSummary.localizedCaseInsensitiveContains("changed after this action was prepared") == true)
        XCTAssertEqual(coverRequests, [[202]], "the second step never writes to the display's replacement numeric ID")
    }

    func testSavedActionsRefuseMissingDuplicateAndChangedIdentityWithoutWrites() async throws {
        let cases: [(String, (inout [DisplayRecord]) -> Void, String)] = [
            ("missing", { $0.removeAll { $0.uuid == self.targetUUID } }, "missing"),
            ("duplicate", { $0.append(self.display(index: 5, id: 505, uuid: self.targetUUID, name: "Duplicate", main: false)) }, "ambiguous"),
            ("changed", { records in
                records.removeAll { $0.uuid == self.targetUUID }
                records.append(self.display(index: 2, id: 202, uuid: self.targetUUID, name: "Changed target", main: false, serial: 999))
            }, "identity changed")
        ]
        for (name, change, reason) in cases {
            let defaults = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
            let inventory = DisplayRecordsBox(displays)
            var coverRequests: [Set<UInt32>] = []
            let model = makeModel(
                defaults: defaults,
                displayProvider: { inventory.value },
                cover: { coverRequests.append($0); return [] }
            )
            let action = try saveBlackOutAction(on: model)
            change(&inventory.value)
            model.refreshDisplays()

            let result = await run(model, id: action.id)
            XCTAssertEqual(result.outcome, .refused, name)
            XCTAssertTrue(result.error?.localizedCaseInsensitiveContains(reason) == true, result.error ?? name)
            XCTAssertFalse(coverRequests.contains(where: { !$0.isEmpty }), "\(name) identity refusal must occur before any display write")
        }
    }

    func testNoOpBlackOutStillRefusesAfterCleanupFailure() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var cleanupSucceeds = true
        var coverRequests: [Set<UInt32>] = []
        let model = makeModel(
            defaults: defaults,
            cover: { coverRequests.append($0); return [] },
            quiesce: { completion in completion(cleanupSucceeds, cleanupSucceeds ? nil : "fake cleanup failure") }
        )
        let alreadyHidden = try saveBlackOutAction(on: model)
        let initialRun = await run(model, id: alreadyHidden.id)
        XCTAssertEqual(initialRun.outcome, .done)
        let writesBeforeFailure = coverRequests.count

        let other = DisplayAction(name: "Cleanup failure trigger", target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == sourceUUID })))
        try model.saveDisplayAction(other)
        cleanupSucceeds = false
        let cleanupFailure = await run(model, id: other.id)
        XCTAssertEqual(cleanupFailure.outcome, .failed)
        XCTAssertEqual(coverRequests.count, writesBeforeFailure)

        let repeated = await run(model, id: alreadyHidden.id)
        XCTAssertEqual(repeated.outcome, .refused)
        XCTAssertTrue(repeated.error?.localizedCaseInsensitiveContains("cleanup needs attention") == true)
        XCTAssertEqual(coverRequests.count, writesBeforeFailure)
    }

    func testNoOpActionIsBusyWhileAnotherActionOwnsTheLease() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        var quiesceCount = 0
        var delayedQuiescence: ((Bool, String?) -> Void)?
        var coverRequests: [Set<UInt32>] = []
        let model = makeModel(
            defaults: defaults,
            cover: { coverRequests.append($0); return [] },
            quiesce: { completion in
                quiesceCount += 1
                if quiesceCount == 1 { completion(true, nil) }
                else { delayedQuiescence = completion }
            }
        )
        let hiddenAction = try saveBlackOutAction(on: model)
        let hiddenResult = await run(model, id: hiddenAction.id)
        XCTAssertEqual(hiddenResult.outcome, .done)
        let active = DisplayAction(name: "Lease owner", target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == sourceUUID })))
        try model.saveDisplayAction(active)
        let finished = expectation(description: "the lease owner completes")
        model.runDisplayAction(id: active.id) { _ in finished.fulfill() }
        XCTAssertEqual(model.runningDisplayAction?.id, active.id)

        let busy = await run(model, id: hiddenAction.id)
        XCTAssertEqual(busy.outcome, .busy)
        XCTAssertTrue(busy.error?.contains("Lease owner") == true)
        XCTAssertEqual(coverRequests, [[202]])

        delayedQuiescence?(true, nil)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(coverRequests, [[202], [202, 303]])
    }

    func testNoOpBlackOutStillRefusesWhenRecoveryNeedsAttention() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(noneStatus())
        var coverRequests: [Set<UInt32>] = []
        let model = makeModel(defaults: defaults, box: box, cover: { coverRequests.append($0); return [] })
        let action = try saveBlackOutAction(on: model)
        let first = await run(model, id: action.id)
        XCTAssertEqual(first.outcome, .done)
        let coverCount = coverRequests.count
        box.value = unreadableStatus()
        model.refreshHandoffStatus()
        await settleQuiescence(model)
        XCTAssertFalse(model.protectionQuiescencePending, "fake recovery cleanup must settle before testing the recovery blocker")

        let repeated = await run(model, id: action.id)
        XCTAssertEqual(repeated.outcome, .recoveryNeeded, repeated.error ?? "missing Action error")
        XCTAssertTrue(repeated.error?.localizedCaseInsensitiveContains("unreadable journal") == true, repeated.error ?? "missing Action error")
        XCTAssertEqual(coverRequests.count, coverCount, "a hidden-display no-op cannot bypass recovery checks")
    }

    func testRemoveNoOpStillRequiresExperimentalConsent() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName(defaults)) }
        let box = StatusBox(noneStatus())
        var hideWrites = 0
        let model = makeModel(
            defaults: defaults, box: box,
            hide: { _, _, _ in hideWrites += 1; box.value = self.hiddenStatus(); return .notRequested }
        )
        let action = try saveRemovalAction(on: model)
        let first = await run(model, id: action.id)
        XCTAssertEqual(first.outcome, .done)
        model.setExperimentalFeaturesEnabled(false)
        let repeated = await run(model, id: action.id)
        XCTAssertEqual(repeated.outcome, .refused)
        XCTAssertTrue(repeated.error?.contains("Experimental features") == true)
        XCTAssertEqual(hideWrites, 1)
    }

    private func saveRemovalAction(on model: AppModel) throws -> DisplayAction {
        var action = model.makeNewDisplayAction(selectedDisplayID: targetUUID)
        action.name = "Remove target"
        action.effect = .removeFromDesktop
        try model.saveDisplayAction(action)
        return try XCTUnwrap(model.displayActions.actions.first { $0.id == action.id })
    }

    private func saveBlackOutAction(on model: AppModel) throws -> DisplayAction {
        var action = model.makeNewDisplayAction(selectedDisplayID: targetUUID)
        action.name = "Black out target"
        action.effect = .blackOut
        try model.saveDisplayAction(action)
        return try XCTUnwrap(model.displayActions.actions.first { $0.id == action.id })
    }

    private func run(_ model: AppModel, id: UUID) async -> AppControlResponse {
        await withCheckedContinuation { continuation in
            model.runDisplayAction(id: id) { continuation.resume(returning: $0) }
        }
    }

    private func awaitControl(_ model: AppModel, _ request: AppControlRequest) async -> AppControlResponse {
        await model.handleDisplayControlRequest(request)
    }

    private func awaitShow(_ model: AppModel) async -> DisplayOperationResult {
        await withCheckedContinuation { continuation in
            model.show(targetUUID: targetUUID) { continuation.resume(returning: $0) }
        }
    }

    private func makeModel(
        defaults: UserDefaults,
        box: StatusBox? = nil,
        displayProvider: (() -> [DisplayRecord])? = nil,
        isMirrored: ((UInt32) -> Bool)? = nil,
        hide: @escaping (DisplayHideIdentity, DisplayHideIdentity, UInt8?) throws -> DisplayInputOutcome = { _, _, _ in .notRequested },
        show: @escaping (String, UInt8?) throws -> DisplayInputOutcome = { _, _ in .notRequested },
        cover: @escaping @MainActor (Set<UInt32>) -> Set<UInt32> = { _ in [] },
        quiesce: @escaping ProtectionQuiesce = { $0(true, nil) }
    ) -> AppModel {
        let state = box ?? StatusBox(noneStatus())
        return AppModel(
            defaults: defaults,
            displayProvider: displayProvider ?? { self.displays },
            idleSecondsProvider: { nil },
            isDisplayMirrored: isMirrored ?? { _ in false },
            inspectHandoff: { state.value },
            hideDisplay: hide,
            showDisplay: show,
            checkDDCInput: { DDCInputReading(displayID: $0.displayID, uuid: $0.uuid, current: 0x0F) },
            coverDisplays: cover,
            quiesceProtection: quiesce
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = suiteName(nil)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "experimentalFeaturesEnabled")
        var preferences = DisplayHidePreferences()
        preferences[targetUUID] = DisplayHideConfiguration(
            target: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == targetUUID })),
            enabled: true,
            source: DisplayIdentitySnapshot(try XCTUnwrap(displays.first { $0.uuid == mainUUID })),
            awayInput: 0x11,
            returnInput: 0x10
        )
        defaults.set(try JSONEncoder().encode(preferences), forKey: "displayHidePreferences")
        return defaults
    }

    private func suiteName(_ defaults: UserDefaults?) -> String {
        "panelctl-display-actions-\(ProcessInfo.processInfo.processIdentifier)"
    }

    private func display(index: Int, id: UInt32, uuid: String, name: String, main: Bool, serial: UInt32? = nil) -> DisplayRecord {
        DisplayRecord(
            index: index, id: id, uuid: uuid, name: name, active: true, online: true,
            asleep: false, builtin: false, main: main, vendor: UInt32(index), model: UInt32(index * 10),
            serial: serial ?? UInt32(index * 100),
            bounds: DisplayBounds(CGRect(x: CGFloat((index - 1) * 1920), y: 0, width: 1920, height: 1080)),
            pixelWidth: 1920, pixelHeight: 1080
        )
    }

    private func identity(_ record: DisplayRecord) -> DisplayHandoffIdentity {
        DisplayHandoffIdentity(DisplayHideIdentity(
            uuid: record.uuid!, displayID: record.id, name: record.name,
            vendor: record.vendor, model: record.model, serial: record.serial
        ))
    }

    private func noneStatus() -> DisplayHandoffStatus {
        DisplayHandoffStatus(state: .none, journalPath: "/tmp/panelctl-actions-fixture/current.json")
    }

    private func unreadableStatus() -> DisplayHandoffStatus {
        DisplayHandoffStatus(
            state: .recovery,
            journalPath: "/tmp/panelctl-actions-fixture/current.json",
            reason: "unreadable journal",
            inspectionFailure: "unreadable journal"
        )
    }

    private func unverifiedRemovalStatus() -> DisplayHandoffStatus {
        let target = try! XCTUnwrap(displays.first { $0.uuid == targetUUID })
        let source = try! XCTUnwrap(displays.first { $0.uuid == mainUUID })
        let targetIdentity = identity(target)
        let sourceIdentity = identity(source)
        let removal = DisplayHandoffRemoval(
            id: "unverified-action-removal", target: targetIdentity, source: sourceIdentity,
            state: "needsAttention", isUnresolved: true, canShow: false,
            reason: "The current desktop topology could not be verified.", topologyVerified: false
        )
        return DisplayHandoffStatus(
            state: .recovery, target: targetIdentity, source: sourceIdentity,
            journalPath: "/tmp/panelctl-actions-fixture/current.json", journalID: "unverified-action-journal",
            reason: "The current desktop topology could not be verified.", canShow: false,
            observations: [DisplayHideObservation(
                identity: DisplayHideIdentity(
                    uuid: targetUUID, displayID: target.id, name: target.name,
                    vendor: target.vendor, model: target.model, serial: target.serial
                ),
                state: .recoveryNeeded,
                source: DisplayHideIdentity(
                    uuid: sourceUUID, displayID: source.id, name: source.name,
                    vendor: source.vendor, model: source.model, serial: source.serial
                ),
                detail: "Unverified topology.", isJournalTarget: true
            )],
            mirrorTopologyVerified: false, removals: [removal]
        )
    }

    private func verifiedRemovalStatus(
        target: DisplayRecord,
        source: DisplayRecord,
        journalID: String
    ) -> DisplayHandoffStatus {
        func hideIdentity(_ display: DisplayRecord) -> DisplayHideIdentity {
            DisplayHideIdentity(
                uuid: display.uuid!, displayID: display.id, name: display.name,
                vendor: display.vendor, model: display.model, serial: display.serial
            )
        }
        let targetIdentity = identity(target)
        let sourceIdentity = identity(source)
        let removal = DisplayHandoffRemoval(
            id: journalID, target: targetIdentity, source: sourceIdentity,
            state: "mirrored", isUnresolved: true, canShow: true,
            reason: nil, topologyVerified: true
        )
        return DisplayHandoffStatus(
            state: .hidden, target: targetIdentity, source: sourceIdentity,
            journalPath: "/tmp/panelctl-actions-fixture/\(journalID).json", journalID: journalID,
            canShow: true,
            observations: [DisplayHideObservation(
                identity: hideIdentity(target), state: .hiddenByPanelCtl,
                source: hideIdentity(source), detail: nil, isJournalTarget: true
            )],
            mirrorTopologyVerified: true, baselineIdentity: "baseline-\(journalID)",
            removals: [removal]
        )
    }

    private func hiddenStatus() -> DisplayHandoffStatus {
        let target = try! XCTUnwrap(displays.first { $0.uuid == targetUUID })
        let source = try! XCTUnwrap(displays.first { $0.uuid == mainUUID })
        let targetIdentity = identity(target)
        let sourceIdentity = identity(source)
        let observation = DisplayHideObservation(
            identity: DisplayHideIdentity(
                uuid: targetUUID, displayID: target.id, name: target.name,
                vendor: target.vendor, model: target.model, serial: target.serial
            ),
            state: .hiddenByPanelCtl,
            source: DisplayHideIdentity(
                uuid: mainUUID, displayID: source.id, name: source.name,
                vendor: source.vendor, model: source.model, serial: source.serial
            ),
            detail: nil,
            isJournalTarget: true
        )
        let removal = DisplayHandoffRemoval(
            id: "action-fixture-removal", target: targetIdentity, source: sourceIdentity,
            state: "mirrored", isUnresolved: true, canShow: true,
            reason: nil, topologyVerified: true
        )
        return DisplayHandoffStatus(
            state: .hidden, target: targetIdentity, source: sourceIdentity,
            journalPath: "/tmp/panelctl-actions-fixture/current.json", journalID: "action-fixture",
            canShow: true, recoveryCommand: "panelctl recovery status",
            observations: [observation], mirrorTopologyVerified: true,
            baselineIdentity: "actions-fixture-baseline", removals: [removal]
        )
    }

    private func settleQuiescence(_ model: AppModel) async {
        for _ in 0..<20 where model.protectionQuiescencePending {
            await Task.yield()
        }
    }
}

private final class StatusBox {
    var value: DisplayHandoffStatus
    init(_ value: DisplayHandoffStatus) { self.value = value }
}

private final class DisplayRecordsBox {
    var value: [DisplayRecord]
    init(_ value: [DisplayRecord]) { self.value = value }
}
