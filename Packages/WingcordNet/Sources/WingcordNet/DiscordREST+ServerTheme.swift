import Foundation
import WingcordCore

// MARK: - A server's own theme
//
// Discord's settings page save (`1e901507`'s `ju`): `PATCH /guilds/{id}/theme`
// with the theme in its wire form (`679787`'s `QK`) and the switch beside it.
// Not captured; the body is Discord's writer and the read is the shape
// `GuildThemeDTO` already decodes off `guild.theme`.

extension DiscordREST {

    /// Saves the server's theme: a preset, or one colour and its intensity,
    /// and whether it is on.
    ///
    /// **Both theme fields always go**, one of them null — Discord's writer
    /// sends `preset_id` and `custom_user_theme_settings` together, so picking
    /// a preset clears a custom colour rather than leaving it underneath.
    ///
    /// - Returns: the theme the answer carried, else the one sent — Discord's
    ///   own fallback (`s?.theme !== void 0 ? s.theme : l`).
    public func updateServerTheme(_ theme: GuildTheme, in guildID: GuildID) async throws -> GuildTheme {
        let data = try await requestData(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/theme",
            route: "guilds/{id}/theme",
            body: ServerThemeBody(theme)
        )
        struct Answer: Decodable { var theme: GuildThemeField? }
        let answer = try? Self.decoder.decode(Answer.self, from: data)
        switch answer?.theme {
        case .set(let saved)?: return saved
        case .cleared?, nil: return theme
        }
    }
}

/// The theme as Discord writes it.
struct ServerThemeBody: Encodable, Sendable {
    @ExplicitNull var preset_id: Int?
    @ExplicitNull var custom_user_theme_settings: Custom?
    var enabled: Bool

    struct Custom: Encodable, Sendable {
        /// `#RRGGBB`, as the captured theme carries them.
        var colors: [String]
        /// Always empty: a server's custom theme is one colour, and Discord's
        /// editor writes no stops (`UPDATE_CUSTOM`'s `gradientColorStops: []`).
        var gradient_color_stops: [String]
        var gradient_angle: Double
        var base_mix: Double
    }

    init(_ theme: GuildTheme) {
        enabled = theme.isEnabled
        if let color = theme.colors.first {
            preset_id = nil
            custom_user_theme_settings = Custom(
                colors: [Self.hex(color)],
                gradient_color_stops: [],
                gradient_angle: theme.angle,
                base_mix: theme.baseMix
            )
        } else {
            preset_id = theme.presetID
            custom_user_theme_settings = nil
        }
    }

    /// `#RRGGBB`, upper case like the capture.
    static func hex(_ color: UInt32) -> String {
        String(format: "#%06X", color & 0xFF_FF_FF)
    }
}
