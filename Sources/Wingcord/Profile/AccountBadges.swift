import Foundation
import WingcordCore

/// Every badge a profile can show, resolved to Discord's own artwork.
///
/// **Two sources, and the profile route's own list wins outright when it is
/// there.** That list is complete — it already carries Nitro, the boost tiers,
/// the quest and orb badges and everything else — so nothing may be added to it.
/// Adding to it is what drew two Nitro crests: Discord ships several assets for
/// the same badge under ids that also differ, so no de-duplication key exists
/// that could have caught it.
///
/// The other branch is the one that was broken. When the route sends no list —
/// which happens to plenty of accounts that visibly have badges — the account's
/// `flags` bitfield still describes the dozen oldest, and those used to be drawn
/// as grey SF Symbols. Now they carry Discord's own artwork, along with the
/// Nitro and pre-2023-name facts that used to be text rows under the card.
///
/// **The artwork is Discord's, for both sources.** A badge drawn as an SF Symbol
/// is a grey outline where every other client shows a coloured crest, and the
/// symbol set has nothing resembling most of them. The hashes below are stable
/// CDN assets, verified by fetching each one and looking at it: the three houses
/// come back in Discord's own house colours, the two bug-hunter tiers in green
/// and gold, and `premium`, `legacy_username` and `quest_completed` are pixel
/// matches for badges the profile route already names on live accounts.
///
/// The symbol stays as the last resort for a badge Discord names but sends no
/// icon for.
nonisolated enum AccountBadges {

    /// Everything to draw for one account, in the order it is drawn.
    ///
    /// **Discord's list wins outright when it is there.** Merging the two
    /// sources was the wrong model and it showed: Discord ships several assets
    /// for the same badge — Nitro, Classic, Basic and every boost tier are
    /// different pictures of the same idea — under ids that also differ, so a
    /// merge de-duplicated on neither and drew two Nitro crests. There is no key
    /// that fixes that, because the two entries genuinely are different rows
    /// describing the same thing.
    ///
    /// The list is *complete* when the route sends it, so nothing has to be
    /// added to it. What was actually broken was the other branch: an account
    /// whose list arrives empty fell back to flag bits drawn as grey SF Symbols,
    /// which is why a HypeSquad member showed two outlines where every other
    /// client shows crests. That branch now draws Discord's own artwork too, and
    /// carries the Nitro and pre-2023-name facts that used to be text rows under
    /// the card.
    static func resolve(
        flags: UserFlags,
        decoration: UserDecoration?
    ) -> [ProfileBadge] {
        if let named = decoration?.badges, !named.isEmpty {
            return named.map {
                ProfileBadge(
                    id: $0.id,
                    iconURL: $0.iconHash.flatMap { hash in CDN.accountBadge(hash: hash) },
                    symbolName: symbol(forID: $0.id),
                    label: $0.label
                )
            }
        }

        var result: [ProfileBadge] = []
        for entry in flagBadges where flags.contains(entry.flag) {
            result.append(ProfileBadge(
                id: entry.id,
                iconURL: CDN.accountBadge(hash: entry.hash),
                symbolName: entry.symbol,
                label: entry.label
            ))
        }

        // `label` is nil for `.none`, so this is the whole of the test.
        if let tier = decoration?.premiumTier.label {
            let since = decoration?.premiumSince.map {
                "Subscriber since \($0.formatted(.dateTime.month(.wide).day().year()))"
            }
            result.append(ProfileBadge(
                id: "premium",
                iconURL: CDN.accountBadge(hash: premiumHash),
                symbolName: "sparkles",
                label: since ?? tier
            ))
        }

        if let legacy = decoration?.legacyUsername {
            result.append(ProfileBadge(
                id: "legacy_username",
                iconURL: CDN.accountBadge(hash: legacyUsernameHash),
                symbolName: "clock.arrow.circlepath",
                label: "Originally \(legacy)"
            ))
        }

        return result
    }

    // MARK: The table

    private struct FlagBadge {
        var flag: UserFlags
        /// Discord's own id for the badge, so a named entry and a derived one
        /// for the same badge agree on what they are.
        var id: String
        var hash: String
        var symbol: String
        var label: String
    }

    private static let premiumHash = "2ba85e8026a8614b640c2837bcdfe21b"
    private static let legacyUsernameHash = "6de6d34650760ba5551a79732e98ed60"

    /// In Discord's own display order: programme badges, then HypeSquad, then
    /// the earned ones, then the developer marks.
    private static let flagBadges: [FlagBadge] = [
        FlagBadge(
            flag: .staff, id: "staff",
            hash: "5e74e9b61934fc1f67c65515d1f7e60d",
            symbol: "shield.lefthalf.filled", label: "Discord Staff"
        ),
        FlagBadge(
            flag: .partner, id: "partner",
            hash: "3f9748e53446a137a052f3454e2de41e",
            symbol: "checkmark.seal.fill", label: "Partnered Server Owner"
        ),
        FlagBadge(
            flag: .certifiedModerator, id: "certified_moderator",
            hash: "fee1624003e2fee35cb398e125dc479b",
            symbol: "checkmark.shield.fill", label: "Moderator Programs Alumni"
        ),
        FlagBadge(
            flag: .hypesquadEvents, id: "hypesquad",
            hash: "bf01d1073931f921909045f3a39fd264",
            symbol: "sparkles", label: "HypeSquad Events"
        ),
        FlagBadge(
            flag: .hypesquadBravery, id: "hypesquad_house_1",
            hash: "8a88d63823d8a71cd5e390baa45efa02",
            symbol: "shield.fill", label: "HypeSquad Bravery"
        ),
        FlagBadge(
            flag: .hypesquadBrilliance, id: "hypesquad_house_2",
            hash: "011940fd013da3f7fb926e4a1cd2e618",
            symbol: "flame.fill", label: "HypeSquad Brilliance"
        ),
        FlagBadge(
            flag: .hypesquadBalance, id: "hypesquad_house_3",
            hash: "3aa41de486fa12454c3761e8e223442e",
            symbol: "scalemass.fill", label: "HypeSquad Balance"
        ),
        FlagBadge(
            flag: .bugHunterLevel1, id: "bug_hunter_level_1",
            hash: "2717692c7dca7289b35297368a940dd0",
            symbol: "ant.fill", label: "Discord Bug Hunter"
        ),
        FlagBadge(
            flag: .bugHunterLevel2, id: "bug_hunter_level_2",
            hash: "848f79194d4be5ff5f81505cbd0ce1e6",
            symbol: "ant.circle.fill", label: "Discord Bug Hunter"
        ),
        FlagBadge(
            flag: .earlySupporter, id: "early_supporter",
            hash: "7060786766c9c840eb3019e725d2b358",
            symbol: "heart.fill", label: "Early Supporter"
        ),
        FlagBadge(
            flag: .activeDeveloper, id: "active_developer",
            hash: "6bdc42827a38498929a4920da12695d9",
            symbol: "hammer.fill", label: "Active Developer"
        ),
        FlagBadge(
            flag: .verifiedDeveloper, id: "verified_developer",
            hash: "6df5892e0f35b051f8b61eace34f4967",
            symbol: "chevron.left.forwardslash.chevron.right",
            label: "Early Verified Bot Developer"
        ),
    ]

    /// The fallback mark for a badge Discord named but sent no icon for.
    ///
    /// Matched on the id where the id is one this app knows, so a named badge
    /// with a missing asset still draws the right *kind* of mark rather than the
    /// generic one.
    private static func symbol(forID id: String) -> String {
        if let known = flagBadges.first(where: { $0.id == id }) { return known.symbol }
        return switch id {
        case "premium": "sparkles"
        case "legacy_username": "clock.arrow.circlepath"
        case "quest_completed": "laurel.leading"
        // A boost badge is `guild_booster_lvl1` through `lvl9`.
        default: id.hasPrefix("guild_booster") ? "chevron.up.circle.fill" : "rosette"
        }
    }
}
