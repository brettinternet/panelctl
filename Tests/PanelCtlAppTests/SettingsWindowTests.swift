import AppKit
import SwiftUI
import XCTest
@testable import PanelCtlApp
@testable import PanelCtlCore

@MainActor
final class SettingsWindowTests: XCTestCase {
    private static let mainUUID = "00000000-0000-0000-0000-0000000000A1"
    private static let sideUUID = "00000000-0000-0000-0000-0000000000A2"
    private static let laptopUUID = "00000000-0000-0000-0000-0000000000A3"

    private var displays: [DisplayRecord] {
        [
            Self.display(index: 1, id: 11, uuid: Self.mainUUID, name: "DELL AW3423DW", main: true),
            Self.display(index: 2, id: 12, uuid: Self.sideUUID, name: "DELL S2721DGF", main: false),
            Self.display(index: 3, id: 13, uuid: Self.laptopUUID, name: "Built-in Retina Display", main: false, builtin: true)
        ]
    }

    override func tearDown() {
        NSApplication.shared.windows
            .filter { $0.identifier == SettingsWindowController.windowIdentifier }
            .forEach { $0.close() }
        super.tearDown()
    }

    func testDockPresenceFollowsSettingsLifetime() throws {
        try requireInteractiveUI()
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        let originalMenu = app.mainMenu
        let originalWindowsMenu = app.windowsMenu
        let originalHelpMenu = app.helpMenu
        defer {
            app.mainMenu = originalMenu
            app.windowsMenu = originalWindowsMenu
            app.helpMenu = originalHelpMenu
        }
        let (model, defaults) = try makeModel()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let delegate = AppDelegate()
        delegate.model = model
        delegate.configureMainMenu()
        var presentations: [Bool] = []
        let controller = SettingsWindowController(model: model) { presentations.append($0) }
        let window = try XCTUnwrap(controller.window)

        XCTAssertTrue(presentations.isEmpty)
        controller.present()
        XCTAssertEqual(presentations, [true])
        XCTAssertEqual(app.activationPolicy(), originalPolicy, "fixtures must not promote XCTest into the Dock")
        XCTAssertTrue(window.isVisible)
        window.miniaturize(nil)
        XCTAssertEqual(presentations, [true], "minimizing is not closing")
        controller.present()
        XCTAssertFalse(window.isMiniaturized)
        XCTAssertEqual(presentations, [true, true])

        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(presentations, [true, true, false])
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(app))

        controller.present()
        XCTAssertEqual(presentations, [true, true, false, true])
        XCTAssertTrue(window.isVisible)
        let closeItem = try XCTUnwrap(app.mainMenu?.items
            .first { $0.title == "File" }?.submenu?.items.first)
        XCTAssertEqual(closeItem.keyEquivalent, "w")
        XCTAssertEqual(closeItem.keyEquivalentModifierMask, .command)
        XCTAssertEqual(closeItem.action, #selector(NSWindow.performClose(_:)))
        // Exercise the same responder action as Command-W.
        XCTAssertTrue(app.sendAction(try XCTUnwrap(closeItem.action), to: window, from: closeItem))
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(presentations, [true, true, false, true, false])
        XCTAssertEqual(app.activationPolicy(), originalPolicy)

        let quitItem = try XCTUnwrap(app.mainMenu?.items.first?.submenu?.items
            .first { $0.title == "Quit PanelCtl" })
        XCTAssertEqual(quitItem.keyEquivalent, "q")
        XCTAssertEqual(quitItem.keyEquivalentModifierMask, .command)
        XCTAssertTrue(quitItem.target === delegate)
    }

    func testDefaultSettingsFixtureLeavesHostActivationPolicyUnchanged() throws {
        try requireInteractiveUI()
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        let (model, defaults) = try makeModel()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let controller = SettingsWindowController(model: model)
        controller.present()
        XCTAssertEqual(app.activationPolicy(), originalPolicy)
        try XCTUnwrap(controller.window).close()
        XCTAssertEqual(app.activationPolicy(), originalPolicy)
    }

    func testDelegateForwardsSettingsPresentationWithoutPromotingTestHost() throws {
        try requireInteractiveUI()
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        let (model, defaults) = try makeModel()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        var presentations: [Bool] = []
        let delegate = AppDelegate { presentations.append($0) }
        delegate.model = model
        XCTAssertFalse(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
        XCTAssertEqual(presentations, [true])
        let window = try XCTUnwrap(app.windows.first {
            $0.identifier == SettingsWindowController.windowIdentifier && $0.isVisible
        })
        window.close()
        XCTAssertEqual(presentations, [true, false])
        XCTAssertFalse(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
        XCTAssertEqual(presentations, [true, false, true])
        window.close()
        XCTAssertEqual(presentations, [true, false, true, false])
        XCTAssertEqual(app.activationPolicy(), originalPolicy)
    }

    func testToolbarTabsAndKeyboardShortcutsReachEveryTab() throws {
        try requireInteractiveUI()
        let (model, defaults) = try makeModel()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let controller = SettingsWindowController(model: model)
        controller.present()
        let window = try XCTUnwrap(controller.window)
        let toolbar = try XCTUnwrap(window.toolbar)
        XCTAssertEqual(window.toolbarStyle, .preference)
        XCTAssertEqual(toolbar.items.map(\.label), ["Displays", "Automations", "General"])
        XCTAssertEqual(toolbar.items.map { $0.image?.accessibilityDescription }, ["Displays", "Automations", "General"])
        XCTAssertEqual(controller.selectedTab, .displays)
        XCTAssertEqual(toolbar.selectedItemIdentifier, SettingsTab.displays.toolbarIdentifier)
        XCTAssertEqual(window.title, "Displays")

        for (number, tab) in zip(1..., SettingsTab.allCases).reversed() {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\(number)",
                charactersIgnoringModifiers: "\(number)", isARepeat: false, keyCode: 0
            ))
            XCTAssertTrue(window.performKeyEquivalent(with: event), "Command-\(number)")
            XCTAssertEqual(controller.selectedTab, tab)
            XCTAssertEqual(toolbar.selectedItemIdentifier, tab.toolbarIdentifier)
            XCTAssertEqual(window.title, tab.title)
        }
        // VoiceOver sees each tab as a toolbar button and can press it.
        let axToolbar = try XCTUnwrap((window.accessibilityChildren() ?? [])
            .compactMap { $0 as? NSAccessibilityProtocol }
            .first { $0.accessibilityRole() == .toolbar })
        let axTabs = (axToolbar.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityProtocol }
        XCTAssertEqual(axTabs.map { $0.accessibilityRole() }, [.button, .button, .button])
        XCTAssertEqual(axTabs.map { $0.accessibilityTitle() }, ["Displays", "Automations", "General"])
        for (axTab, tab) in zip(axTabs, SettingsTab.allCases).reversed() {
            _ = axTab.accessibilityPerformPress()
            XCTAssertEqual(controller.selectedTab, tab)
        }

        controller.select(.general)
        controller.selectDisplay(uuid: Self.sideUUID)
        XCTAssertEqual(controller.selectedTab, .displays, "selecting a display opens Displays")
        XCTAssertEqual(controller.selectedDisplayID, Self.sideUUID.lowercased())
    }

    func testMigratedRuleAndPausedScopeFeedAutomationsControls() throws {
        _ = NSApplication.shared
        let resumeDate = Date().addingTimeInterval(3600)
        let (model, defaults) = try makeModel(configure: { defaults in
            var legacy = ProtectionPreferences()
            legacy.isEnabled = true
            legacy.didChooseDisplays = true
            legacy.selectedDisplayUUIDs = [Self.mainUUID]
            defaults.set(try JSONEncoder().encode(legacy), forKey: "blackoutPreferences")
            defaults.set(resumeDate, forKey: "snoozedUntil")
        })
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let original = model.automationPreferences
        let rule = try XCTUnwrap(original.rules.first)
        XCTAssertEqual(SettingsTab.automation.title, "Automations")
        XCTAssertEqual(rule.name, "Display protection")
        XCTAssertTrue(rule.isEnabled)
        XCTAssertTrue(original.isEnabled)
        XCTAssertEqual(model.snoozedUntil, resumeDate)
        XCTAssertEqual(ProtectionRulePresentation.ruleSwitchAccessibilityLabel(for: rule.name), "Turn on Display protection")
        XCTAssertEqual(ProtectionRulePresentation.editAccessibilityLabel(for: rule.name), "Edit Display protection")

        // Resume only clears the global snooze; no rule is enabled by the fixture.
        model.setProtectionRuleEnabled(false, id: rule.id)
        XCTAssertFalse(try XCTUnwrap(model.automationPreferences.rule(namedID: rule.id)).isEnabled)
        XCTAssertTrue(model.automationPreferences.isEnabled)
        model.resumeProtection()
        XCTAssertNil(model.snoozedUntil)
        XCTAssertFalse(try XCTUnwrap(model.automationPreferences.rule(namedID: rule.id)).isEnabled)
    }

    func testBlockedRuleReviewRoutesToDisplaysAndSelectsTheAffectedDisplay() throws {
        _ = NSApplication.shared
        let targetIdentity = DisplayHideIdentity(
            uuid: Self.sideUUID, displayID: 12, name: "DELL S2721DGF", vendor: 2, model: 20, serial: 200
        )
        let sourceIdentity = DisplayHideIdentity(
            uuid: Self.mainUUID, displayID: 11, name: "DELL AW3423DW", vendor: 1, model: 10, serial: 100
        )
        let target = DisplayHandoffIdentity(targetIdentity)
        let source = DisplayHandoffIdentity(sourceIdentity)
        let removal = DisplayHandoffRemoval(
            id: Self.sideUUID, target: target, source: source, state: "needsAttention",
            isUnresolved: true, canShow: false, reason: "Needs display recovery.", topologyVerified: false
        )
        let handoff = DisplayHandoffStatus(
            state: .recovery, target: target, source: source, journalPath: Self.journalPath,
            journalID: Self.sideUUID, reason: "Needs display recovery.", removals: [removal]
        )
        var settings = ProtectionPreferences()
        settings.selectedDisplayUUIDs = [Self.sideUUID]
        let rule = ProtectionRule(name: "Desk", isEnabled: true, settings: settings)
        let (model, defaults) = try makeModel(status: { handoff }, configure: { defaults in
            defaults.set(try JSONEncoder().encode(AutomationPreferences(isEnabled: true, rules: [rule])), forKey: "automationRules")
        })
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }

        XCTAssertTrue(model.protectionRuleNeedsDisplayReview(rule))
        XCTAssertEqual(model.protectionRuleReviewDisplayUUID(rule)?.lowercased(), Self.sideUUID.lowercased())
        XCTAssertTrue(model.protectionRuleRowStatus(for: rule).isBlocked)
        let navigation = SettingsNavigation()
        navigation.tab = .automation
        navigation.showDisplays(selecting: model.protectionRuleReviewDisplayUUID(rule))
        XCTAssertEqual(navigation.tab, .displays)
        XCTAssertEqual(navigation.selectedDisplayID, Self.sideUUID.lowercased())
    }

    func testHiddenAutomationChoicesIncludeInactiveAndDisconnectedTargets() throws {
        for inventory in [hiddenDisplays, [displays[0], displays[2]]] {
            let (model, defaults) = try makeModel(displays: inventory, status: { self.hiddenStatus() })
            defer { defaults.removePersistentDomain(forName: Self.suiteName) }
            let choices = model.automationDisplayChoices
            XCTAssertEqual(choices.compactMap { $0.uuid?.uppercased() }, [Self.mainUUID, Self.laptopUUID, Self.sideUUID])
            let hidden = try XCTUnwrap(choices.last)
            XCTAssertEqual(hidden.automationChoiceLabel, "DELL S2721DGF (Hidden)")
            XCTAssertEqual(model.automationDisplayIdentity(for: hidden)?.uuid.uppercased(), Self.sideUUID)
            XCTAssertFalse(model.activeDisplays.contains { $0.uuid == Self.sideUUID })
            var rule = model.makeNewProtectionRule()
            rule.settings.selectedDisplayUUIDs = [Self.sideUUID]
            XCTAssertTrue(model.unavailableSelectedDisplayUUIDs(for: rule.settings).isEmpty)
            try model.saveProtectionRule(rule)
            XCTAssertEqual(model.automationPreferences.rules.last?.settings.selectedDisplayUUIDs, [Self.sideUUID])
            var action = model.makeNewDisplayAction(selectedDisplayID: Self.sideUUID)
            action.name = "Show hidden monitor"
            action.steps[0].effect = .show
            try model.saveDisplayAction(action)
            XCTAssertEqual(model.displayActions.actions.last?.target?.uuid.uppercased(), Self.sideUUID)
            XCTAssertEqual(model.handoffStatus?.state, .hidden)
        }
    }

    func testRuleEditorCancelSaveAndKeyboardShortcuts() throws {
        try requireInteractiveUI()
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        defer { app.setActivationPolicy(originalPolicy) }
        app.activate(ignoringOtherApps: true)
        let (model, defaults) = try makeModel(displays: hiddenDisplays, status: { self.hiddenStatus() }, configure: { defaults in
            let existing = ProtectionRule(name: "Existing", isEnabled: false)
            defaults.set(
                try JSONEncoder().encode(AutomationPreferences(isEnabled: false, rules: [existing])),
                forKey: "automationRules"
            )
        })
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let original = model.automationPreferences
        let originalData = try XCTUnwrap(defaults.data(forKey: "automationRules"))
        var editorParents: [NSWindow] = []
        defer { editorParents.forEach { $0.close() } }
        var cancelledDraft = model.makeNewProtectionRule()
        cancelledDraft.name = "Cancel this draft"
        cancelledDraft.settings.selectedDisplayUUIDs = [Self.mainUUID]
        cancelledDraft.settings.followUpAction = .restore
        let (cancelParent, cancelSheet) = try presentProductionRuleEditor(
            model: model, rule: cancelledDraft, isNew: true
        )
        editorParents.append(cancelParent)
        try replaceEditorName(in: cancelSheet, with: "Cancelled edit")
        XCTAssertEqual(model.automationPreferences, original, "editing the sheet only changes its draft")
        XCTAssertEqual(defaults.data(forKey: "automationRules"), originalData)
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: cancelSheet.windowNumber, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53
        ))
        XCTAssertTrue(cancelSheet.performKeyEquivalent(with: escape), "Escape is routed as the sheet's Cancel action")
        spin { cancelParent.attachedSheet == nil }
        XCTAssertNil(cancelParent.attachedSheet, "Cancel must dismiss the production sheet")
        XCTAssertEqual(model.automationPreferences, original, "Cancel discards the edited draft")
        XCTAssertEqual(defaults.data(forKey: "automationRules"), originalData, "Cancel does not persist")

        var savedDraft = model.makeNewProtectionRule()
        savedDraft.settings.selectedDisplayUUIDs = [Self.sideUUID]
        savedDraft.settings.followUpAction = .restore
        let (saveParent, saveSheet) = try presentProductionRuleEditor(
            model: model, rule: savedDraft, isNew: true
        )
        editorParents.append(saveParent)
        XCTAssertTrue(model.protectionRuleValidation(for: savedDraft).allowsSave(isEnabled: savedDraft.isEnabled))
        try replaceEditorName(in: saveSheet, with: "Saved draft")
        XCTAssertEqual(model.automationPreferences, original, "the saved rule is still only a draft before Return")
        let returnKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: saveSheet.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))
        app.sendEvent(returnKey)
        spin { saveParent.attachedSheet == nil }
        XCTAssertNil(saveParent.attachedSheet, "Return must dismiss the production sheet after Save")
        let saved = try XCTUnwrap(model.automationPreferences.rule(namedID: savedDraft.id))
        XCTAssertEqual(saved.name, "Saved draft")
        XCTAssertEqual(saved.settings.selectedDisplayUUIDs, [Self.sideUUID])
        XCTAssertEqual(model.handoffStatus?.state, .hidden)
        XCTAssertNotEqual(model.automationPreferences, original)
        XCTAssertEqual(
            try JSONDecoder().decode(AutomationPreferences.self, from: XCTUnwrap(defaults.data(forKey: "automationRules"))),
            model.automationPreferences,
            "Return/Save persists the edited draft"
        )
    }

    func testDisplayActionEditorCancelSaveAndStableID() throws {
        try requireInteractiveUI()
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        defer { app.setActivationPolicy(originalPolicy) }

        let (model, defaults) = try makeModel(displays: hiddenDisplays, status: { self.hiddenStatus() })
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let navigation = SettingsNavigation()
        navigation.selectedDisplayID = Self.sideUUID.lowercased()

        var draft = model.makeNewDisplayAction(selectedDisplayID: Self.sideUUID)
        let (cancelParent, cancelSheet) = try presentProductionDisplayActionEditor(
            model: model, navigation: navigation, action: draft, existingID: nil, isNew: true
        )
        try replaceEditorName(in: cancelSheet, with: "Canceled action")
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: cancelSheet.windowNumber, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53
        ))
        XCTAssertTrue(cancelSheet.performKeyEquivalent(with: escape), "Escape invokes the production editor's Cancel action")
        spin { cancelParent.attachedSheet == nil }
        XCTAssertNil(cancelParent.attachedSheet, "Cancel dismisses the production editor")
        XCTAssertTrue(model.displayActions.actions.isEmpty, "Cancel discards the editor draft")
        XCTAssertNil(defaults.data(forKey: AppModel.displayActionsKey))
        cancelParent.close()

        draft = model.makeNewDisplayAction(selectedDisplayID: Self.sideUUID)
        let (saveParent, saveSheet) = try presentProductionDisplayActionEditor(
            model: model, navigation: navigation, action: draft, existingID: nil, isNew: true
        )
        try replaceEditorName(in: saveSheet, with: "Desk blackout")
        XCTAssertTrue(model.displayActions.actions.isEmpty, "The production editor keeps changes in its draft until Save")
        let returnKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: saveSheet.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))
        app.sendEvent(returnKey)
        spin { saveParent.attachedSheet == nil && model.displayActions.actions.count == 1 }
        XCTAssertNil(saveParent.attachedSheet, "Return dismisses the production editor after Save")
        let saved = try XCTUnwrap(model.displayActions.actions.first)
        XCTAssertEqual(saved.target?.uuid.lowercased(), Self.sideUUID.lowercased())
        XCTAssertEqual(saved.effect, .blackOut)
        XCTAssertEqual(model.handoffStatus?.state, .hidden)
        XCTAssertEqual(
            try JSONDecoder().decode(DisplayActionSet.self, from: XCTUnwrap(defaults.data(forKey: AppModel.displayActionsKey))),
            model.displayActions,
            "The production editor Save shortcut persists the action"
        )
        saveParent.close()

        var renamed = saved
        renamed.name = "Desk blackout renamed"
        let (editParent, editSheet) = try presentProductionDisplayActionEditor(
            model: model, navigation: navigation, action: renamed, existingID: saved.id, isNew: false
        )
        try replaceEditorName(in: editSheet, with: "Desk blackout renamed")
        let editReturnKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: editSheet.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))
        app.sendEvent(editReturnKey)
        spin { editParent.attachedSheet == nil && model.displayActions.actions.first?.name == "Desk blackout renamed" }
        XCTAssertNil(editParent.attachedSheet, "Return dismisses the editor after rename")
        XCTAssertEqual(model.displayActions.actions.first?.id, saved.id, "Rename preserves the script's stable action ID")
        editParent.close()
    }

    func testDefaultDisplayActionEditorShowsMissingRemovalSetupAndNavigatesToSelectedDisplay() throws {
        try requireInteractiveUI()
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        defer { app.setActivationPolicy(originalPolicy) }

        let (model, defaults) = try makeModel(configure: {
            $0.set(true, forKey: "experimentalFeaturesEnabled")
        })
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let navigation = SettingsNavigation()
        navigation.tab = .automation
        var action = model.makeNewDisplayAction(selectedDisplayID: Self.sideUUID)
        XCTAssertEqual(action.effect, .blackOut, "new actions start with the default effect")
        XCTAssertNil(model.hidePreferences[Self.sideUUID], "this is the first-use state with no Remove setup")
        action.effect = .removeFromDesktop
        XCTAssertNotNil(model.displayActionValidation(for: action), "Remove without Displays setup can't be saved")
        let (parent, sheet) = try presentProductionDisplayActionEditor(
            model: model, navigation: navigation, action: action, existingID: nil, isNew: true
        )
        defer { parent.close() }

        let content = try XCTUnwrap(sheet.contentView)
        let guidance = "Turn on Remove from desktop for this display in Settings → Displays first."
        XCTAssertEqual(model.displayActionRemovalSetupReason(for: Self.sideUUID), guidance)
        content.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let setupY = content.isFlipped ? content.bounds.minY + 390 : content.bounds.maxY - 390
        let setupPoint = content.convert(NSPoint(x: 100, y: setupY), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: setupPoint, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: setupPoint, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: sheet.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0
        ))
        // AppKit may track mouse-down synchronously until it dequeues mouse-up.
        app.postEvent(up, atStart: true)
        sheet.sendEvent(down)
        spin { parent.attachedSheet == nil && navigation.tab == .displays &&
            navigation.selectedDisplayID == Self.sideUUID.lowercased() }
        XCTAssertNil(parent.attachedSheet)
        XCTAssertEqual(navigation.tab, .displays)
        XCTAssertEqual(navigation.selectedDisplayID, Self.sideUUID.lowercased())
    }

    func testDisplayActionFixtureSnapshots() async throws {
        try requireInteractiveUI()
        guard let output = ProcessInfo.processInfo.environment["PANELCTL_SETTINGS_FIXTURE_OUTPUT"] else {
            throw XCTSkip("Set PANELCTL_SETTINGS_FIXTURE_OUTPUT to a directory to write Settings PNGs.")
        }
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        let originalAppearance = app.appearance
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        defer {
            app.appearance = originalAppearance
            app.setActivationPolicy(originalPolicy)
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let fakeHelper = URL(fileURLWithPath: output).appendingPathComponent("panelctl-fixture")
        try Data().write(to: fakeHelper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeHelper.path)
        setenv("PANELCTL_HELPER", fakeHelper.path, 1)
        defer { unsetenv("PANELCTL_HELPER") }
        let target = DisplayIdentitySnapshot(displays[1])
        let unavailable = DisplayIdentitySnapshot(Self.display(
            index: 4, id: 14, uuid: "00000000-0000-0000-0000-0000000000FF",
            name: "Conference display", main: false
        ))
        let main = DisplayIdentitySnapshot(displays[0])
        let laptop = DisplayIdentitySnapshot(displays[2])
        let blackOut = DisplayAction(name: "Black out conference display", target: target)
        let focus = DisplayAction(name: "Focus mode", steps: [
            DisplayActionStep(target: target),
            DisplayActionStep(target: main, effect: .show)
        ])
        let reviewedWorkflow = DisplayAction(name: "Conference handoff", steps: [
            DisplayActionStep(
                target: target,
                effect: .removeFromDesktop,
                reviewedRemoval: ReviewedRemovalSetup(removeEnabled: true, sourceUUID: Self.mainUUID, awayInput: 0x11)
            ),
            DisplayActionStep(target: laptop, effect: .show)
        ])
        let actions = DisplayActionSet(actions: [
            blackOut,
            focus,
            DisplayAction(name: "Show main display", target: main, effect: .show),
            DisplayAction(name: "Show conference display", target: target, effect: .show),
            DisplayAction(
                name: "Remove conference display — review required",
                target: target,
                effect: .removeFromDesktop,
                reviewedRemoval: ReviewedRemovalSetup(removeEnabled: true, sourceUUID: Self.mainUUID, awayInput: 0x11)
            ),
            reviewedWorkflow,
            DisplayAction(name: "Show unavailable conference display", target: unavailable, effect: .show)
        ])

        for width in [680, 440] {
            let suite = "panelctl-display-action-fixture-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(try JSONEncoder().encode(actions), forKey: AppModel.displayActionsKey)
            let model = AppModel(
                defaults: defaults,
                displayProvider: { self.displays },
                idleSecondsProvider: { nil },
                isDisplayMirrored: { _ in false },
                inspectHandoff: { DisplayHandoffStatus(state: .none, journalPath: Self.journalPath) },
                coverDisplays: { _ in [] },
                quiesceProtection: { $0(true, nil) }
            )
            let initialRunFinished = expectation(description: "the one-step fixture Action completes before list capture")
            model.runDisplayAction(id: blackOut.id) { response in
                XCTAssertEqual(response.outcome, .done)
                initialRunFinished.fulfill()
            }
            await fulfillment(of: [initialRunFinished], timeout: 2)
            let controller = SettingsWindowController(model: model)
            controller.present()
            controller.select(.automation)
            let window = try XCTUnwrap(controller.window)
            window.setContentSize(NSSize(width: width, height: 1080))
            try writeSnapshot(of: window, to: output, name: "actions-list-\(width)")

            let successSuite = "panelctl-display-action-success-\(UUID().uuidString)"
            let successDefaults = try XCTUnwrap(UserDefaults(suiteName: successSuite))
            defer { successDefaults.removePersistentDomain(forName: successSuite) }
            let successAction = DisplayAction(name: "Show displays — verified input", steps: [
                DisplayActionStep(target: target, effect: .show),
                DisplayActionStep(target: main, effect: .show)
            ])
            successDefaults.set(try JSONEncoder().encode(DisplayActionSet(actions: [successAction])), forKey: AppModel.displayActionsKey)
            let hidden = hiddenStatus()
            var successStatus = DisplayHandoffStatus(
                state: .hidden, target: hidden.target, source: hidden.source,
                journalPath: Self.journalPath, journalID: hidden.journalID,
                canShow: true, observations: hidden.observations, mirrorTopologyVerified: true,
                removals: [DisplayHandoffRemoval(
                    id: "fixture-removal", target: try XCTUnwrap(hidden.target), source: try XCTUnwrap(hidden.source),
                    state: "mirrored", isUnresolved: true, canShow: true, reason: nil, topologyVerified: true
                )]
            )
            let successModel = AppModel(
                defaults: successDefaults,
                displayProvider: { self.displays }, idleSecondsProvider: { nil },
                isDisplayMirrored: { _ in false }, inspectHandoff: { successStatus },
                showDisplay: { _, _ in
                    successStatus = DisplayHandoffStatus(state: .none, journalPath: Self.journalPath)
                    return DisplayInputOutcome(state: .verified, requestedInput: 0x0F, observedInput: 0x0F)
                },
                coverDisplays: { _ in [] }, quiesceProtection: { $0(true, nil) }
            )
            if successModel.protectionQuiescencePending {
                let ready = expectation(description: "fixture recovery cleanup settles")
                successModel.onStatusChange = {
                    if !successModel.protectionQuiescencePending {
                        successModel.onStatusChange = nil
                        ready.fulfill()
                    }
                }
                await fulfillment(of: [ready], timeout: 2)
            }
            let successFinished = expectation(description: "verified input Action completes")
            successModel.runDisplayAction(id: successAction.id) { response in
                XCTAssertEqual(response.outcome, .done, response.summary)
                XCTAssertEqual(response.steps?.map(\.outcome), [.done, .noOp])
                XCTAssertNotNil(response.steps?.first?.inputDetail)
                XCTAssertTrue(response.steps?.allSatisfy { !DisplayActionPresentation.stepNeedsAttention($0) } == true)
                successFinished.fulfill()
            }
            await fulfillment(of: [successFinished], timeout: 2)
            let successController = SettingsWindowController(model: successModel)
            successController.present()
            successController.select(.automation)
            let successWindow = try XCTUnwrap(successController.window)
            successWindow.setContentSize(NSSize(width: width, height: 720))
            try writeSnapshot(of: successWindow, to: output, name: "actions-success-\(width)")
            successWindow.close()

            let progressSuite = "panelctl-display-action-progress-\(UUID().uuidString)"
            let progressDefaults = try XCTUnwrap(UserDefaults(suiteName: progressSuite))
            defer { progressDefaults.removePersistentDomain(forName: progressSuite) }
            progressDefaults.set(try JSONEncoder().encode(actions), forKey: AppModel.displayActionsKey)
            var delayedActionQuiescence: ((Bool, String?) -> Void)?
            let progressModel = AppModel(
                defaults: progressDefaults,
                displayProvider: { self.displays },
                idleSecondsProvider: { nil },
                isDisplayMirrored: { _ in false },
                inspectHandoff: { DisplayHandoffStatus(state: .none, journalPath: Self.journalPath) },
                coverDisplays: { _ in [] },
                quiesceProtection: { completion in delayedActionQuiescence = completion }
            )
            let progressFinished = expectation(description: "the fixture Action completes after progress is captured")
            progressModel.runDisplayAction(id: focus.id) { _ in progressFinished.fulfill() }
            XCTAssertEqual(progressModel.runningDisplayAction?.id, focus.id)
            XCTAssertEqual(progressModel.runningDisplayAction?.currentStep, 1)
            let progressController = SettingsWindowController(model: progressModel)
            progressController.present()
            progressController.select(.automation)
            let progressWindow = try XCTUnwrap(progressController.window)
            progressWindow.setContentSize(NSSize(width: width, height: 1080))
            try writeSnapshot(of: progressWindow, to: output, name: "actions-progress-\(width)")
            delayedActionQuiescence?(true, nil)
            await fulfillment(of: [progressFinished], timeout: 2)
            progressWindow.close()

            let partialSuite = "panelctl-display-action-partial-\(UUID().uuidString)"
            let partialDefaults = try XCTUnwrap(UserDefaults(suiteName: partialSuite))
            defer { partialDefaults.removePersistentDomain(forName: partialSuite) }
            let partialAction = DisplayAction(name: "Focus mode — partial", steps: [
                DisplayActionStep(target: target),
                DisplayActionStep(target: main, effect: .show),
                DisplayActionStep(target: laptop, effect: .show)
            ])
            let partialActions = DisplayActionSet(actions: [blackOut, partialAction])
            partialDefaults.set(try JSONEncoder().encode(partialActions), forKey: AppModel.displayActionsKey)
            var partialInventory = displays
            let partialModel = AppModel(
                defaults: partialDefaults,
                displayProvider: { partialInventory },
                idleSecondsProvider: { nil },
                isDisplayMirrored: { _ in false },
                inspectHandoff: { DisplayHandoffStatus(state: .none, journalPath: Self.journalPath) },
                coverDisplays: { ids in
                    if ids.contains(12) { partialInventory.removeAll { $0.uuid == Self.mainUUID } }
                    return []
                },
                quiesceProtection: { $0(true, nil) }
            )
            let partialFinished = expectation(description: "the fake partial Action completes")
            partialModel.runDisplayAction(id: partialAction.id) { response in
                XCTAssertEqual(response.outcome, .partial)
                XCTAssertEqual(response.steps?.map(\.outcome), [.done, .refused, .notRun])
                partialFinished.fulfill()
            }
            await fulfillment(of: [partialFinished], timeout: 2)
            let partialController = SettingsWindowController(model: partialModel)
            partialController.present()
            partialController.select(.automation)
            let partialWindow = try XCTUnwrap(partialController.window)
            partialWindow.setContentSize(NSSize(width: width, height: 1080))
            try writeSnapshot(of: partialWindow, to: output, name: "actions-partial-\(width)")
            partialWindow.close()

            let firstUseSuite = "panelctl-display-action-first-use-\(UUID().uuidString)"
            let firstUseDefaults = try XCTUnwrap(UserDefaults(suiteName: firstUseSuite))
            firstUseDefaults.set(true, forKey: "experimentalFeaturesEnabled")
            let firstUseModel = AppModel(
                defaults: firstUseDefaults,
                displayProvider: { self.displays },
                idleSecondsProvider: { nil },
                isDisplayMirrored: { _ in false },
                inspectHandoff: { DisplayHandoffStatus(state: .none, journalPath: Self.journalPath) },
                coverDisplays: { _ in [] },
                quiesceProtection: { $0(true, nil) }
            )
            let firstUseAction = firstUseModel.makeNewDisplayAction(selectedDisplayID: target.uuid)
            XCTAssertEqual(firstUseAction.effect, .blackOut)
            let firstUseEditor = try presentStandaloneDisplayActionEditor(
                in: window, model: firstUseModel, navigation: SettingsNavigation(),
                action: firstUseAction, existingID: nil, isNew: true
            )
            try writeSnapshot(of: firstUseEditor, to: output, name: "action-editor-first-use-\(width)")
            window.endSheet(firstUseEditor)
            spin { window.attachedSheet == nil }
            var setupAction = firstUseAction
            setupAction.effect = .removeFromDesktop
            let setupEditor = try presentStandaloneDisplayActionEditor(
                in: window, model: firstUseModel, navigation: SettingsNavigation(),
                action: setupAction, existingID: nil, isNew: true
            )
            try writeSnapshot(of: setupEditor, to: output, name: "action-editor-remove-setup-\(width)")
            window.endSheet(setupEditor)
            spin { window.attachedSheet == nil }
            firstUseDefaults.removePersistentDomain(forName: firstUseSuite)

            var preferences = DisplayHidePreferences()
            preferences[Self.sideUUID] = DisplayHideConfiguration(
                target: target,
                enabled: true,
                source: DisplayIdentitySnapshot(displays[0]),
                awayInput: 0x11,
                returnInput: 0x0F
            )
            let configuredSuite = "panelctl-display-action-editor-fixture-\(UUID().uuidString)"
            let configuredDefaults = try XCTUnwrap(UserDefaults(suiteName: configuredSuite))
            configuredDefaults.set(true, forKey: "experimentalFeaturesEnabled")
            configuredDefaults.set(try JSONEncoder().encode(preferences), forKey: "displayHidePreferences")
            let configuredModel = AppModel(
                defaults: configuredDefaults,
                displayProvider: { self.displays },
                idleSecondsProvider: { nil },
                isDisplayMirrored: { _ in false },
                inspectHandoff: { DisplayHandoffStatus(state: .none, journalPath: Self.journalPath) },
                checkDDCInput: { DDCInputReading(displayID: $0.displayID, uuid: $0.uuid, current: 0x0F) },
                coverDisplays: { _ in [] },
                quiesceProtection: { $0(true, nil) }
            )
            let removal = DisplayAction(
                name: "Remove conference display",
                target: target,
                effect: .removeFromDesktop,
                reviewedRemoval: ReviewedRemovalSetup(removeEnabled: true, sourceUUID: Self.mainUUID, awayInput: 0x11)
            )
            let detailsEditor = try presentStandaloneDisplayActionEditor(
                in: window, model: configuredModel, navigation: SettingsNavigation(),
                action: removal, existingID: nil, isNew: true
            )
            try writeSnapshot(of: detailsEditor, to: output, name: "action-editor-remove-\(width)")
            window.endSheet(detailsEditor)
            spin { window.attachedSheet == nil }

            let mixedConflict = DisplayAction(name: "Mixed steps with a setup conflict", steps: [
                DisplayActionStep(target: main),
                DisplayActionStep(
                    target: target,
                    effect: .removeFromDesktop,
                    reviewedRemoval: ReviewedRemovalSetup(removeEnabled: true, sourceUUID: Self.mainUUID, awayInput: 0x12)
                )
            ])
            let mixedEditor = try presentStandaloneDisplayActionEditor(
                in: window, model: configuredModel, navigation: SettingsNavigation(),
                action: mixedConflict, existingID: nil, isNew: true
            )
            try writeSnapshot(of: mixedEditor, to: output, name: "action-editor-mixed-conflict-\(width)")
            window.endSheet(mixedEditor)
            spin { window.attachedSheet == nil }

            configuredModel.setExperimentalFeaturesEnabled(false)
            let disabledEditor = try presentStandaloneDisplayActionEditor(
                in: window, model: configuredModel, navigation: SettingsNavigation(),
                action: removal, existingID: nil, isNew: true
            )
            try writeSnapshot(of: disabledEditor, to: output, name: "action-editor-remove-disabled-\(width)")
            window.close()
            defaults.removePersistentDomain(forName: suite)
            configuredDefaults.removePersistentDomain(forName: configuredSuite)
        }
    }

    func testRunRuleMenuIncludesDisabledRulesAndExplainsEmptyRules() throws {
        _ = NSApplication.shared
        let (model, defaults) = try makeModel()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let delegate = AppDelegate()
        delegate.model = model
        var rules = model.automationPreferences.rules
        var dimSettings = ProtectionPreferences()
        dimSettings.mode = .working
        dimSettings.selectedDisplayUUIDs = [Self.sideUUID]
        let dimRule = ProtectionRule(name: "Desk dimming", settings: dimSettings)
        rules.append(dimRule)
        model.automationPreferences.rules = rules
        var menu = delegate.makeMenu()
        let submenu = try XCTUnwrap(menu.items.first { $0.title == "Run rule" }?.submenu)
        XCTAssertEqual(submenu.items.map(\.title), rules.map(\.name))
        XCTAssertEqual(submenu.items.map { $0.representedObject as? UUID }, rules.map(\.id))
        XCTAssertFalse(menu.items.contains { ["Black Out Now", "Black Out and Dim Now"].contains($0.title) })
        XCTAssertFalse(menu.items.contains { ["Display protection", "Desk dimming"].contains($0.title) })

        model.automationPreferences.rules = model.automationPreferences.rules.map { rule in
            var rule = rule
            rule.isEnabled = false
            return rule
        }
        menu = delegate.makeMenu()
        let disabledRules = try XCTUnwrap(menu.items.first { $0.title == "Run rule" }?.submenu)
        XCTAssertEqual(disabledRules.items.map(\.title), rules.map { $0.name + " (Off)" })
        model.automationPreferences.rules = []
        let empty = try XCTUnwrap(delegate.makeMenu().items.first { $0.title == "Run rule" })
        XCTAssertFalse(empty.isEnabled)
        XCTAssertEqual(empty.toolTip, "Create a rule in Settings → Automations.")
    }

    func testExperimentalFlagDefaultsOffPersistsAndGatesRemovalButNotShow() throws {
        try requireInteractiveUI()
        var hidden: DisplayHandoffStatus?
        let (model, defaults) = try makeModel(status: { hidden }, configure: { defaults in
            var hidePreferences = DisplayHidePreferences()
            hidePreferences[Self.sideUUID] = DisplayHideConfiguration(
                target: DisplayIdentitySnapshot(self.displays[1]),
                enabled: true,
                source: DisplayIdentitySnapshot(self.displays[0])
            )
            defaults.set(try JSONEncoder().encode(hidePreferences), forKey: "displayHidePreferences")
        })
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let delegate = AppDelegate()
        delegate.model = model

        XCTAssertFalse(model.experimentalFeaturesEnabled)
        XCTAssertEqual(try sideTile(model).action, .hide, "Hide blacks out without the Experimental flag")
        XCTAssertFalse(model.hideRemovesFromDesktop(displays[1]), "removal needs the Experimental flag")
        XCTAssertThrowsError(try model.makeHideRequest(targetUUID: Self.sideUUID)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Turn on Experimental features"))
        }
        XCTAssertTrue(delegate.makeMenu().items.contains { $0.title == "Hide DELL S2721DGF" })
        XCTAssertNil(try removalSwitch(in: model), "removal setup stays out of Settings")

        model.acceptExperimentalConsent()
        XCTAssertTrue(defaults.bool(forKey: "experimentalFeaturesEnabled"))
        XCTAssertEqual(try sideTile(model).action, .hide)
        XCTAssertTrue(model.hideRemovesFromDesktop(displays[1]))
        XCTAssertNil(try sideTile(model).actionBlocker)
        XCTAssertNoThrow(try model.makeHideRequest(targetUUID: Self.sideUUID))
        XCTAssertTrue(delegate.makeMenu().items.contains { $0.title == "Hide DELL S2721DGF" })
        XCTAssertEqual(try removalSwitch(in: model)?.state, .on)
        let reloaded = try makeModel(keepingDefaults: true).0
        XCTAssertTrue(reloaded.experimentalFeaturesEnabled)

        // Turning the flag off never strands a hidden desktop.
        model.setExperimentalFeaturesEnabled(false)
        XCTAssertFalse(defaults.bool(forKey: "experimentalFeaturesEnabled"))
        hidden = hiddenStatus()
        model.refreshHandoffStatus()
        spin { !model.protectionQuiescencePending }
        let titles = delegate.makeMenu().items.map(\.title)
        XCTAssertTrue(titles.contains("Show DELL S2721DGF"))
        XCTAssertNoThrow(try model.makeShowRequest())
    }

    func testMenuStatusTextWrapsToFixedWidth() throws {
        let font = NSFont.menuFont(ofSize: 0)
        let long = String(repeating: "Display recovery needs attention before automation resumes. ", count: 6)
        let lines = AppDelegate.wrap(long, width: 240, font: font, maxLines: 3)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[2].hasSuffix("\u{2026}"))
        XCTAssertTrue(lines.allSatisfy { ($0 as NSString).size(withAttributes: [.font: font]).width <= 240 })
        XCTAssertEqual(AppDelegate.wrap("Short", width: 240, font: font, maxLines: 3), ["Short"])

        let (model, defaults) = try makeModel()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let delegate = AppDelegate()
        delegate.model = model
        XCTAssertEqual(delegate.makeMenu().size.width, AppDelegate.menuWidth)
    }

    func testRecoveryDetailsDisclosureRespondsAcrossItsFullRowAndToKeyboard() throws {
        try requireInteractiveUI()
        let status = DisplayHandoffStatus(
            state: .recovery,
            target: hiddenStatus().target,
            source: hiddenStatus().source,
            journalPath: Self.journalPath,
            journalID: "disclosure-interaction-fixture",
            reason: "Synthetic recovery details for disclosure interaction."
        )
        let (model, defaults) = try makeModel(status: { status }, configure: {
            $0.set(true, forKey: "experimentalFeaturesEnabled")
        })
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let controller = SettingsWindowController(model: model)
        controller.present()
        controller.selectDisplay(uuid: Self.sideUUID)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        window.setContentSize(NSSize(width: 680, height: 900))
        window.makeKeyAndOrderFront(nil)
        spin { window.isKeyWindow }
        guard window.isKeyWindow else {
            throw XCTSkip("AppKit fixture could not activate a key window, so native keyboard interaction is unavailable.")
        }

        func disclosureButton() -> NSButton? {
            guard let content = window.contentView else { return nil }
            return nativeViews(in: content).compactMap { $0 as? NSButton }.first {
                $0.title == "Recovery details" || $0.accessibilityLabel() == "Recovery details"
            }
        }
        spin { window.contentView?.layoutSubtreeIfNeeded(); return disclosureButton() != nil }
        guard let collapsed = disclosureButton() else {
            throw XCTSkip("SwiftUI disclosure accessibility button is not exposed in the synthetic AppKit view tree.")
        }
        XCTAssertGreaterThan(collapsed.bounds.width, 200, "the disclosure button covers the header row, not only the caret")
        XCTAssertEqual(collapsed.accessibilityValue() as? String, "Collapsed")
        XCTAssertEqual(collapsed.accessibilityHelp(), "Show or hide details.")

        clickNativeButton(collapsed, atX: collapsed.bounds.minX + 4)
        spin { disclosureButton()?.accessibilityValue() as? String == "Expanded" }
        let expanded = try XCTUnwrap(disclosureButton())
        clickNativeButton(expanded, atX: expanded.bounds.maxX - 4)
        spin { disclosureButton()?.accessibilityValue() as? String == "Collapsed" }

        let keyboardButton = try XCTUnwrap(disclosureButton())
        XCTAssertTrue(window.makeFirstResponder(keyboardButton), "the native disclosure button can receive keyboard focus")
        sendSpaceKey(to: window)
        spin { disclosureButton()?.accessibilityValue() as? String == "Expanded" }
        window.close()
    }

    func testBlackedOutDisplayStaysHiddenAfterSettingsCloses() throws {
        try requireInteractiveUI()
        let (model, defaults) = try makeModel()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let controller = SettingsWindowController(model: model)
        controller.present()
        controller.selectDisplay(uuid: Self.sideUUID)
        model.hide(targetUUID: Self.sideUUID)
        XCTAssertEqual(try sideTile(model).status, .hidden)

        try XCTUnwrap(controller.window).close()
        XCTAssertTrue(model.isBlackoutHidden(Self.sideUUID))
        XCTAssertEqual(model.coveredHiddenDisplayIDs, [12])
        XCTAssertEqual(try sideTile(model).action, .show)
    }

    func testExperimentalToggleAsksForConsentBeforeTurningOn() throws {
        try requireInteractiveUI()
        // SwiftUI consent sheets require a key window on macOS 15. Activate
        // this fixture as an accessory, never a Dock application.
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        defer { app.setActivationPolicy(originalPolicy) }
        let (model, defaults) = try makeModel()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let controller = SettingsWindowController(model: model)
        controller.present()
        controller.select(.general)
        let window = try XCTUnwrap(controller.window)
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        spin { window.isKeyWindow }
        XCTAssertTrue(window.isKeyWindow, "consent fixture needs a key window")
        // Wait for the selected tab to mount before changing its alert binding.
        spin {
            window.contentView?.layoutSubtreeIfNeeded()
            return window.contentView.map {
                nativeViews(in: $0).compactMap { $0 as? NSSwitch }.count == 3
            } == true
        }
        XCTAssertEqual(nativeViews(in: try XCTUnwrap(window.contentView))
            .compactMap { $0 as? NSSwitch }.count, 3)

        func consentButton(_ title: String) throws -> NSButton {
            spin { window.attachedSheet != nil }
            let sheet = try XCTUnwrap(window.attachedSheet,
                "consent is presented on Settings; policy=\(app.activationPolicy().rawValue), key=\(window.isKeyWindow), pending=\(model.experimentalConsentPending)")
            let texts = nativeViews(in: try XCTUnwrap(sheet.contentView)).compactMap { ($0 as? NSTextField)?.stringValue }
            XCTAssertTrue(texts.contains(GeneralSettingsView.experimentalConsentTitle))
            XCTAssertTrue(texts.contains(GeneralSettingsView.experimentalConsentMessage))
            let buttons = nativeViews(in: try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }
            XCTAssertEqual(Set(buttons.map(\.title)), ["Turn On", "Cancel"])
            return try XCTUnwrap(buttons.first { $0.title == title })
        }

        model.setExperimentalFeaturesEnabled(true)
        XCTAssertFalse(model.experimentalFeaturesEnabled, "turning on waits for consent")
        try consentButton("Cancel").performClick(nil)
        spin { window.attachedSheet == nil }
        XCTAssertNil(window.attachedSheet)
        XCTAssertFalse(model.experimentalFeaturesEnabled)
        XCTAssertFalse(model.experimentalConsentPending)
        XCTAssertFalse(defaults.bool(forKey: "experimentalFeaturesEnabled"))

        model.setExperimentalFeaturesEnabled(true)
        try consentButton("Turn On").performClick(nil)
        spin { window.attachedSheet == nil }
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(model.experimentalFeaturesEnabled)
        XCTAssertTrue(defaults.bool(forKey: "experimentalFeaturesEnabled"))

        model.setExperimentalFeaturesEnabled(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(window.attachedSheet, "turning off needs no consent")
        XCTAssertFalse(model.experimentalFeaturesEnabled)

        // The shared presenter must still display and dismiss ordinary notices.
        model.notice = AppNotice(title: "Fixture notice", message: "No hardware action", opensLoginItemSettings: false)
        spin { window.attachedSheet != nil }
        let noticeSheet = try XCTUnwrap(window.attachedSheet)
        let noticeViews = nativeViews(in: try XCTUnwrap(noticeSheet.contentView))
        XCTAssertTrue(noticeViews.compactMap { ($0 as? NSTextField)?.stringValue }.contains("Fixture notice"))
        try XCTUnwrap(noticeViews.compactMap { $0 as? NSButton }.first { $0.title == "OK" }).performClick(nil)
        spin { window.attachedSheet == nil && model.notice == nil }
        XCTAssertNil(window.attachedSheet)
        XCTAssertNil(model.notice)
    }

    func testMenuUsesAutomationWording() throws {
        let (model, defaults) = try makeModel()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let delegate = AppDelegate()
        delegate.model = model

        var titles = delegate.makeMenu().items.map(\.title)
        XCTAssertTrue(titles.contains("Turn On Automation"))
        XCTAssertTrue(titles.contains("Sleep Displays"))
        XCTAssertFalse(titles.contains("View on GitHub"))
        XCTAssertFalse(titles.contains { $0.localizedCaseInsensitiveContains("protection") || $0.contains("OLED") })

        // Selecting only a disconnected display turns automation on without
        // launching the blackout helper.
        var preferences = model.preferences
        preferences.isEnabled = true
        preferences.didChooseDisplays = true
        preferences.selectedDisplayUUIDs = ["00000000-0000-0000-0000-0000000000FF"]
        model.preferences = preferences
        defer { model.setProtectionEnabled(false) }
        guard case .waitingForDisplays = model.runtimeState else {
            return XCTFail("Expected automation to wait for displays, got \(model.runtimeState)")
        }
        let menu = delegate.makeMenu()
        titles = menu.items.map(\.title)
        XCTAssertFalse(titles.contains("Turn On Automation"))
        let pause = try XCTUnwrap(menu.items.first { $0.title == "Pause Automation" }?.submenu)
        XCTAssertEqual(
            pause.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["For 30 Minutes", "For 1 Hour", "Until Tomorrow", "Turn Off Automation"]
        )
    }

    /// Opt-in visual fixtures for every task-35 state at each requested width.
    func testAutomationFixtureSnapshots() throws {
        try requireInteractiveUI()
        guard let output = ProcessInfo.processInfo.environment["PANELCTL_SETTINGS_FIXTURE_OUTPUT"] else {
            throw XCTSkip("Set PANELCTL_SETTINGS_FIXTURE_OUTPUT to a directory to write Settings PNGs.")
        }
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        let originalAppearance = app.appearance
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        defer {
            app.appearance = originalAppearance
            app.setActivationPolicy(originalPolicy)
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let missingUUID = "00000000-0000-0000-0000-0000000000FF"
        func settings(_ uuid: String, mode: BlackoutMode = .blocking) -> ProtectionPreferences {
            var value = ProtectionPreferences()
            value.didChooseDisplays = true
            value.selectedDisplayUUIDs = [uuid]
            value.mode = mode
            value.followUpAction = .restore
            return value
        }
        let migratedSettings: ProtectionPreferences = {
            var value = ProtectionPreferences()
            value.didChooseDisplays = true
            value.selectedDisplayUUIDs = [Self.mainUUID]
            return value
        }()
        let first = ProtectionRule(name: "Display protection", isEnabled: true, settings: settings(Self.mainUUID))
        let dim = ProtectionRule(name: "Desk dimming", isEnabled: true, settings: settings(Self.sideUUID, mode: .working))
        let missing = ProtectionRule(name: "Missing display", isEnabled: true, settings: settings(missingUUID))
        let conflict = ProtectionRule(name: "Desk dimming", isEnabled: true, settings: settings(Self.mainUUID, mode: .working))
        var partialSettings = settings(Self.sideUUID)
        partialSettings.selectedDisplayUUIDs.insert(missingUUID)
        partialSettings.followUpAction = .sleepDisplays
        let partial = ProtectionRule(name: "OLED protection", isEnabled: true, settings: partialSettings)
        let scenarios: [(name: String, ruleSet: AutomationPreferences?, legacy: ProtectionPreferences?, cleanupFailure: Bool, editor: String?, activeRuleID: UUID?)] = [
            ("migrated-single", nil, migratedSettings, false, nil, nil),
            ("multiple-watching-active", AutomationPreferences(isEnabled: true, rules: [first, dim]), nil, false, nil, dim.id),
            ("missing-target", AutomationPreferences(isEnabled: true, rules: [missing]), nil, false, nil, nil),
            ("remaining-displays", AutomationPreferences(isEnabled: true, rules: [partial]), nil, false, nil, partial.id),
            ("conflicting-rule", AutomationPreferences(isEnabled: true, rules: [first, conflict]), nil, false, nil, nil),
            ("cleanup-failure", AutomationPreferences(isEnabled: true, rules: []), nil, true, nil, nil),
            ("editor-new", nil, migratedSettings, false, "new", nil),
            ("editor-conflict", AutomationPreferences(isEnabled: true, rules: [first, conflict]), nil, false, "edit", nil)
        ]

        for scenario in scenarios {
            let suite = "panelctl-automation-fixture-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let fakeDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("panelctl-automation-fixture-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: fakeDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: fakeDirectory) }
            if let activeRuleID = scenario.activeRuleID {
                let helper = try writeAutomationFixtureHelper(in: fakeDirectory)
                setenv("PANELCTL_HELPER", helper.path, 1)
                setenv("PANELCTL_FIXTURE_ACTIVE_RULE_ID", activeRuleID.uuidString, 1)
            } else {
                unsetenv("PANELCTL_HELPER")
                unsetenv("PANELCTL_FIXTURE_ACTIVE_RULE_ID")
            }
            if let ruleSet = scenario.ruleSet {
                defaults.set(try JSONEncoder().encode(ruleSet), forKey: "automationRules")
            } else if let legacy = scenario.legacy {
                defaults.set(try JSONEncoder().encode(legacy), forKey: "blackoutPreferences")
            }
            if scenario.cleanupFailure {
                defaults.set("Hardware brightness cleanup failed.", forKey: "automationCleanupFailure")
            }
            let coordinator = ProtectionCoordinator(
                verifyJournal: { _ in true },
                ruleJournalDirectory: fakeDirectory,
                removeDeletedDirectories: false,
                serviceFactory: { id in ProtectionService(cleanupRuleID: id, cleanupIsVerified: { true }) }
            )
            let model = AppModel(
                defaults: defaults,
                displayProvider: { self.displays },
                idleSecondsProvider: { 0 },
                inspectHandoff: {
                    guard scenario.name == "remaining-displays" else {
                        return DisplayHandoffStatus(state: .none, journalPath: Self.journalPath)
                    }
                    let source = self.displays[1]
                    return DisplayHandoffStatus(
                        state: .hidden,
                        target: DisplayHandoffIdentity(DisplayHideIdentity(
                            uuid: missingUUID, displayID: 99, name: "Removed display", vendor: 1, model: 1, serial: 99
                        )),
                        source: DisplayHandoffIdentity(DisplayHideIdentity(
                            uuid: Self.sideUUID, displayID: source.id, name: source.name,
                            vendor: source.vendor, model: source.model, serial: source.serial
                        )),
                        journalPath: Self.journalPath, journalID: "remaining-fixture", canShow: true,
                        mirrorTopologyVerified: true
                    )
                },
                coverDisplays: { _ in [] },
                quiesceProtection: { $0(true, nil) },
                protectionCoordinator: coordinator
            )
            if let activeRuleID = scenario.activeRuleID {
                spin(timeout: 4) {
                    model.controlRuleStatuses.first(where: { $0.id == activeRuleID })?.state == "blacked_out"
                }
                XCTAssertEqual(model.blackedOutDisplayIDs, [12], "only the fake dimming helper reports an active cover")
            }

            let controller = SettingsWindowController(model: model)
            controller.present()
            controller.select(.automation)
            let window = try XCTUnwrap(controller.window)
            window.setContentSize(fixtureSize)
            app.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            spin { app.isActive && window.isKeyWindow }
            if let editor = scenario.editor {
                let helper = try writeAutomationFixtureHelper(in: fakeDirectory)
                setenv("PANELCTL_HELPER", helper.path, 1)
                let rule: ProtectionRule
                let existingID: UUID?
                let isNew: Bool
                if editor == "new" {
                    rule = model.makeNewProtectionRule()
                    existingID = nil
                    isNew = true
                } else {
                    rule = try XCTUnwrap(model.automationPreferences.rules.first)
                    existingID = rule.id
                    isNew = false
                }
                let sheet = try presentStandaloneRuleEditor(
                    in: window, model: model, rule: rule, existingID: existingID, isNew: isNew
                )
                try writeSnapshot(of: sheet, to: output, name: "automation-\(scenario.name)")
                let content = try XCTUnwrap(sheet.contentView)
                let scrollView = try XCTUnwrap(nativeViews(in: content).compactMap { $0 as? NSScrollView }.first)
                let document = try XCTUnwrap(scrollView.documentView)
                let bottom = document.isFlipped
                    ? max(0, document.bounds.height - scrollView.contentView.bounds.height)
                    : 0
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                spin { content.layoutSubtreeIfNeeded(); return true }
                try writeSnapshot(of: sheet, to: output, name: "automation-\(scenario.name)-command")
            } else {
                let content = try XCTUnwrap(window.contentView)
                spin { content.layoutSubtreeIfNeeded(); return true }
                try writeSnapshot(of: window, to: output, name: "automation-\(scenario.name)")
            }

            if scenario.activeRuleID != nil {
                var stopped = false
                model.shutdown { stopped = true }
                spin(timeout: 4) { stopped }
            }
            window.close()
            defaults.removePersistentDomain(forName: suite)
            unsetenv("PANELCTL_HELPER")
            unsetenv("PANELCTL_FIXTURE_ACTIVE_RULE_ID")
        }
    }

    private func writeAutomationFixtureHelper(in directory: URL) throws -> URL {
        let helper = directory.appendingPathComponent("fake-panelctl")
        let script = """
        #!/bin/bash
        if [[ "$PANELCTL_CLEANUP_ONLY" == "1" ]]; then
            printf '{"state":"stopped","blackedOutDisplayIDs":[],"cleanupSucceeded":true}\\n'
            exit 0
        fi
        active=0
        for argument in "$@"; do
            if [[ "$argument" == "$PANELCTL_FIXTURE_ACTIVE_RULE_ID" ]]; then active=1; fi
        done
        if [[ $active == 1 ]]; then
            printf '{"state":"blacked_out","blackedOutDisplayIDs":[12]}\\n'
        else
            printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'
        fi
        trap 'printf "{\\"state\\":\\"stopped\\",\\"blackedOutDisplayIDs\\":[],\\"cleanupSucceeded\\":true}\\n"; exit 0' TERM
        while IFS= read -r command; do
            if [[ "$command" == "restore" ]]; then printf '{"state":"waiting","blackedOutDisplayIDs":[]}\\n'; fi
        done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return helper
    }

    /// Opt-in visual fixture: writes one PNG per tab for review and docs.
    func testSettingsFixtureSnapshots() throws {
        try requireInteractiveUI()
        guard let output = ProcessInfo.processInfo.environment["PANELCTL_SETTINGS_FIXTURE_OUTPUT"] else {
            throw XCTSkip("Set PANELCTL_SETTINGS_FIXTURE_OUTPUT to a directory to write Settings PNGs.")
        }
        // Automation stays off: an enabled model would launch the blackout helper.
        var variant = ProtectionPreferences()
        variant.didChooseDisplays = true
        variant.mode = .working
        variant.hardwareDimmingEnabled = true
        variant.followUpAction = .untilActivity
        variant.selectedDisplayUUIDs = [Self.mainUUID, Self.sideUUID, Self.laptopUUID, "00000000-0000-0000-0000-0000000000FF"]
        let scenarios: [(name: String, preferences: ProtectionPreferences?, experimental: Bool)] = [
            ("default", nil, false),
            ("variant", variant, true)
        ]
        for scenario in scenarios {
            let (model, defaults) = try makeModel(configure: { defaults in
                if let preferences = scenario.preferences {
                    defaults.set(try JSONEncoder().encode(preferences), forKey: "blackoutPreferences")
                }
                defaults.set(scenario.experimental, forKey: "experimentalFeaturesEnabled")
            })
            defer { defaults.removePersistentDomain(forName: Self.suiteName) }
            let controller = SettingsWindowController(model: model)
            controller.present()
            let window = try XCTUnwrap(controller.window)
            defer { window.close() }
            window.setContentSize(fixtureSize)
            for tab in SettingsTab.allCases {
                controller.select(tab)
                try writeSnapshot(of: window, to: output, name: "settings-\(scenario.name)-\(tab.rawValue)")
            }
        }
    }

    /// Opt-in visual fixture: writes one PNG per Displays state for review and docs.
    func testDisplaysFixtureSnapshots() throws {
        try requireInteractiveUI()
        guard let output = ProcessInfo.processInfo.environment["PANELCTL_SETTINGS_FIXTURE_OUTPUT"] else {
            throw XCTSkip("Set PANELCTL_SETTINGS_FIXTURE_OUTPUT to a directory to write Settings PNGs.")
        }
        let recovery = DisplayHandoffStatus(
            state: .recovery,
            target: hiddenStatus().target,
            source: hiddenStatus().source,
            journalPath: Self.journalPath,
            journalID: "settings-fixture",
            reason: "The display\u{2019}s mode changed since it was hidden. Reconnect it as it was, then try again.",
            recoveryCommand: "panelctl recovery enable --journal \(Self.journalPath)"
        )
        // A `recovery capture` journal names no display, so Displays shows it above them.
        let targetless = DisplayHandoffStatus(
            state: .unsupported,
            journalPath: Self.journalPath,
            journalID: "settings-capture-fixture",
            reason: "An unfinished recovery journal needs review."
        )
        let wakeReason = "display topology no longer matches this removal; inspect recovery before continuing"
        func fixtureIdentity(_ display: DisplayRecord) -> DisplayHandoffIdentity {
            DisplayHandoffIdentity(DisplayHideIdentity(
                uuid: display.uuid ?? "unavailable-\(display.id)", displayID: display.id,
                name: display.name, vendor: display.vendor, model: display.model, serial: display.serial
            ))
        }
        func recoveryObservation(_ display: DisplayRecord) -> DisplayHideObservation {
            DisplayHideObservation(
                identity: DisplayHideIdentity(uuid: display.uuid ?? "unavailable-\(display.id)",
                    displayID: display.id, name: display.name, vendor: display.vendor,
                    model: display.model, serial: display.serial),
                state: .recoveryNeeded,
                source: DisplayHideIdentity(uuid: displays[0].uuid!, displayID: displays[0].id,
                    name: displays[0].name, vendor: displays[0].vendor, model: displays[0].model,
                    serial: displays[0].serial), detail: wakeReason, isJournalTarget: true
            )
        }
        let wakeRemovals = [
            DisplayHandoffRemoval(id: "fixture-side", target: fixtureIdentity(displays[1]),
                                  source: fixtureIdentity(displays[0]), state: "needsAttention",
                                  isUnresolved: true, canShow: false, reason: wakeReason, topologyVerified: false),
            DisplayHandoffRemoval(id: "fixture-built-in", target: fixtureIdentity(displays[2]),
                                  source: fixtureIdentity(displays[0]), state: "needsAttention",
                                  isUnresolved: true, canShow: false, reason: wakeReason, topologyVerified: false)
        ]
        let wakeRecovery = DisplayHandoffStatus(
            state: .recovery, target: wakeRemovals[0].target, source: wakeRemovals[0].source,
            journalPath: Self.journalPath, journalID: "settings-wake-reset",
            reason: wakeReason, canShow: false,
            observations: [recoveryObservation(displays[1]), recoveryObservation(displays[2])],
            baselineIdentity: "synthetic-baseline", removals: wakeRemovals
        )
        let scenarios: [(name: String, experimental: Bool, status: DisplayHandoffStatus?, tab: SettingsTab)] = [
            ("off", false, nil, .displays),
            ("blacked-out", false, nil, .displays),
            ("setup", true, nil, .displays),
            ("main-target-setup", true, nil, .displays),
            ("no-switch", true, nil, .displays),
            ("mac-input", true, nil, .displays),
            ("unreadable", true, nil, .displays),
            ("refused", true, nil, .displays),
            ("partial", true, nil, .displays),
            ("hidden", true, hiddenStatus(), .displays),
            ("recovery", true, recovery, .displays),
            ("wake-reset", true, wakeRecovery, .displays),
            ("recovery-banner", true, recovery, .automation),
            ("recovery-journal", false, targetless, .displays),
            ("cleanup-displays", true, nil, .displays),
            ("cleanup-automation", true, nil, .automation)
        ]
        for scenario in scenarios {
            // "unreadable" uses a custom input code and a monitor that doesn't answer over DDC.
            let unreadable = scenario.name == "unreadable"
            // "partial" switched the monitor input, then couldn't hide the display.
            let partial = scenario.name == "partial"
            // "no-switch" doesn't switch inputs; "mac-input" then chooses this Mac's own input.
            let switches = !["no-switch", "mac-input"].contains(scenario.name)
            let (model, defaults) = try makeModel(
                status: { scenario.status },
                hideDisplay: { _, _, input in
                    guard partial else {
                        XCTFail("Settings fixtures never hide a display")
                        return .notRequested
                    }
                    throw DisplayHandoffOperationFailure(
                        action: "hide",
                        inputOutcome: DisplayInputOutcome(
                            state: .verified, requestedInput: input, observedInput: input,
                            recoveryCommand: "panelctl ddc-input --display '\(Self.sideUUID)' --set 0x0F"
                        ),
                        message: "Mirroring failed, so the display layout wasn\u{2019}t changed."
                    )
                },
                checkDDCInput: {
                    if unreadable { throw DDCError.requestFailed(-536870212) }
                    return DDCInputReading(displayID: $0.displayID, uuid: $0.uuid, current: 0x0F)
                },
                configure: { defaults in
                    defaults.set(scenario.experimental, forKey: "experimentalFeaturesEnabled")
                    if scenario.name.hasPrefix("cleanup-") {
                        defaults.set("Hardware brightness cleanup failed.",
                                     forKey: "automationCleanupFailure")
                    }
                    var hidePreferences = DisplayHidePreferences()
                    hidePreferences[Self.sideUUID] = DisplayHideConfiguration(
                        target: DisplayIdentitySnapshot(self.displays[1]),
                        enabled: true,
                        source: DisplayIdentitySnapshot(self.displays[0]),
                        awayInput: unreadable ? 0x1B : switches ? 0x11 : nil,
                        returnInput: unreadable || !switches ? nil : 0x0F
                    )
                    defaults.set(try JSONEncoder().encode(hidePreferences), forKey: "displayHidePreferences")
                }
            )
            defer { defaults.removePersistentDomain(forName: Self.suiteName) }
            spin { !model.protectionQuiescencePending }
            if scenario.name == "main-target-setup" {
                model.setHideEnabled(true, for: displays[0])
            }
            if scenario.name == "refused" {
                model.setDisplayLifecycleTransitioning(true)
                model.hide(targetUUID: Self.sideUUID)
                model.setDisplayLifecycleTransitioning(false)
            }
            if partial || scenario.name == "blacked-out" {
                model.hide(targetUUID: Self.sideUUID)
                spin { !model.hideOperation.isBusy }
            }
            if scenario.name == "mac-input" {
                model.detectMacInput(for: Self.sideUUID)
                model.setHideSwitchInput(0x0F, for: Self.sideUUID)
            }
            let controller = SettingsWindowController(model: model)
            controller.present()
            let window = try XCTUnwrap(controller.window)
            defer { window.close() }
            window.setContentSize(fixtureSize)
            controller.selectDisplay(uuid: scenario.name == "main-target-setup" ? Self.mainUUID : Self.sideUUID)
            controller.select(scenario.tab)
            try writeSnapshot(of: window, to: output, name: "displays-\(scenario.name)")
        }
    }

    func testDismissInputWarningFixtureSnapshots() throws {
        try requireInteractiveUI()
        for portrait in [false, true] {
            let records = [displays[0], Self.display(
                index: 2, id: displays[1].id, uuid: Self.sideUUID, name: "DELL S2721DGF",
                main: false, portrait: portrait)]
            var status: DisplayHandoffStatus? = hiddenStatus()
            var writes = 0
            let (model, defaults) = try makeModel(
                displays: records,
                status: { status },
                showDisplay: { _, _ in
                    writes += 1
                    status = nil
                    return DisplayInputOutcome(state: .skipped, requestedInput: 15,
                                               detail: "DDC input could not be read: invalid payload length.")
                },
                configure: { defaults in
                    defaults.set(true, forKey: "experimentalFeaturesEnabled")
                    var preferences = DisplayHidePreferences()
                    preferences[Self.sideUUID] = DisplayHideConfiguration(
                        target: DisplayIdentitySnapshot(records[1]), enabled: true,
                        source: DisplayIdentitySnapshot(records[0]), awayInput: 17, returnInput: 15)
                    defaults.set(try JSONEncoder().encode(preferences), forKey: "displayHidePreferences")
                })
            defer { defaults.removePersistentDomain(forName: Self.suiteName) }
            spin { !model.protectionQuiescencePending }
            model.show(targetUUID: Self.sideUUID)
            spin { !model.hideOperation.isBusy }
            XCTAssertTrue(model.canDismissInputWarning(for: Self.sideUUID))
            let controller = SettingsWindowController(model: model)
            controller.present()
            controller.selectDisplay(uuid: Self.sideUUID)
            let window = try XCTUnwrap(controller.window)
            defer { window.close() }
            window.setContentSize(fixtureSize)
            let orientation = portrait ? "portrait" : "landscape"
            if let output = ProcessInfo.processInfo.environment["PANELCTL_SETTINGS_FIXTURE_OUTPUT"] {
                try writeSnapshot(of: window, to: output, name: "input-warning-\(orientation)")
            }
            model.dismissInputWarning(for: Self.sideUUID)
            XCTAssertFalse(model.canDismissInputWarning(for: Self.sideUUID))
            XCTAssertFalse(try XCTUnwrap(model.displayResults[Self.sideUUID.lowercased()]).needsAttention)
            XCTAssertEqual(model.controlDisplayOutcome, .partial)
            XCTAssertEqual(writes, 1, "dismissal does not run Show again")
            if let output = ProcessInfo.processInfo.environment["PANELCTL_SETTINGS_FIXTURE_OUTPUT"] {
                try writeSnapshot(of: window, to: output, name: "input-dismissed-\(orientation)")
            }
        }
    }

    /// The fixture window's content size; the environment can override either side.
    private var fixtureSize: NSSize {
        let environment = ProcessInfo.processInfo.environment
        return NSSize(
            width: environment["PANELCTL_SETTINGS_FIXTURE_WIDTH"].flatMap(Double.init) ?? 680,
            height: environment["PANELCTL_SETTINGS_FIXTURE_HEIGHT"].flatMap(Double.init) ?? 640
        )
    }

    private func writeSnapshot(of window: NSWindow, to directory: String, name: String) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let bitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private static let suiteName = "panelctl-settings-window-\(ProcessInfo.processInfo.processIdentifier)"
    private static let journalPath = "/tmp/panelctl-settings-fixture/current.json"

    private func spin(timeout: TimeInterval = 2, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            // Like DisplayHideAppTests, drive AppKit lifecycle events: XCTest
            // runs the run loop but does not provide an NSApplication event loop.
            for _ in 0..<100 {
                guard let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) else { break }
                NSApp.sendEvent(event)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func sideTile(_ model: AppModel) throws -> DisplayTile {
        try XCTUnwrap(model.displayTiles.first { $0.id == Self.sideUUID.lowercased() })
    }

    private func nativeViews(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(nativeViews)
    }

    private func presentProductionRuleEditor(
        model: AppModel,
        rule: ProtectionRule,
        isNew: Bool
    ) throws -> (parent: NSWindow, sheet: NSWindow) {
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Swift owns this fixture window through teardown; close must not
        // also release the AppKit object.
        parent.isReleasedWhenClosed = false
        parent.contentView = NSHostingView(rootView: AutomationSettingsView(
            model: model,
            navigation: SettingsNavigation(),
            initialEditor: RuleEditorPresentation(rule: rule, isNew: isNew)
        ))
        parent.makeKeyAndOrderFront(nil)
        spin { parent.attachedSheet != nil }
        return (parent, try XCTUnwrap(parent.attachedSheet))
    }

    private func replaceEditorName(in sheet: NSWindow, with name: String) throws {
        let fields = nativeViews(in: try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSTextField }
        let field = try XCTUnwrap(fields.first(where: \.isEditable), "The production editor should expose its Name field")
        XCTAssertTrue(sheet.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(name, replacementRange: editor.selectedRange())
        XCTAssertEqual(field.stringValue, name)
    }

    private func presentProductionDisplayActionEditor(
        model: AppModel,
        navigation: SettingsNavigation,
        action: DisplayAction,
        existingID: UUID?,
        isNew: Bool
    ) throws -> (parent: NSWindow, sheet: NSWindow) {
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        parent.isReleasedWhenClosed = false
        parent.contentView = NSHostingView(rootView: DisplayActionEditorSheetHost(
            model: model,
            navigation: navigation,
            action: action,
            existingID: existingID,
            isNew: isNew
        ))
        parent.makeKeyAndOrderFront(nil)
        spin { parent.attachedSheet != nil }
        return (parent, try XCTUnwrap(parent.attachedSheet))
    }

    private func presentStandaloneDisplayActionEditor(
        in parent: NSWindow,
        model: AppModel,
        navigation: SettingsNavigation,
        action: DisplayAction,
        existingID: UUID?,
        isNew: Bool
    ) throws -> NSWindow {
        let sheetWidth = parent.contentView?.bounds.width ?? 520
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: sheetWidth, height: 760),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        sheet.contentView = NSHostingView(rootView: DisplayActionEditor(
            model: model, navigation: navigation, action: action, existingID: existingID, isNew: isNew
        ))
        parent.beginSheet(sheet)
        spin { parent.attachedSheet === sheet }
        return try XCTUnwrap(parent.attachedSheet)
    }

    private func presentStandaloneRuleEditor(
        in parent: NSWindow,
        model: AppModel,
        rule: ProtectionRule,
        existingID: UUID?,
        isNew: Bool
    ) throws -> NSWindow {
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        sheet.contentView = NSHostingView(rootView: ProtectionRuleEditor(
            model: model, rule: rule, existingID: existingID, isNew: isNew
        ))
        parent.beginSheet(sheet)
        spin { parent.attachedSheet === sheet }
        return try XCTUnwrap(parent.attachedSheet)
    }

    private func clickNativeButton(_ button: NSButton, atX x: CGFloat) {
        guard let window = button.window else { XCTFail("disclosure button has no window"); return }
        let point = button.convert(NSPoint(x: x, y: button.bounds.midY), to: nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
                                    windowNumber: window.windowNumber, context: nil,
                                    eventNumber: 1, clickCount: 1, pressure: 0)!
        // Queue the release before entering NSButton's synchronous tracking loop.
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
    }

    private func sendSpaceKey(to window: NSWindow) {
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil,
                                    characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0.01,
                                  windowNumber: window.windowNumber, context: nil,
                                  characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        window.sendEvent(down)
        window.sendEvent(up)
    }

    /// Opens the side display in Displays and returns its Remove from desktop switch, if shown.
    private func removalSwitch(in model: AppModel) throws -> NSSwitch? {
        let controller = SettingsWindowController(model: model)
        controller.present()
        controller.selectDisplay(uuid: Self.sideUUID)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        window.setContentSize(NSSize(width: 680, height: 1200))
        let content = try XCTUnwrap(window.contentView)
        let expectedState: NSControl.StateValue = model.hideRemovesFromDesktop(displays[1]) ? .on : .off
        spin {
            content.layoutSubtreeIfNeeded()
            let switches = nativeViews(in: content).compactMap { $0 as? NSSwitch }
            return model.experimentalFeaturesEnabled
                ? switches.count == 1 && switches[0].state == expectedState
                : switches.isEmpty
        }
        // The Displays tab has only one switch. Wait for SwiftUI to apply the
        // selection and binding instead of reading the initial default state.
        let switches = nativeViews(in: content).compactMap { $0 as? NSSwitch }
        return switches.count == 1 ? switches[0] : nil
    }

    private var hiddenDisplays: [DisplayRecord] {
        [displays[0], Self.display(index: 2, id: 12, uuid: Self.sideUUID,
                                  name: "DELL S2721DGF", main: false, active: false), displays[2]]
    }

    private func hiddenStatus() -> DisplayHandoffStatus {
        let identity: (DisplayRecord) -> DisplayHideIdentity = {
            DisplayHideIdentity(uuid: $0.uuid!, displayID: $0.id, name: $0.name, vendor: $0.vendor, model: $0.model, serial: $0.serial)
        }
        let target = identity(displays[1])
        let source = identity(displays[0])
        return DisplayHandoffStatus(
            state: .hidden,
            target: DisplayHandoffIdentity(target),
            source: DisplayHandoffIdentity(source),
            journalPath: Self.journalPath,
            journalID: "settings-fixture",
            canShow: true,
            observations: [DisplayHideObservation(
                identity: target, state: .hiddenByPanelCtl, source: source, detail: nil, isJournalTarget: true
            )],
            mirrorTopologyVerified: true
        )
    }

    private func makeModel(
        displays: [DisplayRecord]? = nil,
        keepingDefaults: Bool = false,
        status: @escaping () -> DisplayHandoffStatus? = { nil },
        hideDisplay: @escaping (DisplayHideIdentity, DisplayHideIdentity, UInt8?) throws -> DisplayInputOutcome = { _, _, _ in
            XCTFail("Settings fixtures never hide a display")
            return .notRequested
        },
        showDisplay: @escaping (String, UInt8?) throws -> DisplayInputOutcome = { _, _ in
            XCTFail("Settings fixtures never show a display")
            return .notRequested
        },
        // Showing the removal setup reads this Mac's input; it never writes.
        checkDDCInput: @escaping (DisplayHideIdentity) throws -> DDCInputReading = {
            DDCInputReading(displayID: $0.displayID, uuid: $0.uuid, current: 0x0F)
        },
        protectionCoordinator: ProtectionCoordinator? = nil,
        configure: (UserDefaults) throws -> Void = { _ in }
    ) throws -> (AppModel, UserDefaults) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        if !keepingDefaults {
            defaults.removePersistentDomain(forName: Self.suiteName)
        }
        try configure(defaults)
        let displays = displays ?? self.displays
        let model = AppModel(
            defaults: defaults,
            displayProvider: { displays },
            idleSecondsProvider: { nil },
            isDisplayMirrored: { _ in false },
            inspectHandoff: {
                status() ?? DisplayHandoffStatus(state: .none, journalPath: Self.journalPath)
            },
            hideDisplay: hideDisplay,
            showDisplay: showDisplay,
            checkDDCInput: checkDDCInput,
            // Black out never draws over a real screen in tests.
            coverDisplays: { _ in [] },
            quiesceProtection: { $0(true, nil) },
            protectionCoordinator: protectionCoordinator
        )
        return (model, defaults)
    }

    private static func display(
        index: Int, id: UInt32, uuid: String, name: String, main: Bool, builtin: Bool = false,
        portrait: Bool = false, active: Bool = true
    ) -> DisplayRecord {
        DisplayRecord(
            index: index,
            id: id,
            uuid: uuid,
            name: name,
            active: active,
            online: true,
            asleep: false,
            builtin: builtin,
            main: main,
            vendor: UInt32(index),
            model: UInt32(index * 10),
            serial: UInt32(index * 100),
            bounds: DisplayBounds(CGRect(x: (index - 1) * 1920, y: 0,
                                         width: portrait ? 1080 : 1920, height: portrait ? 1920 : 1080)),
            pixelWidth: portrait ? 1080 : 1920,
            pixelHeight: portrait ? 1920 : 1080
        )
    }
}

@MainActor
private struct DisplayActionEditorSheetHost: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigation
    @State private var presentation: DisplayActionEditorPresentation?

    private let existingID: UUID?
    private let isNew: Bool

    init(
        model: AppModel,
        navigation: SettingsNavigation,
        action: DisplayAction,
        existingID: UUID?,
        isNew: Bool
    ) {
        self.model = model
        self.navigation = navigation
        self.existingID = existingID
        self.isNew = isNew
        _presentation = State(initialValue: DisplayActionEditorPresentation(action: action, isNew: isNew))
    }

    var body: some View {
        Text("Display action editor test host")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(item: $presentation) { presentation in
                DisplayActionEditor(
                    model: model,
                    navigation: navigation,
                    action: presentation.action,
                    existingID: existingID,
                    isNew: isNew
                )
            }
    }
}
