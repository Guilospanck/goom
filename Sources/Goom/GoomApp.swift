import SwiftUI

@main
struct GoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The menu bar item and library window are managed by AppDelegate (see below); a scene is required.
        Settings { EmptyView() }
    }
}

/// A container whose origin is its top-left corner, so a child at y = 0 stays put while the window resizes.
private final class TopAnchoredView: NSView {
    override var isFlipped: Bool { true }
}

/// Owns the menu bar item. A plain NSStatusItem (instead of MenuBarExtra) lets a click on the icon stop a
/// running recording, and lets the popover be dismissed as soon as recording starts.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = Recorder()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var hosting: NSHostingView<MenuContent>!
    private var libraryWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The SwiftUI content is always laid out at its full height and pinned to the top of a clipping container;
        // the popover window then grows or shrinks over it (see `applyLayout`), so nothing inside ever moves.
        hosting = NSHostingView(rootView: MenuContent(recorder: recorder, openLibrary: { [weak self] in
            self?.openLibrary()
        }, onLayout: { [weak self] full, hidden in
            self?.applyLayout(full: full, hidden: hidden)
        }))
        hosting.sizingOptions = [.intrinsicContentSize]   // reports a size for the initial fit; never resizes the window
        let container = TopAnchoredView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.addSubview(hosting)
        hosting.autoresizingMask = [.width]   // follows the width; the flipped container keeps the top edge at y = 0
        let fitting = NSSize(width: MenuContent.width, height: hosting.fittingSize.height)
        hosting.frame = NSRect(origin: .zero, size: fitting)
        container.frame = hosting.frame
        let controller = NSViewController()
        controller.view = container
        popover.contentViewController = controller
        popover.contentSize = fitting
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

    /// `full` is the content's natural height; `hidden` is the part currently collapsed (clipped by the window).
    private func applyLayout(full: CGFloat, hidden: CGFloat) {
        guard full > 0 else { return }
        let visible = full - hidden
        hosting.frame = NSRect(x: 0, y: 0, width: MenuContent.width, height: full)
        popover.contentSize = NSSize(width: MenuContent.width, height: visible)
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
        // The hosted view lives across shows, so its .task doesn't re-run; refresh what can change between opens.
        recorder.refreshScreens()
        recorder.refreshDevices()
        Task { await recorder.refreshWindows() }
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

/// Link (pointing-hand) pointer over anything clickable, plus an optional hover background.
private struct Interactive: ViewModifier {
    var radius: CGFloat = 10
    var highlight = true
    var enabled = true
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.primary.opacity(highlight && hovering && enabled ? 0.08 : 0))
                    .allowsHitTesting(false)
            )
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .onHover { hovering = $0 }
            .pointerStyle(enabled ? .link : nil)
            .onDisappear { hovering = false }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private extension View {
    func interactive(radius: CGFloat = 10, highlight: Bool = true, enabled: Bool = true) -> some View {
        modifier(Interactive(radius: radius, highlight: highlight, enabled: enabled))
    }
}

private extension CaptureMode {
    var symbol: String {
        switch self {
        case .display: "display"
        case .window: "macwindow"
        case .region: "rectangle.dashed"
        }
    }
}

struct MenuContent: View {
    let recorder: Recorder
    let openLibrary: () -> Void
    static let width: CGFloat = 320
    let onLayout: (_ full: CGFloat, _ hidden: CGFloat) -> Void
    @State private var showOptions = false
    @State private var optionsHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private struct Metrics: Equatable { var full, card: CGFloat; var open: Bool }

    private var isRecording: Bool { recorder.state == .recording }

    var body: some View {
        @Bindable var r = recorder
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(CaptureMode.allCases) { modeTile($0) }
                }
                sourceRow
            }

            VStack(spacing: 0) {
                toggleRow("Camera", symbol: "video.fill", isOn: $r.useCamera)
                Divider().padding(.leading, 38)
                toggleRow("Microphone", symbol: "mic.fill", isOn: $r.useMic)
                Divider().padding(.leading, 38)
                toggleRow("Countdown", symbol: "timer", isOn: $r.showCountdown)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            if recorder.useCamera {
                Text(recorder.mode == .display
                     ? "Right-click the bubble to change its size or shape, even while recording."
                     : "The bubble is recorded only where it overlaps the \(recorder.mode == .window ? "window" : "region"). Right-click it to change its size or shape, even while recording.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            recordButton

            if let error = recorder.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            footer

            optionsSection
        }
        .padding(16)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
        .onChange(of: Metrics(full: fullHeight, card: optionsHeight, open: showOptions)) { _, m in
            onLayout(m.full, m.open ? 0 : m.card)
        }
        .task {
            recorder.refreshDevices()
            recorder.refreshScreens()
            await recorder.refreshWindows()
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle.fill").foregroundStyle(.red).font(.title3)
            Text("Goom").font(.headline)
            Spacer()
            if recorder.isBusy {
                Text(isRecording ? "Recording" : "Starting…")
                    .font(.caption.weight(.medium)).foregroundStyle(.red)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.red.opacity(0.15), in: Capsule())
            }
        }
    }

    private func modeTile(_ mode: CaptureMode) -> some View {
        let selected = recorder.mode == mode
        return Button {
            recorder.mode = mode
        } label: {
            VStack(spacing: 5) {
                Image(systemName: mode.symbol).font(.system(size: 20))
                Text(mode.rawValue).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(selected ? Color.accentColor : .secondary)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .interactive(highlight: !selected, enabled: !recorder.isBusy)
        .disabled(recorder.isBusy)
    }

    @ViewBuilder private var sourceRow: some View {
        switch recorder.mode {
        case .display:
            displayPicker
        case .window:
            windowPicker
        case .region:
            regionPicker
        }
    }

    private func toggleRow(_ title: String, symbol: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .interactive(radius: 8, enabled: !recorder.isBusy)
        .onTapGesture { if !recorder.isBusy { isOn.wrappedValue.toggle() } }
        .opacity(recorder.isBusy ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var recordButton: some View {
        Button {
            recorder.toggle()
        } label: {
            Label(isRecording ? "Stop Recording" : "Start Recording",
                  systemImage: isRecording ? "stop.fill" : "record.circle")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(isRecording ? .red : .accentColor)
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .interactive(highlight: false, enabled: !recorder.isBusy || isRecording)
        .disabled(recorder.isBusy && !isRecording)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            footerButton("Library", symbol: "film.stack", action: openLibrary)
            footerButton("Folder", symbol: "folder") { NSWorkspace.shared.open(Storage.directory) }
            Spacer()
            footerButton("Quit", symbol: "power") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .padding(.horizontal, -8)
    }

    private func footerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.callout)
                .padding(.horizontal, 8).padding(.vertical, 5)
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .interactive(radius: 7)
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { showOptions.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(showOptions ? 90 : 0))
                    Text("Devices & quality").font(.callout)
                    Spacer()
                    Image(systemName: "slider.horizontal.3").font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .interactive()

            // Always laid out, at the very bottom: collapsing just shrinks the popover window past it.
            optionsCard
                .opacity(showOptions ? 1 : 0)
                .accessibilityHidden(!showOptions)
        }
    }

    private var optionsCard: some View {
        @Bindable var r = recorder
        return VStack(spacing: 0) {
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
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(.top, 8)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { optionsHeight = $0 }
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

    @ViewBuilder private var displayPicker: some View {
        @Bindable var r = recorder
        if recorder.screens.count > 1 {
            Picker("Display", selection: $r.displayID) {
                Text("Main display").tag(CGDirectDisplayID?.none)
                ForEach(recorder.screens) { Text($0.name).tag(CGDirectDisplayID?.some($0.id)) }
            }
            .labelsHidden()
            .disabled(recorder.isBusy)
        } else {
            Label("Records your main display", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var regionPicker: some View {
        HStack {
            Label(recorder.region.map { "\(Int($0.rect.width)) × \(Int($0.rect.height)) pt" } ?? "No region selected",
                  systemImage: "viewfinder")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(recorder.region == nil ? "Select…" : "Reselect…") {
                Task { await recorder.pickRegion() }
            }
            .disabled(recorder.isBusy)
        }
    }
}
