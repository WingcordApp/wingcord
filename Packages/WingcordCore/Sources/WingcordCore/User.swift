import Foundation

/// A Discord account, as this client stores it.
///
/// **Every rarely-present field lives behind `decoration`, and that is a memory
/// decision made once rather than a shape that grew.** A `User` is held for
/// every author in every loaded page, every roster row, every reaction, every
/// mention — tens of thousands in a busy session. Inlining the cosmetics (avatar
/// decoration, nameplate, banner, accent, bio) costs those bytes on all of them
/// to serve the handful that have any. Behind one optional class reference the
/// cost is 8 bytes for a user with none, which is nearly all of them.
public struct User: Hashable, Sendable, Identifiable, Codable {
    public var id: UserID
    /// The account name. Unique, lowercase, no discriminator on migrated
    /// accounts.
    public var username: String
    /// The chosen display name, which is what the UI shows when present.
    /// Discord calls this `global_name`.
    public var displayName: String?
    /// The avatar hash, not a URL. A hash is 32 bytes of hex; the URL built from
    /// it is 90-odd bytes and depends on the size being requested, so storing
    /// the URL would either fix the size at store time or store several.
    public var avatarHash: String?
    /// The legacy four-digit discriminator. `"0"` on a migrated account, which
    /// is how a migrated account is recognised.
    public var discriminator: String
    public var flags: UserFlags
    public var isBot: Bool
    public var isSystem: Bool
    /// Cosmetics and profile extras. Nil for the overwhelming majority.
    public var decoration: UserDecoration?

    public init(
        id: UserID,
        username: String,
        displayName: String? = nil,
        avatarHash: String? = nil,
        discriminator: String = "0",
        flags: UserFlags = [],
        isBot: Bool = false,
        isSystem: Bool = false,
        decoration: UserDecoration? = nil
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.avatarHash = avatarHash
        self.discriminator = discriminator
        self.flags = flags
        self.isBot = isBot
        self.isSystem = isSystem
        self.decoration = decoration
    }

    /// What to show wherever a person is named with no server context.
    ///
    /// A server nickname beats this, and resolving that needs the guild — see
    /// `Member.resolvedName`. This is the fallback and the DM answer.
    public var preferredName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return username
    }

    /// The handle, in the form Discord shows it. Migrated accounts have no
    /// discriminator and are written bare.
    public var handle: String {
        discriminator == "0" || discriminator.isEmpty
            ? username
            : "\(username)#\(discriminator)"
    }

    /// The letter shown while an avatar loads, or forever if there is none.
    ///
    /// Derived from the *preferred* name rather than the username, so it matches
    /// the label beside it. Unicode-correct: `first` yields a grapheme cluster,
    /// so an emoji or a combined character is one letter and not half of one.
    public var monogram: String {
        preferredName.first.map { String($0).uppercased() } ?? "?"
    }

    /// Whether this account has an animated avatar. The hash carries the answer:
    /// Discord prefixes animated assets with `a_`.
    public var hasAnimatedAvatar: Bool {
        avatarHash?.hasPrefix("a_") ?? false
    }

    /// The default avatar Discord serves for an account with none.
    ///
    /// Migrated accounts index by `(id >> 22) % 6`, legacy ones by
    /// `discriminator % 5`. Getting this wrong is not a crash — it is everyone
    /// without an avatar sharing one colour, which reads as a bug in the roster.
    public var defaultAvatarIndex: Int {
        if discriminator == "0" || discriminator.isEmpty {
            return Int((id.rawValue >> 22) % 6)
        }
        return (Int(discriminator) ?? 0) % 5
    }
}

/// One account badge, as the profile route describes it.
///
/// **Named artwork, not a symbol.** The flag bits on a `User` can be turned into
/// a rough SF Symbol each, but they cover only the handful of badges Discord has
/// had longest — every Nitro tier, every guild-boost month and every seasonal
/// mark is invisible to them. The profile route answers with the real list, and
/// this is what carries it.
public struct AccountBadge: Hashable, Sendable, Codable {
    public let id: String
    /// The CDN hash of the artwork. Nil for a badge the route named without one.
    public let iconHash: String?
    /// What the badge means, in Discord's own words. This is the hover text.
    public let label: String

    public init(id: String, iconHash: String?, label: String) {
        self.id = id
        self.iconHash = iconHash
        self.label = label
    }
}

/// An account linked to a Discord profile — Steam, Spotify, GitHub.
public struct ConnectedAccount: Hashable, Sendable, Codable, Identifiable {
    public let id: String
    /// Discord's service key: `steam`, `spotify`, `github`, `youtube`…
    public let service: String
    public let name: String
    public let isVerified: Bool
    /// What the service publishes about the account, verbatim.
    ///
    /// **Every value is a string, and the keys are the service's own.** Steam
    /// sends `created_at`, `game_count` and two `item_count_*`; Reddit sends
    /// `total_karma`, `gold` and `mod`; Twitter sends `followers_count` and
    /// `statuses_count`. There is no closed set — a service Discord adds next
    /// month arrives with keys nothing here has seen, which is why this is a map
    /// rather than a struct and why `ConnectionFact` renders it by *shape*.
    public let metadata: [String: String]

    public init(
        id: String,
        service: String,
        name: String,
        isVerified: Bool,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.service = service
        self.name = name
        self.isVerified = isVerified
        self.metadata = metadata
    }

    /// The line under the account name: what the service says about it.
    ///
    /// Ordered so a date leads and counts follow, because "Member since 2019 ·
    /// 16 Games" reads and "16 Games · Member since 2019" does not.
    public var facts: [ConnectionFact] {
        metadata
            .compactMap { ConnectionFact(key: $0.key, rawValue: $0.value) }
            .sorted { $0.sortRank < $1.sortRank }
    }

    /// Where this account lives on the web, when it has a public page.
    ///
    /// **Nil is a real answer and the common one for half these services.** A
    /// PlayStation gamertag, a Battle.net BattleTag and a Riot ID have no
    /// address anybody can open; a chip that looked like a link and opened
    /// nothing would be the inert control `INVARIANTS.md` §5.5 is about — so
    /// those copy the name instead, which is the only useful thing to do with
    /// one.
    ///
    /// **Built by service key, not by trusting a URL from the payload.** The
    /// profile route carries no link for these, and inventing one from an
    /// attacker-controllable name is how a client ends up navigating somewhere
    /// a message told it to. The name is percent-encoded into a host this file
    /// chose.
    public var profileURL: URL? {
        guard let template = Self.template(for: service) else { return nil }
        let segment = template.usesID ? id : name
        guard !segment.isEmpty,
              let encoded = segment.addingPercentEncoding(
                  withAllowedCharacters: .urlPathAllowed
              )
        else { return nil }
        return URL(string: template.prefix + encoded + template.suffix)
    }

    private struct Template {
        var prefix: String
        /// Whether the address is built from the account's *id* rather than its
        /// display name. Steam and Spotify are both — a Steam profile is a
        /// 64-bit id and the visible name is not addressable at all.
        var usesID: Bool
        /// After the name — Letterboxd's profile is `letterboxd.com/{name}/`,
        /// as Discord's own table builds it.
        var suffix = ""
    }

    private static func template(for service: String) -> Template? {
        switch service.lowercased() {
        case "steam": Template(prefix: "https://steamcommunity.com/profiles/", usesID: true)
        case "spotify": Template(prefix: "https://open.spotify.com/user/", usesID: true)
        case "youtube": Template(prefix: "https://www.youtube.com/channel/", usesID: true)
        case "twitch": Template(prefix: "https://www.twitch.tv/", usesID: false)
        case "github": Template(prefix: "https://github.com/", usesID: false)
        case "reddit": Template(prefix: "https://www.reddit.com/user/", usesID: false)
        case "twitter", "x": Template(prefix: "https://x.com/", usesID: false)
        case "instagram": Template(prefix: "https://www.instagram.com/", usesID: false)
        case "tiktok": Template(prefix: "https://www.tiktok.com/@", usesID: false)
        case "bluesky": Template(prefix: "https://bsky.app/profile/", usesID: false)
        case "domain": Template(prefix: "https://", usesID: false)
        case "ebay": Template(prefix: "https://www.ebay.com/usr/", usesID: false)
        case "paypal": Template(prefix: "https://www.paypal.me/", usesID: false)
        case "soundcloud": Template(prefix: "https://soundcloud.com/", usesID: false)
        case "letterboxd": Template(prefix: "https://letterboxd.com/", usesID: false, suffix: "/")
        // Everything else — PlayStation, Xbox, Battle.net, Riot, Epic, Crunchyroll,
        // Facebook, Roblox — has no address a client can build. They copy.
        default: nil
        }
    }
}

/// Somebody the reader and the person being looked at both know.
///
/// **The list, for the reason `MutualGuild` is a list**: the count is derivable
/// from it and not the other way round, and "3 Mutual Friends" that cannot say
/// which three is a fact the reader has to go and look up somewhere else.
public struct MutualFriend: Hashable, Sendable, Codable, Identifiable {
    public let id: UserID
    public let name: String
    public let avatarHash: String?
    public let monogram: String
    /// The server tag they wear, if any — `clan` / `primary_guild` on the wire.
    ///
    /// **Carried on the row rather than resolved from the store**, because the
    /// tag belongs to a server the *reader* very often is not in: the whole
    /// point of a tag is that it travels with the person. Looking it up locally
    /// would draw a blank mark for exactly the people whose tag is interesting.
    public let tag: String?
    public let tagBadgeHash: String?
    public let tagGuildID: GuildID?

    public init(
        id: UserID,
        name: String,
        avatarHash: String?,
        monogram: String,
        tag: String? = nil,
        tagBadgeHash: String? = nil,
        tagGuildID: GuildID? = nil
    ) {
        self.id = id
        self.name = name
        self.avatarHash = avatarHash
        self.monogram = monogram
        self.tag = tag
        self.tagBadgeHash = tagBadgeHash
        self.tagGuildID = tagGuildID
    }
}

/// A server the reader shares with someone.
///
/// The **list**, not a count, because the count is the only thing that can be
/// derived from the list and not the other way round — and a "1 Mutual Server"
/// line that cannot say *which* server is a fact the reader has to go and look
/// up somewhere else.
public struct MutualGuild: Hashable, Sendable, Codable, Identifiable {
    public let id: GuildID
    /// The nickname they use in that server, when it differs from their name.
    public let nickname: String?

    public init(id: GuildID, nickname: String? = nil) {
        self.id = id
        self.nickname = nickname
    }
}

/// Which Nitro an account carries.
public enum PremiumTier: Int, Hashable, Sendable, Codable {
    case none = 0
    case classic = 1
    case nitro = 2
    case basic = 3

    public var label: String? {
        switch self {
        case .none: nil
        case .classic: "Nitro Classic"
        case .nitro: "Nitro"
        case .basic: "Nitro Basic"
        }
    }

    /// Whether Discord themes this account's profile from its own artwork when
    /// it has set no `theme_colors`.
    ///
    /// **Not "has paid for something", which is the gate this replaced.**
    /// `basic` is a paid tier and does not get it — so a test for `!= .none`
    /// quantises an avatar, spends a fetch and a decode on it, and then themes
    /// a profile Discord leaves grey. Confirmed against live accounts: `0` and
    /// `3` are excluded, `1` and `2` are not.
    ///
    /// On the tier rather than at the call site because it is a fact about what
    /// the tier buys, and because there is more than one surface that will want
    /// to ask.
    public var derivesProfileTheme: Bool {
        switch self {
        case .none, .basic: false
        case .classic, .nitro: true
        }
    }
}

extension User {
    /// This user, keeping anything `existing` knows that this one does not.
    ///
    /// **The fix for a profile that goes blank while you are looking at it.**
    /// A user arrives from four places — READY, a member-list op, a message
    /// author, and the profile route — and only the last carries a banner, a
    /// bio, badges, connections or theme colours. Writing whichever arrived last
    /// straight into the table means a presence flush or a roster update lands
    /// *while the card is open* and wipes everything the profile fetch paid for:
    /// the banner goes, the bio goes, the badge row drops to whatever the flag
    /// bits alone can say.
    ///
    /// Identity comes from the incoming record — a rename has to take effect —
    /// and the decoration is merged field by field.
    ///
    /// **The profile route does NOT go through this.** It is the authoritative
    /// answer for every cosmetic field, so a bio somebody deleted has to be able
    /// to disappear; merging there would make removal impossible.
    public func merged(over existing: User?) -> User {
        guard let existing else { return self }
        var result = self
        result.decoration = UserDecoration.merged(
            incoming: decoration, existing: existing.decoration
        )
        return result
    }
}

/// Cosmetics, profile extras, and everything else a `User` almost never has.
///
/// A class, not a struct: it is optional on `User` and shared by every copy of
/// that user, so one allocation serves all of them and copying a `User` copies a
/// pointer. Immutable (`let` throughout) so sharing is safe without a lock —
/// changing a cosmetic replaces the box rather than mutating it.
public final class UserDecoration: Hashable, Sendable, Codable {
    /// Avatar decoration asset hash — the ring or frame drawn *around* the
    /// avatar, at 1.2x its diameter and outside its circular mask.
    public let avatarDecorationHash: String?
    /// The product the decoration came from. Needed only by the editor, which
    /// sends it as `avatar_decoration_sku_id` and marks it in the picker.
    public let avatarDecorationSKU: String?
    /// The strip drawn behind a whole roster row, and the colour it grounds
    /// that row with.
    public let nameplate: Nameplate?
    /// The face, effect and colours their display name is drawn with.
    ///
    /// Nil for nearly everyone, and nil is also what a style that asked for
    /// nothing decodes to — see `DisplayNameStyle.isPlain`. Discord's own dialog
    /// says colours and effects do not appear in servers, so this reaches the
    /// profile surfaces and no roster row.
    public let displayNameStyle: DisplayNameStyle?
    public let bannerHash: String?
    /// The profile accent, as Discord sends it: a 24-bit integer, or nil when
    /// unset. Nil and zero are different states and must not be collapsed —
    /// zero is a deliberate black accent.
    public let accentColor: UInt32?
    public let bio: String?
    /// The two colours a profile is themed with, primary first.
    ///
    /// Separate from `accentColor`, which is a single legacy swatch: a themed
    /// profile carries a PAIR and reads as a gradient, and collapsing the pair
    /// to its first colour is why a profile that should be purple-to-blue comes
    /// out as one flat purple. Empty and nil are both "no theme".
    public let themeColorValues: [UInt32]?
    /// The account's badges, as named by the profile route.
    public let badges: [AccountBadge]
    /// The SKU of the profile effect, if they own one. Resolved to artwork
    /// separately — the profile route names the purchase, not the pictures.
    public let profileEffectSKU: String?
    /// The SKU of the profile frame, if they own one.
    ///
    /// **A separate collectible from the effect, and an account can wear
    /// both.** Discovered from `user_profile.collectibles`, which lists every
    /// worn collectible by type; `profile_effect` names only the effect, so a
    /// client reading that alone never learns the frame exists.
    public let profileFrameSKU: String?
    /// Every collectible this layer of the profile lists as worn — the
    /// profile route's `collectibles` — **without** the account's layer
    /// standing in for a server's. Nil where the route said nothing.
    ///
    /// Read for one thing: Discord saves an effect or a frame by sending this
    /// list back with that one kind swapped (`collectibles_sku_ids`), so a
    /// write built from the effect and the frame alone would drop whatever
    /// else the list carried. See `WornCollectible.skus(swapping:)`.
    public let wornCollectibles: [WornCollectible]?
    /// Free text the account chose. Discord shows it beside the handle.
    public let pronouns: String?
    public let connectedAccounts: [ConnectedAccount]
    public let premiumTier: PremiumTier
    /// When the Nitro subscription started, for the "since" line.
    public let premiumSince: Date?
    /// The pre-2023 `name#1234`, when Discord still knows it.
    public let legacyUsername: String?
    /// The servers the reader shares with them, as the profile route listed
    /// them. Empty until that route has answered.
    public let mutualGuilds: [MutualGuild]
    /// The people both accounts know. Only the profile route reports them, and
    /// only when the reader asked with `with_mutual_friends`.
    public let mutualFriends: [MutualFriend]
    /// Whether the account has turned its profile private.
    ///
    /// **A fact the profile route reports, not one the client infers.** Discord
    /// answers `private: true` and still returns the mutual servers the reader
    /// can see for themselves — so this is a *label*, not a filter. A client
    /// that used it to hide what the payload already gave would be inventing a
    /// restriction the server did not make, and one that ignored it would be
    /// silently dropping something the person chose to say.
    public let isProfilePrivate: Bool
    /// The clan / guild tag shown beside the name.
    public let primaryGuildTag: String?
    public let primaryGuildBadgeHash: String?
    public let primaryGuildID: GuildID?
    /// An app's own facts, which its profile carries and no other route —
    /// nil for a person, and for an app until its profile has answered.
    public let application: ProfileApplication?

    public init(
        avatarDecorationHash: String? = nil,
        avatarDecorationSKU: String? = nil,
        nameplate: Nameplate? = nil,
        displayNameStyle: DisplayNameStyle? = nil,
        bannerHash: String? = nil,
        accentColor: UInt32? = nil,
        bio: String? = nil,
        themeColorValues: [UInt32]? = nil,
        badges: [AccountBadge] = [],
        profileEffectSKU: String? = nil,
        profileFrameSKU: String? = nil,
        wornCollectibles: [WornCollectible]? = nil,
        pronouns: String? = nil,
        connectedAccounts: [ConnectedAccount] = [],
        premiumTier: PremiumTier = .none,
        premiumSince: Date? = nil,
        legacyUsername: String? = nil,
        mutualGuilds: [MutualGuild] = [],
        mutualFriends: [MutualFriend] = [],
        isProfilePrivate: Bool = false,
        primaryGuildTag: String? = nil,
        primaryGuildBadgeHash: String? = nil,
        primaryGuildID: GuildID? = nil,
        application: ProfileApplication? = nil
    ) {
        self.avatarDecorationHash = avatarDecorationHash
        self.avatarDecorationSKU = avatarDecorationSKU
        self.nameplate = nameplate
        self.displayNameStyle = displayNameStyle
        self.bannerHash = bannerHash
        self.accentColor = accentColor
        self.bio = bio
        self.themeColorValues = themeColorValues
        self.badges = badges
        self.profileEffectSKU = profileEffectSKU
        self.profileFrameSKU = profileFrameSKU
        self.wornCollectibles = wornCollectibles
        self.pronouns = pronouns
        self.connectedAccounts = connectedAccounts
        self.premiumTier = premiumTier
        self.premiumSince = premiumSince
        self.legacyUsername = legacyUsername
        self.mutualGuilds = mutualGuilds
        self.mutualFriends = mutualFriends
        self.isProfilePrivate = isProfilePrivate
        self.primaryGuildTag = primaryGuildTag
        self.primaryGuildBadgeHash = primaryGuildBadgeHash
        self.primaryGuildID = primaryGuildID
        self.application = application
    }

    /// The fuller of two decorations, field by field.
    ///
    /// Nil where both are nil, so a user with no cosmetics still costs no
    /// allocation. Every field takes the incoming answer where it has one and
    /// falls back to what was already known — which is what lets a roster
    /// update refresh somebody's nameplate without taking their bio with it.
    static func merged(
        incoming: UserDecoration?,
        existing: UserDecoration?
    ) -> UserDecoration? {
        guard let existing else { return incoming }
        guard let incoming else { return existing }
        let merged = UserDecoration(
            avatarDecorationHash: incoming.avatarDecorationHash
                ?? existing.avatarDecorationHash,
            avatarDecorationSKU: incoming.avatarDecorationSKU
                ?? existing.avatarDecorationSKU,
            nameplate: incoming.nameplate ?? existing.nameplate,
            displayNameStyle: incoming.displayNameStyle ?? existing.displayNameStyle,
            bannerHash: incoming.bannerHash ?? existing.bannerHash,
            accentColor: incoming.accentColor ?? existing.accentColor,
            bio: incoming.bio ?? existing.bio,
            themeColorValues: incoming.themeColorValues?.isEmpty == false
                ? incoming.themeColorValues
                : existing.themeColorValues,
            badges: incoming.badges.isEmpty ? existing.badges : incoming.badges,
            profileEffectSKU: incoming.profileEffectSKU ?? existing.profileEffectSKU,
            profileFrameSKU: incoming.profileFrameSKU ?? existing.profileFrameSKU,
            wornCollectibles: incoming.wornCollectibles ?? existing.wornCollectibles,
            pronouns: incoming.pronouns ?? existing.pronouns,
            connectedAccounts: incoming.connectedAccounts.isEmpty
                ? existing.connectedAccounts
                : incoming.connectedAccounts,
            premiumTier: incoming.premiumTier == .none
                ? existing.premiumTier
                : incoming.premiumTier,
            premiumSince: incoming.premiumSince ?? existing.premiumSince,
            legacyUsername: incoming.legacyUsername ?? existing.legacyUsername,
            mutualGuilds: incoming.mutualGuilds.isEmpty
                ? existing.mutualGuilds
                : incoming.mutualGuilds,
            // Only the profile route reports this, and only it can clear it —
            // so an OR would make the flag one-way and leave a lock on somebody
            // who turned it off. The incoming answer wins where there is one,
            // and a roster merge carries no answer at all.
            mutualFriends: incoming.mutualFriends.isEmpty
                ? existing.mutualFriends
                : incoming.mutualFriends,
            isProfilePrivate: incoming.isProfilePrivate || existing.isProfilePrivate,
            // The tag is one fact in three fields and they move together: an
            // account that took its tag off sends all three empty, and keeping
            // the old id beside a new nil badge would draw half a mark.
            primaryGuildTag: incoming.primaryGuildTag ?? existing.primaryGuildTag,
            primaryGuildBadgeHash: incoming.primaryGuildTag != nil
                ? incoming.primaryGuildBadgeHash
                : existing.primaryGuildBadgeHash,
            primaryGuildID: incoming.primaryGuildTag != nil
                ? incoming.primaryGuildID
                : existing.primaryGuildID,
            application: incoming.application ?? existing.application
        )
        return merged.isEmpty ? nil : merged
    }

    /// Whether the box holds anything at all. A decoder that builds one of these
    /// unconditionally and attaches it to every user has undone the entire point
    /// of the type, so it asks this first.
    public var isEmpty: Bool {
        avatarDecorationHash == nil && nameplate == nil && displayNameStyle == nil
            && bannerHash == nil
            && accentColor == nil && bio == nil && primaryGuildTag == nil
            && (themeColorValues?.isEmpty ?? true) && badges.isEmpty
            && profileEffectSKU == nil && profileFrameSKU == nil
            && (wornCollectibles?.isEmpty ?? true) && pronouns == nil
            && connectedAccounts.isEmpty && premiumTier == .none
            && legacyUsername == nil && mutualGuilds.isEmpty && mutualFriends.isEmpty
            && !isProfilePrivate && application == nil
    }

    public static func == (lhs: UserDecoration, rhs: UserDecoration) -> Bool {
        lhs === rhs
            || (lhs.avatarDecorationHash == rhs.avatarDecorationHash
                && lhs.nameplate == rhs.nameplate
                && lhs.displayNameStyle == rhs.displayNameStyle
                && lhs.bannerHash == rhs.bannerHash
                && lhs.accentColor == rhs.accentColor
                && lhs.bio == rhs.bio
                && lhs.themeColorValues == rhs.themeColorValues
                && lhs.badges == rhs.badges
                && lhs.profileEffectSKU == rhs.profileEffectSKU
                && lhs.profileFrameSKU == rhs.profileFrameSKU
                && lhs.wornCollectibles == rhs.wornCollectibles
                && lhs.pronouns == rhs.pronouns
                && lhs.connectedAccounts == rhs.connectedAccounts
                && lhs.premiumTier == rhs.premiumTier
                && lhs.premiumSince == rhs.premiumSince
                && lhs.legacyUsername == rhs.legacyUsername
                && lhs.mutualGuilds == rhs.mutualGuilds
                && lhs.mutualFriends == rhs.mutualFriends
                && lhs.isProfilePrivate == rhs.isProfilePrivate
                && lhs.primaryGuildTag == rhs.primaryGuildTag
                && lhs.primaryGuildBadgeHash == rhs.primaryGuildBadgeHash
                && lhs.primaryGuildID == rhs.primaryGuildID
                && lhs.application == rhs.application)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(avatarDecorationHash)
        hasher.combine(nameplate)
        hasher.combine(displayNameStyle)
        hasher.combine(bannerHash)
        hasher.combine(accentColor)
        hasher.combine(themeColorValues)
        hasher.combine(badges)
        hasher.combine(profileEffectSKU)
        hasher.combine(profileFrameSKU)
        hasher.combine(primaryGuildTag)
    }
}

/// Account badges, as the bitfield Discord sends.
public struct UserFlags: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let staff = UserFlags(rawValue: 1 << 0)
    public static let partner = UserFlags(rawValue: 1 << 1)
    public static let hypesquadEvents = UserFlags(rawValue: 1 << 2)
    public static let bugHunterLevel1 = UserFlags(rawValue: 1 << 3)
    public static let hypesquadBravery = UserFlags(rawValue: 1 << 6)
    public static let hypesquadBrilliance = UserFlags(rawValue: 1 << 7)
    public static let hypesquadBalance = UserFlags(rawValue: 1 << 8)
    public static let earlySupporter = UserFlags(rawValue: 1 << 9)
    public static let teamPseudoUser = UserFlags(rawValue: 1 << 10)
    public static let bugHunterLevel2 = UserFlags(rawValue: 1 << 14)
    public static let verifiedBot = UserFlags(rawValue: 1 << 16)
    public static let verifiedDeveloper = UserFlags(rawValue: 1 << 17)
    public static let certifiedModerator = UserFlags(rawValue: 1 << 18)
    public static let botHTTPInteractions = UserFlags(rawValue: 1 << 19)
    public static let activeDeveloper = UserFlags(rawValue: 1 << 22)
}
