import AppKit
@preconcurrency import AVFoundation

/// A floating, draggable camera preview (circle, rounded square or wide). It is only a live preview and
/// drag handle: the recording excludes this window and draws the camera itself (see CameraCompositor),
/// using the panel's position, so the bubble is in the video in every capture mode.
@MainActor
final class CameraBubble {
    private var panel: NSPanel?
    private let session = AVCaptureSession()
    /// Latest camera frame, read by the recording compositor.
    let feed = CameraFeed()

    /// Called when the user picks a different shape or size from the bubble's right-click menu.
    var onStyleChange: ((BubbleShape, BubbleSize) -> Void)?

    var windowNumber: Int? { panel?.windowNumber }
    var frame: NSRect? { panel?.frame }

    func show(deviceID: String?, quality: CameraQuality, shape: BubbleShape, size: BubbleSize) async -> Bool {
        guard await AVCaptureDevice.requestAccess(for: .video) else { return false }

        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        session.outputs.forEach { session.removeOutput($0) }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(feed, queue: feed.queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.sessionPreset = session.canSetSessionPreset(quality.preset) ? quality.preset : .high
        session.commitConfiguration()

        let frame = NSRect(x: 0, y: 0, width: size.width, height: (size.width * shape.aspect).rounded())
        let view = BubbleView(frame: frame, session: session, shape: shape, size: size)
        view.onStyleChange = { [weak self] shape, size in self?.onStyleChange?(shape, size) }
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

    /// Resizes / reshapes the live bubble, keeping its center where it is.
    func update(shape: BubbleShape, size: BubbleSize) {
        guard let panel, let view = panel.contentView as? BubbleView else { return }
        let newSize = NSSize(width: size.width, height: (size.width * shape.aspect).rounded())
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.setFrame(NSRect(x: center.x - newSize.width / 2, y: center.y - newSize.height / 2,
                              width: newSize.width, height: newSize.height), display: true)
        view.apply(shape: shape, size: size)
    }

    func hide() {
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        panel?.orderOut(nil)
        panel = nil
        feed.clear()
    }
}

private final class BubbleView: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    private var shape: BubbleShape
    private var size: BubbleSize
    var onStyleChange: ((BubbleShape, BubbleSize) -> Void)?

    init(frame: NSRect, session: AVCaptureSession, shape: BubbleShape, size: BubbleSize) {
        self.shape = shape
        self.size = size
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: frame)
        wantsLayer = true
        preview.frame = bounds
        preview.videoGravity = .resizeAspectFill
        preview.cornerRadius = shape.cornerRadius(for: frame.size)
        preview.masksToBounds = true
        preview.borderWidth = 3
        preview.borderColor = NSColor.white.cgColor
        // Mirror like a selfie view.
        preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Call after the window has been resized.
    func apply(shape: BubbleShape, size: BubbleSize) {
        self.shape = shape
        self.size = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        preview.cornerRadius = shape.cornerRadius(for: bounds.size)
        CATransaction.commit()
    }

    // MARK: - Right-click menu

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "Size"))
        for option in BubbleSize.allCases {
            let item = NSMenuItem(title: option.rawValue, action: #selector(pickSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option
            item.state = option == size ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Shape"))
        for option in BubbleShape.allCases {
            let item = NSMenuItem(title: option.rawValue, action: #selector(pickShape(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option
            item.state = option == shape ? .on : .off
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func pickSize(_ item: NSMenuItem) {
        guard let option = item.representedObject as? BubbleSize else { return }
        onStyleChange?(shape, option)
    }

    @objc private func pickShape(_ item: NSMenuItem) {
        guard let option = item.representedObject as? BubbleShape else { return }
        onStyleChange?(option, size)
    }
}
