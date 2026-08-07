import AppKit
import Combine
import PanelCtlCore

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
        terminationPending = true
        model.shutdown {
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
        if case .blackedOut = model.runtimeState {
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
            let selectedIDs: Set<UInt32>
            if model.preferences.allDisplays {
                selectedIDs = Set(model.activeDisplays.map(\.id))
            } else {
                selectedIDs = Set(model.activeDisplays.compactMap { display in
                    guard let uuid = display.uuid,
                          model.preferences.selectedDisplayUUIDs.contains(where: {
                              $0.caseInsensitiveCompare(uuid) == .orderedSame
                          }) else { return nil }
                    return display.id
                })
            }
            let frames = NSScreen.screens.compactMap { screen -> CGRect? in
                guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                      selectedIDs.contains(id) else { return nil }
                return screen.frame
            }
            blackoutFocusController.enter(targetFrames: frames)
        } else {
            blackoutFocusTimer?.invalidate()
            blackoutFocusTimer = nil
            blackoutFocusController.leave()
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
            systemSymbolName: model.runtimeState.systemImage,
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
            systemSymbolName: model.runtimeState.systemImage,
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
            menu.addItem(item("Restore", action: #selector(restoreNow)))
        default:
            menu.addItem(item("Blackout Now", action: #selector(blackoutNow)))
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
        guard let status = menu.items.first else { return }
        status.title = model.statusSummary
        status.image = NSImage(
            systemSymbolName: model.runtimeState.systemImage,
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

    private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(model: model)
        }
        model.refreshLaunchAtLoginStatus()
        model.refreshDisplays()
        settingsWindowController?.present()
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
                    summary: "Blackout requested"
                )
            } catch {
                return controlResponse(
                    ok: false,
                    summary: "Blackout request failed",
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
        model.refreshDisplays()
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }
}

private extension AppDelegate {
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
