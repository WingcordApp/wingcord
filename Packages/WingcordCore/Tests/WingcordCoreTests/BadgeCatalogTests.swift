import Foundation
import Testing
@testable import WingcordCore

/// Discord's levelled badges (docs/CLIPS-PRESENCE.md, Phase 8).
@Suite("Badge catalog")
struct BadgeCatalogTests {

    private let url = { (name: String) in URL(string: "https://cdn.discordapp.com/badges/\(name).png") }

    private func streaming(owned: Bool = true, hidden: Bool = false) -> CatalogBadge {
        CatalogBadge(
            badgeID: 19, name: "Streaming", isOwned: owned, isHidden: hidden, isEarnable: !owned,
            currentTierKey: owned ? "breakout" : nil, nextTierKey: "standout",
            tiers: [
                BadgeTier(key: "newcomer", name: "Newcomer", simpleIconURL: url("n")),
                BadgeTier(key: "breakout", name: "Breakout", simpleIconURL: url("b"), complexIconURL: url("B"),
                          complexIconAnimatedURL: url("B-moving"), rarity: .epic),
                BadgeTier(key: "standout", name: "Standout", simpleIconURL: url("s")),
            ],
            progress: (23, 75), infoLabel: "23 hours streamed to others"
        )
    }

    @Test("The profile's string ids map to Discord's integer ones")
    func profileIDs() {
        #expect(BadgeKind.forProfileID("premium_tenure_24_month_v2") == .premiumTenure)
        #expect(BadgeKind.forProfileID("guild_booster_lvl3") == .guildBooster)
        #expect(BadgeKind.forProfileID("staff_hidden") == .staff)
        #expect(BadgeKind.forProfileID("account_age") == .accountAge)
        #expect(BadgeKind.forProfileID("hypesquad_house_2") == .hypesquadHouse2)
        #expect(BadgeKind.forProfileID("something_new") == nil)
        #expect(BadgeKind.streaming.rawValue == 19 && BadgeKind.staff.rawValue == 22)
    }

    @Test("An owned badge draws its level; one not yet owned the level it unlocks first")
    func displayTier() {
        #expect(streaming().displayTier?.name == "Breakout")
        #expect(streaming().title == "Breakout")
        #expect(streaming(owned: false).displayTier?.name == "Standout")
        #expect(streaming().remainingToNextTier == 52)
        #expect(abs(streaming().fractionToNextTier - 23.0 / 75.0) < 0.0001)
        #expect(streaming().isReached(streaming().tiers[0]))
        #expect(!streaming().isReached(streaming().tiers[2]))
    }

    @Test("Moving artwork unless motion is reduced, then still, then the mark")
    func artwork() {
        #expect(streaming().artwork(reducesMotion: false)?.lastPathComponent == "B-moving.png")
        #expect(streaming().artwork(reducesMotion: true)?.lastPathComponent == "B.png")
        #expect(streaming().mark?.lastPathComponent == "b.png")
        #expect(streaming().displayRarity == .epic)
    }

    @Test("Nitro's title is Nitro and its level")
    func nitroTitle() {
        let nitro = CatalogBadge(
            badgeID: 1, isOwned: true, currentTierKey: "ruby",
            tiers: [BadgeTier(key: "ruby", name: "Ruby", rarity: .mythic)]
        )
        #expect(nitro.title == "Nitro Ruby")
        #expect(BadgeRarity.mythic.title == "Mythic")
    }

    @Test("Owned and earnable split; staff and Nitro fixed unless tenure is hideable")
    func arrangement() {
        let staff = CatalogBadge(badgeID: 22, isOwned: true)
        let nitro = CatalogBadge(badgeID: 1, isOwned: true)
        let hidden = streaming(hidden: true)
        let earnable = CatalogBadge(badgeID: 21, isOwned: false, isEarnable: true)
        let all = [staff, nitro, hidden, earnable]
        #expect(all.ownedAndEarnable.owned.count == 3)
        #expect(all.ownedAndEarnable.earnable.map(\.badgeID) == [21])
        let fixed = all.arrangement(tenureHideable: false)
        #expect(fixed.fixed.map(\.badgeID) == [22, 1])
        #expect(fixed.hidden.map(\.badgeID) == [19])
        let hideable = all.arrangement(tenureHideable: true)
        #expect(hideable.fixed.map(\.badgeID) == [22])
        #expect(hideable.ordered.map(\.badgeID) == [1])
    }

    @Test("The popout's mark: the highest levels first, three at most")
    func topIcons() {
        let age = CatalogBadge(
            badgeID: 18, isOwned: true, currentTierKey: "c",
            tiers: ["a", "b", "c", "d"].map { BadgeTier(key: $0, name: $0, simpleIconURL: url("age-\($0)")) }
        )
        let icons = [streaming(), age].topLevelIcons
        #expect(icons.map(\.lastPathComponent) == ["age-c.png", "B.png"])
    }
}
