import Foundation

/// Where a custom emoji or a sticker came from.
///
/// `GET /emojis/{id}/source` and `GET /stickers/{id}/guild` are the **only**
/// routes that answer for a server the reader is not in — which is the case the
/// question is always asked about. One of your own servers' expressions can be
/// named from the resident tables; somebody else's is otherwise an anonymous
/// picture, and "a server you are not in" is a non-answer to the only question
/// the card exists for.
///
/// **One type for both**, because the answer has the same shape: a server, its
/// counts, its standing, and a strip of what else it has. The two routes differ
/// only in which strip they fill.
public enum ExpressionSource: Hashable, Sendable {
    case guild(Guild)
    /// An app's own emoji, which belongs to no server.
    case application(name: String, iconHash: String?)

    public struct Guild: Hashable, Sendable {
        public var id: GuildID
        public var name: String
        public var iconHash: String?
        public var description: String?
        public var memberCount: Int?
        public var onlineCount: Int?
        public var features: Set<String>
        /// A handful of the server's other emoji, as the emoji route sends them.
        ///
        /// Shown as a strip under the source row: a picture of what the server
        /// is *like* answers "should I care about this place" far better than a
        /// member count does.
        public var sampleEmoji: [EmojiRef]
        /// The same, from the sticker route.
        public var sampleStickers: [StickerRef]

        public init(
            id: GuildID,
            name: String,
            iconHash: String? = nil,
            description: String? = nil,
            memberCount: Int? = nil,
            onlineCount: Int? = nil,
            features: Set<String> = [],
            sampleEmoji: [EmojiRef] = [],
            sampleStickers: [StickerRef] = []
        ) {
            self.id = id
            self.name = name
            self.iconHash = iconHash
            self.description = description
            self.memberCount = memberCount
            self.onlineCount = onlineCount
            self.features = features
            self.sampleEmoji = sampleEmoji
            self.sampleStickers = sampleStickers
        }

        /// The mark beside the server's name. The route carries no boost
        /// count, so a boosted server's rosette is the plain one here.
        public var mark: GuildMark? { GuildMark(features: features) }

        /// Whether the server can be looked at by somebody who is not in it.
        ///
        /// **A private server's name and counts are not the reader's to see.**
        /// The route answers for one all the same — it is scoped to the emoji,
        /// not to the server — so the discretion is the client's to exercise,
        /// and a card that publishes a closed community's size because an emoji
        /// leaked out of it is a card doing something nobody asked it to.
        public var isPublic: Bool {
            features.contains("DISCOVERABLE") || features.contains("PREVIEW_ENABLED")
        }
    }
}
