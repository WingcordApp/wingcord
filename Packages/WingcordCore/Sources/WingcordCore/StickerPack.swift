import Foundation

/// One of Discord's own sticker packs — the standard sets, grouped by
/// character.
///
/// A server's stickers arrive on the guild object; these do not belong to any
/// server and have to be fetched. They are the same for every account, which is
/// why the picker keeps them for the life of the process rather than per
/// channel.
public struct StickerPack: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The sticker that stands for the pack on the rail. Discord names one; the
    /// first is the fallback, because a pack with no face is a blank icon.
    public var coverStickerID: UInt64
    public var stickers: [StickerRef]

    public init(id: String, name: String, coverStickerID: UInt64, stickers: [StickerRef]) {
        self.id = id
        self.name = name
        self.coverStickerID = coverStickerID
        self.stickers = stickers
    }
}
