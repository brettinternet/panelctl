import AppKit
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
        NSApp.windows
            .filter { $0.identifier == SettingsWindowController.windowIdentifier }
            .forEach { $0.close() }
        super.tearDown()
    }

    func testToolbarTabsAndKeyboardShortcutsReachEveryTab() throws {
        let (model, defaults) = try makeModel()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let controller = SettingsWindowController(model: model)
        controller.present()
        let window = try XCTUnwrap(controller.window)
        let toolbar = try XCTUnwrap(window.toolbar)
        XCTAssertEqual(window.toolbarStyle, .preference)
        XCTAssertEqual(toolbar.items.map(\.label), ["Displays", "Automation", "General"])
        XCTAssertEqual(toolbar.items.map { $0.image?.accessibilityDescription }, ["Displays", "Automation", "General"])
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
        XCTAssertEqual(axTabs.map { $0.accessibilityTitle() }, ["Displays", "Automation", "General"])
        for (axTab, tab) in zip(axTabs, SettingsTab.allCases).reversed() {
            _ = axTab.accessibilityPerformPress()
            XCTAssertEqual(controller.selectedTab, tab)
        }

        controller.select(.general)
        controller.selectDisplay(uuid: Self.sideUUID)
        XCTAssertEqual(controller.selectedTab, .displays, "selecting a display opens Displays")
        XCTAssertEqual(controller.selectedDisplayID, Self.sideUUID.lowercased())
    }

    func testExperimentalFlagDefaultsOffPersistsAndGatesRemovalButNotShow() throws {
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
        XCTAssertEqual(model.handleDisplayControlRequest(AppControlRequest(command: .hide, targetUUID: Self.sideUUID)).outcome, .refused)
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

    func testBlackedOutDisplayStaysHiddenAfterSettingsCloses() throws {
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
        let (model, defaults) = try makeModel()
        defer { defaults.removePersistentDomain(forName: Self.suiteName) }
        let controller = SettingsWindowController(model: model)
        controller.present()
        controller.select(.general)
        let window = try XCTUnwrap(controller.window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        func consentButton(_ title: String) throws -> NSButton {
            spin { window.attachedSheet != nil }
            let sheet = try XCTUnwrap(window.attachedSheet, "consent is presented on the Settings window")
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

    /// Opt-in visual fixture: writes one PNG per tab for review and docs.
    func testSettingsFixtureSnapshots() throws {
        guard let output = ProcessInfo.processInfo.environment["PANELCTL_SETTINGS_FIXTURE_OUTPUT"] else {
            throw XCTSkip("Set PANELCTL_SETTINGS_FIXTURE_OUTPUT to a directory to write Settings PNGs.")
        }
        let height = ProcessInfo.processInfo.environment["PANELCTL_SETTINGS_FIXTURE_HEIGHT"].flatMap(Double.init) ?? 640
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
            window.setContentSize(NSSize(width: 680, height: height))
            for tab in SettingsTab.allCases {
                controller.select(tab)
                try writeSnapshot(of: window, to: output, name: "settings-\(scenario.name)-\(tab.rawValue)")
            }
        }
    }

    /// Opt-in visual fixture: writes one PNG per Displays state for review and docs.
    func testDisplaysFixtureSnapshots() throws {
        guard let output = ProcessInfo.processInfo.environment["PANELCTL_SETTINGS_FIXTURE_OUTPUT"] else {
            throw XCTSkip("Set PANELCTL_SETTINGS_FIXTURE_OUTPUT to a directory to write Settings PNGs.")
        }
        let height = ProcessInfo.processInfo.environment["PANELCTL_SETTINGS_FIXTURE_HEIGHT"].flatMap(Double.init) ?? 640
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
        let scenarios: [(name: String, experimental: Bool, status: DisplayHandoffStatus?, tab: SettingsTab)] = [
            ("off", false, nil, .displays),
            ("blacked-out", false, nil, .displays),
            ("setup", true, nil, .displays),
            ("unreadable", true, nil, .displays),
            ("refused", true, nil, .displays),
            ("partial", true, nil, .displays),
            ("hidden", true, hiddenStatus(), .displays),
            ("recovery", true, recovery, .displays),
            ("recovery-banner", true, recovery, .automation),
            ("recovery-journal", false, targetless, .displays)
        ]
        for scenario in scenarios {
            // "unreadable" uses a custom input code and a monitor that doesn't answer over DDC.
            let unreadable = scenario.name == "unreadable"
            // "partial" switched the monitor input, then couldn't hide the display.
            let partial = scenario.name == "partial"
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
                    var hidePreferences = DisplayHidePreferences()
                    hidePreferences[Self.sideUUID] = DisplayHideConfiguration(
                        target: DisplayIdentitySnapshot(self.displays[1]),
                        enabled: true,
                        source: DisplayIdentitySnapshot(self.displays[0]),
                        awayInput: unreadable ? 0x1B : 0x11,
                        returnInput: unreadable ? nil : 0x0F
                    )
                    defaults.set(try JSONEncoder().encode(hidePreferences), forKey: "displayHidePreferences")
                }
            )
            defer { defaults.removePersistentDomain(forName: Self.suiteName) }
            spin { !model.protectionQuiescencePending }
            if scenario.name == "refused" {
                model.setDisplayLifecycleTransitioning(true)
                model.hide(targetUUID: Self.sideUUID)
                model.setDisplayLifecycleTransitioning(false)
            }
            if partial || scenario.name == "blacked-out" {
                model.hide(targetUUID: Self.sideUUID)
                spin { !model.hideOperation.isBusy }
            }
            let controller = SettingsWindowController(model: model)
            controller.present()
            let window = try XCTUnwrap(controller.window)
            defer { window.close() }
            window.setContentSize(NSSize(width: 680, height: height))
            controller.selectDisplay(uuid: Self.sideUUID)
            controller.select(scenario.tab)
            try writeSnapshot(of: window, to: output, name: "displays-\(scenario.name)")
        }
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
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func sideTile(_ model: AppModel) throws -> DisplayTile {
        try XCTUnwrap(model.displayTiles.first { $0.id == Self.sideUUID.lowercased() })
    }

    private func nativeViews(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(nativeViews)
    }

    /// Opens the side display in Displays and returns its Remove from desktop switch, if shown.
    private func removalSwitch(in model: AppModel) throws -> NSSwitch? {
        let controller = SettingsWindowController(model: model)
        controller.present()
        controller.selectDisplay(uuid: Self.sideUUID)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        window.setContentSize(NSSize(width: 680, height: 1200))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return nativeViews(in: try XCTUnwrap(window.contentView)).lazy.compactMap { $0 as? NSSwitch }.first
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
        checkDDCInput: @escaping (DisplayHideIdentity) throws -> DDCInputReading = { _ in
            XCTFail("Settings fixtures never query DDC")
            return DDCInputReading(displayID: 0, uuid: "", current: 1)
        },
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
            showDisplay: { _, _ in
                XCTFail("Settings fixtures never show a display")
                return .notRequested
            },
            checkDDCInput: checkDDCInput,
            // Black out never draws over a real screen in tests.
            coverDisplays: { _ in [] },
            quiesceProtection: { $0(true, nil) }
        )
        return (model, defaults)
    }

    private static func display(
        index: Int, id: UInt32, uuid: String, name: String, main: Bool, builtin: Bool = false
    ) -> DisplayRecord {
        DisplayRecord(
            index: index,
            id: id,
            uuid: uuid,
            name: name,
            active: true,
            online: true,
            asleep: false,
            builtin: builtin,
            main: main,
            vendor: UInt32(index),
            model: UInt32(index * 10),
            serial: UInt32(index * 100),
            bounds: DisplayBounds(CGRect(x: (index - 1) * 1920, y: 0, width: 1920, height: 1080)),
            pixelWidth: 1920,
            pixelHeight: 1080
        )
    }
}
