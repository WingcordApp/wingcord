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
    /// The four letters this server lends its members, and the badge beside
    /// them — `guild.profile.tag` and `guild.profile.badge` on the wire.
    ///
    /// **It arrives in READY and was being dropped.** Discord's own client
    /// builds the "choose a server tag" list from exactly this and asks no
    /// route for it: `guild?.profile?.tag != null` is the whole eligibility
    /// test in its bundle. A client that did not decode it could only discover
    /// a tag by fetching `/guilds/{id}/profile` once per server.
    public var tag: String?
    public var tagBadgeHash: String?
    /// Members Discord reports, when it reports any.
    public var memberCount: Int?
    /// The rules channel, for a community guild.
    public var rulesChannelID: ChannelID?
    /// The Community Updates channel, where Discord posts to moderators.
    public var publicUpdatesChannelID: ChannelID?
    /// Where the server parks members who have gone idle in voice.
    ///
    /// **Nobody in it is counted as being in voice.** Discord's rail chip and
    /// the tile's own mark both skip this channel (modules `24594` and
    /// `34162`): somebody moved here for being away is not in a conversation,
    /// and on a busy server the room can hold dozens of them.
    public var afkChannelID: ChannelID?
    /// Whether this guild's member list can be fetched over the lazy-load
    /// subscription. Large guilds only send members on request.
    public var isLarge: Bool
    /// What this server tells a member who has set nothing of their own.
    ///
    /// **The floor under every notification decision here** — see
    /// `NotificationPolicy.resolvedLevel`. Most large servers set Only
    /// @mentions, and a client that assumed All Messages would notify on every
    /// line of a channel with four hundred thousand people in it.
    public var defaultMessageNotifications: NotificationLevel = .allMessages
    /// When the reader joined, off READY's own guild object.
    ///
    /// **The fallback read cursor for a channel that has none**, which is the
    /// one thing that stops the inbox showing a server's history from before
    /// the reader was in it. See `AppModel.unreadInboxChannels`.
    public var joinedAt: Date?
    /// The server's own theme, as it arrived — on or off. See `GuildTheme`.
    public var theme: GuildTheme?
    /// The owner marked the whole server age-restricted.
    ///
    /// Discord's `owner_configured_content_level` of explicit or age-restricted
    /// (1 or 3) — its client's test for a server whose channels are never
    /// summarised (module `260509`).
    public var isAgeRestricted: Bool
    /// What the server asks of an account before it may talk — and before it
    /// may apply: Discord's application form reads it to decide which of its
    /// two verification rows to show (`823591`). Nil where the payload did not
    /// carry it, which asks for nothing rather than guessing.
    public var verificationLevel: VerificationLevel?

    /// The mark beside the server's name — see `GuildMark`.
    public var mark: GuildMark? {
        GuildMark(features: features, boostTier: premiumTier, boostCount: premiumSubscriptionCount)
    }

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
        tag: String? = nil,
        tagBadgeHash: String? = nil,
        memberCount: Int? = nil,
        rulesChannelID: ChannelID? = nil,
        publicUpdatesChannelID: ChannelID? = nil,
        afkChannelID: ChannelID? = nil,
        isLarge: Bool = false,
        defaultMessageNotifications: NotificationLevel = .allMessages,
        joinedAt: Date? = nil,
        theme: GuildTheme? = nil,
        isAgeRestricted: Bool = false,
        verificationLevel: VerificationLevel? = nil
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
        self.tag = tag
        self.tagBadgeHash = tagBadgeHash
        self.memberCount = memberCount
        self.rulesChannelID = rulesChannelID
        self.publicUpdatesChannelID = publicUpdatesChannelID
        self.afkChannelID = afkChannelID
        self.isLarge = isLarge
        self.defaultMessageNotifications = defaultMessageNotifications
        self.joinedAt = joinedAt
        self.theme = theme
        self.isAgeRestricted = isAgeRestricted
        self.verificationLevel = verificationLevel
    }

    public var hasAnimatedIcon: Bool { iconHash?.hasPrefix("a_") ?? false }

    /// Whether this server lends its members a tag they can wear.
    ///
    /// **The tag being present is the test, not the feature flag.** Discord's
    /// own client asks `guild?.profile?.tag != null` — `GUILD_TAGS` says the
    /// server is *allowed* one, which is not the same as having set one, and
    /// gating on the flag would offer empty rows for servers with nothing to
    /// wear.
    public var offersTag: Bool { tag?.isEmpty == false }

    /// The initials drawn on a tile when a guild has no icon.
    ///
    /// Discord takes the first letter of each word, which is why "The Iris
    /// Project" reads "TIP" and not "Th". Capped at four so a long name does not
    /// overflow a 44pt tile.
    public var monogram: String { Self.monogram(of: name) }

    /// The same letters for a server known only by its name — an invite's.
    public static func monogram(of name: String) -> String {
        let letters = name
            .split(separator: " ", omittingEmptySubsequences: true)
            .compactMap(\.first)
            .prefix(4)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

/// One entry of the rail, from the client's own settings: a folder, or a
/// server sitting loose.
///
/// `id` is optional because Discord genuinely sends entries with no id, and
/// that is how the settings payload represents a server loose in the rail —
/// see `GuildArrangement`.
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

    /// Whether this entry is a folder rather than a loose server.
    ///
    /// **The id decides, not the count.** Discord draws an entry with an id as
    /// a folder even when it holds one server (`711014`'s `N`) — which is what
    /// a folder is after everything else has been dragged out of it, and what
    /// a captured account had sitting in its rail.
    public var isRealFolder: Bool { id != nil }
}
