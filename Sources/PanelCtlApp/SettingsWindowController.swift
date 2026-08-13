import AppKit
import SwiftUI

private final class SettingsWindow: NSWindow {
    private var enforcedMinSize: NSSize?
    private var enforcedMaxSize: NSSize?

    override var minSize: NSSize {
        get { enforcedMinSize ?? super.minSize }
        set { super.minSize = enforcedMinSize ?? newValue }
    }

    override var maxSize: NSSize {
        get { enforcedMaxSize ?? super.maxSize }
        set { super.maxSize = enforcedMaxSize ?? newValue }
    }

    func enforceResizeLimits(minSize: NSSize, maxSize: NSSize) {
        enforcedMinSize = minSize
        enforcedMaxSize = maxSize
        super.minSize = minSize
        super.maxSize = maxSize
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(model: AppModel) {
        let hostingView = NSHostingView(rootView: SettingsView(model: model))
        let window = SettingsWindow(
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
        window.center()
        super.init(window: window)
        applySizeConstraints(to: window)
    }

    private func applySizeConstraints(to window: SettingsWindow) {
        let minimumFrameSize = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: 440, height: 480)
        ).size
        let maximumFrameWidth = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: 680, height: 480)
        ).width
        window.enforceResizeLimits(
            minSize: minimumFrameSize,
            maxSize: NSSize(
                width: maximumFrameWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        )

        var frame = window.frame
        frame.size.width = min(
            max(frame.width, minimumFrameSize.width),
            maximumFrameWidth
        )
        frame.size.height = max(frame.height, minimumFrameSize.height)
        window.setFrame(frame, display: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window = window as? SettingsWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        applySizeConstraints(to: window)
    }
}
