import Foundation

/// What the signed-in account is entitled to: the perks its subscription buys,
/// and the age group Discord has placed it in.
///
/// **Its own value, and never read off `User`.** `User` is what this client
/// knows about *anybody*, and the reader's own row in that table is rewritten
/// by every route and event that carries a user object — a roster row, a
/// message author, a profile, READY's own arrays. Only three answers carry
/// these two fields at all — READY's `user`, `GET /users/@me` and
/// `USER_UPDATE` — so a gate that read the tier off the shared row was one thin
/// write away from locking every perk the account pays for. That is what a
/// Nitro account saw: no other server's emoji, no stickers, a per-server
/// profile editor that said "Nitro only".
///
/// **Raw values, merged field by field.** An answer that did not carry a field
/// keeps what an earlier one said (`updated(premiumType:ageVerificationStatus:)`)
/// — the same rule `User.merged(over:)` follows, applied to the two fields
/// that rule could not protect.
public struct AccountEntitlements: Hashable, Sendable {
    public private(set) var premiumTier: PremiumTier
    /// `age_verification_status`, verbatim. Nil until an account-scoped answer
    /// has carried it.
    public private(set) var ageVerificationStatus: Int?
    /// The account's `perks` — nil until an answer has carried them. See
    /// `AccountPerks`.
    public private(set) var perks: AccountPerks?

    public init(premiumTier: PremiumTier = .none, ageVerificationStatus: Int? = nil, perks: AccountPerks? = nil) {
        self.premiumTier = premiumTier
        self.ageVerificationStatus = ageVerificationStatus
        self.perks = perks
    }

    /// This answer, keeping whatever an earlier one knew that it does not.
    public func updated(premiumType: Int?, ageVerificationStatus: Int?, perks: AccountPerks? = nil) -> AccountEntitlements {
        AccountEntitlements(
            premiumTier: premiumType.flatMap(PremiumTier.init(rawValue:)) ?? premiumTier,
            ageVerificationStatus: ageVerificationStatus ?? self.ageVerificationStatus,
            perks: perks ?? self.perks
        )
    }

    /// Whether the account pays for any tier at all — what super reactions and
    /// the inbox's quotas ask.
    public var isPremium: Bool { premiumTier != .none }

    /// Whether the subscription buys `perk`.
    public func has(_ perk: PremiumPerk) -> Bool { premiumTier.grants(perk) }

    /// The age group Discord shows on the account page.
    public var ageGroup: AgeGroup { AgeGroup(verificationStatus: ageVerificationStatus) }
}

/// A perk Discord gates on the subscription, named for the entry in its own
/// table (`animatedEmojis`, `emojisEverywhere`, …).
///
/// Only the perks this client has a surface for. Discord's table has thirty;
/// a case nothing asks about would be a promise with no control behind it.
public enum PremiumPerk: Hashable, Sendable, CaseIterable {
    /// `animatedEmojis` — an animated emoji anywhere, the server it belongs to
    /// included.
    case animatedEmoji
    /// `emojisEverywhere` — a server's emoji outside that server.
    case emojiEverywhere
    /// `stickersEverywhere` — a server's stickers outside that server.
    case stickersEverywhere
    /// `soundboardEverywhere` — a server's sounds outside that server.
    case soundboardEverywhere
    /// `profilePremiumFeatures` — the account's banner, theme colours and
    /// profile effect.
    case profileCustomization
    /// `premiumGuildMemberProfile` — a per-server avatar, banner, bio and
    /// cosmetics.
    case serverProfile
    /// `streamMidQuality` — Go Live at 1080p and 1440p, and at 60 FPS. See
    /// `GoLiveGate`.
    case streamMidQuality
    /// `streamHighQuality` — Go Live at Source.
    case streamHighQuality
    /// `ANIMATED_AVATAR` — a moving avatar on the account's own profile.
    /// **Classic carries it too**; a moving banner is `profileCustomization`.
    case animatedAvatar
    /// `collectibles` — wearing what was claimed through Nitro. Bought,
    /// gifted, free, Orbs and quest-reward collectibles need no perk at all
    /// (`993408`'s `gA`: only `purchase_type` 7 locks).
    case collectibles
    /// Nitro Emoji Packs' emoji, used anywhere. **Nitro proper only**: Discord
    /// asks `isPremiumAtLeast(user, TIER_2)` for a pack emoji (its
    /// `getEmojiUnavailableReason`, 2026-11-17), not the animated-emoji perk
    /// Basic and Classic carry.
    case emojiPacks
}

extension PremiumTier {
    /// What this tier buys, as Discord's own table has it.
    ///
    /// **The tiers do not nest.** The table sits beside
    /// `canUseEmojisEverywhere` in the web bundle and lists each tier's perks
    /// outright: Basic has stickers everywhere and Classic does not, Classic
    /// has an animated avatar and Basic does not, and only Nitro proper has
    /// the profile and the soundboard. A `>=` over the raw values — which run
    /// 1 Classic, 2 Nitro, 3 Basic, in the order they were launched — gets
    /// every one of those wrong.
    public func grants(_ perk: PremiumPerk) -> Bool {
        switch self {
        case .none:
            false
        case .nitro:
            true
        case .basic:
            switch perk {
            case .animatedEmoji, .emojiEverywhere, .stickersEverywhere: true
            case .soundboardEverywhere, .profileCustomization, .serverProfile,
                 .streamMidQuality, .streamHighQuality, .animatedAvatar, .collectibles, .emojiPacks: false
            }
        case .classic:
            switch perk {
            case .animatedEmoji, .emojiEverywhere, .streamMidQuality, .animatedAvatar: true
            case .stickersEverywhere, .soundboardEverywhere, .profileCustomization,
                 .serverProfile, .streamHighQuality, .collectibles, .emojiPacks: false
            }
        }
    }
}

/// Which age group Discord has placed the account in.
public enum AgeGroup: Hashable, Sendable {
    case adult
    case teen
    case unconfirmed

    /// Discord's own resolution, from `age_verification_status`.
    ///
    /// The statuses are `1` unverified, `2` verified teen, `3` verified adult,
    /// `4` inferred adult and `5` inferred teen (module `155718`). The resolver
    /// (`506775`) asks *teen* first and then whether the account is anything
    /// but unverified — so an absent status resolves to **adult**, exactly as
    /// Discord's own `undefined !== UNVERIFIED` does, and only an explicit `1`
    /// is unconfirmed.
    public init(verificationStatus: Int?) {
        switch verificationStatus {
        case 2, 5: self = .teen
        case 1: self = .unconfirmed
        default: self = .adult
        }
    }

    /// The word Discord's account page uses.
    public var label: String {
        switch self {
        case .adult: "Adult"
        case .teen: "Teen"
        case .unconfirmed: "Unconfirmed"
        }
    }
}
