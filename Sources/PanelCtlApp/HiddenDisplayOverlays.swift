import AppKit
import PanelCtlCore

/// Opaque windows over the displays Hide blacks out. They belong to the app,
/// so quitting or a crash shows every display again.
@MainActor
final class HiddenDisplayOverlays {
    private var windows: [UInt32: NSWindow] = [:]

    /// Covers exactly these displays, at their current frames, and uncovers
    /// the rest. Returns the displays it couldn't cover.
    func cover(_ displayIDs: Set<UInt32>) -> Set<UInt32> {
        var screens: [UInt32: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
                screens[id] = screen
            }
        }
        for (id, window) in windows where !displayIDs.contains(id) {
            Self.close(window)
            windows[id] = nil
        }
        var uncovered: Set<UInt32> = []
        for id in displayIDs {
            // AppKit moves a window off a disconnected screen, and a moved or
            // resized display leaves it short; such a window is replaced.
            let current = windows.removeValue(forKey: id)
            if let current, let screen = screens[id], BlackoutController.isCovering(current, screen: screen) {
                windows[id] = current
                continue
            }
            // The replacement goes up before the stale window comes down, so
            // the display doesn't flash.
            if let screen = screens[id], let window = BlackoutController.makeCoveringWindow(for: screen) {
                window.orderFrontRegardless()
                if BlackoutController.isCovering(window, screen: screen) {
                    windows[id] = window
                } else {
                    Self.close(window)
                    uncovered.insert(id)
                }
            } else {
                uncovered.insert(id)
            }
            current.map(Self.close)
        }
        return uncovered
    }

    private static func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.close()
    }
}
