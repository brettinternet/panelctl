import AppKit
import Combine
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case displays
    case automation
    case general

    var title: String {
        switch self {
        case .displays: return "Displays"
        case .automation: return "Automation"
        case .general: return "General"
        }
    }

    var systemImage: String {
        switch self {
        case .displays: return "display.2"
        case .automation: return "timer"
        case .general: return "gearshape"
        }
    }

    var toolbarIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("PanelCtlSettings.\(rawValue)")
    }

    init?(toolbarIdentifier: NSToolbarItem.Identifier) {
        guard let tab = Self.allCases.first(where: { $0.toolbarIdentifier == toolbarIdentifier }) else {
            return nil
        }
        self = tab
    }
}

/// Selected Settings tab and display, shared by AppKit and the SwiftUI content.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsTab = .displays
    /// A `DisplayTile.id`; the Displays tab falls back to the first tile.
    @Published var selectedDisplayID: String?

    /// Opens the Displays tab, on one display when given its UUID.
    func showDisplays(selecting uuid: String?) {
        if let uuid { selectedDisplayID = uuid.lowercased() }
        tab = .displays
    }
}

private final class SettingsWindow: NSWindow {
    private var enforcedMinSize: NSSize?
    private var enforcedMaxSize: NSSize?
    var onSelectTab: ((SettingsTab) -> Void)?

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

    /// Command-1 through Command-3 select tabs, so the keyboard reaches every
    /// tab without Full Keyboard Access.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let number = event.charactersIgnoringModifiers.flatMap({ Int($0) }),
           SettingsTab.allCases.indices.contains(number - 1) {
            onSelectTab?(SettingsTab.allCases[number - 1])
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("PanelCtlSettingsWindow")

    private let navigation: SettingsNavigation
    private var tabSubscription: AnyCancellable?

    init(model: AppModel) {
        let navigation = SettingsNavigation()
        self.navigation = navigation
        let hostingView = NSHostingView(rootView: SettingsView(model: model, navigation: navigation))
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = Self.windowIdentifier
        window.contentView = hostingView
        window.autorecalculatesKeyViewLoop = true
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "PanelCtlSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        window.onSelectTab = { [weak self] in self?.select($0) }
        tabSubscription = navigation.$tab.sink { [weak window] tab in
            window?.toolbar?.selectedItemIdentifier = tab.toolbarIdentifier
            window?.title = tab.title
        }

        window.setFrameAutosaveName("PanelCtlSettingsWindow")
        window.center()
        applySizeConstraints(to: window)
    }

    var selectedTab: SettingsTab { navigation.tab }

    var selectedDisplayID: String? { navigation.selectedDisplayID }

    func select(_ tab: SettingsTab) {
        navigation.tab = tab
    }

    /// Opens the Displays tab on one display, by UUID.
    func selectDisplay(uuid: String) {
        navigation.showDisplays(selecting: uuid)
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

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = SettingsTab(toolbarIdentifier: itemIdentifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.paletteLabel = tab.title
        item.toolTip = tab.title
        item.image = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(toolbarItemSelected(_:))
        return item
    }

    @objc private func toolbarItemSelected(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab(toolbarIdentifier: sender.itemIdentifier) else { return }
        select(tab)
    }
}
