import SwiftUI

@main
struct GoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The menu bar item and library window are managed by AppDelegate (see below); a scene is required.
        Settings { EmptyView() }
    }
}

/// Owns the menu bar item. A plain NSStatusItem (instead of MenuBarExtra) lets a click on the icon stop a
/// running recording, and lets the popover be dismissed as soon as recording starts.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = Recorder()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var libraryWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = NSHostingController(rootView: MenuContent(recorder: recorder, openLibrary: { [weak self] in
            self?.openLibrary()
        }))
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
        popover.behavior = .transient

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        statusItem = item

        // Get the popover out of the frame before anything is captured.
        recorder.onWillCapture = { [weak self] in self?.popover.performClose(nil) }
        recorder.onError = { [weak self] in self?.showPopover() }
        trackStatus()
    }

    @objc private func statusItemClicked() {
        switch recorder.state {
        case .recording: recorder.toggle()
        case .idle: popover.isShown ? popover.performClose(nil) : showPopover()
        case .countdown, .finishing: break
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func openLibrary() {
        popover.performClose(nil)
        if libraryWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Goom Library"
            window.contentViewController = NSHostingController(rootView: LibraryView().environment(recorder))
            window.isReleasedWhenClosed = false
            window.center()
            libraryWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        libraryWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Menu bar icon

    /// Re-runs `updateStatus` whenever the recorder state or elapsed time changes.
    private func trackStatus() {
        withObservationTracking {
            updateStatus()
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackStatus() }
        }
    }

    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        func symbol(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: "Goom") }
        button.contentTintColor = nil
        switch recorder.state {
        case .idle:
            button.image = symbol("record.circle")
            button.title = ""
        case .countdown(let n):
            button.image = nil
            button.title = "\(n)"
        case .recording:
            button.image = symbol("stop.circle.fill")
            button.imagePosition = .imageLeading
            button.title = " " + Self.format(recorder.elapsed)
            button.contentTintColor = .systemRed
        case .finishing:
            button.image = symbol("hourglass")
            button.title = ""
        }
    }

    static func format(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

private struct MenuContent: View {
    let recorder: Recorder
    let openLibrary: () -> Void

    var body: some View {
        @Bindable var r = recorder
        VStack(alignment: .leading, spacing: 12) {
            Picker("Capture", selection: $r.mode) {
                ForEach(CaptureMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(recorder.isBusy)

            switch recorder.mode {
            case .display:
                Label("Records your main display", systemImage: "display").foregroundStyle(.secondary)
            case .window:
                windowPicker
            case .region:
                regionPicker
            }

            Divider()
            Toggle("Camera bubble", isOn: $r.useCamera).disabled(recorder.isBusy)
            Toggle("Microphone", isOn: $r.useMic).disabled(recorder.isBusy)
            Toggle("3-2-1 countdown", isOn: $r.showCountdown).disabled(recorder.isBusy)
            if recorder.useCamera {
                Text(recorder.mode == .display
                     ? "Right-click the bubble to change its size or shape, even while recording."
                     : "The bubble is recorded only where it overlaps the \(recorder.mode == .window ? "window" : "region"). Right-click it to change its size or shape, even while recording.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            optionsSection

            Button {
                recorder.toggle()
            } label: {
                Text(recorder.state == .recording ? "Stop Recording" : "Start Recording")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(recorder.state == .recording ? .red : .accentColor)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(recorder.isBusy && recorder.state != .recording)

            if let error = recorder.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Button("Library") { openLibrary() }
                Button("Folder") { NSWorkspace.shared.open(Storage.directory) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 300)
        .task {
            recorder.refreshDevices()
            await recorder.refreshWindows()
        }
    }

    private var optionsSection: some View {
        @Bindable var r = recorder
        return DisclosureGroup("Devices & quality") {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                optionRow("Camera") {
                    Picker("Camera", selection: $r.cameraID) {
                        Text("Default").tag(String?.none)
                        ForEach(recorder.cameras) { Text($0.name).tag(String?.some($0.id)) }
                    }
                }
                optionRow("Microphone") {
                    Picker("Microphone", selection: $r.micID) {
                        Text("Default").tag(String?.none)
                        ForEach(recorder.microphones) { Text($0.name).tag(String?.some($0.id)) }
                    }
                }
                Divider()
                optionRow("Resolution") {
                    Picker("Resolution", selection: $r.resolution) {
                        ForEach(VideoResolution.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                optionRow("Frame rate") {
                    Picker("Frame rate", selection: $r.frameRate) {
                        ForEach(VideoFrameRate.allCases) { Text($0.label).tag($0) }
                    }
                }
                optionRow("Codec") {
                    Picker("Codec", selection: $r.codec) {
                        ForEach(VideoCodec.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                optionRow("Audio") {
                    Picker("Audio", selection: $r.audioQuality) {
                        ForEach(AudioQuality.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Divider()
                optionRow("Camera quality") {
                    Picker("Camera quality", selection: $r.cameraQuality) {
                        ForEach(CameraQuality.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                optionRow("Bubble shape") {
                    Picker("Bubble shape", selection: $r.bubbleShape) {
                        ForEach(BubbleShape.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                optionRow("Bubble size") {
                    Picker("Bubble size", selection: $r.bubbleSize) {
                        ForEach(BubbleSize.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            }
            .labelsHidden()
            .disabled(recorder.isBusy)
            .padding(.top, 6)
        }
    }

    private func optionRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var windowPicker: some View {
        @Bindable var r = recorder
        return HStack {
            Picker("Window", selection: $r.selectedWindowID) {
                Text("Choose a window…").tag(CGWindowID?.none)
                ForEach(recorder.windows, id: \.windowID) { w in
                    Text("\(w.owningApplication?.applicationName ?? "App") — \(w.title ?? "")")
                        .lineLimit(1).tag(CGWindowID?.some(w.windowID))
                }
            }
            .labelsHidden()
            .disabled(recorder.isBusy)
            Button { Task { await recorder.refreshWindows() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(recorder.isBusy)
        }
    }

    private var regionPicker: some View {
        HStack {
            if let region = recorder.region {
                Text("\(Int(region.rect.width)) × \(Int(region.rect.height)) pt")
                    .foregroundStyle(.secondary)
            } else {
                Text("No region selected").foregroundStyle(.secondary)
            }
            Spacer()
            Button(recorder.region == nil ? "Select…" : "Reselect…") {
                Task { await recorder.pickRegion() }
            }
            .disabled(recorder.isBusy)
        }
    }
}
