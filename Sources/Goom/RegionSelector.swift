import AppKit

struct RegionSelection: Equatable {
    var displayID: CGDirectDisplayID
    /// Display-local points, origin top-left (what SCStreamConfiguration.sourceRect expects).
    var rect: CGRect
}

/// Dimmed overlay on every display where the user drags out a capture rectangle. Esc cancels.
@MainActor
enum RegionSelector {
    private static var windows: [SelectorWindow] = []

    static func select() async -> RegionSelection? {
        guard windows.isEmpty else { return nil }

        return await withCheckedContinuation { (c: CheckedContinuation<RegionSelection?, Never>) in
            var finished = false
            var monitor: Any?
            @MainActor func finish(_ result: RegionSelection?) {
                guard !finished else { return }
                finished = true
                if let monitor { NSEvent.removeMonitor(monitor) }
                windows.forEach { $0.orderOut(nil) }
                windows = []
                NSCursor.arrow.set()
                c.resume(returning: result)
            }

            // One overlay per display, so the region can be picked on any of them.
            for screen in NSScreen.screens {
                guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                else { continue }
                let win = SelectorWindow(screen: screen)
                let view = SelectorView(frame: NSRect(origin: .zero, size: screen.frame.size))
                view.onFinish = { rect in
                    if let rect, rect.width >= 20, rect.height >= 20 {
                        finish(RegionSelection(displayID: displayID, rect: rect))
                    } else {
                        finish(nil)
                    }
                }
                win.contentView = view
                windows.append(win)
            }
            guard !windows.isEmpty else {
                c.resume(returning: nil)
                return
            }

            // Only one window is key, so Esc is handled globally rather than by each view.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    MainActor.assumeIsolated { finish(nil) }   // local monitors run on the main thread
                    return nil
                }
                return event
            }
            NSApp.activate(ignoringOtherApps: true)
            windows.forEach { $0.orderFrontRegardless() }
            let mouse = NSEvent.mouseLocation
            if let key = windows.first(where: { $0.frame.contains(mouse) }) ?? windows.first {
                key.makeKeyAndOrderFront(nil)
                key.makeFirstResponder(key.contentView)
            }
        }
    }
}

/// A border drawn around the selected region while recording. It sits entirely outside the captured
/// rectangle (with a gap), so it never appears in the video.
@MainActor
final class RegionOutline {
    private var panel: NSPanel?
    private let inset: CGFloat = 6

    func show(_ region: RegionSelection) {
        hide()
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == region.displayID
        }) else { return }

        // Region is display-local with a top-left origin; AppKit is bottom-left.
        let frame = NSRect(
            x: screen.frame.minX + region.rect.minX - inset,
            y: screen.frame.maxY - region.rect.maxY - inset,
            width: region.rect.width + inset * 2, height: region.rect.height + inset * 2)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = OutlineView(frame: NSRect(origin: .zero, size: frame.size))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class OutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setStroke()
        // Stroke hugs the outer edge of the panel (spans ~0.5-3.5pt), leaving a gap before the region.
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 3, yRadius: 3)
        path.lineWidth = 3
        path.stroke()
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
    // The first click on a non-key display's overlay should start the drag, not just focus the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
