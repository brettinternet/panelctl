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
        let minimumFrameSize = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: 440, height: 480)
        ).size
        let maximumFrameWidth = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: 680, height: 480)
        ).width
        window.minSize = minimumFrameSize
        window.maxSize = NSSize(
            width: maximumFrameWidth,
            height: CGFloat.greatestFiniteMagnitude
        )

        var restoredFrame = window.frame
        restoredFrame.size.width = min(
            max(restoredFrame.width, minimumFrameSize.width),
            maximumFrameWidth
        )
        restoredFrame.size.height = max(
            restoredFrame.height,
            minimumFrameSize.height
        )
        window.setFrame(restoredFrame, display: false)
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
