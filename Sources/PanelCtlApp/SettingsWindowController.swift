import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(model: AppModel) {
        let hostingView = NSHostingView(rootView: SettingsView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 590),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PanelCtl Settings"
        window.contentView = hostingView
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PanelCtlSettingsWindow")
        let minimumContentSize = NSSize(width: 440, height: 480)
        let maximumContentSize = NSSize(
            width: 680,
            height: CGFloat.greatestFiniteMagnitude
        )
        window.contentMinSize = minimumContentSize
        window.contentMaxSize = maximumContentSize

        var restoredContentSize = window.contentRect(forFrameRect: window.frame).size
        restoredContentSize.width = min(
            max(restoredContentSize.width, minimumContentSize.width),
            maximumContentSize.width
        )
        restoredContentSize.height = max(
            restoredContentSize.height,
            minimumContentSize.height
        )
        window.setContentSize(restoredContentSize)
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
