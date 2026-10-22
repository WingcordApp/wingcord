import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The invite a chat asks about as it opens — `invites.har` entry 8, trimmed
/// to the fields the card reads.
struct InviteCardDecodeTests {

    private static let captured = """
    {"type":0,"code":"LumenClub",
     "inviter":{"id":"987654321987654321","username":"alexsample","avatar":"00112233445566778899aabbccddeeff","global_name":"alex"},
     "expires_at":"2026-10-22T06:38:45+00:00",
     "guild":{"id":"1520000000000000001","name":"Lumen Club","splash":null,"banner":null,
              "icon":"161365fbbaa7c9a3e4b2a0d556a21ae3","features":["COMMUNITY","NEWS"]},
     "guild_id":"1520000000000000001",
     "channel":{"id":"1520000000000000002","type":0,"name":"\\ud83d\\udeec\\u2502welcome"},
     "approximate_member_count":121,"approximate_presence_count":38,
     "profile":{"id":"1520000000000000001","name":"Lumen Club","icon_hash":"161365fbbaa7c9a3e4b2a0d556a21ae3",
                "member_count":121,"online_count":38,"description":null,"banner_hash":null,
                "game_application_ids":[],"game_activity":{},"tag":null,"badge":0,
                "badge_color_primary":null,"badge_color_secondary":null,"badge_hash":null,"traits":[],
                "features":["COMMUNITY"],"visibility":1,"custom_banner_hash":null,
                "premium_subscription_count":0,"premium_tier":0}}
    """

    @Test("The captured server invite becomes its card, inviter and counts included")
    func capturedServerInvite() throws {
        let dto = try JSONDecoder().decode(InviteDTO.self, from: Data(Self.captured.utf8))
        let card = try #require(dto.card)
        #expect(card.kind == .server)
        #expect(card.name == "Lumen Club")
        #expect(card.memberCount == 121)
        #expect(card.onlineCount == 38)
        #expect(card.inviterName == "alex")
        #expect(card.inviterAvatarHash == "00112233445566778899aabbccddeeff")
        #expect(card.expiresAt != nil)
        #expect(card.header(sentByReader: false) == "You've been invited to join a server")
        // The profile is what Discord's current card is drawn from, and a
        // community without discovery wears the house.
        #expect(card.profile?.name == "Lumen Club")
        #expect(card.profile?.memberCount == 121)
        #expect(card.mark?.kind == .community)
        #expect(card.mark?.detail == "People with an invite link can join.")
    }

    @Test("An invite to a voice channel says so — Discord's voice card is drawn from it")
    func voiceChannelInvite() throws {
        let voice = Self.captured.replacingOccurrences(of: #""type":0,"name""#, with: #""type":2,"name""#)
        let card = try #require(try JSONDecoder().decode(InviteDTO.self, from: Data(voice.utf8)).card)
        #expect(card.isVoiceChannel)
        let text = try #require(try JSONDecoder().decode(InviteDTO.self, from: Data(Self.captured.utf8)).card)
        #expect(!text.isVoiceChannel)
    }

    /// Discord's own join for an unnamed group, and its member count is the
    /// number of people in it.
    @Test("An unnamed group is named by its members")
    func unnamedGroup() throws {
        let json = #"""
        {"type":1,"code":"g","channel":{"id":"5","type":3,"name":null,
         "recipients":[{"username":"a"},{"username":"b","global_name":"Bee"},{"username":"c"}]}}
        """#
        let card = try #require(try JSONDecoder().decode(InviteDTO.self, from: Data(json.utf8)).card)
        #expect(card.kind == .groupDirectMessage)
        #expect(card.name == "a, Bee, and c")
        #expect(card.memberCount == 3)
        #expect(card.header(sentByReader: true) == "You sent an invite to")
    }

    @Test("A friend link is about the person who made it")
    func friendLink() throws {
        let json = #"{"type":2,"code":"abc","inviter":{"id":"1","username":"oz._.7","global_name":"Oz"}}"#
        let card = try #require(try JSONDecoder().decode(InviteDTO.self, from: Data(json.utf8)).card)
        #expect(card.kind == .friend)
        #expect(card.name == "Oz")
        #expect(card.header(sentByReader: false) == "You've got a friend link")
    }
    /// The same captured invite, asked with `?event=`: Discord's answer adds
    /// the event whole, which is what the card turns into.
    private static let withEvent = captured.dropLast() + """
    ,
     "guild_scheduled_event":{"id":"1323893975486496490","guild_id":"1520000000000000001",
       "name":"Movie night","scheduled_start_time":"2026-10-09T19:00:00+00:00","status":1,
       "entity_type":2,"channel_id":"1520000000000000002","creator_id":"987654321987654321"}}
    """

    @Test("An invite asked with its event carries the event")
    func inviteWithEvent() throws {
        let dto = try DiscordREST.decoder.decode(InviteDTO.self, from: Data(Self.withEvent.utf8))
        let event = try #require(dto.card?.event)
        #expect(event.id == 1_323_893_975_484_369_279)
        #expect(event.name == "Movie night")
        #expect(event.status == .scheduled)
        #expect(event.location == .voice(ChannelID(rawValue: 1_520_000_000_000_000_002)))
    }

    @Test("An event that cannot be read costs the card its event, not the invite")
    func unreadableEvent() throws {
        let broken = Self.captured.dropLast() + #"""
        ,"guild_scheduled_event":{"id":"1","scheduled_start_time":{"no":"date"}}}
        """#
        let card = try #require(try DiscordREST.decoder.decode(InviteDTO.self, from: Data(broken.utf8)).card)
        #expect(card.name == "Lumen Club")
        #expect(card.event == nil)
    }

    /// Discord's `resolveInvite`: the event id rides between `with_expiration`
    /// and `with_permissions`, and the path is the bare code.
    @Test("A link's event is asked for on the invite's own route")
    func eventQuery() async throws {
        let (rest, token) = await RequestRecorder.client(body: Self.captured)
        _ = try await rest.inviteCard("LumenClub?event=1323893975486496490")
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.path == "/api/v9/invites/LumenClub")
        #expect(request.queryItems.map(\.name) == [
            "with_counts", "with_expiration", "guild_scheduled_event_id", "with_permissions",
        ])
        #expect(request.query["guild_scheduled_event_id"] == "1323893975486496490")
    }
}
