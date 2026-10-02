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

    // MARK: The editor's half
    //
    // Five fields the *reader's* card never needed and the Server Profile page
    // cannot write without. They are here rather than on a second type because
    // `PATCH /guilds/{id}/profile` sends the whole page every time — see the
    // captures — so a client holding half the object can only write half of it,
    // and the other half would go back as whatever the encoder defaulted to.

    /// The **Banner** swatch, and not a banner at all.
    ///
    /// The grid of ten gradient tiles on the Server Profile page writes this
    /// one hex string — picking the pink tile sent `"brand_color_primary":
    /// "#ff1c90"`. The uploaded artwork behind a tag is `customBannerHash`, and
    /// the boost banner is `bannerHash`; three different things, and the one the
    /// page labels "Banner" is this.
    public var brandColorPrimary: UInt32?
    /// `GuildVisibility` — 1 public, 2 restricted, 3 public with recruitment.
    /// The page's "Private Profile" switch is 1 ⇄ 2.
    public var visibility: Int
    /// Which badge shape the tag wears. See `GuildBadge`.
    public var badge: Int
    /// The tag profile's own uploaded header, kept apart from `bannerHash` so
    /// the editor knows which of the two it is allowed to replace.
    public var customBannerHash: String?
    /// The games the server says it plays, in the order the page lists them.
    public var gameApplicationIDs: [ApplicationID]
    /// How busy each of those games is in this server.
    ///
    /// **`game_activity` on the wire, and nothing read it.** It is what decides
    /// the little flame on a game's icon — see `GuildGameActivity`.
    public var gameActivity: [ApplicationID: GuildGameActivity]

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
        premiumTier: Int = 0,
        brandColorPrimary: UInt32? = nil,
        visibility: Int = 1,
        badge: Int = 0,
        customBannerHash: String? = nil,
        gameApplicationIDs: [ApplicationID] = [],
        gameActivity: [ApplicationID: GuildGameActivity] = [:]
    ) {
        self.brandColorPrimary = brandColorPrimary
        self.visibility = visibility
        self.badge = badge
        self.customBannerHash = customBannerHash
        self.gameApplicationIDs = gameApplicationIDs
        self.gameActivity = gameActivity
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

    /// Whether the profile is hidden from non-members — the "Private Profile"
    /// switch. Named rather than compared to a literal, because 2 meaning
    /// *private* while 1 and 3 both mean public is not a thing to re-derive at
    /// a call site.
    public var isPrivateProfile: Bool { visibility == 2 }

    /// Whether the server may wear a tag at all.
    public var canSetTag: Bool { features.contains("GUILD_TAGS") }

    /// The mark beside the server's name — see `GuildMark`.
    public var mark: GuildMark? {
        GuildMark(features: features, boostTier: premiumTier, boostCount: premiumSubscriptionCount)
    }
}

/// The shape on a server tag's badge.
///
/// Four packs Discord sells, plus ten originals, and **eleven retired values in
/// the middle of the range**. 10 through 20 can no longer be chosen and are
/// still worn by servers that chose them before they went — so the reader's side
/// must know all of them and the picker must offer only the live ones. One
/// table, two audiences, and `selectable` is the only place the difference is
/// written.
public enum GuildBadge: Hashable, Sendable, Identifiable, CaseIterable {
    case sword, waterDrop, skull, toadstool, moon, lightning, leaf, heart, fire, compass
    case bunny, dog, frog, goat, cat, diamond, crown, trophy, moneyBag, dollarSign
    case clover, blossom, pottedPlant, maple, wiltedFlower, butterfly, snail, caterpillar
    case spider, bee

    public var id: Int { rawValue }

    public init?(rawValue: Int) {
        guard let match = Self.allCases.first(where: { $0.rawValue == rawValue }) else {
            return nil
        }
        self = match
    }

    public var rawValue: Int {
        switch self {
        case .sword: 0
        case .waterDrop: 1
        case .skull: 2
        case .toadstool: 3
        case .moon: 4
        case .lightning: 5
        case .leaf: 6
        case .heart: 7
        case .fire: 8
        case .compass: 9
        case .bunny: 21
        case .dog: 22
        case .frog: 23
        case .goat: 24
        case .cat: 25
        case .diamond: 26
        case .crown: 27
        case .trophy: 28
        case .moneyBag: 29
        case .dollarSign: 30
        case .clover: 31
        case .blossom: 32
        case .pottedPlant: 33
        case .maple: 34
        case .wiltedFlower: 35
        case .butterfly: 36
        case .snail: 37
        case .caterpillar: 38
        case .spider: 39
        case .bee: 40
        }
    }

    /// Which pack the badge belongs to. The picker groups by it, because thirty
    /// unlabelled shapes in one grid is a wall.
    public var pack: Pack {
        switch self {
        case .sword, .waterDrop, .skull, .toadstool, .moon,
             .lightning, .leaf, .heart, .fire, .compass:
            .original
        case .bunny, .dog, .frog, .goat, .cat:
            .pets
        case .diamond, .crown, .trophy, .moneyBag, .dollarSign:
            .flex
        case .clover, .blossom, .pottedPlant, .maple, .wiltedFlower:
            .plant
        case .butterfly, .snail, .caterpillar, .spider, .bee:
            .creepyCrawlies
        }
    }

    public enum Pack: Hashable, Sendable, CaseIterable, Identifiable {
        case original, pets, flex, plant, creepyCrawlies

        public var id: Self { self }

        public var title: String {
            switch self {
            case .original: "Classic"
            case .pets: "Pets"
            case .flex: "Flex"
            case .plant: "Plants"
            case .creepyCrawlies: "Creepy Crawlies"
            }
        }

        /// The guild feature that unlocks it. Nil for the ten every server has.
        public var feature: String? {
            switch self {
            case .original: nil
            case .pets: "GUILD_TAGS_BADGE_PACK_PETS"
            case .flex: "GUILD_TAGS_BADGE_PACK_FLEX"
            case .plant: "GUILD_TAGS_BADGE_PACK_PLANT"
            case .creepyCrawlies: "GUILD_TAGS_BADGE_PACK_CREEPY_CRAWLIES"
            }
        }
    }

    /// Whether a server holding these features may choose this badge.
    public func isAvailable(features: Set<String>) -> Bool {
        guard let required = pack.feature else { return true }
        return features.contains(required)
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

    /// The trait's emoji as every other emoji is carried — a custom one's
    /// picture, or a shortcode's glyph — and nil where neither can be drawn.
    public var emoji: EmojiRef? {
        if let emojiID {
            return EmojiRef(id: emojiID, name: emojiName ?? "", isAnimated: emojiAnimated)
        }
        return glyph.map { EmojiRef(name: $0) }
    }
}


/// How busy one game is inside one server.
///
/// `{"activity_level": 2, "activity_score": 29697}` — captured on every server
/// profile that names a game, and read by nothing until now.
public struct GuildGameActivity: Hashable, Sendable {
    public var level: Int
    public var score: Int

    public init(level: Int, score: Int) {
        self.level = level
        self.score = score
    }

    /// Whether the icon wears a flame.
    ///
    /// **Two captures, both level 2, both with a flame** — the Wooting server's
    /// twelve games and Counter-Strike's one. Level 0 and level 1 have never
    /// been seen, so the threshold is the conservative one: a level this client
    /// has no evidence for draws no flame, where the other direction would put a
    /// "busy here" mark on a game nobody plays.
    ///
    /// If a server ever shows a game with no flame beside one that has it, that
    /// is the capture that settles where the line actually is.
    public var isHot: Bool { level >= 2 }
}
