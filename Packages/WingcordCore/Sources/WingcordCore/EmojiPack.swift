import Foundation

/// One of Discord's Nitro Emoji Packs (Anime, Happy Feet, Little Guys, Meow
/// Squad, Skelly…): a set of custom emoji that belongs to no server, usable
/// with Nitro once added to the picker (docs/ACTIVITIES-CALLS-PICKER.md,
/// decision 16). `GET /emoji-packs`; the picks are `pinned_emoji_packs`.
public struct EmojiPack: Hashable, Sendable, Identifiable {
    public var id: UInt64
    public var name: String
    public var description: String?
    /// False where Discord has retired it or the account can't have it.
    public var isAvailable: Bool
    /// The emoji that stands for the pack on the rail and its card.
    public var representativeEmojiID: UInt64?
    public var emojis: [Emoji]

    public struct Emoji: Hashable, Sendable, Identifiable {
        public var id: UInt64
        public var name: String
        public var isAnimated: Bool
        public var isAvailable: Bool

        public init(id: UInt64, name: String, isAnimated: Bool, isAvailable: Bool = true) {
            self.id = id
            self.name = name
            self.isAnimated = isAnimated
            self.isAvailable = isAvailable
        }

        /// What a message carries to show it, as any custom emoji.
        public var messageToken: String { "<\(isAnimated ? "a" : ""):\(name):\(id)>" }
    }

    public init(
        id: UInt64, name: String, description: String? = nil, isAvailable: Bool = true,
        representativeEmojiID: UInt64? = nil, emojis: [Emoji]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isAvailable = isAvailable
        self.representativeEmojiID = representativeEmojiID
        self.emojis = emojis
    }

    /// The pack's face: its representative emoji, else its first.
    public var cover: Emoji? {
        emojis.first { $0.id == representativeEmojiID } ?? emojis.first
    }
}
