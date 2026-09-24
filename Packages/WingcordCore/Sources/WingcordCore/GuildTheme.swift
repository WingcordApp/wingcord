import Foundation

/// A server's own theme — the colours a server with the `GUILD_THEME` feature
/// asks every member's window to take while they are in it.
///
/// **Captured**, as `theme` on a whole guild object (`join discoverable
/// server.har`, the join's answer): `{"preset_id": null,
/// "custom_user_theme_settings": {"colors": ["#77C579"], "gradient_color_stops":
/// [], "gradient_angle": 0, "base_mix": 0}, "enabled": true}`. It rides READY
/// (under `properties`), GUILD_CREATE and GUILD_UPDATE.
///
/// **The same shape as a reader's own custom theme**, and Discord renders it
/// with the same generator — one of ten server presets, or a single colour
/// expanded into a gradient. See `ServerTheme` for the drawing.
public struct GuildTheme: Hashable, Sendable, Codable {
    /// The server has the theme switched on. A theme that is set up and off
    /// arrives whole, with this false.
    public var isEnabled: Bool
    /// One of Discord's ten server presets, `1...10`, or nil.
    public var presetID: Int?
    /// The custom colours, 24-bit. Discord draws a custom theme only from
    /// exactly **one**; see `resolved`.
    public var colors: [UInt32]
    /// Whether the custom theme carries explicit gradient stops — which
    /// disqualifies it, in Discord's own test.
    public var hasGradientStops: Bool
    /// CSS degrees, for a custom theme's gradient.
    public var angle: Double
    /// `0...100`: how far the ground comes forward — Discord's `base_mix`.
    public var baseMix: Double

    public init(
        isEnabled: Bool,
        presetID: Int? = nil,
        colors: [UInt32] = [],
        hasGradientStops: Bool = false,
        angle: Double = 0,
        baseMix: Double = 0
    ) {
        self.isEnabled = isEnabled
        self.presetID = presetID
        self.colors = colors
        self.hasGradientStops = hasGradientStops
        self.angle = angle
        self.baseMix = baseMix
    }

    /// What a server theme draws as, once Discord's rules are applied.
    public enum Resolved: Hashable, Sendable {
        /// One of the ten server presets, by Discord's id.
        case preset(Int)
        /// One colour, expanded into a gradient at `angle`.
        case custom(color: UInt32, angle: Double, baseMix: Double)
    }

    /// Discord's ids for its server presets — Twilight 1 through Blurple 10.
    public static let presetIDs = 1...10

    /// What is drawn, or nil for a theme that draws nothing.
    ///
    /// Module `875317`, line for line: **off is nothing**; a custom theme counts
    /// only as exactly one colour with no stops of its own, and wins over a
    /// preset id when it does; a preset id counts only if it is one of the ten.
    /// Anything else — two colours, stops, an id from a later release — is no
    /// theme at all rather than a guess at one.
    public var resolved: Resolved? {
        guard isEnabled else { return nil }
        if colors.count == 1, !hasGradientStops {
            return .custom(color: colors[0], angle: angle, baseMix: baseMix)
        }
        if let presetID, Self.presetIDs.contains(presetID) { return .preset(presetID) }
        return nil
    }
}

/// Whose theme a themed server is drawn in — Discord's
/// `GuildThemeSourcePreference`, synced in the reader's settings.
///
/// Two places hold one: **Appearance → "Default theme in servers"** for every
/// server (`appearance.default_guild_theme_preference`, field 14), and a
/// per-server override (`guilds[id].guild_theme_source_preference`, field 13).
public enum GuildThemeSource: Int, Hashable, Sendable {
    case unspecified = 0
    /// "Use my theme".
    case personal = 1
    /// "Use the server's theme".
    case guild = 2

    /// A value from a later release reads as unset, which is Discord's own
    /// default rather than a guess.
    public init(wire: UInt64) {
        self = Self(rawValue: Int(truncatingIfNeeded: wire)) ?? .unspecified
    }

    /// Which applies in one server — module `350503`, line for line: a
    /// server's own override wins when it says either, and otherwise the
    /// default does, where **anything but "my theme" is the server's** — so an
    /// account that has never touched the setting sees server themes.
    public static func resolved(override: GuildThemeSource, default: GuildThemeSource) -> GuildThemeSource {
        switch override {
        case .guild, .personal: override
        case .unspecified: `default` == .personal ? .personal : .guild
        }
    }
}

/// The reader's server-theme preferences, as their settings hold them.
public struct ServerThemePreferences: Hashable, Sendable {
    /// Appearance → "Default theme in servers".
    public var `default`: GuildThemeSource
    /// Servers the reader set apart from the default.
    public var overrides: [GuildID: GuildThemeSource]

    public init(default: GuildThemeSource = .unspecified, overrides: [GuildID: GuildThemeSource] = [:]) {
        self.default = `default`
        self.overrides = overrides
    }

    /// Whether `guildID`'s own theme is drawn, when it has one.
    public func usesServerTheme(in guildID: GuildID) -> Bool {
        GuildThemeSource.resolved(override: overrides[guildID] ?? .unspecified, default: `default`)
            == .guild
    }
}
