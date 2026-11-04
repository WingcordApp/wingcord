import Foundation

/// The Boost progress bar's goal — how many boosts unlock everything a
/// server can buy with them.
///
/// **Ported from Discord's own sum** (stable 649389, `35a17d…`'s `ti` over the
/// price table in `568065`): the boosts that reach level 3, plus the price of
/// every power-up that stands outside the levels. The same for every server —
/// the bar counts toward everything, not toward what a server already has —
/// except that a server Discord has lifted to level 3 by hand
/// (`PREMIUM_TIER_3_OVERRIDE`) starts from nothing.
public enum BoostGoal {
    /// Boosts that reach level 3.
    public static let levelThree = 14

    /// Power-ups outside the levels, and what each costs. Vanity URL (5) is
    /// part of level 3 and is not counted again.
    public static let powerUps: [(feature: String, price: Int)] = [
        ("GUILD_TAGS", 3),
        ("ENHANCED_ROLE_COLORS", 3),
        ("GUILD_TAGS_BADGE_PACK_PETS", 3),
        ("GUILD_TAGS_BADGE_PACK_FLEX", 5),
        ("GUILD_TAGS_BADGE_PACK_PLANT", 3),
        ("GUILD_TAGS_BADGE_PACK_CREEPY_CRAWLIES", 2),
    ]
    /// The two Discord counts only where they are offered: a server theme and
    /// game server hosting, 3 each.
    public static let themePrice = 3
    public static let gameServersPrice = 3

    /// The goal for a server.
    ///
    /// - Parameters:
    ///   - offersThemes: whether the server-theme power-up is on offer.
    ///   - offersGameServers: whether game server hosting is.
    public static func goal(features: Set<String>, offersThemes: Bool, offersGameServers: Bool) -> Int {
        var goal = features.contains("PREMIUM_TIER_3_OVERRIDE") ? 0 : levelThree
        goal += powerUps.reduce(0) { $0 + $1.price }
        if offersThemes { goal += themePrice }
        if offersGameServers { goal += gameServersPrice }
        return goal
    }
}
