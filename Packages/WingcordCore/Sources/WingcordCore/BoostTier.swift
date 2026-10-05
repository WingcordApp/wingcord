import Foundation

/// What a server's boost level unlocks — Discord's own table (`ti` in the web
/// bundle, beside `PremiumGuildTiers`), in one place.
///
/// **A perk is offered on the FEATURE, and the tier is only the fallback.**
/// Discord grants `BANNER`, `VANITY_URL` and the rest to partnered and verified
/// servers whatever their boosts, and the feature string is what its own pages
/// test. So `unlocks(_:in:)` asks the features first and the tier second — a
/// server that has the feature without the boosts must not be told to boost.
public enum BoostTier {
    /// The level each perk arrives at, as Discord's table lists it.
    public enum Perk: Hashable, Sendable, CaseIterable {
        case inviteSplash
        case animatedIcon
        case banner
        case roleIcons
        case animatedBanner
        case vanityURL

        /// The feature string Discord sets on a server that has it.
        public var feature: String {
            switch self {
            case .inviteSplash: "INVITE_SPLASH"
            case .animatedIcon: "ANIMATED_ICON"
            case .banner: "BANNER"
            case .roleIcons: "ROLE_ICONS"
            case .animatedBanner: "ANIMATED_BANNER"
            case .vanityURL: "VANITY_URL"
            }
        }

        /// The first level that unlocks it.
        public var level: Int {
            switch self {
            case .inviteSplash, .animatedIcon: 1
            case .banner, .roleIcons: 2
            case .animatedBanner, .vanityURL: 3
            }
        }
    }

    /// Whether a server has a perk — by its feature, or by its level.
    public static func unlocks(_ perk: Perk, features: Set<String>, premiumTier: Int) -> Bool {
        features.contains(perk.feature) || premiumTier >= perk.level
    }

    /// A voice channel's ceiling, in bits per second.
    ///
    /// 96, 128, 256 and 384 kbps by level; `VIP_REGIONS` lifts any server to
    /// the top one, which is Discord's own rule for partnered servers.
    public static func maximumBitrate(premiumTier: Int, features: Set<String>) -> Int {
        if features.contains("VIP_REGIONS") { return 384_000 }
        switch premiumTier {
        case 1: return 128_000
        case 2: return 256_000
        case 3: return 384_000
        default: return 96_000
        }
    }

    /// The bitrates a voice channel's Overview offers: Discord's slider stops
    /// up to the server's ceiling, with the channel's own value kept even when
    /// it sits above it — a server that lost its boosts still has channels at
    /// 256 kbps, and a picker that cannot show the value silently changes it.
    public static func bitrateChoices(maximum: Int, current: Int) -> [Int] {
        let stops = [8_000, 16_000, 32_000, 48_000, 64_000, 80_000, 96_000, 128_000, 256_000, 384_000]
        var choices = stops.filter { $0 <= maximum }
        if !choices.contains(current) {
            choices.append(current)
            choices.sort()
        }
        return choices
    }
}

/// The slowmode intervals Discord's Overview offers (`s_7`), and the ceiling a
/// typed value may reach (`WA1`, six hours).
public enum SlowmodeChoices {
    public static let presets = [0, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 21600]
    public static let maximum = 21600

    /// The presets, with a channel's own value kept in place where it is not
    /// one of them — Discord's control does exactly this (`e.includes(r) ||
    /// e.unshift(r)`), so a custom 45 seconds is shown rather than replaced.
    public static func choices(including current: Int) -> [Int] {
        presets.contains(current) ? presets : ([current] + presets).sorted()
    }

    /// Discord's own labels: "Off", "5s", "1m", "6h".
    public static func title(_ seconds: Int) -> String {
        switch seconds {
        case 0: "Off"
        case ..<60: "\(seconds)s"
        case ..<3600 where seconds % 60 == 0: "\(seconds / 60)m"
        case 3600... where seconds % 3600 == 0: "\(seconds / 3600)h"
        default: "\(seconds)s"
        }
    }
}

/// A server's Custom Invite Link — `GET /guilds/{id}/vanity-url`.
public struct VanityURL: Hashable, Sendable {
    /// Nil where the server has none.
    public var code: String?
    public var uses: Int

    public init(code: String? = nil, uses: Int = 0) {
        self.code = code
        self.uses = uses
    }
}
