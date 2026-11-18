import Foundation

/// One of Discord's own sticker packs — the standard sets, grouped by
/// character.
///
/// A server's stickers arrive on the guild object; these do not belong to any
/// server and have to be fetched. They are the same for every account, which is
/// why the picker keeps them for the life of the process rather than per
/// channel.
public struct StickerPack: Hashable, Sendable, Identifiable, Codable {
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

/// One sticker as `GET /stickers/{id}` describes it — what a message does not.
///
/// **A message's `sticker_items` carry an id, a name and a format, and nothing
/// that says whose sticker it is.** One of Discord's own and a server's look
/// identical there, which is how a stock sticker came to be described as "a
/// custom sticker from a server you are not in". This route answers `type`
/// (1 is Discord's, 2 a server's) and, for Discord's, the pack. Captured,
/// `stock stickers.har`.
public struct StickerDetail: Hashable, Sendable {
    public var sticker: StickerRef
    /// The pack a standard sticker belongs to. Nil for a server's sticker.
    public var packID: String?
    /// The server that owns it, when the route names one.
    public var guildID: GuildID?
    /// Whether it is one of Discord's own — `type` 1.
    public var isStandard: Bool

    public init(sticker: StickerRef, packID: String?, guildID: GuildID?, isStandard: Bool) {
        self.sticker = sticker
        self.packID = packID
        self.guildID = guildID
        self.isStandard = isStandard
    }
}
