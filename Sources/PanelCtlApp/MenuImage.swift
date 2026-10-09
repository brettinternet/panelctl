import AppKit

/// Menu images by name: SF Symbols, plus the app icon's display mark.
enum MenuImage {
    /// The app icon's mark: a display in front of a second one.
    static let displays = "panelctl.displays"
    /// The mark with the front display filled.
    static let displaysFill = "panelctl.displays.fill"

    static func named(_ name: String, accessibilityDescription: String?) -> NSImage? {
        let image: NSImage?
        switch name {
        case displays: image = mark(filled: false)
        case displaysFill: image = mark(filled: true)
        default: image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }
        image?.accessibilityDescription = accessibilityDescription
        return image
    }

    /// Sized like SF Symbols' `display`; edges land on whole pixels at 2x.
    private static func mark(filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 15), flipped: false) { bounds in
            let line: CGFloat = 1.5
            let front = NSRect(x: 0.75, y: 3.75, width: 12.5, height: 7.5)
            let back = NSRect(x: 6.75, y: 6.75, width: 12.5, height: 7.5)
            NSColor.black.set()

            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: bounds)
            clip.append(NSBezierPath(roundedRect: front.insetBy(dx: -1.75, dy: -1.75), xRadius: 3.5, yRadius: 3.5))
            clip.windingRule = .evenOdd
            clip.addClip()
            let backPath = NSBezierPath(roundedRect: back, xRadius: 1.75, yRadius: 1.75)
            backPath.lineWidth = line
            backPath.stroke()
            NSGraphicsContext.restoreGraphicsState()

            if filled {
                NSBezierPath(roundedRect: front.insetBy(dx: -line / 2, dy: -line / 2), xRadius: 2.5, yRadius: 2.5).fill()
            } else {
                let frontPath = NSBezierPath(roundedRect: front, xRadius: 1.75, yRadius: 1.75)
                frontPath.lineWidth = line
                frontPath.stroke()
            }
            NSBezierPath(rect: NSRect(x: front.midX - 1, y: 1, width: 2, height: 2)).fill()
            NSBezierPath(roundedRect: NSRect(x: front.midX - 3, y: 0, width: 6, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
