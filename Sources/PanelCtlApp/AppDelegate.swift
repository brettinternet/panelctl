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
    private var noticeCancellable: AnyCancellable?
    private var launchedAsLoginItem = false
    private var suppressInitialSettings = false
    private var terminationPending = false
    private var systemSleeping = false
    private lazy var blackoutFocusController = BlackoutFocusController { [weak self] in
        self?.handleBlackoutEscape() ?? false
    }
    private var blackoutFocusTimer: Timer?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAsLoginItem =
            event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                == keyAELaunchedAsLogInItem
        suppressInitialSettings = CommandLine.arguments.contains("--background")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        if model.protectionPausedForDisplayRecovery {
            displayHideLogger.error("Startup found unresolved display recovery: \(self.model.handoffStatus?.inspectionCommand ?? "inspect shared display journal", privacy: .public)")
        }
        let controlServer = AppControlServer { [weak self] request, receivedAt in
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
            self.updateStatusItem()
            self.updateBlackoutFocus()
            self.moveSettingsOffHiddenDisplays()
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

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
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
            let canShow = model.canShowHiddenDisplay
            let alert = NSAlert()
            alert.alertStyle = .warning
            if status?.hasUnresolvedJournal == true {
                alert.messageText = status?.state == .hidden && canShow
                    ? "\(target?.name ?? "A display") is still hidden"
                    : "Display recovery isn\u{2019}t finished"
                alert.informativeText = "PanelCtl won\u{2019}t show it or switch the monitor input after quitting. Open PanelCtl again to show it."
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
                if canShow, let uuid = target?.uuid {
                    model.show(targetUUID: uuid) { [weak self] result in
                        if result.succeeded {
                            NSApp.terminate(nil)
                        } else {
                            self?.showSettings(displayUUID: uuid)
                        }
                    }
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
        if Self.shouldEngageBlackoutFocus(
            runtimeState: model.runtimeState,
            mode: model.effectiveBlackoutMode,
            hasBlackedOutDisplays: !model.blackedOutDisplayIDs.isEmpty
        ) {
            focusDisplayIDs.formUnion(model.blackedOutDisplayIDs)
        }
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
    static func blackoutActionTitle(for mode: BlackoutMode) -> String {
        mode == .working ? "Dim Now" : "Black Out Now"
    }

    static func blackoutRequestSummary(
        for mode: BlackoutMode,
        succeeded: Bool
    ) -> String {
        switch (mode, succeeded) {
        case (.working, true): return "Dimming requested"
        case (.working, false): return "Dimming request failed"
        case (.blocking, true): return "Blackout requested"
        case (.blocking, false): return "Blackout request failed"
        }
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

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem(
            title: "PanelCtl",
            action: nil,
            keyEquivalent: ""
        )
        let appMenu = NSMenu()
        appMenu.addItem(item("Settings…", action: #selector(openSettings), key: ","))
        appMenu.addItem(item("View on GitHub", action: #selector(openGitHub)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit PanelCtl", action: #selector(quit), key: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
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

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let status = NSMenuItem(title: model.statusSummary, action: nil, keyEquivalent: "")
        status.image = NSImage(
            systemSymbolName: model.statusSystemImage,
            accessibilityDescription: nil
        )
        status.isEnabled = false
        menu.addItem(status)

        if let message = model.runtimeState.detailMessage {
            let detail = NSMenuItem(
                title: message.replacingOccurrences(of: "\n", with: " "),
                action: nil,
                keyEquivalent: ""
            )
            detail.isEnabled = false
            menu.addItem(detail)
        }

        menu.addItem(.separator())
        switch model.runtimeState {
        case .blackedOut, .sleeping:
            menu.addItem(restoreMenuItem())
        default:
            menu.addItem(item(
                Self.blackoutActionTitle(for: model.effectiveBlackoutMode),
                action: #selector(blackoutNow)
            ))
            if !model.blackedOutDisplayIDs.isEmpty {
                menu.addItem(restoreMenuItem())
            }
        }
        menu.addItem(item("Sleep Displays", action: #selector(sleepAllNow)))
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
            retry.isEnabled = !model.protectionQuiescencePending && !model.hideOperation.isBusy
            menu.addItem(retry)
        } else if model.runtimeState.errorMessage != nil, model.preferences.isEnabled {
            menu.addItem(item("Retry Automation", action: #selector(retryProtection)))
        }

        menu.addItem(item("Settings…", action: #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit PanelCtl", action: #selector(quit), key: "q"))
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
            if #available(macOS 14.4, *) {
                display.subtitle = tile.status.label
            } else {
                display.title += " — \(tile.status.label)"
            }
            items.append(display)
            if let line = model.displayResults[tile.id]?.menuLine {
                let result = disabledItem(line.count > 72 ? String(line.prefix(71)) + "…" : line)
                result.toolTip = line
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
        status.title = model.statusSummary
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
        restore.toolTip = "Ends automation blackout or dimming. Hidden displays stay hidden."
        return restore
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

    @objc private func blackoutNow() {
        do {
            try model.blackoutNow()
        } catch {
            presentActionError("Could not start blackout", error: error)
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

    /// Opens Settings on a tab or display; a display recovery problem opens
    /// its display unless the caller asks for something else.
    private func showSettings(tab: SettingsTab? = nil, displayUUID: String? = nil) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(model: model)
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
        guard request.protocolVersion == AppControlRequest.currentProtocol else {
            return controlResponse(
                ok: false,
                error: "unsupported app-control protocol \(request.protocolVersion)"
            )
        }

        switch request.command {
        case .hide, .show, .toggleHide:
            return await model.handleDisplayControlRequest(request, receivedAt: receivedAt)
        case .enable:
            model.setProtectionEnabled(true)
        case .disable:
            model.setProtectionEnabled(false)
        case .toggle:
            model.setProtectionEnabled(!model.preferences.isEnabled)
        case .status:
            model.refreshDisplays()
            return controlResponse(ok: true, outcome: model.controlDisplayOutcome,
                                   displays: model.controlDisplayStatuses)
        case .blackoutNow:
            do {
                try model.blackoutNow()
                return controlResponse(
                    ok: true,
                    summary: Self.blackoutRequestSummary(
                        for: model.preferences.mode,
                        succeeded: true
                    )
                )
            } catch {
                return controlResponse(
                    ok: false,
                    summary: Self.blackoutRequestSummary(
                        for: model.preferences.mode,
                        succeeded: false
                    ),
                    error: error.localizedDescription
                )
            }
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

    private func controlResponse(
        ok: Bool,
        summary: String? = nil,
        error: String? = nil,
        outcome: AppControlOutcome? = nil,
        displays: [AppControlDisplayStatus]? = nil
    ) -> AppControlResponse {
        AppControlResponse(
            ok: ok,
            running: true,
            enabled: model.preferences.isEnabled,
            state: model.runtimeState.controlIdentifier,
            summary: summary ?? model.statusSummary,
            detail: model.runtimeState.detailMessage,
            error: error,
            nextAction: model.nextAction,
            secondsRemaining: model.secondsRemaining,
            snoozedUntil: model.snoozedUntil.map(Self.iso8601.string),
            outcome: outcome,
            displays: displays
        )
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func screenConfigurationChanged(_ notification: Notification) {
        guard !terminationPending else { return }
        if notification.name == NSWorkspace.willSleepNotification ||
            notification.name == NSWorkspace.screensDidSleepNotification {
            systemSleeping = true
            model.setDisplayLifecycleTransitioning(true)
            model.refreshHandoffStatus()
            return
        }
        if notification.name == NSWorkspace.didWakeNotification {
            model.setDisplayLifecycleTransitioning(true)
            model.refreshDisplays(restartWatcher: true)
            return
        }
        if notification.name == NSWorkspace.screensDidWakeNotification {
            model.setDisplayLifecycleTransitioning(true)
            model.refreshDisplays(restartWatcher: true)
            systemSleeping = false
            model.setDisplayLifecycleTransitioning(false)
            return
        }
        model.setDisplayLifecycleTransitioning(true)
        // AppKit can retain stale display coordinate transforms after a display
        // transition. Replace the helper's WindowServer connection; the service
        // rearms the idle interval so replacement cannot cause a blackout.
        model.refreshDisplays(
            restartWatcher: Self.shouldRestartWatcher(after: notification.name)
        )
        if !systemSleeping {
            model.setDisplayLifecycleTransitioning(false)
        }
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
