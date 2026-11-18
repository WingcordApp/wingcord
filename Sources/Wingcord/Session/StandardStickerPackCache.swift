import Foundation
import WingcordCore

/// Discord's own sticker packs as last fetched, kept on disk so the picker has
/// them the moment it opens (`SessionController.loadDefaultStickerPacks`).
///
/// In Caches beside the image cache: it is Discord's answer, not the reader's
/// data, and losing it costs one request.
nonisolated struct StandardStickerPackCache: Sendable {
    /// How long an answer stands before the network is asked again. The set
    /// changes about twice a year; a day keeps a new pack at most a day late.
    static let interval: TimeInterval = 24 * 3600

    var file: URL = ImageStore.cacheDirectory
        .deletingLastPathComponent()
        .appending(path: "sticker-packs.json")

    struct Stored: Codable, Sendable {
        var fetchedAt: Date
        var packs: [StickerPack]
    }

    func read() -> Stored? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    func write(_ packs: [StickerPack], now: Date = .now) {
        guard let data = try? JSONEncoder().encode(Stored(fetchedAt: now, packs: packs)) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: file, options: .atomic)
    }

    func isStale(_ stored: Stored, now: Date = .now) -> Bool {
        now.timeIntervalSince(stored.fetchedAt) >= Self.interval
    }
}
