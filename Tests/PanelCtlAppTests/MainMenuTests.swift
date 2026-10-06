import AppKit
import XCTest
@testable import PanelCtlApp

@MainActor
final class MainMenuTests: XCTestCase {
    func testStandardMenusAndEditingShortcuts() throws {
        try requireInteractiveUI()
        let app = NSApplication.shared
        let originalMenu = app.mainMenu
        let originalWindowsMenu = app.windowsMenu
        let originalHelpMenu = app.helpMenu
        let originalPolicy = app.activationPolicy()
        defer {
            app.mainMenu = originalMenu
            app.windowsMenu = originalWindowsMenu
            app.helpMenu = originalHelpMenu
            app.setActivationPolicy(originalPolicy)
        }
        let delegate = AppDelegate()
        delegate.configureMainMenu()
        let menu = try XCTUnwrap(app.mainMenu)
        XCTAssertEqual(menu.items.map(\.title), ["PanelCtl", "File", "Edit", "Window", "Help"])
        let appMenu = try XCTUnwrap(menu.items.first?.submenu)
        XCTAssertNotNil(appMenu.item(withTitle: "About PanelCtl"))
        XCTAssertEqual(appMenu.item(withTitle: "Hide PanelCtl")?.keyEquivalent, "h")
        XCTAssertEqual(appMenu.item(withTitle: "Hide Others")?.keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(appMenu.item(withTitle: "Show All")?.action, #selector(NSApplication.unhideAllApplications(_:)))
        XCTAssertNil(appMenu.item(withTitle: "View on GitHub"))
        XCTAssertTrue(app.helpMenu?.item(withTitle: "View on GitHub")?.target === delegate)
        XCTAssertNil(app.windowsMenu?.item(withTitle: "Zoom"))
        let minimize = try XCTUnwrap(app.windowsMenu?.item(withTitle: "Minimize"))
        XCTAssertEqual(minimize.keyEquivalent, "m")
        XCTAssertEqual(minimize.action, #selector(NSWindow.performMiniaturize(_:)))
        XCTAssertNil(minimize.target)
        let editMenu = try XCTUnwrap(menu.item(withTitle: "Edit")?.submenu)
        for item in editMenu.items where !item.isSeparatorItem {
            XCTAssertNil(item.target, "Native editing must follow the responder chain")
        }

        // A real native text responder exercises dispatch without starting the app
        // or touching display hardware. Preserve the user's clipboard contents.
        let pasteboard = NSPasteboard.general
        let savedClipboard = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            let items = savedClipboard.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(items)
        }
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 150))
        text.allowsUndo = true
        text.string = "PanelCtl"
        window.contentView = text
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(text))


        func press(_ key: String, modifiers: NSEvent.ModifierFlags = .command) throws {
            let item = try XCTUnwrap(menu.items.compactMap(\.submenu).flatMap(\.items).first {
                $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers
            })
            let action = try XCTUnwrap(item.action)
            // XCTest cannot always become the key application. Dispatch the
            // shortcut's actual action to its native responder explicitly.
            let target: AnyObject = (key == "m" || key == "z") ? window : text
            XCTAssertTrue(app.sendAction(action, to: target, from: item), "Shortcut \(key) must be handled")
        }
        try press("a")
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 8))
        try press("c")
        XCTAssertTrue(pasteboard.string(forType: .string) == "PanelCtl")
        try press("x")
        XCTAssertEqual(text.string, "")
        try press("z")
        XCTAssertEqual(text.string, "PanelCtl")
        try press("z", modifiers: [.command, .shift])
        XCTAssertEqual(text.string, "")
        try press("v")
        XCTAssertEqual(text.string, "PanelCtl")
        try press("m")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(window.isMiniaturized)
    }
}
