import Foundation
import WingcordCore

extension DiscordTheme {

    /// Discord's Grand Theft Auto VI campaign, which brought the Vice City
    /// theme on 2026-11-16 at 18:00 UTC, with an app icon and the Pricedown
    /// display-name font ("hexagon" in its bundle: dates in module `211824`,
    /// rules in `773527`).
    ///
    /// **Free for a while, longer with Nitro, then gone.** Every account may
    /// wear the theme until 13 December 2026, 18:00 UTC; Nitro (not Classic or
    /// Basic: Discord asks for `TIER_2`) keeps it until 20 February 2027,
    /// 18:00 UTC, when Discord hides it from everyone.
    enum ViceCity {
        /// 2026-11-16T18:00:00Z.
        static let start = Date(timeIntervalSince1970: 1_794_852_000)
        /// 2026-12-13T18:00:00Z: the end for an account without Nitro.
        static let freeUntil = Date(timeIntervalSince1970: 1_797_184_800)
        /// 2027-02-20T18:00:00Z: the end with Nitro, and for everyone.
        static let nitroUntil = Date(timeIntervalSince1970: 1_803_146_400)

        /// Until when an account on `tier` may wear it (`773527`'s `A`).
        static func lastMoment(for tier: PremiumTier) -> Date {
            tier == .nitro ? nitroUntil : freeUntil
        }

        /// Whether the account may wear it now, as Discord decides: what the
        /// sync may write to the account.
        static func isAvailable(to tier: PremiumTier, at now: Date = .now) -> Bool {
            now >= start && now < lastMoment(for: tier)
        }

        /// Whether the gallery offers it: from the campaign's start until
        /// Discord hides it for everyone. A reader already wearing it keeps it
        /// after that; it is only no longer offered.
        static func isOffered(at now: Date = .now) -> Bool {
            now >= start && now < nitroUntil
        }

        /// Discord's own words for it, under the tile.
        static let help = "Limited-Time Color Theme. Promoted by Rockstar Games."
    }

    /// The themes the gallery lists now: Discord's own, and Vice City while
    /// Discord's campaign runs, or while it is the reader's theme.
    static func offered(wearing current: DiscordTheme?, at now: Date = .now) -> [DiscordTheme] {
        allCases.filter { $0 != .viceCity || ViceCity.isOffered(at: now) || current == .viceCity }
    }
}
