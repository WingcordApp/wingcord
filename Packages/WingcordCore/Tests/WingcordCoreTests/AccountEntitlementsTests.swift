import Testing
@testable import WingcordCore

/// What each tier buys, and the two rules that keep a perk from being lost.
///
/// **The table is Discord's own** — the three arrays beside
/// `canUseEmojisEverywhere` in the web bundle — and the point of pinning it is
/// that the tiers do not nest: a `>=` over the raw values gets Basic's stickers
/// and Classic's missing ones wrong in opposite directions.
@Suite("Account entitlements")
struct AccountEntitlementsTests {

    @Test("Basic has stickers everywhere; Classic does not")
    func tiersDoNotNest() {
        #expect(PremiumTier.basic.grants(.stickersEverywhere))
        #expect(!PremiumTier.classic.grants(.stickersEverywhere))
        for tier in [PremiumTier.basic, .classic, .nitro] {
            #expect(tier.grants(.emojiEverywhere))
            #expect(tier.grants(.animatedEmoji))
        }
    }

    @Test("Only Nitro proper buys the profile, the server profile and the soundboard")
    func nitroOnlyPerks() {
        for perk in [PremiumPerk.profileCustomization, .serverProfile, .soundboardEverywhere] {
            #expect(PremiumTier.nitro.grants(perk))
            #expect(!PremiumTier.basic.grants(perk))
            #expect(!PremiumTier.classic.grants(perk))
        }
        for perk in PremiumPerk.allCases {
            #expect(!PremiumTier.none.grants(perk))
        }
    }

    /// Discord's table (`836714`): `ANIMATED_AVATAR` sits in Classic's row and
    /// Nitro's; `collectibles` only in Nitro's.
    @Test("Classic moves its avatar; only Nitro wears Nitro's collectibles")
    func avatarAndCollectibles() {
        #expect(PremiumTier.classic.grants(.animatedAvatar))
        #expect(PremiumTier.nitro.grants(.animatedAvatar))
        #expect(!PremiumTier.basic.grants(.animatedAvatar))
        #expect(!PremiumTier.none.grants(.animatedAvatar))
        #expect(PremiumTier.nitro.grants(.collectibles))
        for tier in [PremiumTier.none, .basic, .classic] {
            #expect(!tier.grants(.collectibles))
        }
    }

    @Test("An answer that did not carry a field keeps what was known")
    func absentFieldsMerge() {
        let known = AccountEntitlements().updated(premiumType: 2, ageVerificationStatus: 4)
        // A thinner answer — the shape a READY without the private fields has.
        let merged = known.updated(premiumType: nil, ageVerificationStatus: nil)
        #expect(merged.premiumTier == .nitro)
        #expect(merged.ageGroup == .adult)
        // A present zero is an answer, and it does take the tier away.
        #expect(known.updated(premiumType: 0, ageVerificationStatus: nil).premiumTier == .none)
    }

    @Test("Age groups resolve the way Discord's own resolver does")
    func ageGroups() {
        #expect(AgeGroup(verificationStatus: 2) == .teen)
        #expect(AgeGroup(verificationStatus: 5) == .teen)
        #expect(AgeGroup(verificationStatus: 1) == .unconfirmed)
        #expect(AgeGroup(verificationStatus: 3) == .adult)
        #expect(AgeGroup(verificationStatus: 4) == .adult)
        // `undefined !== UNVERIFIED` — an absent status is adult in Discord.
        #expect(AgeGroup(verificationStatus: nil) == .adult)
    }
}
