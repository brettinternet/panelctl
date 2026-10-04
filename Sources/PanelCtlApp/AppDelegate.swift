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
    private var quitAfterShow = false
    private var systemSleeping = false
    private lazy var blackoutFocusController = BlackoutFocusController { [weak self] in
        self?.requestBlackoutRestore() ?? false
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
        model.onRequestHide = { [weak self] request in
            self?.confirmHide(request)
        }
        model.onRequestShow = { [weak self] status in
            self?.confirmShow(status)
        }
        model.onShowCompletion = { [weak self] succeeded in
            guard let self, self.quitAfterShow else { return }
            self.quitAfterShow = false
            if succeeded { NSApp.terminate(nil) }
        }
        if model.protectionPausedForDisplayRecovery {
            displayHideLogger.error("Startup found unresolved display recovery: \(self.model.handoffStatus?.inspectionCommand ?? "inspect shared display journal", privacy: .public)")
        }
        let controlServer = AppControlServer { [weak self] request in
            self?.handleControlRequest(request) ?? .unavailable()
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
        }
        noticeCancellable = model.$notice.sink { [weak self] notice in
            guard let self, let notice else { return }
            self.presentNoticeIfNeeded(notice)
        }
        installScreenObservers()
        updateStatusItem()
        updateBlackoutFocus()

        if !launchedAsLoginItem && !suppressInitialSettings {
            showSettings(focusRecovery: model.protectionPausedForDisplayRecovery)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showSettings(focusRecovery: model.protectionPausedForDisplayRecovery)
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
            alert.informativeText = "PanelCtl is finishing a confirmed Hide or Show. Wait for it to finish before quitting. The operation cannot be canceled after it starts."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return .terminateCancel
        }
        if model.handoffStatus?.hasUnresolvedJournal == true || model.protectionQuiescenceFailure != nil {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Hidden desktop/recovery remains after quitting"
            alert.informativeText = "PanelCtl will not automatically Show, restore topology, or switch monitor inputs when it quits. The shared journal remains available after relaunch."
            alert.addButton(withTitle: "Cancel")
            let canShow = (model.handoffStatus?.state == .hidden || model.handoffStatus?.state == .recovery) &&
                model.handoffStatus?.canShow == true
            alert.addButton(withTitle: canShow ? "Show…" : "Review recovery…")
            alert.addButton(withTitle: "Quit Without Showing")
            if let cancel = alert.buttons.first {
                alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
            }
            switch alert.runModal() {
            case .alertSecondButtonReturn:
                if canShow {
                    do {
                        confirmShow(try model.makeShowRequest(), quitAfterShow: true)
                    } catch {
                        showSettings(focusRecovery: true)
                    }
                } else {
                    showSettings(focusRecovery: true)
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

    private func updateBlackoutFocus() {
        guard let model else { return }
        if Self.shouldEngageBlackoutFocus(
            runtimeState: model.runtimeState,
            mode: model.preferences.mode,
            hasBlackedOutDisplays: !model.blackedOutDisplayIDs.isEmpty
        ) {
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
                guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                      model.blackedOutDisplayIDs.contains(id) else { return nil }
                return screen.frame
            }
            blackoutFocusController.enter(targetFrames: frames)
        } else {
            blackoutFocusTimer?.invalidate()
            blackoutFocusTimer = nil
            blackoutFocusController.leave()
        }
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
        mode == .working ? "Dim Now" : "Blackout Now"
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
        let toggleTitle = model.preferences.isEnabled
            ? "Disable Protection"
            : "Enable Protection"
        menu.addItem(item(toggleTitle, action: #selector(toggleProtection)))
        if model.snoozedUntil != nil {
            menu.addItem(item("Resume Protection", action: #selector(resumeProtection)))
        }

        switch model.runtimeState {
        case .blackedOut, .sleeping:
            menu.addItem(restoreMenuItem())
        default:
            menu.addItem(item(
                Self.blackoutActionTitle(for: model.preferences.mode),
                action: #selector(blackoutNow)
            ))
            if !model.blackedOutDisplayIDs.isEmpty {
                menu.addItem(restoreMenuItem())
            }
        }
        menu.addItem(item("Sleep All Now", action: #selector(sleepAllNow)))

        if model.preferences.isEnabled, model.snoozedUntil == nil {
            let snoozeMenuItem = NSMenuItem(title: "Snooze", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            submenu.addItem(snoozeItem("30 Minutes", duration: 30 * 60))
            submenu.addItem(snoozeItem("1 Hour", duration: 60 * 60))
            submenu.addItem(item("Until Tomorrow", action: #selector(snoozeUntilTomorrow)))
            snoozeMenuItem.submenu = submenu
            menu.addItem(snoozeMenuItem)
        }

        menu.addItem(.separator())
        let hideHeading = NSMenuItem(title: "Hide a desktop · Experimental", action: nil, keyEquivalent: "")
        hideHeading.isEnabled = false
        menu.addItem(hideHeading)
        switch model.hideOperation {
        case .hiding:
            disabledMenuItem("Hiding…", in: menu)
        case .showing:
            disabledMenuItem("Showing…", in: menu)
        case .idle:
            if model.handoffStatus?.hasUnresolvedJournal == true {
                if model.handoffStatus?.state == .hidden,
                   model.handoffStatus?.canShow == true {
                    let name = model.handoffStatus?.target?.name ?? "desktop"
                    let show = item("Show \(name)…", action: #selector(showDisplayFromMenu))
                    show.toolTip = model.handoffStatus?.target?.identityDetail
                    show.isEnabled = !model.displayLifecycleTransitioning
                    menu.addItem(show)
                    disabledMenuItem("Desktop hidden by PanelCtl · input unknown", in: menu)
                } else {
                    menu.addItem(item("Review display recovery…", action: #selector(reviewDisplayRecovery)))
                }
            } else if model.displayLifecycleTransitioning {
                disabledMenuItem("Display transition in progress · Refresh after wake", in: menu)
            } else if model.menuHideConfigurations.isEmpty {
                menu.addItem(item("Configure in Displays…", action: #selector(reviewDisplayRecovery)))
            } else {
                for configuration in model.menuHideConfigurations {
                    let name = configuration.target.name ?? "Display \(configuration.target.id)"
                    let suffix = String(configuration.target.uuid.prefix(8))
                    let hide = item("Hide \(name) · \(suffix)…", action: #selector(hideDisplayFromMenu(_:)))
                    hide.toolTip = configuration.target.identityDetail
                    hide.representedObject = configuration.target.uuid
                    menu.addItem(hide)
                }
            }
        }
        menu.addItem(.separator())

        if model.runtimeState.errorMessage != nil, model.preferences.isEnabled {
            menu.addItem(item("Retry Watcher", action: #selector(retryProtection)))
        }

        menu.addItem(item("Settings…", action: #selector(openSettings), key: ","))
        menu.addItem(item("View on GitHub", action: #selector(openGitHub)))
        menu.addItem(.separator())
        menu.addItem(item("Quit PanelCtl", action: #selector(quit), key: "q"))
        return menu
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
        restore.toolTip = "Removes PanelCtl blackout or dimming; does not show hidden desktops or switch inputs. Use Show for that."
        return restore
    }

    private func disabledMenuItem(_ title: String, in menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func snoozeItem(_ title: String, duration: TimeInterval) -> NSMenuItem {
        let menuItem = item(title, action: #selector(snoozeForDuration(_:)))
        menuItem.representedObject = duration
        return menuItem
    }

    @objc private func toggleProtection() {
        model.setProtectionEnabled(!model.preferences.isEnabled)
        if model.preferences.isEnabled, model.validationMessage != nil {
            showSettings()
        }
    }

    @objc private func retryProtection() {
        model.retryProtection()
    }

    @objc private func hideDisplayFromMenu(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        model.requestHide(targetUUID: uuid)
    }

    @objc private func showDisplayFromMenu() {
        model.requestShow()
    }

    @objc private func reviewDisplayRecovery() {
        showSettings(focusRecovery: true)
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

    private func confirmHide(_ request: DisplayHideRequest) {
        let targetName = request.target.name ?? "Display \(request.target.id)"
        let message = DisplayOperationConfirmation.hideMessage(
            request,
            journalPath: DisplayHandoff.defaultJournalPath
        )
        guard DisplayOperationConfirmation.confirm(
            title: "Hide \(targetName) desktop?",
            message: message,
            actionTitle: "Hide desktop"
        ) else { return }
        model.confirmHide(request, acknowledged: true)
    }

    private func confirmShow(_ request: DisplayShowRequest, quitAfterShow shouldQuit: Bool = false) {
        let target = request.status.target
        let targetName = target?.name ?? "journaled display"
        let message = DisplayOperationConfirmation.showMessage(request)
        guard DisplayOperationConfirmation.confirm(
            title: "Show \(targetName) desktop?",
            message: message,
            actionTitle: "Show desktop"
        ) else { return }
        quitAfterShow = shouldQuit
        model.confirmShow(request, acknowledged: true)
        if model.hideOperation == .idle {
            quitAfterShow = false
        }
    }

    private func showSettings(focusRecovery: Bool = false) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(model: model)
        }
        model.refreshLaunchAtLoginStatus()
        model.refreshDisplays()
        settingsWindowController?.present()
        if focusRecovery || model.protectionPausedForDisplayRecovery {
            model.requestDisplayRecoveryFocus()
        }
    }

    private func handleControlRequest(
        _ request: AppControlRequest
    ) -> AppControlResponse {
        guard request.protocolVersion == AppControlRequest.currentProtocol else {
            return controlResponse(
                ok: false,
                error: "unsupported app-control protocol \(request.protocolVersion)"
            )
        }

        switch request.command {
        case .enable:
            model.setProtectionEnabled(true)
        case .disable:
            model.setProtectionEnabled(false)
        case .toggle:
            model.setProtectionEnabled(!model.preferences.isEnabled)
        case .status:
            break
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
        error: String? = nil
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
            snoozedUntil: model.snoozedUntil.map(Self.iso8601.string)
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

private extension ProtectionRuntimeState {
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
