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

        let persisted = try XCTUnwrap(defaults.data(forKey: "displayActions"))
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
        XCTAssertTrue(model.displayActionRunBlocker(for: action)?.contains("Needs review") == true)
        XCTAssertEqual(model.displayActionStatus(for: action), "Display setup changed. Edit to review.")
        var unreviewed = action
        unreviewed.reviewedRemoval = nil
        XCTAssertEqual(model.displayActionStatus(for: unreviewed), "Display setup changed. Edit to review.")

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
        XCTAssertTrue(response.error?.localizedCaseInsensitiveContains("unreadable journal") == true)
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
        XCTAssertEqual(busyModel.hideOperation, .hiding(targetUUID))
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
            isDisplayMirrored: { _ in false },
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

    private func display(index: Int, id: UInt32, uuid: String, name: String, main: Bool) -> DisplayRecord {
        DisplayRecord(
            index: index, id: id, uuid: uuid, name: name, active: true, online: true,
            asleep: false, builtin: false, main: main, vendor: UInt32(index), model: UInt32(index * 10),
            serial: UInt32(index * 100),
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
