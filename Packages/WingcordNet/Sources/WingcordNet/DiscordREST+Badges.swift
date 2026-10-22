import Foundation
import WingcordCore

// MARK: - The badge directory
//
// docs/CLIPS-PRESENCE.md, Phase 8. Discord's three routes (build 643186,
// `682618` and the profile editor's `l7`):
//
//   GET   /users/{id|@me}/badges                  → {badges:[…]}
//   GET   /users/{id|@me}/badges/{badge_id}       → one, with progress
//                                                    (?with_progress=false
//                                                    for the popover)
//   PATCH /users/@me/badges/settings              {display_order?, hidden_badges?}

extension DiscordREST {

    /// Every badge `userID` owns or could earn. Nil is the reader.
    public func badgeCatalog(of userID: UserID?) async throws -> [CatalogBadge] {
        struct Reply: Decodable { var badges: [BadgeDTO]? }
        let who = userID.map { String($0.rawValue) } ?? "@me"
        return try await get("/users/\(who)/badges", route: "users/{id}/badges", as: Reply.self)
            .badges?.compactMap(\.domain) ?? []
    }

    /// One badge, with its progress unless asked not to.
    public func badge(_ badgeID: Int, of userID: UserID?, withProgress: Bool = true) async throws -> CatalogBadge? {
        let who = userID.map { String($0.rawValue) } ?? "@me"
        let query = withProgress ? "" : "?with_progress=false"
        return try await get(
            "/users/\(who)/badges/\(badgeID)\(query)", route: "users/{id}/badges/{badge}", as: BadgeDTO.self
        ).domain
    }

    /// Hides badges and — with Nitro — orders the rest. A key left out is
    /// left as it is, as Discord's own save leaves it.
    public func setBadgeSettings(displayOrder: [Int]?, hiddenBadges: [Int]?) async throws {
        struct Body: Encodable {
            var display_order: [Int]?
            var hidden_badges: [Int]?
        }
        guard displayOrder != nil || hiddenBadges != nil else { return }
        _ = try await requestData(
            method: "PATCH",
            path: "/users/@me/badges/settings",
            route: "users/@me/badges/settings",
            body: Body(display_order: displayOrder, hidden_badges: hiddenBadges)
        )
    }
}

/// A badge as the directory sends it.
struct BadgeDTO: Decodable, Sendable {
    var badge_id: LenientInt?
    var name: String?
    var description: String?
    var owned: Bool?
    var hidden: Bool?
    var is_earnable: Bool?
    var current_tier: LenientString?
    var next_tier: LenientString?
    var tiers: [TierDTO]?
    var progress: [ProgressDTO]?
    var obtained_at: String?
    var tier_obtained_at: [String: String]?
    var info_label: String?
    var simple_icon_url: URL?
    var complex_icon_static_url: URL?
    var complex_icon_animated_url: URL?
    var rarity: Int?

    struct TierDTO: Decodable, Sendable {
        var key: LenientString?
        var name: String?
        var milestone_text: String?
        var simple_icon_url: URL?
        var simple_icon_raster_url: URL?
        var complex_icon_static_url: URL?
        var complex_icon_animated_url: URL?
        var rarity: Int?

        var domain: BadgeTier? {
            guard let key = key?.value else { return nil }
            return BadgeTier(
                key: key,
                name: name ?? key.capitalized,
                milestoneText: milestone_text,
                simpleIconURL: simple_icon_url ?? simple_icon_raster_url,
                complexIconURL: complex_icon_static_url,
                complexIconAnimatedURL: complex_icon_animated_url,
                rarity: rarity.flatMap(BadgeRarity.init(rawValue:))
            )
        }
    }

    struct ProgressDTO: Decodable, Sendable {
        var current: Double?
        var threshold: Double?
    }

    var domain: CatalogBadge? {
        guard let id = badge_id?.value else { return nil }
        let first = progress?.first
        return CatalogBadge(
            badgeID: id,
            name: name,
            description: description,
            isOwned: owned ?? false,
            isHidden: hidden ?? false,
            isEarnable: is_earnable ?? false,
            currentTierKey: current_tier?.value,
            nextTierKey: next_tier?.value,
            tiers: (tiers ?? []).compactMap(\.domain),
            progress: first.flatMap { entry in
                entry.threshold.map { (current: entry.current ?? 0, threshold: $0) }
            },
            obtainedAt: obtained_at.flatMap(Self.date),
            tierObtainedAt: (tier_obtained_at ?? [:]).compactMapValues(Self.date),
            infoLabel: info_label,
            simpleIconURL: simple_icon_url,
            complexIconURL: complex_icon_static_url,
            complexIconAnimatedURL: complex_icon_animated_url,
            rarity: rarity.flatMap(BadgeRarity.init(rawValue:))
        )
    }

    static func date(_ text: String) -> Date? {
        ISO8601DateFormatter.withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// An id Discord sends as a number or as a string.
struct LenientInt: Decodable, Sendable {
    var value: Int?
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            value = number
        } else if let text = try? container.decode(String.self) {
            value = Int(text)
        }
    }
}

/// A key Discord sends as a string or as a number.
struct LenientString: Decodable, Sendable {
    var value: String?
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = text
        } else if let number = try? container.decode(Int.self) {
            value = String(number)
        }
    }
}
