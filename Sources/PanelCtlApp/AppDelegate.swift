import AppKit
import Combine
import OSLog
import PanelCtlCore

private let shutdownLogger = Logger(
    subsystem: "com.brettinternet.panelctl",
    category: "shutdown"
)
private let displayHideLogger = Logger(
    subsystem: "com.brettinternet.panelctl",
    category: "display-hide"
)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var model: AppModel!
    private var controlServer: AppControlServer?
    private var statusItem: NSStatusItem?
    private var settingsWindowController: SettingsWindowController?
    private let onSettingsPresentationChange: (Bool) -> Void
    private var noticeCancellable: AnyCancellable?
    private var statusCancellable: AnyCancellable?
    private var launchedAsLoginItem = false
    private var suppressInitialSettings = false
    private var terminationPending = false
    private lazy var blackoutFocusController = BlackoutFocusController { [weak self] in
        self?.handleBlackoutEscape() ?? false
    }
    private var blackoutFocusTimer: Timer?

    init(onSettingsPresentationChange: @escaping (Bool) -> Void = { _ in }) {
        self.onSettingsPresentationChange = onSettingsPresentationChange
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAsLoginItem =
            event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                == keyAELaunchedAsLogInItem
        suppressInitialSettings = CommandLine.arguments.contains("--background")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel(windowMovePermission: SystemWindowMovePermission())
        if model.protectionPausedForDisplayRecovery {
            displayHideLogger.error("Startup found unresolved display recovery: \(self.model.handoffStatus?.inspectionCommand ?? "inspect shared display journal", privacy: .public)")
        }
        let controlServer = AppControlServer(statusSnapshot: { [weak self] in
            self?.controlStatusResponse() ?? .unavailable()
        }) { [weak self] request, receivedAt in
            await self?.handleControlRequest(request, receivedAt: receivedAt) ?? .unavailable()
        }
        do {
            try controlServer.start()
            self.controlServer = controlServer
        } catch {
            fputs("PanelCtl: app control unavailable: \(error.localizedDescription)\n", stderr)
        }
        configureMainMenu()
        configureStatusItem()
        model.onStatusChange = { [weak self] in
            guard let self else { return }
            self.controlServer?.statusDidChange()
            self.updateStatusItem()
            self.updateBlackoutFocus()
            self.moveSettingsOffHiddenDisplays()
        }
        statusCancellable = model.objectWillChange.sink { [weak self] _ in
            // Snapshot after the mutation, in the stream's coalescing window.
            self?.controlServer?.statusDidChange()
        }
        noticeCancellable = model.$notice.sink { [weak self] notice in
            guard let self, let notice else { return }
            self.presentNoticeIfNeeded(notice)
        }
        installScreenObservers()
        updateStatusItem()
        updateBlackoutFocus()

        if !launchedAsLoginItem && !suppressInitialSettings {
            showSettings()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showSettings()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !blackoutFocusController.isEngaged else { return }
        model?.refreshLaunchAtLoginStatus()
        model?.refreshDisplays()
        if settingsWindowController?.window?.isVisible == true {
            settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        if let runningAction = model.runningDisplayAction {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Action in progress"
            alert.informativeText = "Action “\(runningAction.name)” is running step \(runningAction.currentStep) of \(runningAction.totalSteps). Wait for it to finish before quitting."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return .terminateCancel
        }
        if model.hideOperation.isBusy {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Display operation in progress"
            alert.informativeText = "Wait for Hide or Show to finish. It can\u{2019}t be canceled."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return .terminateCancel
        }
        if model.handoffStatus?.hasUnresolvedJournal == true || model.protectionQuiescenceFailure != nil {
            let status = model.handoffStatus
            let target = status?.hasUnresolvedJournal == true ? status?.target : nil
            let removalCount = status?.removals.filter(\.isUnresolved).count ?? (target == nil ? 0 : 1)
            let canShow = model.canShowHiddenDisplay
            let alert = NSAlert()
            alert.alertStyle = .warning
            if status?.hasUnresolvedJournal == true {
                alert.messageText = status?.state == .hidden && canShow
                    ? (removalCount > 1 ? "\(removalCount) displays are still removed" : "\(target?.name ?? "A display") is still hidden")
                    : "Display recovery isn\u{2019}t finished"
                alert.informativeText = "PanelCtl won\u{2019}t show removed displays or switch monitor inputs after quitting. Open PanelCtl again to show them."
            } else {
                alert.messageText = "Automation cleanup needs attention"
                alert.informativeText = "PanelCtl couldn\u{2019}t confirm automation stopped: \(model.protectionQuiescenceFailure ?? "unknown error")"
            }
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: canShow ? "Show and Quit" : "Review\u{2026}")
            alert.addButton(withTitle: "Quit Anyway")
            if let cancel = alert.buttons.first {
                alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
            }
            switch alert.runModal() {
            case .alertSecondButtonReturn:
                if canShow, status?.hasUnresolvedJournal == true {
                    showAndQuitRemainingDisplays()
                } else if let uuid = target?.uuid {
                    showSettings(displayUUID: uuid)
                } else {
                    showSettings(tab: status?.hasUnresolvedJournal == true ? .displays : .automation)
                }
                return .terminateCancel
            case .alertThirdButtonReturn:
                break
            default:
                return .terminateCancel
            }
        }
        terminationPending = true
        let startedAt = ProcessInfo.processInfo.systemUptime
        shutdownLogger.info("Application termination requested")
        model.shutdown {
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let duration = String(format: "%.3f", elapsed)
            shutdownLogger.info(
                "Application termination cleanup completed in \(duration, privacy: .public)s"
            )
            DispatchQueue.main.async {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.cancelPendingSleepHideResume()
        blackoutFocusTimer?.invalidate()
        blackoutFocusController.shutdown()
        controlServer?.stop()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Focus follows the pointer onto hidden displays and, in blocking mode,
    /// onto displays automation blacked out, so Escape reaches PanelCtl.
    private func updateBlackoutFocus() {
        guard let model else { return }
        var focusDisplayIDs = model.coveredHiddenDisplayIDs
        focusDisplayIDs.formUnion(model.automationBlockingDisplayIDs)
        if !focusDisplayIDs.isEmpty {
            if blackoutFocusTimer == nil {
                let timer = Timer(
                    timeInterval: 0.05,
                    target: self,
                    selector: #selector(pollBlackoutFocus),
                    userInfo: nil,
                    repeats: true
                )
                RunLoop.main.add(timer, forMode: .common)
                blackoutFocusTimer = timer
            }
            let frames = NSScreen.screens.compactMap { screen -> CGRect? in
                guard let id = Self.displayID(of: screen), focusDisplayIDs.contains(id) else { return nil }
                return screen.frame
            }
            blackoutFocusController.enter(targetFrames: frames)
        } else {
            blackoutFocusTimer?.invalidate()
            blackoutFocusTimer = nil
            blackoutFocusController.leave()
        }
    }

    /// Escape on a hidden display shows it; elsewhere it restores automation.
    private func handleBlackoutEscape() -> Bool {
        let pointer = NSEvent.mouseLocation
        if let id = NSScreen.screens.first(where: { $0.frame.contains(pointer) }).flatMap(Self.displayID(of:)),
           model.showHiddenDisplay(at: id) {
            return true
        }
        return requestBlackoutRestore()
    }

    /// Settings on a hidden display would sit under its cover; center it on a visible one.
    private func moveSettingsOffHiddenDisplays() {
        let hidden = model.coveredHiddenDisplayIDs
        guard let window = settingsWindowController?.window, window.isVisible,
              let id = window.screen.flatMap(Self.displayID(of:)), hidden.contains(id),
              let visible = NSScreen.screens.first(where: {
                  Self.displayID(of: $0).map { !hidden.contains($0) } ?? false
              }) else { return }
        let area = visible.visibleFrame
        window.setFrameOrigin(NSPoint(
            x: area.midX - window.frame.width / 2,
            y: area.midY - window.frame.height / 2
        ))
    }

    private static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func shouldRestartWatcher(after notification: Notification.Name) -> Bool {
        notification == NSApplication.didChangeScreenParametersNotification ||
            notification == NSWorkspace.screensDidWakeNotification ||
            notification == screenUnlockedNotification
    }

    static func shouldEngageBlackoutFocus(
        runtimeState: ProtectionRuntimeState,
        mode: BlackoutMode,
        hasBlackedOutDisplays: Bool = false
    ) -> Bool {
        mode == .blocking &&
            (runtimeState == .blackedOut || hasBlackedOutDisplays)
    }

    @objc private func pollBlackoutFocus() {
        updateBlackoutFocus()
    }


    private func configureStatusItem() {
        guard model.showMenuBarIcon, statusItem == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "PanelCtlStatusItem"
        self.statusItem = statusItem
    }

    func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem(
            title: "PanelCtl",
            action: nil,
            keyEquivalent: ""
        )
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "About PanelCtl", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", action: #selector(openSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide PanelCtl", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(
            title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(
            title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit PanelCtl", action: #selector(quit), key: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(
            title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"
        ))
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        // Leave native commands untargeted so the focused control handles them.
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(
            title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"
        ))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(item("View on GitHub", action: #selector(openGitHub)))
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    private func updateStatusItem() {
        guard let model else { return }
        if !model.showMenuBarIcon {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
            return
        }
        configureStatusItem()
        guard let statusItem else { return }
        let image = NSImage(
            systemSymbolName: model.statusSystemImage,
            accessibilityDescription: model.statusSummary
        ) ?? NSImage(systemSymbolName: "shield", accessibilityDescription: "PanelCtl")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "PanelCtl — \(model.statusSummary)"
        statusItem.menu = makeMenu()
    }

    /// The menu keeps this width; status text wraps instead of widening it.
    static let menuWidth: CGFloat = 300
    /// Room for the menu's insets and image column, so wrapped text never widens it.
    private static let menuTextWidth = menuWidth - 60

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = Self.menuWidth
        menu.delegate = self

        let status = infoItem(model.statusSummary)
        status.image = NSImage(
            systemSymbolName: model.statusSystemImage,
            accessibilityDescription: nil
        )
        menu.addItem(status)

        if let message = model.runtimeState.detailMessage {
            menu.addItem(infoItem(message, maxLines: 3))
        }
        for (uuid, status) in model.keepWindowsOffStatuses.sorted(by: { $0.key < $1.key }) where status.state != .off {
            let name = model.displayTiles.first(where: { $0.id == uuid })?.name ?? "Display \(uuid.prefix(8))…"
            menu.addItem(infoItem("\(name): \(status.description)", maxLines: 3))
        }

        menu.addItem(.separator())
        let runRule = NSMenuItem(title: "Run rule", action: nil, keyEquivalent: "")
        let rulesMenu = NSMenu()
        rulesMenu.autoenablesItems = false
        for rule in model.automationPreferences.rules {
            let running = model.controlRunningRule?.id == rule.id
            let title = rule.name + (rule.isEnabled ? "" : " (Off)") + (running ? " — Running once" : "")
            let entry = item(title, action: #selector(runRuleFromMenu(_:)))
            entry.representedObject = rule.id
            let blocker = model.protectionRuleRunBlocker(id: rule.id)
            entry.isEnabled = blocker == nil
            entry.toolTip = blocker ?? "Run just this rule once without changing its automatic trigger."
            rulesMenu.addItem(entry)
        }
        runRule.submenu = rulesMenu
        runRule.isEnabled = !model.automationPreferences.rules.isEmpty
        runRule.toolTip = runRule.isEnabled ? "Run one saved Automation rule once." : "Create a rule in Settings → Automations."
        menu.addItem(runRule)
        if model.controlRunningRule != nil || !model.blackedOutDisplayIDs.isEmpty {
            menu.addItem(restoreMenuItem())
        } else {
            switch model.runtimeState {
            case .blackedOut, .sleeping: menu.addItem(restoreMenuItem())
            default: break
            }
        }
        let sleep = item("Sleep Displays", action: #selector(sleepAllNow))
        if model.runningDisplayAction != nil {
            sleep.isEnabled = false
            sleep.toolTip = model.displayActionBusyMessage
        }
        menu.addItem(sleep)
        if !model.preferences.isEnabled {
            menu.addItem(item("Turn On Automation", action: #selector(toggleProtection)))
        } else if model.snoozedUntil != nil {
            menu.addItem(item("Resume Automation", action: #selector(resumeProtection)))
            menu.addItem(item("Turn Off Automation", action: #selector(toggleProtection)))
        } else {
            let pauseMenuItem = NSMenuItem(title: "Pause Automation", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            submenu.addItem(snoozeItem("For 30 Minutes", duration: 30 * 60))
            submenu.addItem(snoozeItem("For 1 Hour", duration: 60 * 60))
            submenu.addItem(item("Until Tomorrow", action: #selector(snoozeUntilTomorrow)))
            submenu.addItem(.separator())
            submenu.addItem(item("Turn Off Automation", action: #selector(toggleProtection)))
            pauseMenuItem.submenu = submenu
            menu.addItem(pauseMenuItem)
        }

        addDisplayMenuSection(to: menu)
        menu.addItem(.separator())

        if model.protectionQuiescenceFailure != nil {
            let retry = item("Retry Automation Cleanup", action: #selector(retryProtection))
            retry.isEnabled = model.runningDisplayAction == nil && !model.protectionQuiescencePending && !model.hideOperation.isBusy
            if model.runningDisplayAction != nil { retry.toolTip = model.displayActionBusyMessage }
            menu.addItem(retry)
        } else if model.runtimeState.errorMessage != nil, model.preferences.isEnabled {
            menu.addItem(item("Retry Automation", action: #selector(retryProtection)))
        }

        menu.addItem(item("Settings…", action: #selector(openSettings), key: ","))
        menu.addItem(.separator())
        let quit = item("Quit PanelCtl", action: #selector(quit), key: "q")
        if model.runningDisplayAction != nil {
            quit.isEnabled = false
            quit.toolTip = model.displayActionBusyMessage
        }
        menu.addItem(quit)
        if model.runningDisplayAction != nil {
            let busy = model.displayActionBusyMessage
            for menuItem in menu.items where menuItem.isEnabled &&
                menuItem.action != #selector(openSettings) && menuItem.action != #selector(reviewDisplayRecovery) {
                menuItem.isEnabled = false
                menuItem.toolTip = busy
                for child in menuItem.submenu?.items ?? [] where child.isEnabled {
                    child.isEnabled = false
                    child.toolTip = busy
                }
            }
        }
        return menu
    }

    /// Each display with its Hide or Show and its state. An action that can't
    /// run is dimmed, and its tooltip says why.
    private func addDisplayMenuSection(to menu: NSMenu) {
        var items: [NSMenuItem] = []
        if model.displayRecoveryProblem != nil {
            items.append(item("Review Display Recovery…", action: #selector(reviewDisplayRecovery)))
        }
        for tile in model.displayTiles {
            let display: NSMenuItem
            switch tile.action {
            case .hide?:
                display = item("Hide \(tile.name)", action: #selector(hideDisplayFromMenu(_:)))
            case .show?:
                display = item("Show \(tile.name)", action: #selector(showDisplayFromMenu(_:)))
            case nil:
                display = disabledItem(tile.name)
            }
            display.representedObject = tile.uuid
            if tile.action != nil {
                display.isEnabled = tile.actionBlocker == nil
                display.toolTip = tile.actionBlocker
            }
            let enforcement = model.keepWindowsOffStatuses[tile.id]
            let subtitle = enforcement.map { "\(tile.status.label) · Keep windows \($0.label)" } ?? tile.status.label
            if #available(macOS 14.4, *) {
                display.subtitle = subtitle
            } else {
                display.title += " — \(subtitle)"
            }
            items.append(display)
            if let enforcement {
                let line = infoItem(enforcement.description, maxLines: 3)
                line.indentationLevel = 1
                items.append(line)
            }
            if let line = model.displayResults[tile.id]?.menuLine {
                let result = infoItem(line, maxLines: 2)
                result.indentationLevel = 1
                items.append(result)
            }
        }
        guard !items.isEmpty else { return }
        menu.addItem(.separator())
        items.forEach(menu.addItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.refreshHandoffStatus()
        guard let status = menu.items.first else { return }
        setInfoTitle(model.statusSummary, of: status)
        status.image = NSImage(
            systemSymbolName: model.statusSystemImage,
            accessibilityDescription: nil
        )
        statusItem?.button?.toolTip = "PanelCtl — \(model.statusSummary)"
    }

    private func item(
        _ title: String,
        action: Selector,
        key: String = ""
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        menuItem.isEnabled = true
        return menuItem
    }

    private func restoreMenuItem() -> NSMenuItem {
        let restore = item("Restore", action: #selector(restoreNow))
        restore.toolTip = model.runningDisplayAction?.id != nil
            ? model.displayActionBusyMessage
            : "Ends blackout or dimming from every rule. Hidden displays stay hidden."
        restore.isEnabled = model.runningDisplayAction == nil
        return restore
    }

    /// A disabled line of status text, wrapped to the menu's fixed width.
    private func infoItem(_ text: String, maxLines: Int = 2) -> NSMenuItem {
        let item = disabledItem("")
        setInfoTitle(text, of: item, maxLines: maxLines)
        return item
    }

    /// Menu titles don't wrap on their own, but an attributed title renders
    /// its line breaks, so break the text where it would pass the fixed width.
    private func setInfoTitle(_ text: String, of item: NSMenuItem, maxLines: Int = 2) {
        let font = NSFont.menuFont(ofSize: 0)
        let lines = Self.wrap(text, width: Self.menuTextWidth, font: font, maxLines: maxLines)
        item.attributedTitle = NSAttributedString(
            string: lines.joined(separator: "\n"),
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        )
        item.toolTip = lines.joined(separator: " ") == text ? nil : text
    }

    static func wrap(_ text: String, width: CGFloat, font: NSFont, maxLines: Int) -> [String] {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let storage = NSTextStorage(string: flat, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var lines: [String] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, glyphs, _ in
            let range = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            lines.append((flat as NSString).substring(with: range).trimmingCharacters(in: .whitespaces))
        }
        guard lines.count > maxLines else { return lines }
        lines = Array(lines.prefix(maxLines))
        var last = lines[maxLines - 1]
        let fits = { (line: String) in
            ((line + "…") as NSString).size(withAttributes: [.font: font]).width <= width
        }
        while !last.isEmpty, !fits(last) { last.removeLast() }
        lines[maxLines - 1] = last.trimmingCharacters(in: .whitespaces) + "…"
        return lines
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func snoozeItem(_ title: String, duration: TimeInterval) -> NSMenuItem {
        let menuItem = item(title, action: #selector(snoozeForDuration(_:)))
        menuItem.representedObject = duration
        return menuItem
    }

    @objc private func toggleProtection() {
        model.setProtectionEnabled(!model.preferences.isEnabled)
        if model.preferences.isEnabled, model.validationMessage != nil {
            showSettings(tab: .automation)
        }
    }

    @objc private func retryProtection() {
        model.retryProtection()
    }

    @objc private func hideDisplayFromMenu(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        model.hide(targetUUID: uuid) { [weak self] in self?.revealFailure($0, displayUUID: uuid) }
    }

    @objc private func showDisplayFromMenu(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        model.show(targetUUID: uuid) { [weak self] in self?.revealFailure($0, displayUUID: uuid) }
    }

    /// A menu action that fails opens its display in Settings, where the result is shown.
    private func revealFailure(_ result: DisplayOperationResult, displayUUID: String) {
        guard !result.succeeded else { return }
        showSettings(displayUUID: displayUUID)
    }

    @objc private func reviewDisplayRecovery() {
        if let uuid = model.handoffStatus?.target?.uuid {
            showSettings(displayUUID: uuid)
        } else {
            showSettings(tab: .displays)
        }
    }

    @objc func runRuleFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        Task {
            let result = await model.runProtectionRule(id: id)
            if !result.ok { showSettings(tab: .automation) }
        }
    }

    @objc private func restoreNow() {
        _ = requestBlackoutRestore()
    }

    private func requestBlackoutRestore() -> Bool {
        do {
            return try model.restoreBlackout()
        } catch {
            presentActionError("Could not restore displays", error: error)
            return false
        }
    }

    @objc private func sleepAllNow() {
        do {
            try model.sleepAllNow()
        } catch {
            presentActionError("Could not sleep displays", error: error)
        }
    }

    @objc private func snoozeForDuration(_ sender: NSMenuItem) {
        guard let duration = sender.representedObject as? TimeInterval else { return }
        model.snooze(for: duration)
    }

    @objc private func snoozeUntilTomorrow() {
        model.snoozeUntilTomorrow()
    }

    @objc private func resumeProtection() {
        model.resumeProtection()
    }

    @objc private func openSettings() {
        showSettings()
    }

    @objc private func openGitHub() {
        model.openGitHub()
    }

    private func showAndQuitRemainingDisplays() {
        guard let model else { return }
        model.refreshHandoffStatus()
        guard let status = model.handoffStatus, status.hasUnresolvedJournal else {
            NSApp.terminate(nil)
            return
        }
        let unresolved = status.removals.filter(\.isUnresolved)
        let target = unresolved.first?.target.uuid ?? status.target?.uuid
        guard let target, model.canShowHiddenDisplay else {
            showSettings(tab: .displays, displayUUID: target)
            return
        }
        model.show(targetUUID: target) { [weak self] result in
            guard let self else { return }
            if result.succeeded {
                self.showAndQuitRemainingDisplays()
            } else {
                self.showSettings(tab: .displays, displayUUID: target)
            }
        }
    }

    /// Opens Settings on a tab or display; a display recovery problem opens
    /// its display unless the caller asks for something else.
    private func showSettings(tab: SettingsTab? = nil, displayUUID: String? = nil) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                model: model, onPresentationChange: onSettingsPresentationChange
            )
        }
        model.refreshLaunchAtLoginStatus()
        model.refreshDisplays()
        settingsWindowController?.present()
        moveSettingsOffHiddenDisplays()
        if let displayUUID {
            settingsWindowController?.selectDisplay(uuid: displayUUID)
        } else if let tab {
            settingsWindowController?.select(tab)
        } else if model.displayRecoveryProblem != nil {
            if let uuid = model.handoffStatus?.target?.uuid {
                settingsWindowController?.selectDisplay(uuid: uuid)
            } else {
                settingsWindowController?.select(.displays)
            }
        }
    }

    func handleControlRequest(
        _ request: AppControlRequest,
        receivedAt: ContinuousClock.Instant
    ) async -> AppControlResponse {
        guard request.hasSupportedProtocol else {
            return controlResponse(
                ok: false,
                error: "unsupported app-control protocol \(request.protocolVersion)"
            )
        }
        if request.command == .blackoutNow {
            let message = AppControlCommand.blackoutNowMigrationGuidance
            return controlResponse(ok: false, summary: message, error: message, outcome: .refused)
        }
        if model.runningDisplayAction != nil,
           ![AppControlCommand.status, .openSettings, .hide, .show, .toggleHide, .runAction, .runRule].contains(request.command) {
            return controlResponse(ok: false, summary: model.displayActionBusyMessage,
                                   error: model.displayActionBusyMessage, outcome: .busy)
        }

        if model.controlRunningRule != nil && request.command == .sleepNow {
            return controlResponse(ok: false, summary: model.protectionRuleBusyMessage,
                                   error: model.protectionRuleBusyMessage, outcome: .busy)
        }

        switch request.command {
        case .hide, .show, .toggleHide, .runAction:
            return await model.handleDisplayControlRequest(request, receivedAt: receivedAt)
        case .runRule:
            return await model.handleProtectionRuleControlRequest(request, receivedAt: receivedAt)
        case .enable:
            model.setProtectionEnabled(true)
        case .disable:
            model.setProtectionEnabled(false)
        case .toggle:
            model.setProtectionEnabled(!model.preferences.isEnabled)
        case .status:
            model.refreshDisplays()
            return controlStatusResponse()
        case .blackoutNow:
            return controlResponse(
                ok: false,
                summary: AppControlCommand.blackoutNowMigrationGuidance,
                error: AppControlCommand.blackoutNowMigrationGuidance,
                outcome: .refused
            )
        case .sleepNow:
            do {
                try model.sleepAllNow()
                return controlResponse(ok: true, summary: "Display sleep requested")
            } catch {
                return controlResponse(
                    ok: false,
                    summary: "Display sleep request failed",
                    error: error.localizedDescription
                )
            }
        case .snooze:
            guard let duration = request.durationSeconds,
                  duration.isFinite,
                  duration > 0,
                  duration <= AppModel.maximumSnoozeDuration else {
                return controlResponse(
                    ok: false,
                    summary: "Snooze request failed",
                    error: "snooze duration must be between 1 second and 30 days"
                )
            }
            model.snooze(for: duration)
        case .resume:
            model.resumeProtection()
        case .restore:
            do {
                let requested = try model.restoreBlackout()
                return controlResponse(
                    ok: true,
                    summary: requested
                        ? "Restore requested"
                        : "No active blackout"
                )
            } catch {
                return controlResponse(
                    ok: false,
                    summary: "Restore request failed",
                    error: error.localizedDescription
                )
            }
        case .openSettings:
            showSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        return controlResponse(ok: true)
    }

    private func controlStatusResponse() -> AppControlResponse {
        controlResponse(ok: true, outcome: model.controlDisplayOutcome,
                        displays: model.controlDisplayStatuses,
                        rules: model.controlRuleStatuses,
                        actions: model.controlActionStatuses,
                        runningAction: model.controlRunningDisplayAction,
                        runningRule: model.controlRunningRule)
    }

    private func controlResponse(
        ok: Bool,
        summary: String? = nil,
        error: String? = nil,
        outcome: AppControlOutcome? = nil,
        displays: [AppControlDisplayStatus]? = nil,
        rules: [AppControlRuleStatus]? = nil,
        actions: [AppControlActionStatus]? = nil,
        detail: String? = nil,
        runningAction: AppControlRunningAction? = nil,
        runningRule: AppControlRunningRule? = nil
    ) -> AppControlResponse {
        AppControlResponse(
            ok: ok,
            running: true,
            enabled: model.preferences.isEnabled,
            state: model.runtimeState.controlIdentifier,
            summary: summary ?? model.statusSummary,
            detail: detail ?? model.statusDetail,
            error: error,
            nextAction: model.nextAction,
            secondsRemaining: model.secondsRemaining,
            snoozedUntil: model.snoozedUntil.map(Self.iso8601.string),
            outcome: outcome,
            displays: displays,
            rules: rules,
            actions: actions,
            runningAction: runningAction,
            runningRule: runningRule ?? model.controlRunningRule
        )
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func screenConfigurationChanged(_ notification: Notification) {
        guard !terminationPending else { return }
        if notification.name == NSWorkspace.willSleepNotification ||
            notification.name == NSWorkspace.screensDidSleepNotification {
            model.beginDisplaySleepTransition()
            // The in-memory resume intent is captured before inspection can
            // reconcile a system-restored layout and retire its journal entries.
            model.refreshHandoffStatus()
            return
        }
        if notification.name == NSWorkspace.didWakeNotification {
            model.displayWakeObserved(screensAwake: false)
            return
        }
        if notification.name == NSWorkspace.screensDidWakeNotification {
            DisplaySleepController.automationScreensDidWake()
            model.displayWakeObserved(screensAwake: true)
            return
        }
        if notification.name == NSApplication.didChangeScreenParametersNotification {
            model.displayParametersChanged()
            return
        }
        // AppKit can retain stale display coordinate transforms after a display
        // transition. Replace the helper's WindowServer connection; the service
        // rearms the idle interval so replacement cannot cause a blackout.
        model.displayConfigurationChanged(
            restartWatcher: Self.shouldRestartWatcher(after: notification.name)
        )
    }

    private func presentNoticeIfNeeded(_ notice: AppNotice) {
        if settingsWindowController?.window?.isVisible == true { return }
        model.notice = nil

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = notice.title
        alert.informativeText = notice.message
        if notice.opensLoginItemSettings {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                model.openLoginItemSettings()
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func presentActionError(_ title: String, error: Error) {
        model.notice = AppNotice(
            title: title,
            message: error.localizedDescription,
            opensLoginItemSettings: false
        )
    }

    private func installScreenObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        for name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification
        ] {
            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(screenConfigurationChanged),
                name: name,
                object: nil
            )
        }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: Self.screenUnlockedNotification,
            object: nil
        )
    }
}

private extension AppDelegate {
    static let screenUnlockedNotification = Notification.Name(
        "com.apple.screenIsUnlocked"
    )
    static let iso8601 = ISO8601DateFormatter()
}

extension ProtectionRuntimeState {
    var controlIdentifier: String {
        switch self {
        case .disabled: return "disabled"
        case .snoozed: return "snoozed"
        case .disconnectPaused: return "disconnect_paused"
        case .starting: return "starting"
        case .waiting: return "waiting"
        case .waitingForInput: return "waiting_for_input"
        case .waitingForPlayback: return "waiting_for_playback"
        case .blackedOut: return "blacked_out"
        case .sleeping: return "sleeping"
        case .stopping: return "stopping"
        case .waitingForDisplays: return "waiting_for_displays"
        case .failed: return "failed"
        }
    }
}
