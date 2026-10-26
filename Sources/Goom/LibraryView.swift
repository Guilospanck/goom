import SwiftUI
import AVKit

struct LibraryView: View {
    @Environment(Recorder.self) private var recorder
    @State private var items: [URL] = []
    @State private var selection: URL?

    var body: some View {
        NavigationSplitView {
            List(items, id: \.self, selection: $selection) { url in
                VStack(alignment: .leading) {
                    Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                    Text(Self.size(of: url)).font(.caption).foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Move to Trash", role: .destructive) { trash(url) }
                }
            }
            .overlay { if items.isEmpty { ContentUnavailableView("No recordings yet", systemImage: "video", description: Text("Start one from the menu bar icon.")) } }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let selection {
                VStack(spacing: 0) {
                    VideoPlayer(player: AVPlayer(url: selection))
                        .id(selection)
                    HStack {
                        ShareLink(item: selection)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([selection]) }
                        Spacer()
                        Button("Move to Trash", role: .destructive) { trash(selection) }
                    }
                    .padding(10)
                }
            } else {
                Text("Select a recording").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .onAppear(perform: reload)
        .onChange(of: recorder.libraryVersion) { reload() }
    }

    private func reload() {
        items = Storage.recordings()
        if selection == nil || !items.contains(selection!) { selection = items.first }
    }

    private func trash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reload()
    }

    private static func size(of url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
