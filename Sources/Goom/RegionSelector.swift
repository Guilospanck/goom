import AppKit

struct RegionSelection: Equatable {
    var displayID: CGDirectDisplayID
    /// Display-local points, origin top-left (what SCStreamConfiguration.sourceRect expects).
    var rect: CGRect
}

/// Full-screen dimmed overlay where the user drags out a capture rectangle. Esc cancels.
@MainActor
enum RegionSelector {
    private static var window: SelectorWindow?

    static func select() async -> RegionSelection? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }

        return await withCheckedContinuation { (c: CheckedContinuation<RegionSelection?, Never>) in
            let win = SelectorWindow(screen: screen)
            let view = SelectorView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onFinish = { rect in
                win.orderOut(nil)
                window = nil
                NSCursor.arrow.set()
                if let rect, rect.width >= 20, rect.height >= 20 {
                    c.resume(returning: RegionSelection(displayID: displayID, rect: rect))
                } else {
                    c.resume(returning: nil)
                }
            }
            win.contentView = view
            window = win
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(view)
        }
    }
}

private final class SelectorWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        setFrame(screen.frame, display: true)
    }
    override var canBecomeKey: Bool { true }
}

private final class SelectorView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var selection: CGRect? {
        guard let s = start, let c = current else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()
        if let r = selection {
            NSGraphicsContext.current?.compositingOperation = .clear
            r.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: r)
            path.lineWidth = 2
            path.stroke()
            let label = "\(Int(r.width)) × \(Int(r.height))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.7),
            ]
            label.draw(at: CGPoint(x: r.minX, y: max(r.minY - 20, 4)), withAttributes: attrs)
        } else {
            let hint = "Drag to select a region · Esc to cancel" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = hint.size(withAttributes: attrs)
            hint.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        onFinish?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
    }
}
