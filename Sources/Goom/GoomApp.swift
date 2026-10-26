import SwiftUI

@main
struct GoomApp: App {
    @State private var recorder = Recorder()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuContent(recorder: recorder)
        } label: {
            switch recorder.state {
            case .idle: Image(systemName: "record.circle")
            case .countdown(let n): Text("\(n)")
            case .recording: Label(Self.format(recorder.elapsed), systemImage: "stop.circle.fill")
            case .finishing: Image(systemName: "hourglass")
            }
        }
        .menuBarExtraStyle(.window)

        Window("Goom Library", id: "library") {
            LibraryView().environment(recorder)
        }
    }

    static func format(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

private struct MenuContent: View {
    let recorder: Recorder
    @Environment(\.openWindow) private var openWindow

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
            if recorder.mode == .window && recorder.useCamera {
                Text("The camera bubble isn't captured in window mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }

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
                Button("Library") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "library")
                }
                Button("Folder") { NSWorkspace.shared.open(Storage.directory) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 300)
        .task { await recorder.refreshWindows() }
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
