import Foundation
import Testing
@testable import WingcordCore
@testable import WingcordNet

/// Clearing a setting sends `null`, never nothing.
///
/// A synthesised `Encodable` drops nil keys, and on these routes an absent key
/// means "leave it". So "No System Messages", "No Inactive Channel", a widget's
/// "No Invite", a role going back to one colour and the banner's "Server Icon
/// Color" all saved nothing while the indicator said "Saved". Each is pinned on
/// the request the client actually makes.
@Suite("Clearing a setting sends null")
struct ExplicitNullWireTests {

    private let guild = GuildID(rawValue: 1)

    @Test("No System Messages and No Inactive Channel send null")
    func engagementSendsNull() async throws {
        let (rest, token) = await RequestRecorder.client()
        _ = try? await rest.updateEngagementSettings(
            in: guild,
            systemChannelID: nil,
            systemChannelFlags: [],
            defaultMessageNotifications: .onlyMentions,
            afkChannelID: nil,
            afkTimeout: 300
        )
        let body = try #require(RequestRecorder.requests(for: token).first?.json)
        #expect(body["system_channel_id"] is NSNull)
        #expect(body["afk_channel_id"] is NSNull)
    }

    @Test("A widget with no invite channel sends null")
    func widgetSendsNull() async throws {
        let (rest, token) = await RequestRecorder.client()
        _ = try? await rest.updateWidget(in: guild, isEnabled: true, channelID: nil)
        let body = try #require(RequestRecorder.requests(for: token).first?.json)
        #expect(body["channel_id"] is NSNull)
    }

    @Test("A role going back to one colour sends its other stops as null")
    func solidRoleSendsNullStops() async throws {
        let (rest, token) = await RequestRecorder.client()
        let role = Role(
            id: RoleID(rawValue: 5),
            name: "Mods",
            colorValue: 0xFF0000,
            colors: RoleColors(primary: 0xFF0000)
        )
        _ = try? await rest.updateRole(role, in: guild)
        let body = try #require(RequestRecorder.requests(for: token).first?.json)
        let colors = try #require(body["colors"] as? [String: Any])
        #expect(colors["secondary_color"] is NSNull)
        #expect(colors["tertiary_color"] is NSNull)
    }

    @Test("Server Icon Color sends brand_color_primary as null")
    func iconColourSendsNull() async throws {
        let (rest, token) = await RequestRecorder.client()
        let profile = GuildProfile(id: guild, name: "bnaotter")
        _ = try? await rest.updateGuildProfile(profile)
        let body = try #require(RequestRecorder.requests(for: token).first?.json)
        #expect(body.keys.contains("brand_color_primary"))
        #expect(body["brand_color_primary"] is NSNull)
        #expect(body["description"] is NSNull)
    }

    @Test("An empty trait slot is not sent")
    func emptyTraitsDropped() async throws {
        let (rest, token) = await RequestRecorder.client()
        var profile = GuildProfile(id: guild, name: "bnaotter")
        profile.traits = [
            GuildTrait(id: 0, emojiName: "fire", label: "Speedruns"),
            GuildTrait(id: 1, label: ""),
            GuildTrait(id: 2, label: "Art"),
        ]
        _ = try? await rest.updateGuildProfile(profile)
        let body = try #require(RequestRecorder.requests(for: token).first?.json)
        let traits = try #require(body["traits"] as? [[String: Any]])
        #expect(traits.count == 2)
        #expect(traits.map { $0["position"] as? Int } == [0, 1])
        #expect(traits.first?["emoji_name"] as? String == "fire")
    }
}
