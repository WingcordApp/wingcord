import Foundation

/// The cosmetics a reader has asked not to see.
///
/// **A set rather than six booleans on the store**, because the thing every
/// caller actually asks is "is this one suppressed" and the thing the filter
/// needs is "are any of them" — both of which are one instruction here and six
/// comparisons otherwise. It is also the memo key: the filtered decorations are
/// cached against it, and a set compares in one word.
///
/// **These are accessibility settings, not taste.** A name drawn in a
/// low-contrast gradient face, a profile effect that animates behind somebody's
/// bio, a nameplate that colours a whole row — each is content somebody else
/// chose and this reader has to look at. Discord ships the same switches for the
/// same reason.
public struct CosmeticSuppression: OptionSet, Hashable, Sendable, Identifiable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// **The bit, so a single option is its own identity.** `all` lists six
    /// single-bit values and a `ForEach` over them needs a stable key; the raw
    /// value is one, and it stays right if the order of the list ever changes.
    public var id: UInt8 { rawValue }

    /// The animation behind a profile card.
    public static let profileEffects = Self(rawValue: 1 << 0)
    /// The strip behind a name in the roster, the DM list and the now bar.
    public static let nameplates = Self(rawValue: 1 << 1)
    /// The ring or frame drawn around an avatar.
    public static let avatarDecorations = Self(rawValue: 1 << 2)
    /// The artwork that hangs over a profile card's edges.
    public static let profileFrames = Self(rawValue: 1 << 3)
    /// The face, effect and colours a display name is drawn with.
    public static let nameStyles = Self(rawValue: 1 << 4)
    /// The two-colour theme a profile is drawn on.
    public static let profileGradients = Self(rawValue: 1 << 5)

    /// Every one, in the order the pane lists them.
    public static let all: [(option: Self, title: String)] = [
        (.profileEffects, "Profile effects"),
        (.nameplates, "Nameplates"),
        (.avatarDecorations, "Avatar decorations"),
        (.profileFrames, "Profile frames"),
        (.nameStyles, "Name styles"),
        (.profileGradients, "Profile gradients"),
    ]
}

extension UserDecoration {

    /// The same cosmetics with the suppressed ones removed.
    ///
    /// **Returns `self` when nothing is suppressed, and that is the whole
    /// performance argument.** This is asked once per visible row per
    /// presentation pass on the roster and in the transcript; for the
    /// overwhelming majority of readers the set is empty and the answer is the
    /// object that was already there, at the cost of one `isEmpty`. Only a
    /// reader who has actually switched something off pays for an allocation,
    /// and `AppModel` memoizes that one against the set.
    ///
    /// **Everything that is not a cosmetic is carried across untouched** — the
    /// bio, the badges, the connected accounts, the mutuals, the pronouns. This
    /// hides decoration, not people.
    public func suppressing(_ suppressed: CosmeticSuppression) -> UserDecoration {
        guard !suppressed.isEmpty else { return self }
        return UserDecoration(
            avatarDecorationHash: suppressed.contains(.avatarDecorations)
                ? nil : avatarDecorationHash,
            avatarDecorationSKU: suppressed.contains(.avatarDecorations)
                ? nil : avatarDecorationSKU,
            nameplate: suppressed.contains(.nameplates) ? nil : nameplate,
            displayNameStyle: suppressed.contains(.nameStyles) ? nil : displayNameStyle,
            bannerHash: bannerHash,
            accentColor: accentColor,
            bio: bio,
            // **The gradient goes, the legacy accent stays.** They are two
            // different things on the wire — see `themeColorValues` — and the
            // accent is one flat swatch that predates the collectible. Taking it
            // with the pair would leave a profile with no colour at all rather
            // than with its plain one.
            themeColorValues: suppressed.contains(.profileGradients) ? nil : themeColorValues,
            badges: badges,
            profileEffectSKU: suppressed.contains(.profileEffects) ? nil : profileEffectSKU,
            profileFrameSKU: suppressed.contains(.profileFrames) ? nil : profileFrameSKU,
            // What is worn, not what is drawn: the editor writes from this,
            // and a filtered copy would save the reader's own frame away.
            wornCollectibles: wornCollectibles,
            pronouns: pronouns,
            connectedAccounts: connectedAccounts,
            premiumTier: premiumTier,
            premiumSince: premiumSince,
            legacyUsername: legacyUsername,
            mutualGuilds: mutualGuilds,
            mutualFriends: mutualFriends,
            isProfilePrivate: isProfilePrivate,
            primaryGuildTag: primaryGuildTag,
            primaryGuildBadgeHash: primaryGuildBadgeHash,
            primaryGuildID: primaryGuildID,
            // **Carried, like every other fact that is not a cosmetic.** This
            // was left out, so a reader with any switch off lost an app's
            // install buttons and store links from its profile.
            application: application
        )
    }
}
