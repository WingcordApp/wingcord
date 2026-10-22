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
    /// What the sidecar says — who was there, which track is whose. Nil for a
    /// file this app did not write.
    var manifest: ClipManifest?
    /// A capture bar recording — a `.wingcordtake` package — and what it holds.
    var take: TakeManifest?

    var isRecording: Bool { url.pathExtension == TakeManifest.pathExtension }

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
        // `--demo` keeps its own, beside the real one rather than in it: a
        // demo's clips and self-tests are not the reader's.
        let name = LaunchOptions.current.usesDemoFixtures ? "Wingcord Demo Clips" : "Wingcord Clips"
        return movies.appendingPathComponent(name, isDirectory: true)
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
        contents(of: folder)
    }

    /// Auto Clips waiting to be kept or thrown away (docs/CLIPS-PRESENCE.md,
    /// Phase 7.2): `.wingcord/auto-review` inside the clips folder — out of
    /// the library and of Finder's sight until the reader keeps one.
    static var reviewFolder: URL {
        folder.appendingPathComponent(".wingcord", isDirectory: true)
            .appendingPathComponent("auto-review", isDirectory: true)
    }

    /// The Auto Clips waiting for the reader, newest first.
    static func reviewContents() -> [Clip] {
        contents(of: reviewFolder)
    }

    /// Keeps an Auto Clip: into the library, its sidecar with it.
    @discardableResult
    static func keep(_ clip: Clip) throws -> URL {
        let destination = availableURL(
            in: folder, named: clip.url.deletingPathExtension().lastPathComponent,
            extension: clip.url.pathExtension
        )
        try FileManager.default.moveItem(at: clip.url, to: destination)
        let sidecar = manifestURL(for: clip.url)
        if FileManager.default.fileExists(atPath: sidecar.path) {
            let kept = manifestURL(for: destination)
            try? FileManager.default.createDirectory(
                at: kept.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? FileManager.default.moveItem(at: sidecar, to: kept)
        }
        return destination
    }

    private static func contents(of folder: URL) -> [Clip] {
        let keys: Set<URLResourceKey> = [.creationDateKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        return entries.compactMap { url -> Clip? in
            let ext = url.pathExtension.lowercased()
            let values = try? url.resourceValues(forKeys: keys)
            if ext == TakeManifest.pathExtension {
                return Clip(
                    url: url,
                    created: values?.creationDate ?? .distantPast,
                    byteCount: packageBytes(url),
                    isScreenshot: false,
                    take: take(in: url)
                )
            }
            guard ext == "mp4" || ext == "png" else { return nil }
            return Clip(
                url: url,
                created: values?.creationDate ?? .distantPast,
                byteCount: values?.fileSize ?? 0,
                isScreenshot: ext == "png",
                manifest: manifest(for: url)
            )
        }
        .sorted { $0.created > $1.created }
    }

    static func delete(_ clip: Clip) throws {
        try FileManager.default.removeItem(at: clip.url)
        try? FileManager.default.removeItem(at: manifestURL(for: clip.url))
    }

    /// `name.ext` in `folder`, or `name 2.ext`, `name 3.ext`… — never over
    /// a file that is there. Two saves in the same second share a stamp.
    static func availableURL(in folder: URL, named name: String, extension pathExtension: String) -> URL {
        var candidate = folder.appendingPathComponent(name).appendingPathExtension(pathExtension)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name) \(number)").appendingPathExtension(pathExtension)
            number += 1
        }
        return candidate
    }

    // MARK: What a clip knows

    /// **Beside the file, out of sight**: `.wingcord/<file name>.json` in the
    /// clip's own folder, so the folder in Finder is only the clips, and a
    /// clip moved with its folder keeps what it knows. Discord keeps the same
    /// facts in its own store; a folder anybody can open has to carry them
    /// itself.
    static func manifestURL(for clip: URL) -> URL {
        clip.deletingLastPathComponent()
            .appendingPathComponent(".wingcord", isDirectory: true)
            .appendingPathComponent(clip.lastPathComponent)
            .appendingPathExtension("json")
    }

    static func writeManifest(_ manifest: ClipManifest, for clip: URL) {
        let url = manifestURL(for: clip)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: url, options: .atomic)
        } catch {
            // The clip is saved either way; what it knows is a bonus.
        }
    }

    // MARK: Favourites

    /// Discord's Add to Favorites, kept with the folder — `.wingcord/library.json`
    /// — so a favourite stays one when the folder moves, by file name.
    private struct Index: Codable {
        var favourites: [String] = []
    }

    private static var indexURL: URL {
        folder.appendingPathComponent(".wingcord", isDirectory: true).appendingPathComponent("library.json")
    }

    static func favourites() -> Set<String> {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data)
        else { return [] }
        return Set(index.favourites)
    }

    static func setFavourites(_ names: Set<String>) {
        let index = Index(favourites: names.sorted())
        try? FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
    }

    /// A recording's own description, inside its package.
    static func take(in package: URL) -> TakeManifest? {
        guard let data = try? Data(contentsOf: package.appendingPathComponent(TakeManifest.fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TakeManifest.self, from: data)
    }

    /// Writes a recording's description back — its edits, after the editor.
    static func writeTake(_ take: TakeManifest, in package: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(take).write(to: package.appendingPathComponent(TakeManifest.fileName), options: .atomic)
    }

    /// Everything inside a package, for the size the list shows.
    private static func packageBytes(_ package: URL) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: package, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func manifest(for clip: URL) -> ClipManifest? {
        guard let data = try? Data(contentsOf: manifestURL(for: clip)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ClipManifest.self, from: data)
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
