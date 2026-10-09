import AppKit

/// The menu-bar mark: the app icon's two displays, filled and badged by state.
struct StatusMark: Equatable {
    enum Badge {
        case paused
        case attention
    }

    /// Automation is running; fills the front display.
    var watching = false
    /// A display is hidden, blacked out or asleep; fills the back display.
    var hidden = false
    var badge: Badge?

    /// A template image sized like SF Symbols' `display`. Edges land on whole
    /// pixels at 1x and 2x, for non-Retina external displays too.
    func image(accessibilityDescription: String?) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 15), flipped: false) { bounds in
            let scale = NSGraphicsContext.current?.cgContext.userSpaceToDeviceSpaceTransform.a ?? 2
            let line: CGFloat = scale < 1.5 ? 1 : 1.5
            let front = NSRect(x: 0, y: 3, width: 14, height: 9)
            let back = NSRect(x: 6, y: 6, width: 14, height: 9)
            let badgeRect = NSRect(x: 11.5, y: 0, width: 8, height: 8)
            NSColor.black.set()

            NSGraphicsContext.saveGraphicsState()
            if badge != nil { Self.clip(bounds, excluding: NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1.25, dy: -1.25))) }
            NSGraphicsContext.saveGraphicsState()
            Self.clip(bounds, excluding: NSBezierPath(
                roundedRect: front.insetBy(dx: -1, dy: -1), xRadius: 3.5, yRadius: 3.5
            ))
            Self.drawDisplay(back, filled: hidden, line: line)
            NSGraphicsContext.restoreGraphicsState()
            Self.drawDisplay(front, filled: watching, line: line)
            NSBezierPath(rect: NSRect(x: front.midX - 1, y: 1, width: 2, height: 2)).fill()
            NSBezierPath(roundedRect: NSRect(x: front.midX - 3, y: 0, width: 6, height: line), xRadius: line / 2, yRadius: line / 2).fill()
            NSGraphicsContext.restoreGraphicsState()

            guard let badge else { return true }
            let disc = NSBezierPath(ovalIn: badgeRect)
            switch badge {
            case .paused:
                disc.append(NSBezierPath(rect: NSRect(x: 14, y: 2, width: 1, height: 4)))
                disc.append(NSBezierPath(rect: NSRect(x: 16, y: 2, width: 1, height: 4)))
            case .attention:
                disc.append(NSBezierPath(rect: NSRect(x: 15, y: 3, width: 1, height: 3)))
                disc.append(NSBezierPath(rect: NSRect(x: 15, y: 1, width: 1, height: 1)))
            }
            disc.windingRule = .evenOdd
            disc.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private static func clip(_ bounds: NSRect, excluding cutout: NSBezierPath) {
        let clip = NSBezierPath(rect: bounds)
        clip.append(cutout)
        clip.windingRule = .evenOdd
        clip.addClip()
    }

    /// Draws a display within its outer edge.
    private static func drawDisplay(_ outer: NSRect, filled: Bool, line: CGFloat) {
        if filled {
            NSBezierPath(roundedRect: outer, xRadius: 2.5, yRadius: 2.5).fill()
        } else {
            let radius = 2.5 - line / 2
            let path = NSBezierPath(roundedRect: outer.insetBy(dx: line / 2, dy: line / 2), xRadius: radius, yRadius: radius)
            path.lineWidth = line
            path.stroke()
        }
    }
}
