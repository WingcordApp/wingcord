import Foundation
import WingcordCore

/// Downloaded notes, by attachment.
///
/// **On disk rather than in memory**, since `AVPlayer` wants a file, and capped, so a
/// year of voice messages doesn't quietly become a gigabyte in Caches.
nonisolated enum VoiceNoteCache {
    private static let capBytes: Int64 = 200 * 1_024 * 1_024

    private static var folder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Wingcord", isDirectory: true)
            .appendingPathComponent("VoiceNotes", isDirectory: true)
    }

    private static func file(for id: AttachmentID) -> URL {
        folder.appendingPathComponent("\(id.rawValue).ogg")
    }

    /// The copy on disk, if there is one, marked as just used.
    static func url(for id: AttachmentID) -> URL? {
        let url = file(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path)
        return url
    }

    static func download(_ source: URL, for id: AttachmentID) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: source)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw URLError(.badServerResponse)
        }
        return try store(temporary, for: id)
    }

    /// Takes a file this app recorded, once it knows the attachment it became, so a note
    /// you've just sent never has to come back down.
    @discardableResult
    static func store(_ file: URL, for id: AttachmentID) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = self.file(for: id)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
        Task.detached(priority: .utility) { trim() }
        return destination
    }

    /// Takes back a copy that turned out not to play, if it's one of these. A file somebody
    /// recorded here, still on its way, isn't.
    static func remove(_ file: URL) {
        guard file.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Oldest first, until it's back under the cap.
    private static func trim() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys
        ) else { return }
        var entries = files.compactMap { url -> (url: URL, size: Int64, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > capBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries {
            guard total > capBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
