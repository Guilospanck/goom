import AppKit
import AVFoundation
import ScreenCaptureKit

enum CaptureMode: String, CaseIterable, Identifiable {
    case display = "Screen", window = "Window", region = "Region"
    var id: String { rawValue }
}

@MainActor
@Observable
final class Recorder: NSObject {
    enum State: Equatable { case idle, countdown(Int), recording, finishing }

    var state: State = .idle
    var elapsed: TimeInterval = 0
    var useCamera = true
    var useMic = true
    var showCountdown = true
    var mode: CaptureMode = .display
    var windows: [SCWindow] = []
    var selectedWindowID: CGWindowID?
    var region: RegionSelection?
    var errorMessage: String?
    /// Bumped whenever a recording finishes so the library reloads.
    var libraryVersion = 0
    var lastRecording: URL?

    // Devices (nil = system default) and quality/bubble preferences, persisted across launches.
    var cameras: [CaptureDevice] = []
    var microphones: [CaptureDevice] = []
    var cameraID: String? = UserDefaults.standard.string(forKey: "cameraID") {
        didSet { UserDefaults.standard.set(cameraID, forKey: "cameraID") }
    }
    var micID: String? = UserDefaults.standard.string(forKey: "micID") {
        didSet { UserDefaults.standard.set(micID, forKey: "micID") }
    }
    var resolution: VideoResolution = Prefs.value("resolution", default: .native) {
        didSet { Prefs.save("resolution", resolution) }
    }
    var frameRate: VideoFrameRate = Prefs.value("frameRate", default: .fps30) {
        didSet { Prefs.save("frameRate", frameRate) }
    }
    var codec: VideoCodec = Prefs.value("codec", default: .h264) {
        didSet { Prefs.save("codec", codec) }
    }
    var audioQuality: AudioQuality = Prefs.value("audioQuality", default: .high) {
        didSet { Prefs.save("audioQuality", audioQuality) }
    }
    var cameraQuality: CameraQuality = Prefs.value("cameraQuality", default: .high) {
        didSet { Prefs.save("cameraQuality", cameraQuality) }
    }
    // Changing these also restyles a visible bubble, so they can be changed mid-recording.
    var bubbleShape: BubbleShape = Prefs.value("bubbleShape", default: .circle) {
        didSet {
            Prefs.save("bubbleShape", bubbleShape)
            applyBubbleStyle()
        }
    }
    var bubbleSize: BubbleSize = Prefs.value("bubbleSize", default: .medium) {
        didSet {
            Prefs.save("bubbleSize", bubbleSize)
            applyBubbleStyle()
        }
    }

    /// Called once validation has passed and recording is really about to begin (the UI should get out of the way).
    @ObservationIgnored var onWillCapture: (() -> Void)?
    /// Called when something failed after the UI was dismissed, so the message can be shown.
    @ObservationIgnored var onError: (() -> Void)?

    private var stream: SCStream?
    private var videoWriter: RecordingWriter?
    private var compositor: CameraCompositor?
    private var layoutTimer: Timer?
    /// Where the capture sits on the desktop (global points, top-left origin) and how it maps to video pixels.
    private var captureArea: CaptureArea?
    private var videoSize = CGSize.zero
    private let bubble = CameraBubble()
    private let countdown = CountdownOverlay()
    private let regionOutline = RegionOutline()
    private var timer: Timer?
    private var startDate: Date?

    var isBusy: Bool { state != .idle }

    // MARK: - Target selection

    func refreshWindows() async {
        // Calling SCShareableContent without access shows a system prompt that doesn't
        // register the app in Settings; CGRequestScreenCaptureAccess does.
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { return }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        let me = Bundle.main.bundleIdentifier
        windows = content.windows
            .filter { $0.windowLayer == 0 && $0.frame.width > 100 && $0.frame.height > 100
                && !($0.title ?? "").isEmpty && $0.owningApplication?.bundleIdentifier != me }
            .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
        if let id = selectedWindowID, !windows.contains(where: { $0.windowID == id }) { selectedWindowID = nil }
    }

    func refreshDevices() {
        cameras = CaptureDevice.cameras()
        microphones = CaptureDevice.microphones()
        // A device that was unplugged falls back to the system default.
        if let id = cameraID, !cameras.contains(where: { $0.id == id }) { cameraID = nil }
        if let id = micID, !microphones.contains(where: { $0.id == id }) { micID = nil }
    }

    func pickRegion() async {
        if let r = await RegionSelector.select() {
            region = r
            mode = .region
        }
    }

    // MARK: - Start / stop

    func toggle() {
        switch state {
        case .idle: Task { await start() }
        case .recording: Task { await stop() }
        default: break
        }
    }

    func start() async {
        guard state == .idle else { return }
        errorMessage = nil

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            errorMessage = "Screen recording permission is required. Enable Goom in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch."
            return
        }
        if useMic, await !AVCaptureDevice.requestAccess(for: .audio) {
            errorMessage = "Microphone access was denied. Enable it in System Settings or turn the mic off."
            return
        }
        switch mode {
        case .window where selectedWindowID == nil:
            errorMessage = "Choose a window to record first."
            return
        case .region where region == nil:
            errorMessage = "Select a region to record first."
            return
        default: break
        }
        onWillCapture?()
        if mode == .region, let region { regionOutline.show(region) }
        if useCamera {
            bubble.onStyleChange = { [weak self] shape, size in
                self?.bubbleShape = shape
                self?.bubbleSize = size
            }
            if await !bubble.show(deviceID: cameraID, quality: cameraQuality, shape: bubbleShape, size: bubbleSize) {
                errorMessage = "Camera unavailable or denied; recording without it."
                useCamera = false
            }
        }

        if showCountdown {
            for n in stride(from: 3, through: 1, by: -1) {
                state = .countdown(n)
                countdown.show(n, on: NSScreen.main)
                try? await Task.sleep(for: .seconds(1))
            }
            countdown.hide()
            // Let the overlay actually leave the screen before frames are captured.
            try? await Task.sleep(for: .milliseconds(150))
        }

        do {
            try await beginCapture()
            state = .recording
            startDate = Date()
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let s = self.startDate else { return }
                    self.elapsed = Date().timeIntervalSince(s)
                }
            }
            if compositor != nil {
                layoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.updateBubbleLayout() }
                }
            }
        } catch {
            errorMessage = "Couldn't start recording: \(error.localizedDescription)"
            countdown.hide()
            bubble.hide()
            compositor = nil
            captureArea = nil
            regionOutline.hide()
            onError?()
            state = .idle
        }
    }

    func stop() async {
        guard state == .recording, let stream else { return }
        state = .finishing
        timer?.invalidate()
        timer = nil
        layoutTimer?.invalidate()
        layoutTimer = nil

        do { try await stream.stopCapture() }
        catch { errorMessage = "Stop failed: \(error.localizedDescription)" }
        do { try await videoWriter?.finish() }
        catch { errorMessage = "Recording failed: \(error.localizedDescription)" }
        // The preview stays up until the last frame is written so the bubble doesn't vanish early.
        bubble.hide()
        regionOutline.hide()

        self.stream = nil
        videoWriter = nil
        compositor = nil
        captureArea = nil
        state = .idle
        libraryVersion += 1
        if errorMessage != nil { onError?() }
        if let url = lastRecording { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    // MARK: - Capture setup

    private func beginCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID

        func fail(_ msg: String) -> NSError {
            NSError(domain: "Goom", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        // The on-screen bubble is only a preview; the compositor draws the camera into the video, so keep
        // the panel itself out of the capture to avoid a double bubble.
        let bubbleID = bubble.windowNumber.map { CGWindowID($0) }
        let bubbleWindows = content.windows.filter { $0.windowID == bubbleID }

        let config = SCStreamConfiguration()
        let filter: SCContentFilter
        var pixelSize: CGSize

        switch mode {
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first
            else { throw fail("No display found") }
            filter = SCContentFilter(display: display, excludingWindows: bubbleWindows)
            let scale = Self.pixelScale(for: filter, area: display.frame)
            pixelSize = CGSize(width: display.frame.width * scale, height: display.frame.height * scale)
            captureArea = CaptureArea(origin: display.frame.origin, size: display.frame.size, windowID: nil)

        case .window:
            guard let window = content.windows.first(where: { $0.windowID == selectedWindowID })
            else { throw fail("That window is no longer available") }
            filter = SCContentFilter(desktopIndependentWindow: window)
            // window.frame is in points; sizing from it keeps the video and the bubble mapping consistent.
            let scale = Self.pixelScale(for: filter, area: window.frame)
            pixelSize = CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
            captureArea = CaptureArea(origin: window.frame.origin, size: window.frame.size, windowID: window.windowID)

        case .region:
            guard let region, let display = content.displays.first(where: { $0.displayID == region.displayID })
            else { throw fail("The region's display is no longer available") }
            filter = SCContentFilter(display: display, excludingWindows: bubbleWindows)
            let origin = CGPoint(x: display.frame.minX + region.rect.minX, y: display.frame.minY + region.rect.minY)
            let scale = Self.pixelScale(for: filter, area: CGRect(origin: origin, size: region.rect.size))
            config.sourceRect = region.rect
            pixelSize = CGSize(width: region.rect.width * scale, height: region.rect.height * scale)
            captureArea = CaptureArea(origin: origin, size: region.rect.size, windowID: nil)
        }

        if let limit = resolution.maxLongEdge {
            let shrink = min(1, limit / max(pixelSize.width, pixelSize.height))
            pixelSize = CGSize(width: pixelSize.width * shrink, height: pixelSize.height * shrink)
        }
        // Video codecs want even dimensions.
        config.width = max(2, Int(pixelSize.width) / 2 * 2)
        config.height = max(2, Int(pixelSize.height) / 2 * 2)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.captureResolution = .best       // native (Retina) pixels rather than the nominal point size
        videoSize = CGSize(width: config.width, height: config.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate.rawValue))
        config.showsCursor = true
        config.capturesAudio = true            // system audio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = useMic      // macOS 15+
        config.microphoneCaptureDeviceID = micID
        config.sampleRate = audioQuality.sampleRate
        config.channelCount = audioQuality.channelCount
        config.queueDepth = 6

        compositor = useCamera ? CameraCompositor(feed: bubble.feed, shape: bubbleShape) : nil
        updateBubbleLayout()

        let url = Storage.newRecordingURL()
        let writer = try RecordingWriter(
            url: url, width: config.width, height: config.height,
            codec: codec.avCodec, frameRate: frameRate.rawValue,
            sampleRate: audioQuality.sampleRate, channels: audioQuality.channelCount,
            compositor: compositor)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
        if useMic { try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue) }
        do { try await stream.startCapture() }
        catch {
            writer.cancel()
            throw error
        }

        self.stream = stream
        self.videoWriter = writer
        self.lastRecording = url
    }

    // MARK: - Bubble placement

    private func applyBubbleStyle() {
        bubble.update(shape: bubbleShape, size: bubbleSize)
        compositor?.shape = bubbleShape
    }

    /// Maps the on-screen preview panel into video pixels so the composited bubble sits exactly where the
    /// user put it. It is not clamped: a bubble outside the captured screen/window/region is simply not
    /// in the video (the compositor skips it), and one half inside is cropped like anything else.
    private func updateBubbleLayout() {
        guard let compositor, let area = captureArea, let panel = bubble.frame, area.size.width > 0 else { return }

        var origin = area.origin
        if let id = area.windowID, let bounds = Self.windowBounds(id) { origin = bounds.origin }

        let scale = videoSize.width / area.size.width
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let top = primaryHeight - panel.maxY    // AppKit is bottom-left, capture coordinates are top-left

        compositor.rect = CGRect(
            x: (panel.minX - origin.x) * scale, y: (top - origin.y) * scale,
            width: panel.width * scale, height: panel.height * scale)
    }

    /// Pixels per point for captured content (2 on Retina). `area` is in global points, top-left origin.
    /// Takes the larger of what ScreenCaptureKit reports and the backing scale of the screen the area mostly
    /// sits on, so a window on a second display isn't captured at too low a resolution.
    private static func pixelScale(for filter: SCContentFilter, area: CGRect) -> CGFloat {
        let reported = max(1, CGFloat(SCShareableContent.info(for: filter).pointPixelScale))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let appKitArea = CGRect(x: area.minX, y: primaryHeight - area.maxY, width: area.width, height: area.height)
        func overlap(_ screen: NSScreen) -> CGFloat {
            let r = screen.frame.intersection(appKitArea)
            return r.isNull ? 0 : r.width * r.height
        }
        let screen = NSScreen.screens.max { overlap($0) < overlap($1) }
        return max(reported, screen?.backingScaleFactor ?? 1)
    }

    private static func windowBounds(_ id: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }
}

private struct CaptureArea {
    var origin: CGPoint
    var size: CGSize
    var windowID: CGWindowID?
}

extension Recorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            self.errorMessage = "Capture stopped: \(error.localizedDescription)"
            if self.state == .recording {
                self.timer?.invalidate()
                self.layoutTimer?.invalidate()
                // Keep whatever was captured before the stream died.
                try? await self.videoWriter?.finish()
                self.bubble.hide()
                self.regionOutline.hide()
                self.videoWriter = nil
                self.compositor = nil
                self.stream = nil
                self.state = .idle
                self.libraryVersion += 1
                self.onError?()
            }
        }
    }
}
