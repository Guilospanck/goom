import AVFoundation
import CoreImage

/// Receives frames from the camera session and keeps the most recent one for the compositor.
final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "goom.camera-feed")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?

    var frame: CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func clear() {
        lock.lock()
        latest = nil
        lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latest = buffer
        lock.unlock()
    }
}

/// Draws the camera bubble (mirrored, aspect-filled, masked to the chosen shape, white border) onto
/// screen frames. `rect` is in video pixels with a top-left origin and can be updated at any time.
final class CameraCompositor: @unchecked Sendable {
    let feed: CameraFeed

    private let lock = NSLock()
    private var _rect = CGRect.zero
    private var _shape: BubbleShape
    private let context = CIContext()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private var overlay: (size: CGSize, shape: BubbleShape, mask: CIImage, ring: CIImage)?

    init(feed: CameraFeed, shape: BubbleShape) {
        self.feed = feed
        _shape = shape
    }

    /// Can change mid-recording; takes effect on the next frame.
    var shape: BubbleShape {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _shape
        }
        set {
            lock.lock()
            _shape = newValue
            lock.unlock()
        }
    }

    var rect: CGRect {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _rect
        }
        set {
            lock.lock()
            _rect = newValue
            lock.unlock()
        }
    }

    /// Renders `screen` with the bubble on top into `destination`. Returns false if there is nothing to draw.
    func render(screen: CVPixelBuffer, into destination: CVPixelBuffer) -> Bool {
        let rect = self.rect
        let size = CGSize(width: rect.width.rounded(), height: rect.height.rounded())
        let frame = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(destination), height: CVPixelBufferGetHeight(destination))
        // A bubble that is entirely outside the captured area is not part of the video.
        guard size.width >= 2, size.height >= 2, rect.intersects(frame), let cameraBuffer = feed.frame else { return false }
        let shape = self.shape

        // Aspect-fill the camera into the bubble, then mirror it like the on-screen preview.
        var camera = CIImage(cvPixelBuffer: cameraBuffer)
        let extent = camera.extent
        let scale = max(size.width / extent.width, size.height / extent.height)
        camera = camera.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let cropX = camera.extent.minX + (camera.extent.width - size.width) / 2
        let cropY = camera.extent.minY + (camera.extent.height - size.height) / 2
        camera = camera
            .cropped(to: CGRect(x: cropX, y: cropY, width: size.width, height: size.height))
            .transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -size.width, y: 0))

        let (mask, ring) = overlayImages(for: size, shape: shape)
        let transparent = CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: size))
        let masked = camera.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: transparent,
            kCIInputMaskImageKey: mask,
        ])

        // Core Image's origin is bottom-left.
        let height = CGFloat(CVPixelBufferGetHeight(destination))
        let placed = ring.composited(over: masked)
            .transformed(by: CGAffineTransform(translationX: rect.minX.rounded(), y: (height - rect.maxY).rounded()))
        // The frame normally matches the destination; scale it if it doesn't rather than mis-aligning.
        var base = CIImage(cvPixelBuffer: screen)
        let screenWidth = CGFloat(CVPixelBufferGetWidth(screen))
        let screenHeight = CGFloat(CVPixelBufferGetHeight(screen))
        if screenWidth != frame.width || screenHeight != frame.height {
            base = base.transformed(by: CGAffineTransform(scaleX: frame.width / screenWidth, y: frame.height / screenHeight))
        }
        let output = placed.composited(over: base)

        context.render(output, to: destination,
                       bounds: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(destination), height: Int(height)),
                       colorSpace: colorSpace)
        return true
    }

    // MARK: - Mask and border

    private func overlayImages(for size: CGSize, shape: BubbleShape) -> (mask: CIImage, ring: CIImage) {
        if let overlay, overlay.size == size, overlay.shape == shape { return (overlay.mask, overlay.ring) }

        let radius = shape.cornerRadius(for: size)
        let border = max(2, size.width * 0.015)
        let bounds = CGRect(origin: .zero, size: size)

        func draw(_ body: (CGContext) -> Void) -> CIImage {
            guard let ctx = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return CIImage.empty() }
            body(ctx)
            guard let image = ctx.makeImage() else { return CIImage.empty() }
            return CIImage(cgImage: image)
        }

        let mask = draw { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        let ring = draw { ctx in
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.setLineWidth(border)
            let inset = bounds.insetBy(dx: border / 2, dy: border / 2)
            let r = max(0, radius - border / 2)
            ctx.addPath(CGPath(roundedRect: inset, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.strokePath()
        }
        overlay = (size, shape, mask, ring)
        return (mask, ring)
    }
}
