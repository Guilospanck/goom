import AppKit

/// Big centered "3 2 1" on the main screen. Must be hidden before capture starts.
@MainActor
final class CountdownOverlay {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    func show(_ n: Int, on screen: NSScreen?) {
        if panel == nil {
            let size: CGFloat = 180
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .screenSaver
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let bg = NSVisualEffectView(frame: p.contentView!.bounds)
            bg.material = .hudWindow
            bg.state = .active
            bg.wantsLayer = true
            bg.layer?.cornerRadius = 36
            bg.autoresizingMask = [.width, .height]

            label.font = .systemFont(ofSize: 110, weight: .bold)
            label.textColor = .white
            label.alignment = .center
            label.frame = NSRect(x: 0, y: (size - 130) / 2 - 6, width: size, height: 130)
            bg.addSubview(label)
            p.contentView = bg
            if let screen = screen ?? NSScreen.main {
                p.setFrameOrigin(NSPoint(x: screen.frame.midX - size / 2, y: screen.frame.midY - size / 2))
            }
            panel = p
        }
        label.stringValue = "\(n)"
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
