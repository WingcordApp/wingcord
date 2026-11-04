import Foundation

// MARK: - Discord's levelled badges
//
// docs/CLIPS-PRESENCE.md, Phase 8. Discord's badge directory (build 643186,
// `BadgeDirectoryStore`): `GET /users/{id}/badges` answers every badge the
// person owns and every one they could still earn, each with its tiers —
// Streaming's Newcomer, Fledgling, Breakout, Standout…; Account Age's levels
// up to Sequoia; Nitro's Starter to Ruby — its progress towards the next, and
// when each was reached. `PATCH /users/@me/badges/settings` hides badges and,
// with Nitro, orders them.

/// Which badge — Discord's integer `badge_id`.
public enum BadgeKind: Int, Hashable, Sendable, CaseIterable {
    case premiumTenure = 1
    case partner = 2
    case certifiedModerator = 3
    case hypesquad = 4
    case hypesquadHouse1 = 5
    case hypesquadHouse2 = 6
    case hypesquadHouse3 = 7
    case bugHunterLevel1 = 8
    case bugHunterLevel2 = 9
    case verifiedDeveloper = 10
    case earlySupporter = 11
    case guildBooster = 12
    case legacyUsername = 13
    case questCompleted = 14
    case aprilFools2026 = 15
    case orbProfile = 16
    case gifting = 17
    case accountAge = 18
    case streaming = 19
    case gameTime = 20
    case gameVariety = 21
    case staff = 22

    /// The profile route's string ids, as Discord's `609782` maps them.
    public static func forProfileID(_ id: String) -> BadgeKind? {
        if id.hasPrefix("premium_tenure_") || id == "premium" { return .premiumTenure }
        if id.hasPrefix("guild_booster_lvl") { return .guildBooster }
        switch id {
        case "staff", "staff_hidden", "staff_personal": return .staff
        case "partner": return .partner
        case "certified_moderator": return .certifiedModerator
        case "hypesquad": return .hypesquad
        case "hypesquad_house_1": return .hypesquadHouse1
        case "hypesquad_house_2": return .hypesquadHouse2
        case "hypesquad_house_3": return .hypesquadHouse3
        case "bug_hunter_level_1": return .bugHunterLevel1
        case "bug_hunter_level_2": return .bugHunterLevel2
        case "verified_developer": return .verifiedDeveloper
        case "early_supporter": return .earlySupporter
        case "legacy_username": return .legacyUsername
        case "quest_completed": return .questCompleted
        case "april_fools_2026": return .aprilFools2026
        case "orb_profile_badge": return .orbProfile
        case "gifting": return .gifting
        case "account_age": return .accountAge
        case "streaming": return .streaming
        case "game_time": return .gameTime
        case "game_variety": return .gameVariety
        default: return nil
        }
    }

    /// The four that climb through levels (`988341`'s `d`).
    public var isLevelled: Bool {
        switch self {
        case .accountAge, .streaming, .gameTime, .gameVariety: true
        default: false
        }
    }

    /// The three whose progress is a bar to the next level (`988341`'s `l`) —
    /// Account Age climbs by itself.
    public var showsProgress: Bool {
        switch self {
        case .streaming, .gameTime, .gameVariety: true
        default: false
        }
    }

    /// A badge that can never be hidden — Staff always; Nitro's unless the
    /// account's `2026-08-badge-management` says tenure is hideable.
    public func isFixed(tenureHideable: Bool) -> Bool {
        self == .staff || (self == .premiumTenure && !tenureHideable)
    }
}

/// How rare a level is — the chip beside "Unlocked …".
public enum BadgeRarity: Int, Hashable, Sendable, Codable {
    case common = 1
    case rare = 2
    case epic = 3
    case legendary = 4
    case mythic = 5

    public var title: String {
        switch self {
        case .common: "Common"
        case .rare: "Rare"
        case .epic: "Epic"
        case .legendary: "Legendary"
        case .mythic: "Mythic"
        }
    }
}

/// One level of a badge: its name, what reaching it takes, its pictures.
public struct BadgeTier: Hashable, Sendable, Identifiable {
    public var key: String
    /// "Breakout", "Sequoia", "Ruby" — or nothing: the Server Booster's nine
    /// levels have keys ("LEVEL_1") and milestones ("1 Month") but no names,
    /// and Discord draws none (see `CatalogBadge.levelName`).
    public var name: String?
    /// What reaching it takes — "20 hours", "5 years".
    public var milestoneText: String?
    /// The small mark, for the row and the grids.
    public var simpleIconURL: URL?
    /// The large artwork, for the popover and the detail.
    public var complexIconURL: URL?
    /// The same artwork moving — drawn unless Reduce Motion is on, as
    /// Discord's detail does.
    public var complexIconAnimatedURL: URL?
    public var rarity: BadgeRarity?

    public var id: String { key }

    public init(
        key: String, name: String?, milestoneText: String? = nil,
        simpleIconURL: URL? = nil, complexIconURL: URL? = nil, complexIconAnimatedURL: URL? = nil,
        rarity: BadgeRarity? = nil
    ) {
        self.key = key
        self.name = name
        self.milestoneText = milestoneText
        self.simpleIconURL = simpleIconURL
        self.complexIconURL = complexIconURL
        self.complexIconAnimatedURL = complexIconAnimatedURL
        self.rarity = rarity
    }
}

/// One badge in a person's directory.
public struct CatalogBadge: Hashable, Sendable, Identifiable {
    /// Discord's integer id, kept whole — a badge added later still draws.
    public var badgeID: Int
    /// "Streaming", "Account Age", "Game Time".
    public var name: String?
    /// How it is earned — "Stream more hours to other users to level up this
    /// badge."
    public var description: String?
    public var isOwned: Bool
    public var isHidden: Bool
    /// One the person could still earn — "Available to unlock".
    public var isEarnable: Bool
    public var currentTierKey: String?
    public var nextTierKey: String?
    public var tiers: [BadgeTier]
    /// Towards the next level: where they are and what it takes.
    public var progress: (current: Double, threshold: Double)?
    public var obtainedAt: Date?
    public var tierObtainedAt: [String: Date]
    /// What the badge says about them — "23 hours streamed to others",
    /// "7 years, 9 months".
    public var infoLabel: String?
    /// A badge's own pictures and rarity, for one without levels — a level's
    /// win where there is one (Discord's `R?.x ?? h.x`).
    public var simpleIconURL: URL?
    public var complexIconURL: URL?
    public var complexIconAnimatedURL: URL?
    public var rarity: BadgeRarity?

    public var id: Int { badgeID }
    public var kind: BadgeKind? { BadgeKind(rawValue: badgeID) }

    public init(
        badgeID: Int, name: String? = nil, description: String? = nil, isOwned: Bool, isHidden: Bool = false,
        isEarnable: Bool = false, currentTierKey: String? = nil, nextTierKey: String? = nil,
        tiers: [BadgeTier] = [], progress: (current: Double, threshold: Double)? = nil,
        obtainedAt: Date? = nil, tierObtainedAt: [String: Date] = [:], infoLabel: String? = nil,
        simpleIconURL: URL? = nil, complexIconURL: URL? = nil, complexIconAnimatedURL: URL? = nil,
        rarity: BadgeRarity? = nil
    ) {
        self.simpleIconURL = simpleIconURL
        self.complexIconURL = complexIconURL
        self.complexIconAnimatedURL = complexIconAnimatedURL
        self.rarity = rarity
        self.badgeID = badgeID
        self.name = name
        self.description = description
        self.isOwned = isOwned
        self.isHidden = isHidden
        self.isEarnable = isEarnable
        self.currentTierKey = currentTierKey
        self.nextTierKey = nextTierKey
        self.tiers = tiers
        self.progress = progress
        self.obtainedAt = obtainedAt
        self.tierObtainedAt = tierObtainedAt
        self.infoLabel = infoLabel
    }

    public static func == (lhs: CatalogBadge, rhs: CatalogBadge) -> Bool {
        lhs.badgeID == rhs.badgeID && lhs.name == rhs.name && lhs.isOwned == rhs.isOwned
            && lhs.simpleIconURL == rhs.simpleIconURL && lhs.complexIconURL == rhs.complexIconURL
            && lhs.complexIconAnimatedURL == rhs.complexIconAnimatedURL && lhs.rarity == rhs.rarity
            && lhs.isHidden == rhs.isHidden && lhs.isEarnable == rhs.isEarnable
            && lhs.currentTierKey == rhs.currentTierKey && lhs.nextTierKey == rhs.nextTierKey
            && lhs.tiers == rhs.tiers && lhs.progress?.current == rhs.progress?.current
            && lhs.progress?.threshold == rhs.progress?.threshold && lhs.obtainedAt == rhs.obtainedAt
            && lhs.tierObtainedAt == rhs.tierObtainedAt && lhs.infoLabel == rhs.infoLabel
            && lhs.description == rhs.description
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(badgeID)
        hasher.combine(currentTierKey)
        hasher.combine(isHidden)
    }

    public var currentTier: BadgeTier? { currentTierKey.flatMap { key in tiers.first { $0.key == key } } }
    public var nextTier: BadgeTier? { nextTierKey.flatMap { key in tiers.first { $0.key == key } } }

    /// The level drawn for it — the one reached, or for a badge not yet
    /// owned the one it would unlock first (`988341`'s `u`).
    public var displayTier: BadgeTier? {
        (isOwned ? currentTier : nextTier) ?? tiers.first
    }

    /// The artwork to draw large: moving unless motion is reduced, then
    /// still, then the small mark — Discord's `k ?? F ?? D`.
    public func artwork(reducesMotion: Bool) -> URL? {
        let tier = displayTier
        let animated = reducesMotion ? nil : (tier?.complexIconAnimatedURL ?? complexIconAnimatedURL)
        return animated ?? tier?.complexIconURL ?? complexIconURL ?? tier?.simpleIconURL ?? simpleIconURL
    }

    /// The small mark for rows and grids.
    public var mark: URL? {
        displayTier?.simpleIconURL ?? simpleIconURL ?? displayTier?.complexIconURL ?? complexIconURL
    }

    /// The level's rarity, or the badge's.
    public var displayRarity: BadgeRarity? { displayTier?.rarity ?? rarity }

    /// What a level is called on screen — `08ae84284fe61c6f.js`:
    /// `Q ? R?.name ?? R?.key : R?.name`. **Only Nitro falls back to the key**;
    /// any other level without a name has none, so a Server Booster's
    /// "LEVEL_1" is never drawn (Alex's screenshot 16).
    public func levelName(_ tier: BadgeTier) -> String? {
        kind == .premiumTenure ? tier.name ?? tier.key : tier.name
    }

    /// The big title: the level's name — "NITRO RUBY" for Nitro, whose
    /// levels are named by metal and stone — or the badge's own where its
    /// level has none.
    public var title: String {
        let tierName = displayTier.flatMap(levelName)
        if kind == .premiumTenure { return ["Nitro", tierName].compactMap(\.self).joined(separator: " ") }
        return tierName ?? name ?? ""
    }

    /// The small line over the title: the badge's name, when the title is a
    /// level's ("Account Age" over "SEQUOIA") — Discord's `eyebrow`. None for
    /// Nitro, whose title already says it, and none where the title is the
    /// badge's own name.
    public var eyebrow: String? {
        guard kind != .premiumTenure, displayTier.flatMap(levelName) != nil else { return nil }
        return name
    }

    /// When the level drawn was reached — `982240`'s `E`.
    public var unlockedAt: Date? {
        currentTierKey.flatMap { tierObtainedAt[$0] } ?? obtainedAt
    }

    /// What is left to the next level, never below nothing.
    public var remainingToNextTier: Double {
        guard let progress else { return 0 }
        return max(0, progress.threshold - progress.current)
    }

    /// How far between this level and the next, 0…1.
    public var fractionToNextTier: Double {
        guard let progress, progress.threshold > 0 else { return 0 }
        return min(max(progress.current / progress.threshold, 0), 1)
    }

    /// Whether the level at `index` has been reached.
    public func isReached(_ tier: BadgeTier) -> Bool {
        guard let current = currentTierKey,
              let reached = tiers.firstIndex(where: { $0.key == current }),
              let index = tiers.firstIndex(of: tier)
        else { return false }
        return index <= reached
    }
}

extension Array where Element == CatalogBadge {
    /// "Your badges" and "Available to unlock" — `988341`'s `E`.
    public var ownedAndEarnable: (owned: [CatalogBadge], earnable: [CatalogBadge]) {
        (filter(\.isOwned), filter { !$0.isOwned && $0.isEarnable })
    }

    /// What "Customize your badges" can move: the fixed ones, the ones in
    /// order, and the hidden ones — `988341`'s `h`.
    public func arrangement(tenureHideable: Bool) -> (fixed: [CatalogBadge], ordered: [CatalogBadge], hidden: [CatalogBadge]) {
        var fixed: [CatalogBadge] = []
        var ordered: [CatalogBadge] = []
        var hidden: [CatalogBadge] = []
        for badge in self where badge.isOwned {
            if badge.kind?.isFixed(tenureHideable: tenureHideable) == true {
                fixed.append(badge)
            } else if badge.isHidden {
                hidden.append(badge)
            } else {
                ordered.append(badge)
            }
        }
        return (fixed, ordered, hidden)
    }

    /// The popout's mark: the three highest levels among the levelled
    /// badges, highest first (`864197`).
    public var topLevelIcons: [URL] {
        let levelled: [BadgeKind] = [.streaming, .gameVariety, .gameTime, .accountAge]
        var marks: [(url: URL, level: Int)] = []
        for kind in levelled {
            guard let badge = first(where: { $0.badgeID == kind.rawValue }), badge.isOwned,
                  let key = badge.currentTierKey,
                  let level = badge.tiers.firstIndex(where: { $0.key == key }),
                  let url = badge.tiers[level].complexIconURL ?? badge.tiers[level].simpleIconURL
            else { continue }
            marks.append((url, level))
        }
        return marks.sorted { $0.level > $1.level }.prefix(3).map(\.url)
    }
}
