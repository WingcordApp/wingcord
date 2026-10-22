import Foundation
import WingcordCore

/// `shared_client_theme` as a message carries it and a send writes it —
/// `{"colors":["5865F2","EB459E"],"gradient_angle":90,"base_mix":74,"base_theme":1}`
/// (web build 641803's share modal builds exactly this) — and an entry of
/// `GET /users/@me/custom-themes`, which is the same object.
struct SharedClientThemeDTO: Codable, Sendable {
    var colors: [String]?
    var gradient_angle: Double?
    var base_mix: Double?
    var base_theme: Int?

    /// Nil for one Discord would not keep: no colours, or a room it does not
    /// know (`74396`'s check).
    var domain: SharedClientTheme? {
        let parsed = (colors ?? []).compactMap(SharedClientTheme.color(fromHex:))
        let theme = SharedClientTheme(
            colors: parsed,
            gradientAngle: gradient_angle ?? 0,
            baseMix: base_mix ?? SharedClientTheme.defaultBaseMix,
            baseTheme: base_theme ?? 0
        )
        return theme.isValid ? theme : nil
    }

    /// **Field by field, and never failing**: this rides on a message, and a
    /// shape this cannot read must cost the card, never the message.
    init(from decoder: any Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        colors = try? container?.decodeIfPresent([String].self, forKey: .colors)
        gradient_angle = try? container?.decodeIfPresent(Double.self, forKey: .gradient_angle)
        base_mix = try? container?.decodeIfPresent(Double.self, forKey: .base_mix)
        base_theme = try? container?.decodeIfPresent(Int.self, forKey: .base_theme)
    }

    init(_ theme: SharedClientTheme) {
        colors = theme.colors.map(SharedClientTheme.hex)
        gradient_angle = theme.gradientAngle
        base_mix = theme.baseMix
        base_theme = theme.baseTheme
    }
}

extension DiscordREST {
    /// The account's own saved custom themes — what Discord's Appearance panel
    /// asks for as it opens (`GET /users/@me/custom-themes`, answered
    /// `{"custom_themes":[…]}`). Read-only: Discord writes none from the client.
    public func customThemes() async throws -> [SharedClientTheme] {
        struct Reply: Decodable { var custom_themes: [SharedClientThemeDTO]? }
        return try await get("/users/@me/custom-themes", route: "users/@me/custom-themes", as: Reply.self)
            .custom_themes?.compactMap(\.domain) ?? []
    }
}
