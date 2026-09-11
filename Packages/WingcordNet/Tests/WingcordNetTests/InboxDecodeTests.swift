import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The inbox's wire shapes, against what was actually captured.
///
/// **Three of these routes have never answered this client with data**, so the
/// fixtures come from three different places and the tests say which is which:
/// the mentions page is lifted verbatim out of `inbox.har`, the settings-proto
/// blob is the exact six bytes that capture PATCHed, and the saved-message
/// shape is the docs'. A test whose fixture is a guess pins the guess, so the
/// saved-message tests below check *tolerance* — that a row survives a missing
/// field — rather than asserting a shape nobody has seen.
struct InboxDecodeTests {

    // MARK: Mentions — captured

    /// Three messages out of the twenty-five in `inbox.har`, verbatim: a
    /// webhook bot with a rich embed and a role ping, a reply carrying a user
    /// mention, and an `@everyone` with links in it.
    static let mentionsPage = #"""
    [
      {
        "id": "1547712320481169427",
        "type": 0,
        "content": "<@&1495409152335442113>",
        "channel_id": "1495396111177713132",
        "author": {
          "bot": true,
          "id": "1495420927605408681",
          "username": "nicealts.com",
          "avatar": null,
          "discriminator": "0000",
          "global_name": null
        },
        "attachments": [],
        "embeds": [
          {
            "type": "rich",
            "title": "New Refill",
            "description": "• Unbanned 1-7: 2 items\n• Donut: 4 items",
            "color": 9807270,
            "timestamp": "2026-09-10T20:56:12+00:00",
            "content_scan_version": 4,
            "id": "1547712320484038660"
          }
        ],
        "mentions": [],
        "mention_roles": ["1495409152335442113"],
        "mention_everyone": false,
        "pinned": false,
        "tts": false,
        "timestamp": "2026-09-10T20:56:12.307000+00:00",
        "edited_timestamp": null,
        "flags": 0,
        "components": [],
        "webhook_id": "1495420927605408681"
      },
      {
        "id": "1547618742725463638",
        "type": 19,
        "content": "<:joeshrug:1484581915576860458>",
        "channel_id": "672208888016632122",
        "author": {
          "id": "1257131129263951526",
          "username": "backgroundextra",
          "global_name": "Purge",
          "avatar": "b5a724962872ea7a67f7c926c5152abc",
          "discriminator": "0",
          "public_flags": 0
        },
        "attachments": [],
        "embeds": [],
        "mentions": [
          {
            "id": "987654321987654321",
            "username": "alexsample",
            "global_name": "alex",
            "avatar": "00112233445566778899aabbccddeeff",
            "discriminator": "0",
            "public_flags": 256
          }
        ],
        "mention_roles": [],
        "mention_everyone": false,
        "pinned": false,
        "tts": false,
        "timestamp": "2026-09-10T14:44:21.631000+00:00",
        "edited_timestamp": null,
        "flags": 0,
        "components": [],
        "message_reference": {
          "type": 0,
          "channel_id": "672208888016632122",
          "guild_id": "574217343635554305",
          "message_id": "1547618612409140314"
        }
      },
      {
        "id": "1547324474650226820",
        "type": 0,
        "content": "Heya @everyone @here we're doing a quick weekly office hours right now.",
        "channel_id": "952771221915966329",
        "author": {
          "id": "381590592099373964",
          "username": "milesk",
          "global_name": "MilesK",
          "avatar": "c9b68277789a74383b19bc36de095646",
          "discriminator": "0",
          "public_flags": 0
        },
        "attachments": [],
        "embeds": [],
        "mentions": [],
        "mention_roles": [],
        "mention_everyone": true,
        "pinned": false,
        "tts": false,
        "timestamp": "2026-09-10T05:12:44.000000+00:00",
        "edited_timestamp": null,
        "flags": 1,
        "components": []
      }
    ]
    """#

    private static func decodeMentions() throws -> MessagePage {
        let dtos = try DiscordREST.decoder.decode(
            [MessageDTO].self,
            from: Data(mentionsPage.utf8)
        )
        return DiscordREST.page(from: dtos, reversed: false)
    }

    @Test func mentionsKeepTheOrderTheyArrivedIn() throws {
        let page = try Self.decodeMentions()
        // **Not reversed.** History is flipped to oldest-first because the
        // transcript reads downward; the inbox reads newest-first, which is the
        // order Discord already sends. A page that came back flipped would put
        // the oldest mention at the top of the tab.
        #expect(page.messages.map(\.id.rawValue) == [
            1_547_712_320_481_169_427,
            1_547_618_742_725_463_638,
            1_547_324_474_650_226_820,
        ])
    }

    @Test func mentionsCarryNoGuildID() throws {
        // The finding that shapes the whole surface: there is no `guild_id` on
        // a mention, on its author, or anywhere but inside `message_reference`
        // — which is the *quoted* message's guild, not this one's. Checked
        // against all 25 messages in the capture; the three here are a
        // regression guard for the day somebody assumes it is there.
        let raw = try JSONSerialization.jsonObject(with: Data(Self.mentionsPage.utf8))
        let objects = try #require(raw as? [[String: Any]])
        for object in objects {
            #expect(object["guild_id"] == nil)
            let author = try #require(object["author"] as? [String: Any])
            #expect(author["guild_id"] == nil)
        }
    }

    @Test func webhookBotMentionKeepsItsEmbed() throws {
        let page = try Self.decodeMentions()
        let message = try #require(page.messages.first)
        #expect(message.embeds.count == 1)
        #expect(message.embeds.first?.title == "New Refill")
        // The role ping is the only thing in the body, so a client that dropped
        // `mention_roles` would draw an empty message with an embed under it.
        #expect(message.mentionedRoleIDs.map(\.rawValue) == [1_495_409_152_335_442_113])
        #expect(message.webhookID?.rawValue == 1_495_420_927_605_408_681)
    }

    @Test func authorsComeBackWithThePage() throws {
        let page = try Self.decodeMentions()
        // All three writers, plus nobody else: the mentioned user on the reply
        // is not an author and must not be collected as one.
        #expect(page.authors.count == 3)
        #expect(page.authors[UserID(rawValue: 1_495_420_927_605_408_681)]?.isBot == true)
        #expect(page.authors[UserID(rawValue: 381_590_592_099_373_964)]?.username == "milesk")
    }

    @Test func replyKeepsItsReference() throws {
        let page = try Self.decodeMentions()
        let reply = try #require(page.messages.first { $0.kind == .reply })
        #expect(reply.referencedMessageID?.rawValue == 1_547_618_612_409_140_314)
        // The mentioned user is not the author and must be kept separately, or
        // the row that says who was pinged has nothing to name.
        #expect(reply.mentionedUserIDs.map(\.rawValue) == [987_654_321_987_654_321])
    }

    // MARK: The selected tab — captured, byte for byte

    @Test func encodesTheTabExactlyAsDiscordDid() {
        // `inbox.har`: PATCH /users/@me/settings-proto/1 body
        // {"settings":"EgQIBxAB"} sent while the Scheduled tab was open.
        // Six bytes: 12 04 08 07 10 01 — field 2, length 4, {1: 7, 2: 1}.
        #expect(UserSettingsProto.encodeInboxTab(.scheduled) == "EgQIBxAB")
    }

    @Test func roundTripsEveryTab() {
        for tab in InboxTab.allCases {
            // Through the base64 string, which is what actually crosses the
            // wire — encoding and decoding the raw `Data` would skip the one
            // step that has ever been wrong in this file.
            let settings = UserSettingsProto.decode(base64: UserSettingsProto.encodeInboxTab(tab))
            #expect(settings?.inboxTab == tab)
        }
    }

    @Test func anUnknownTabFallsBackRatherThanVanishing() {
        // FOR_YOU is 4 and GAME_INVITES is 5 — real tabs Discord numbers and
        // this client does not draw. A stored 4 must resolve to something the
        // picker can select, or the segmented control opens with no selection.
        var inner = ProtobufWriter()
        inner.varint(field: 1, 4)
        var outer = ProtobufWriter()
        outer.message(field: 2, inner.data)
        #expect(UserSettingsProto.decode(outer.data).inboxTab == .unreads)
    }

    @Test func anAbsentInboxLeavesTheDefault() {
        // An account that has never opened the inbox stores no `inbox` field at
        // all, and the folders around it must still decode.
        #expect(UserSettingsProto.decode(Data()).inboxTab == .unreads)
    }

    // MARK: Saved messages — the docs' shape, decoded tolerantly

    @Test func savedMessageSplitsOnDueAt() throws {
        let json = #"""
        {
          "results": [
            {
              "message": null,
              "save_data": {
                "channel_id": "111",
                "message_id": "222",
                "saved_at": "2026-09-04T22:13:00.000000+00:00"
              }
            },
            {
              "message": null,
              "save_data": {
                "channel_id": "111",
                "message_id": "333",
                "guild_id": "444",
                "saved_at": "2026-09-04T22:13:00.000000+00:00",
                "due_at": "2026-09-12T10:00:00.000000+00:00"
              }
            }
          ]
        }
        """#
        let response = try DiscordREST.decoder.decode(
            SavedMessagesResponseDTO.self,
            from: Data(json.utf8)
        )
        let saved = (response.results ?? []).compactMap { $0.domain()?.saved }
        #expect(saved.count == 2)
        // One route, one list, two tabs. `due_at` is the whole discriminator.
        #expect(saved.bookmarks.map(\.id.rawValue) == [222])
        #expect(saved.reminders.map(\.id.rawValue) == [333])
        #expect(saved.reminders.first?.saveData.guildID?.rawValue == 444)
    }

    @Test func aSavedMessageWhoseMessageIsGoneStillDecodes() throws {
        // Discord keeps the save when the message is deleted. A decoder that
        // required `message` would leave the reader with a bookmark they cannot
        // see and cannot remove.
        let json = #"""
        {"results": [{"save_data": {"channel_id": "1", "message_id": "2",
         "saved_at": "2026-09-04T22:13:00.000000+00:00"}}]}
        """#
        let response = try DiscordREST.decoder.decode(
            SavedMessagesResponseDTO.self,
            from: Data(json.utf8)
        )
        let resolved = try #require(response.results?.first?.domain())
        #expect(resolved.saved.message == nil)
        #expect(resolved.saved.saveData.channelID.rawValue == 1)
    }

    @Test func aMissingSavedAtFallsBackToTheSnowflakeNotNow() throws {
        // `saved_at` is documented required and has never been seen. If it is
        // missing, sorting by `.now` would reshuffle the list on every fetch.
        let json = #"""
        {"results": [{"save_data": {"channel_id": "1", "message_id": "1547712320481169427"}}]}
        """#
        let response = try DiscordREST.decoder.decode(
            SavedMessagesResponseDTO.self,
            from: Data(json.utf8)
        )
        let saved = try #require(response.results?.first?.domain()?.saved)
        #expect(saved.saveData.savedAt == MessageID(rawValue: 1_547_712_320_481_169_427).timestamp)
    }

    @Test func aRowWithNoSaveDataIsDroppedNotInvented() throws {
        // Without a channel there is nothing to address the unsave route with.
        let json = #"{"results": [{"message": null}]}"#
        let response = try DiscordREST.decoder.decode(
            SavedMessagesResponseDTO.self,
            from: Data(json.utf8)
        )
        #expect(response.results?.first?.domain() == nil)
    }

    // MARK: Scheduled messages — inferred, and tolerant by design

    @Test func scheduledMessagesAcceptEitherTimestampSpelling() throws {
        let json = #"""
        [
          {"id": "1", "channel_id": "9", "content": "later",
           "scheduled_at": "2026-09-20T09:00:00.000000+00:00"},
          {"id": "2", "channel_id": "9", "content": "also later",
           "send_at": "2026-09-21T09:00:00.000000+00:00"}
        ]
        """#
        let dtos = try DiscordREST.decoder.decode(
            [ScheduledMessageDTO].self,
            from: Data(json.utf8)
        )
        let messages = dtos.compactMap { $0.domain() }
        #expect(messages.count == 2)
        #expect(messages.upcoming.map(\.id.rawValue) == [1, 2])
    }

    @Test func anUnreadableScheduledRowIsDroppedAndTheRestSurvive() throws {
        // The shape is inferred. A row that does not match must cost one row,
        // never the page — an empty tab on a wrong guess is recoverable; a
        // thrown decode looks like the feature is broken.
        let json = #"""
        [
          {"id": "1", "content": "no channel and no date"},
          {"id": "2", "channel_id": "9", "content": "fine",
           "scheduled_at": "2026-09-20T09:00:00.000000+00:00"}
        ]
        """#
        let dtos = try DiscordREST.decoder.decode(
            [ScheduledMessageDTO].self,
            from: Data(json.utf8)
        )
        #expect(dtos.compactMap { $0.domain() }.map(\.id.rawValue) == [2])
    }

    // MARK: Relationships — three fields that were on the wire and read by nothing

    @Test func relationshipCarriesItsRequestFacts() throws {
        // The docs' own example payload, trimmed to the fields at issue.
        let json = #"""
        {
          "id": "852892297663134629",
          "type": 3,
          "nickname": null,
          "user_ignored": false,
          "is_spam_request": false,
          "since": "2023-02-10T01:58:05.348000+00:00",
          "stranger_request": true
        }
        """#
        let dto = try DiscordREST.decoder.decode(
            RelationshipDTO.self,
            from: Data(json.utf8)
        )
        let facts = try #require(dto.facts)
        #expect(facts.since != nil)
        #expect(facts.isSpam == false)
        // Stranger and spam are different facts and must not collapse.
        #expect(facts.isStranger)
    }

    @Test func anUnremarkableRelationshipStoresNothing() throws {
        // An account with two thousand friends must not carry two thousand
        // rows of three default values.
        let json = #"{"id": "1", "type": 1}"#
        let dto = try DiscordREST.decoder.decode(
            RelationshipDTO.self,
            from: Data(json.utf8)
        )
        #expect(dto.facts == nil)
    }
}
