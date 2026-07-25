import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem?
    private var settingsWindowController: SettingsWindowController?
    private var noticeCancellable: AnyCancellable?
    private var launchedAsLoginItem = false
    private var terminationPending = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAsLoginItem =
            event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        configureMainMenu()
        configureStatusItem()
        model.onStatusChange = { [weak self] in
            self?.updateStatusItem()
        }
        noticeCancellable = model.$notice.sink { [weak self] notice in
            guard let self, let notice else { return }
            self.presentNoticeIfNeeded(notice)
        }
        installScreenObservers()
        updateStatusItem()

        if !launchedAsLoginItem {
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
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func configureStatusItem() {
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
        guard let statusItem, let model else { return }
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

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

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

        if model.runtimeState.errorMessage != nil, model.preferences.isEnabled {
            menu.addItem(item("Retry Watcher", action: #selector(retryProtection)))
        }

        menu.addItem(item("Settings…", action: #selector(openSettings), key: ","))
        menu.addItem(item("View on GitHub", action: #selector(openGitHub)))
        menu.addItem(.separator())
        menu.addItem(item("Quit PanelCtl", action: #selector(quit), key: "q"))
        return menu
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

    @objc private func toggleProtection() {
        model.setProtectionEnabled(!model.preferences.isEnabled)
        if model.preferences.isEnabled, model.validationMessage != nil {
            showSettings()
        }
    }

    @objc private func retryProtection() {
        model.retryProtection()
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
