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

    /// The theme a message shares — **drawn whenever it has colours**, as
    /// Discord's card is (`0c2828db2e3ee692.js`'s `renderShareClientTheme`:
    /// `null != e.sharedClientTheme`). Its room is read only when Preview is
    /// pressed, so a room it does not name — none sent, or 0, proto's unset —
    /// is taken as dark rather than costing the card: that check dropped
    /// whole themes and left their messages blank (Alex's screenshots 20, 21).
    var domain: SharedClientTheme? {
        let parsed = (colors ?? []).compactMap(SharedClientTheme.color(fromHex:))
        guard !parsed.isEmpty else { return nil }
        return SharedClientTheme(
            colors: parsed,
            gradientAngle: gradient_angle ?? 0,
            baseMix: base_mix ?? SharedClientTheme.defaultBaseMix,
            baseTheme: base_theme.flatMap { (1...4).contains($0) ? $0 : nil } ?? 1
        )
    }

    /// One the account keeps — `74396`'s check, which is the saved list's and
    /// not the card's: colours, and a room it knows.
    var savedDomain: SharedClientTheme? {
        guard let base_theme, (1...4).contains(base_theme) else { return nil }
        return domain
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
            .custom_themes?.compactMap(\.savedDomain) ?? []
    }
}
