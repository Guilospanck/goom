import Foundation

enum Storage {
    /// ~/Movies/Goom
    static var directory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let dir = movies.appendingPathComponent("Goom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func newRecordingURL() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return directory.appendingPathComponent("Goom \(f.string(from: Date())).mp4")
    }

    static func recordings() -> [URL] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast
                return a > b
            }
    }
}
