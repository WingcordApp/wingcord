import Foundation

/// A server.
///
/// Channels, roles and members are NOT stored here. They live in the store's own
/// tables keyed by id, for one reason that decides the whole shape: a single
/// inbound message rewrites a channel's `lastMessageID`, and if channels were an
/// array on `Guild` then that write would copy the entire guild — every role,
/// every channel — several times a second, and invalidate every view observing
/// any part of it. Keeping the tables flat means the write touches one entry.
public struct Guild: Hashable, Sendable, Identifiable, Codable {
    public var id: GuildID
    public var name: String
    public var iconHash: String?
    public var bannerHash: String?
    public var splashHash: String?
    public var ownerID: UserID
    /// Discord's boost tier, 0-3. Decides whether the guild can have a banner.
    public var premiumTier: Int
    public var premiumSubscriptionCount: Int
    /// Feature flags, as Discord's uppercase strings. A `Set` because every read
    /// is a membership test.
    public var features: Set<String>
    /// Members Discord reports, when it reports any.
    public var memberCount: Int?
    /// The rules channel, for a community guild.
    public var rulesChannelID: ChannelID?
    /// Whether this guild's member list can be fetched over the lazy-load
    /// subscription. Large guilds only send members on request.
    public var isLarge: Bool

    public init(
        id: GuildID,
        name: String,
        iconHash: String? = nil,
        bannerHash: String? = nil,
        splashHash: String? = nil,
        ownerID: UserID,
        premiumTier: Int = 0,
        premiumSubscriptionCount: Int = 0,
        features: Set<String> = [],
        memberCount: Int? = nil,
        rulesChannelID: ChannelID? = nil,
        isLarge: Bool = false
    ) {
        self.id = id
        self.name = name
        self.iconHash = iconHash
        self.bannerHash = bannerHash
        self.splashHash = splashHash
        self.ownerID = ownerID
        self.premiumTier = premiumTier
        self.premiumSubscriptionCount = premiumSubscriptionCount
        self.features = features
        self.memberCount = memberCount
        self.rulesChannelID = rulesChannelID
        self.isLarge = isLarge
    }

    public var hasAnimatedIcon: Bool { iconHash?.hasPrefix("a_") ?? false }

    /// The initials drawn on a tile when a guild has no icon.
    ///
    /// Discord takes the first letter of each word, which is why "The Iris
    /// Project" reads "TIP" and not "Th". Capped at four so a long name does not
    /// overflow a 44pt tile.
    public var monogram: String {
        let letters = name
            .split(separator: " ", omittingEmptySubsequences: true)
            .compactMap(\.first)
            .prefix(4)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

/// A user-created folder in the guild rail, from the client's own settings.
///
/// `id` is optional because Discord genuinely sends folders with no id: a
/// single-guild "folder" is how the settings payload represents a guild sitting
/// loose in the rail. Those are unwrapped into bare guild entries rather than
/// drawn as one-item folders.
public struct GuildFolder: Hashable, Sendable, Codable {
    public var id: UInt64?
    public var name: String?
    /// Discord's colour integer, or nil for the default.
    public var colorValue: UInt32?
    public var guildIDs: [GuildID]

    public init(
        id: UInt64? = nil,
        name: String? = nil,
        colorValue: UInt32? = nil,
        guildIDs: [GuildID]
    ) {
        self.id = id
        self.name = name
        self.colorValue = colorValue
        self.guildIDs = guildIDs
    }

    /// Whether this entry is a real folder or a single guild wearing one.
    public var isRealFolder: Bool { id != nil && guildIDs.count > 1 }
}
