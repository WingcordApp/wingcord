import Foundation

// MARK: - What a server keeps in its expression drawers
//
// `EmojiRef` and `StickerRef` are what a *message* carries: an id, a name, and
// whether it moves. Enough to draw the picture, and deliberately nothing else.
//
// The three management pages need the other half — who uploaded it, which roles
// may use it, whether it still works, and how many slots are left. None of that
// is on a message and all of it is on `GET /guilds/{id}/emojis`, which answers
// with a whole user object per entry.

/// One of a server's custom emoji, as its own page lists it.
public struct GuildEmoji: Hashable, Sendable, Identifiable {
    public var id: EmojiID
    public var name: String
    public var isAnimated: Bool
    /// Absent on the response to a *create* — Discord echoes the emoji without
    /// the uploader, because the uploader is whoever asked. The page fills it in
    /// from the account rather than re-fetching the list.
    public var uploader: UserID?
    /// The roles allowed to use it. Empty means everybody, which is the ordinary
    /// case; a non-empty list is a boosted server's role-locked emoji.
    public var roleIDs: [RoleID]
    /// False where the server lost the boosts that paid for the slot. The emoji
    /// stays, and nothing can type it.
    public var isAvailable: Bool
    /// True for an emoji an integration owns — a Twitch subscriber emote. Those
    /// cannot be renamed or deleted through this route, so the page offers
    /// neither rather than offering both and answering 403.
    public var isManaged: Bool

    public init(
        id: EmojiID,
        name: String,
        isAnimated: Bool = false,
        uploader: UserID? = nil,
        roleIDs: [RoleID] = [],
        isAvailable: Bool = true,
        isManaged: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isAnimated = isAnimated
        self.uploader = uploader
        self.roleIDs = roleIDs
        self.isAvailable = isAvailable
        self.isManaged = isManaged
    }

    /// What the composer would type. The management page shows it beside the
    /// name, because `:name:` is the only part of an emoji anybody memorises.
    public var shortcode: String { ":\(name):" }

    public var reference: EmojiRef {
        EmojiRef(id: id, name: name, isAnimated: isAnimated)
    }
}

/// One of a server's stickers.
public struct GuildSticker: Hashable, Sendable, Identifiable {
    public var id: UInt64
    public var name: String
    public var description: String?
    /// The related emoji.
    ///
    /// **A literal Unicode glyph, not a shortcode.** The capture sends `"💯"`
    /// in the multipart `tags` field and gets `"💯"` back — not `:100:`, which
    /// is what the upload sheet's own field displays. A client that sent the
    /// shortcode would create a sticker nobody's suggestion bar could match.
    public var relatedEmoji: String?
    public var format: StickerRef.Format
    public var uploader: UserID?
    public var isAvailable: Bool

    public init(
        id: UInt64,
        name: String,
        description: String? = nil,
        relatedEmoji: String? = nil,
        format: StickerRef.Format = .png,
        uploader: UserID? = nil,
        isAvailable: Bool = true
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.relatedEmoji = relatedEmoji
        self.format = format
        self.uploader = uploader
        self.isAvailable = isAvailable
    }

    public var artworkURL: URL? { CDN.sticker(id: id, format: format) }
}

// MARK: - Slots
//
// Every expression page states a budget, and all three budgets are functions of
// the boost tier alone. Written once, here, because the numbers appear in a
// heading ("7 Slots of 8 available"), in a disabled Upload button and in the
// sheet's own footer — and three copies of a table is how one of them keeps
// last year's numbers.

public enum ExpressionSlots {
    /// Static emoji per tier. Animated emoji have a budget of the same size and
    /// are counted separately, which is why the page says "50 slots" twice.
    public static func emoji(premiumTier: Int) -> Int {
        switch premiumTier {
        case 1: 100
        case 2: 150
        case 3: 250
        default: 50
        }
    }

    public static func stickers(premiumTier: Int) -> Int {
        switch premiumTier {
        case 1: 15
        case 2: 30
        case 3: 60
        default: 5
        }
    }

    public static func soundboard(premiumTier: Int) -> Int {
        switch premiumTier {
        case 1: 24
        case 2: 36
        case 3: 48
        default: 8
        }
    }

    /// The upload ceiling Discord's own sheet states, in bytes.
    ///
    /// Stated rather than enforced: the route is the authority and refuses
    /// oversized uploads itself. What this is for is the line under the file
    /// picker, so somebody choosing a file learns the limit before the upload
    /// rather than after it.
    public static let emojiByteLimit = 256 * 1024
    public static let stickerByteLimit = 512 * 1024
    public static let soundByteLimit = 512 * 1024
}

// MARK: - Uploads
//
// Three routes, three encodings, and the differences are not guessable from each
// other — every one of them is a captured fact:
//
//   - **Emoji** is JSON with a `data:image/png;base64,…` URI. The reference
//     client re-encodes whatever was chosen to PNG when it crops, so a JPEG that
//     was never cropped still goes up as PNG.
//   - **Soundboard** is JSON with a `data:audio/ogg;base64,…` URI and a float
//     volume.
//   - **Stickers** are `multipart/form-data`. The only multipart route in this
//     whole client.

/// An image on its way to Discord, as the two JSON routes want it.
///
/// Discord's "image data" is a data URI — the whole `data:<mime>;base64,` prefix
/// included, not the bare payload. Getting that wrong answers a 400 whose message
/// names the *field* rather than the encoding, which is a long afternoon.
public struct ImageData: Hashable, Sendable {
    public var mimeType: String
    public var bytes: Data

    public init(mimeType: String, bytes: Data) {
        self.mimeType = mimeType
        self.bytes = bytes
    }

    public var dataURI: String {
        "data:\(mimeType);base64,\(bytes.base64EncodedString())"
    }

    public static func png(_ bytes: Data) -> ImageData {
        ImageData(mimeType: "image/png", bytes: bytes)
    }

    public static func gif(_ bytes: Data) -> ImageData {
        ImageData(mimeType: "image/gif", bytes: bytes)
    }

    public static func ogg(_ bytes: Data) -> ImageData {
        ImageData(mimeType: "audio/ogg", bytes: bytes)
    }
}

// MARK: - Games
//
// The Server Profile page's "What games does your server play?" — a search field
// and a grid of covers. Two routes behind it, and the second one is the reason
// this type is as thin as it is.

/// A game, as the Server Profile page needs it.
///
/// **Four fields out of thirty.** `GET /games?game_ids=…` answers with the whole
/// catalogue entry — a paragraph of description, every executable on every
/// platform, third-party store SKUs — and a capture of four games came back at
/// 128 KB. The page draws a cover and a name, so those are what is kept; the
/// rest is decoded and dropped rather than stored on a value the profile editor
/// holds in memory while somebody types.
public struct GameSummary: Hashable, Sendable, Identifiable {
    public var id: ApplicationID
    public var name: String
    public var iconHash: String?
    /// A picture named by a whole address rather than a hash — the
    /// autocomplete's `{"type":"url"}`, which is how a mobile game's store art
    /// arrives.
    public var externalIconURL: URL?

    public init(id: ApplicationID, name: String, iconHash: String? = nil, externalIconURL: URL? = nil) {
        self.id = id
        self.name = name
        self.iconHash = iconHash
        self.externalIconURL = externalIconURL
    }

    /// The cover, at the size the grid draws it.
    public var iconURL: URL? {
        iconHash.flatMap { CDN.applicationIcon(id: id, hash: $0, side: 72) } ?? externalIconURL
    }
}
