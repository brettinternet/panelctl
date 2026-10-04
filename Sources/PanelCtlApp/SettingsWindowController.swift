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
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(model: AppModel) {
        let hostingView = NSHostingView(rootView: SettingsView(model: model))
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 590),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        window.title = "PanelCtl Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = hostingView
        window.autorecalculatesKeyViewLoop = true
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PanelCtlSettingsWindow")
        window.center()
        super.init(window: window)
        window.delegate = self
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

    func windowDidEndSheet(_ notification: Notification) {
        // SwiftUI's notice can leave the app with no key window after dismissal.
        // Restore keyboard access without stealing it from another app/window.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, window.isVisible,
                  window.attachedSheet == nil, NSApp.isActive,
                  NSApp.keyWindow == nil else { return }
            window.makeKey()
        }
    }

    func present() {
        guard let window = window as? SettingsWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        applySizeConstraints(to: window)
    }
}
