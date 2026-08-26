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
    /// Nameplate asset path — the strip drawn behind a whole roster row.
    public let nameplateAsset: String?
    public let bannerHash: String?
    /// The profile accent, as Discord sends it: a 24-bit integer, or nil when
    /// unset. Nil and zero are different states and must not be collapsed —
    /// zero is a deliberate black accent.
    public let accentColor: UInt32?
    public let bio: String?
    /// The clan / guild tag shown beside the name.
    public let primaryGuildTag: String?
    public let primaryGuildBadgeHash: String?
    public let primaryGuildID: GuildID?

    public init(
        avatarDecorationHash: String? = nil,
        nameplateAsset: String? = nil,
        bannerHash: String? = nil,
        accentColor: UInt32? = nil,
        bio: String? = nil,
        primaryGuildTag: String? = nil,
        primaryGuildBadgeHash: String? = nil,
        primaryGuildID: GuildID? = nil
    ) {
        self.avatarDecorationHash = avatarDecorationHash
        self.nameplateAsset = nameplateAsset
        self.bannerHash = bannerHash
        self.accentColor = accentColor
        self.bio = bio
        self.primaryGuildTag = primaryGuildTag
        self.primaryGuildBadgeHash = primaryGuildBadgeHash
        self.primaryGuildID = primaryGuildID
    }

    /// Whether the box holds anything at all. A decoder that builds one of these
    /// unconditionally and attaches it to every user has undone the entire point
    /// of the type, so it asks this first.
    public var isEmpty: Bool {
        avatarDecorationHash == nil && nameplateAsset == nil && bannerHash == nil
            && accentColor == nil && bio == nil && primaryGuildTag == nil
    }

    public static func == (lhs: UserDecoration, rhs: UserDecoration) -> Bool {
        lhs === rhs
            || (lhs.avatarDecorationHash == rhs.avatarDecorationHash
                && lhs.nameplateAsset == rhs.nameplateAsset
                && lhs.bannerHash == rhs.bannerHash
                && lhs.accentColor == rhs.accentColor
                && lhs.bio == rhs.bio
                && lhs.primaryGuildTag == rhs.primaryGuildTag
                && lhs.primaryGuildBadgeHash == rhs.primaryGuildBadgeHash
                && lhs.primaryGuildID == rhs.primaryGuildID)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(avatarDecorationHash)
        hasher.combine(nameplateAsset)
        hasher.combine(bannerHash)
        hasher.combine(accentColor)
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
