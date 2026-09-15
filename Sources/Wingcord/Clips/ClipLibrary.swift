import Foundation
import WingcordCore

// MARK: - Clips on disk
//
// **A folder, not a database.** Discord's own clips are local files with a
// `filepath` and a custom protocol URL for playback, and its edits are metadata
// beside the file rather than a rewrite of it. A folder the reader can open in
// Finder is the same thing with nothing to corrupt, and it means a clip
// survives every version of this app including the ones that do not exist yet.

/// One clip or screenshot on disk.
struct Clip: Hashable, Sendable, Identifiable {
    var url: URL
    var created: Date
    var byteCount: Int
    /// Screenshots are `.png` and clips are `.mp4`. The kind decides what the
    /// row draws and which of the two share paths it takes.
    var isScreenshot: Bool

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum ClipLibrary {

    /// Where clips go when the reader has not said otherwise.
    ///
    /// `~/Movies/Wingcord Clips`. Discord resolves `app.getPath("videos")` and
    /// appends a folder of its own name; on macOS that path is Movies, and
    /// putting clips loose in it would be rude.
    static var defaultFolder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return movies.appendingPathComponent("Wingcord Clips", isDirectory: true)
    }

    static var folder: URL {
        AppSettings.shared.clipsFolder ?? defaultFolder
    }

    /// A name that sorts chronologically and never collides.
    ///
    /// **The game's name first, then the moment.** A folder of forty files
    /// called `Clip 1` through `Clip 40` is a folder nobody can search; the
    /// game is what somebody remembers about a clip, and the timestamp is what
    /// makes two clips of the same game distinguishable.
    static func name(for game: String?, at date: Date = Date()) -> String {
        let stamp = DateFormatter.clipStamp.string(from: date)
        guard let game, !game.isEmpty else { return stamp }
        // Slashes and colons are the two characters a file name cannot hold,
        // and a game called "Tom Clancy's Rainbow Six: Siege" has one.
        let safe = game
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
        return "\(safe) \(stamp)"
    }

    /// Everything in the folder, newest first.
    ///
    /// Walks the directory rather than keeping an index: the reader can delete
    /// a clip in Finder, and an index would then list a file that is not there.
    static func contents() -> [Clip] {
        let keys: Set<URLResourceKey> = [.creationDateKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        return entries.compactMap { url -> Clip? in
            let ext = url.pathExtension.lowercased()
            guard ext == "mp4" || ext == "png" else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            return Clip(
                url: url,
                created: values?.creationDate ?? .distantPast,
                byteCount: values?.fileSize ?? 0,
                isScreenshot: ext == "png"
            )
        }
        .sorted { $0.created > $1.created }
    }

    static func delete(_ clip: Clip) throws {
        try FileManager.default.removeItem(at: clip.url)
    }

    /// What the folder costs, for the settings pane to show.
    static func totalBytes() -> Int {
        contents().reduce(0) { $0 + $1.byteCount }
    }
}

private extension DateFormatter {
    /// **Built once.** `Date.formatted(.dateTime…)` re-derives its skeleton on
    /// every call, which this project has already paid for once.
    static let clipStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()
}
