import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// A server's theme as Discord's settings save writes it (`679787`'s `QK`).
@Suite("Server theme on the wire")
struct ServerThemeWireTests {

    private let guild = GuildID(rawValue: 1)

    @Test("A preset sends its id and clears the custom colour")
    func preset() async throws {
        let (rest, token) = await RequestRecorder.client(status: 200, body: "{}")
        let saved = try await rest.updateServerTheme(GuildTheme(isEnabled: true, presetID: 9), in: guild)
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "PATCH")
        #expect(request.path == "/api/v9/guilds/1/theme")
        #expect(request.json?["preset_id"] as? Int == 9)
        #expect(request.json?["custom_user_theme_settings"] is NSNull)
        #expect(request.json?["enabled"] as? Bool == true)
        // No theme in the answer: what was sent is what the server has.
        #expect(saved == GuildTheme(isEnabled: true, presetID: 9))
    }

    @Test("A custom theme sends one colour, no stops, its angle and intensity")
    func custom() async throws {
        let (rest, token) = await RequestRecorder.client(status: 200, body: "{}")
        _ = try await rest.updateServerTheme(
            GuildTheme(isEnabled: true, colors: [0x58_65_F2], angle: 0, baseMix: 74),
            in: guild
        )
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.json?["preset_id"] is NSNull)
        let custom = try #require(request.json?["custom_user_theme_settings"] as? [String: Any])
        #expect(custom["colors"] as? [String] == ["#5865F2"])
        #expect((custom["gradient_color_stops"] as? [Any])?.isEmpty == true)
        #expect(custom["gradient_angle"] as? Double == 0)
        #expect(custom["base_mix"] as? Double == 74)
    }

    @Test("Off is sent as off, with the theme kept for next time")
    func off() async throws {
        let (rest, token) = await RequestRecorder.client(status: 200, body: "{}")
        _ = try await rest.updateServerTheme(GuildTheme(isEnabled: false, presetID: 3), in: guild)
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.json?["enabled"] as? Bool == false)
        #expect(request.json?["preset_id"] as? Int == 3)
    }

    @Test("A theme in the answer is the one kept")
    func answerWins() async throws {
        let (rest, _) = await RequestRecorder.client(
            status: 200,
            body: ##"{"theme":{"preset_id":null,"custom_user_theme_settings":{"colors":["#77C579"],"gradient_color_stops":[],"gradient_angle":0,"base_mix":0},"enabled":true}}"##
        )
        let saved = try await rest.updateServerTheme(GuildTheme(isEnabled: true, presetID: 1), in: guild)
        #expect(saved.colors == [0x77_C5_79])
        #expect(saved.presetID == nil)
    }
}
