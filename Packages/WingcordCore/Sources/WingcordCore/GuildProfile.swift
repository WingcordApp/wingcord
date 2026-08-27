import Foundation

/// A server as its **tag** advertises it — the card behind the two-to-four
/// letters people wear beside their name.
///
/// `GET /guilds/{id}/profile` is the only route that answers with an online
/// count, a description, the tag's own badge artwork and the server's traits.
/// None of it is on the guild object READY delivers, and most of it is for
/// servers the reader is not in at all, so there is nothing resident to build
/// this from.
public struct GuildProfile: Hashable, Sendable, Identifiable {
    public var id: GuildID
    public var name: String
    public var iconHash: String?
    /// The artwork behind the header. `banner_hash` where the server has the
    /// ordinary boost banner, and the tag profile's own otherwise.
    public var bannerHash: String?
    public var description: String?
    public var memberCount: Int?
    public var onlineCount: Int?
    /// The letters worn beside a name.
    public var tag: String?
    public var badgeHash: String?
    /// The two colours the tag chip is drawn in. Discord sends them as `#rrggbb`
    /// strings; they are decoded here so no surface has to parse a colour.
    public var badgeColorPrimary: UInt32?
    public var badgeColorSecondary: UInt32?
    public var traits: [GuildTrait]
    public var features: Set<String>
    public var premiumSubscriptionCount: Int
    public var premiumTier: Int

    public init(
        id: GuildID,
        name: String,
        iconHash: String? = nil,
        bannerHash: String? = nil,
        description: String? = nil,
        memberCount: Int? = nil,
        onlineCount: Int? = nil,
        tag: String? = nil,
        badgeHash: String? = nil,
        badgeColorPrimary: UInt32? = nil,
        badgeColorSecondary: UInt32? = nil,
        traits: [GuildTrait] = [],
        features: Set<String> = [],
        premiumSubscriptionCount: Int = 0,
        premiumTier: Int = 0
    ) {
        self.id = id
        self.name = name
        self.iconHash = iconHash
        self.bannerHash = bannerHash
        self.description = description
        self.memberCount = memberCount
        self.onlineCount = onlineCount
        self.tag = tag
        self.badgeHash = badgeHash
        self.badgeColorPrimary = badgeColorPrimary
        self.badgeColorSecondary = badgeColorSecondary
        self.traits = traits
        self.features = features
        self.premiumSubscriptionCount = premiumSubscriptionCount
        self.premiumTier = premiumTier
    }

    /// When the server was created. From the snowflake, so there is nothing to
    /// fetch and nothing that can disagree with the id.
    public var createdAt: Date { id.timestamp }

    /// The one standing Discord grants the server, highest first.
    ///
    /// **Ordered, not a set.** A partnered server is also a community and
    /// usually also discoverable; drawing every mark it qualifies for is three
    /// rosettes saying the same thing. Discord shows one.
    public var standing: Standing? { Standing(features: features) }

    public enum Standing: Hashable, Sendable {
        case partner
        case verified
        case discoverable
        case community

        /// The highest standing a feature set qualifies for.
        ///
        /// A static resolver as well as an instance property, because a server
        /// the reader is already in can answer this from the guild object it
        /// already holds — with no profile fetch and nothing to construct.
        public init?(features: Set<String>) {
            if features.contains("PARTNERED") { self = .partner }
            else if features.contains("VERIFIED") { self = .verified }
            else if features.contains("DISCOVERABLE") { self = .discoverable }
            else if features.contains("COMMUNITY") { self = .community }
            else { return nil }
        }

        public var label: String {
            switch self {
            case .partner: "Discord Partner"
            case .verified: "Verified"
            case .discoverable: "Discoverable Server"
            case .community: "Community Server"
            }
        }
    }
}

/// One of the four-or-five words a server describes itself with.
///
/// The emoji is either Unicode — sent as a *shortcode*, `fire` rather than 🔥,
/// which is why `emojiName` is resolved through the generated table rather than
/// drawn directly — or one of the server's own custom emoji, sent as an id.
public struct GuildTrait: Hashable, Sendable, Identifiable {
    /// Discord's own ordering field, and unique within a profile.
    public var id: Int
    public var emojiID: EmojiID?
    public var emojiName: String?
    public var emojiAnimated: Bool
    public var label: String

    public init(
        id: Int,
        emojiID: EmojiID? = nil,
        emojiName: String? = nil,
        emojiAnimated: Bool = false,
        label: String
    ) {
        self.id = id
        self.emojiID = emojiID
        self.emojiName = emojiName
        self.emojiAnimated = emojiAnimated
        self.label = label
    }

    /// The Unicode glyph for a shortcode trait, when the table knows it.
    ///
    /// Nil for a custom-emoji trait — that one has a picture — and nil for a
    /// shortcode the table has never heard of, where drawing the bare word
    /// `black_cat` beside "Animal Crossing" would be worse than drawing nothing.
    public var glyph: String? {
        guard emojiID == nil, let emojiName else { return nil }
        return UnicodeEmoji.glyph(for: emojiName)
    }
}
