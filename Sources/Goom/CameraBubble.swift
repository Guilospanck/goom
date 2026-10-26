import AppKit
@preconcurrency import AVFoundation

/// A floating, draggable circular camera preview. Because it is a normal on-screen
/// window, display capture records it into the video, like Loom's bubble.
@MainActor
final class CameraBubble {
    private var panel: NSPanel?
    private let session = AVCaptureSession()
    private var configured = false

    func show(size: CGFloat = 200) async -> Bool {
        guard await AVCaptureDevice.requestAccess(for: .video) else { return false }
        if !configured {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return false }
            session.beginConfiguration()
            session.sessionPreset = .medium
            session.addInput(input)
            session.commitConfiguration()
            configured = true
        }

        let view = BubbleView(frame: NSRect(x: 0, y: 0, width: size, height: size), session: session)
        let panel = NSPanel(
            contentRect: view.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.minY + 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        return true
    }

    func hide() {
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class BubbleView: NSView {
    init(frame: NSRect, session: AVCaptureSession) {
        super.init(frame: frame)
        wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = bounds
        preview.videoGravity = .resizeAspectFill
        preview.cornerRadius = frame.width / 2
        preview.masksToBounds = true
        preview.borderWidth = 3
        preview.borderColor = NSColor.white.cgColor
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // Mirror like a selfie view.
        preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError() }
}
