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

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private let bubble = CameraBubble()
    private let countdown = CountdownOverlay()
    private var timer: Timer?
    private var startDate: Date?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private let sink = NullSink()

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
        if useCamera {
            if await !bubble.show() {
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
        } catch {
            errorMessage = "Couldn't start recording: \(error.localizedDescription)"
            countdown.hide()
            bubble.hide()
            state = .idle
        }
    }

    func stop() async {
        guard state == .recording, let stream else { return }
        state = .finishing
        timer?.invalidate()
        timer = nil
        bubble.hide()

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finishContinuation = c
            Task {
                do { try await stream.stopCapture() }
                catch {
                    await MainActor.run {
                        self.errorMessage = "Stop failed: \(error.localizedDescription)"
                        self.resumeFinish()
                    }
                }
            }
        }

        self.stream = nil
        recordingOutput = nil
        state = .idle
        libraryVersion += 1
        if let url = lastRecording { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    // MARK: - Capture setup

    private func beginCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID

        func fail(_ msg: String) -> NSError {
            NSError(domain: "Goom", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        let config = SCStreamConfiguration()
        let filter: SCContentFilter
        var pixelSize: CGSize

        switch mode {
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first
            else { throw fail("No display found") }
            filter = SCContentFilter(display: display, excludingWindows: [])
            let info = SCShareableContent.info(for: filter)
            let scale = CGFloat(info.pointPixelScale)
            pixelSize = CGSize(width: info.contentRect.width * scale, height: info.contentRect.height * scale)

        case .window:
            guard let window = content.windows.first(where: { $0.windowID == selectedWindowID })
            else { throw fail("That window is no longer available") }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let info = SCShareableContent.info(for: filter)
            let scale = CGFloat(info.pointPixelScale)
            pixelSize = CGSize(width: info.contentRect.width * scale, height: info.contentRect.height * scale)

        case .region:
            guard let region, let display = content.displays.first(where: { $0.displayID == region.displayID })
            else { throw fail("The region's display is no longer available") }
            filter = SCContentFilter(display: display, excludingWindows: [])
            let scale = CGFloat(SCShareableContent.info(for: filter).pointPixelScale)
            config.sourceRect = region.rect
            pixelSize = CGSize(width: region.rect.width * scale, height: region.rect.height * scale)
        }

        // H.264 wants even dimensions.
        config.width = max(2, Int(pixelSize.width) / 2 * 2)
        config.height = max(2, Int(pixelSize.height) / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.capturesAudio = true            // system audio
        config.captureMicrophone = useMic      // macOS 15+
        config.queueDepth = 6

        let url = Storage.newRecordingURL()
        let recCfg = SCRecordingOutputConfiguration()
        recCfg.outputURL = url
        recCfg.outputFileType = .mp4
        recCfg.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: recCfg, delegate: self)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // A stream output is required to avoid "no output" log noise; frames are discarded
        // because SCRecordingOutput writes the file itself.
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: .global())
        try stream.addRecordingOutput(output)
        try await stream.startCapture()

        self.stream = stream
        self.recordingOutput = output
        self.lastRecording = url
    }

    fileprivate func resumeFinish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

extension Recorder: SCRecordingOutputDelegate, SCStreamDelegate {
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.resumeFinish() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor in
            self.errorMessage = "Recording failed: \(error.localizedDescription)"
            self.resumeFinish()
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            self.errorMessage = "Capture stopped: \(error.localizedDescription)"
            if self.state == .recording {
                self.timer?.invalidate()
                self.bubble.hide()
                self.state = .idle
                self.libraryVersion += 1
            }
        }
    }
}

private final class NullSink: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}
