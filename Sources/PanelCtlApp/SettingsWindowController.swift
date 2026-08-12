import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(model: AppModel) {
        let hostingView = NSHostingView(rootView: SettingsView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 490, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PanelCtl Settings"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PanelCtlSettingsWindow")
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
