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
}
