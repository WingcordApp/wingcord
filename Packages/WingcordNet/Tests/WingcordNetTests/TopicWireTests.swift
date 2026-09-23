import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Topics on the wire: Discord's conversations and a topic's messages, decoded
/// from bodies captured in `conversations + slowmode + jump to recent.har` —
/// trimmed to two conversations and three messages, and otherwise verbatim.
@Suite("Topics on the wire")
struct TopicWireTests {

    /// `GET /channels/672208888016632122/conversations?limit=25`, first two.
    private static let list = #"""
{"conversations": [{"id": "1552274688480944573", "channel_id": "672208888016632122", "guild_id": "574217343635554305", "conversation_type": 0, "message_ids": ["1552274688480944573", "1552275008789348655"], "start_message_id": "1552274688480944573", "end_message_id": "1552276154090292646", "user_ids": ["452042543383707648", "761283840619199264", "898226131753616266", "1489432559594319673"], "message_count": 15, "user_count": 4, "keywords": ["prime status", "weekly rewards", "cases", "skins", "xp grind"], "summary_map": {"entries": [{"summary_type": "TOPIC_EXTRACTION_SUMMARY", "version": 1, "content_json": "{\"conversation_id\": 1552295521698093912, \"title\": \"CS Prime benefits\", \"brief_summary\": \"CS Prime is a one-time purchase, not monthly, and grants weekly rewards including a case and a skin, or sometimes a consumable item.\", \"community_value\": \"Provides clear information about the cost, duration, and specific weekly rewards associated with Counter-Strike Prime status.\", \"key_points\": [{\"text\": \"Prime is a one-time purchase for a permanent upgrade, not a monthly subscription.\", \"source_ids\": [1552274688480944573, 1552275008789348655]}, {\"text\": \"With Prime, players can pick 2 out of 4 rewards every Wednesday, which typically includes a case and a skin.\", \"source_ids\": [1552275167917183109, 1552275274101676607, 1552275326286484253, 1552275343928470397]}, {\"text\": \"Occasionally, the case slot might offer a consumable like a 'terminal' or 'chicken' skin instead of a weapon case.\", \"source_ids\": [1552275491830324985, 1552275536460897424, 1552275590749272967, 1552275616811665602, 1552275797264910677]}, {\"text\": \"Playing around 10 hours a week is sufficient to grind the necessary XP for these weekly rewards.\", \"source_ids\": [1552275008789348655, 1552276067960960349, 1552276108335492935, 1552276154090292646]}], \"source_ids\": [1552274688480944573, 1552275008789348655, 1552275167917183109, 1552275274101676607, 1552275326286484253, 1552275343928470397, 1552275491830324985, 1552275536460897424, 1552275590749272967, 1552275591544737214, 1552275616811665602, 1552275797264910677, 1552276067960960349, 1552276108335492935, 1552276154090292646], \"keywords\": [\"cs prime\", \"weekly rewards\", \"cases\", \"skins\"], \"quality_score\": 0.8, \"guild_name\": \"Counter-Strike Discord | CSGO & CS2\", \"channel_name\": \"\\ud83d\\udcac\\u2502general\", \"summary_id\": 1552295566843589984}", "created_at": "2026-09-23T12:28:34.916807+00:00", "status": 1}]}, "messages": null}, {"id": "1552250942642395769", "channel_id": "672208888016632122", "guild_id": "574217343635554305", "conversation_type": 0, "message_ids": ["1552250942642395769", "1552250993304445282"], "start_message_id": "1552250942642395769", "end_message_id": "1552256820704049925", "user_ids": ["797128459075484660", "933314420259781453", "982633284844341443", "1194388119023102684", "1258276091487849856", "1529207024208624093"], "message_count": 35, "user_count": 6, "keywords": ["vac update", "anti-cheat", "ai cheats", "hardware ban"], "summary_map": {"entries": [{"summary_type": "TOPIC_EXTRACTION_SUMMARY", "version": 1, "content_json": "{\"conversation_id\": 1552264611677725157, \"title\": \"new VAC update\", \"brief_summary\": \"The new VAC update is reportedly banning hackers in real-time, with humans monitoring matches, leading to matches being canceled quickly when cheats are detected.\", \"community_value\": \"Provides current insights and anecdotal evidence on the effectiveness of the new VAC anti-cheat system in CS2, useful for players concerned about hacking.\", \"key_points\": [{\"text\": \"The new VAC update involves actual humans monitoring matches, resulting in quick bans for hackers.\", \"source_ids\": [1552251077349701752]}, {\"text\": \"Previously, some players encountered many hackers, including 'spin bot lobbies' in competitive and premier modes, even at lower ELOs like 3k.\", \"source_ids\": [1552251332128107167, 1552251517232976433]}, {\"text\": \"With the update, hackers using 'walls' were banned and matches canceled within 4 rounds, indicating real-time detection and action.\", \"source_ids\": [1552251942201631031, 1552252023000229963]}, {\"text\": \"The discussion touches on different types of cheats, such as DMA, AI cheats, and 'week keys', and the idea that some cheats can bypass VAC.\", \"source_ids\": [1552251918619661484, 1552252217578060978, 1552256374885829635]}], \"source_ids\": [1552250942642395769, 1552250993304445282, 1552251077349701752, 1552251277019280132, 1552251332128107167, 1552251517232976433, 1552251585080823740, 1552251669170203513, 1552251783655013734, 1552251918619661484, 1552251942201631031, 1552252023000229963, 1552252217578060978, 1552252340235295243, 1552252408529293627, 1552252619303905154, 1552252695945749566, 1552252739325915453, 1552252883176335600, 1552253007858152341, 1552254357552115443, 1552255338864046264, 1552255427563935711, 1552255434482173149, 1552255477161926446, 1552256185184180867, 1552256374885829635, 1552256451064202510, 1552256505572361930, 1552256563993304958, 1552256625930077746, 1552256683075415637, 1552256689436170350, 1552256820704049925], \"keywords\": [\"vac update\", \"anti-cheat\", \"hackers\", \"real-time bans\", \"cs2\"], \"quality_score\": 0.8, \"guild_name\": \"Counter-Strike Discord | CSGO & CS2\", \"channel_name\": \"\\ud83d\\udcac\\u2502general\", \"summary_id\": 1552264628743195270}", "created_at": "2026-09-23T10:25:34.647583+00:00", "status": 1}]}, "messages": null}], "before_short_circuited": false, "after_short_circuited": false, "oldest_bucket_checked": null, "newest_bucket_checked": null}
"""#

    /// `GET …/conversations/1552149573769042319/messages?include_message_references=true&include_reactions=true`:
    /// the topic's first message, a reply to it, and a reply to a message
    /// outside the topic — which arrives in `reference_messages`.
    private static let messages = #"""
{"conversation_id": "1552149573769042319", "messages": [{"id": "1552149573769042319", "channel_id": "672208888016632122", "type": 0, "content": "and the state of the game now is terrible", "timestamp": "2026-09-23T02:48:15.931000+00:00", "author": {"id": "323491787911926177", "username": "twelvetrees", "global_name": "Twelvetrees", "avatar": "37b7af3f6918101178dea57b3b97b7a3"}, "attachments": [], "embeds": [], "mentions": [], "mention_roles": [], "flags": 0}, {"id": "1552149654526747088", "channel_id": "672208888016632122", "type": 19, "content": "you don't say after them adding chicken pets to the game", "timestamp": "2026-09-23T02:48:35.185000+00:00", "author": {"id": "385109713912102024", "username": "thesloth2718", "global_name": "The Sloth", "avatar": "194750c9699b204de319d4a079ab5009"}, "message_reference": {"type": 0, "channel_id": "672208888016632122", "message_id": "1552149573769042319", "guild_id": "574217343635554305"}, "attachments": [], "embeds": [], "mentions": [{"id": "323491787911926177", "username": "twelvetrees", "avatar": "37b7af3f6918101178dea57b3b97b7a3", "discriminator": "0", "public_flags": 256, "flags": 256, "banner": null, "accent_color": null, "global_name": "Twelvetrees", "avatar_decoration_data": {"asset": "a_1e84201a6282ec5414b7e2eeedb43a8c", "sku_id": "1357589632482247151", "expires_at": null}, "collectibles": {"nameplate": {"sku_id": "1382845914319569346", "asset": "nameplates/nameplates_v3/touch_grass/", "label": "COLLECTIBLES_NAMEPLATES_VOL_3_TOUCH_GRASS_A11Y", "palette": "sky"}}, "display_name_styles": null, "vad_colors": null, "banner_color": null, "clan": null, "primary_guild": null}], "mention_roles": [], "flags": 0}, {"id": "1552150170751908250", "channel_id": "672208888016632122", "type": 19, "content": "it feels less responsive update to update", "timestamp": "2026-09-23T02:50:38.262000+00:00", "author": {"id": "323491787911926177", "username": "twelvetrees", "global_name": "Twelvetrees", "avatar": "37b7af3f6918101178dea57b3b97b7a3"}, "message_reference": {"type": 0, "channel_id": "672208888016632122", "message_id": "1552150095600794694", "guild_id": "574217343635554305"}, "attachments": [], "embeds": [], "mentions": [{"id": "999258398684701506", "username": "77orchard", "avatar": "a_6ba056cfe2f94fcb22af8208c783db52", "discriminator": "0", "public_flags": 64, "flags": 64, "banner": null, "accent_color": null, "global_name": "moravin", "avatar_decoration_data": {"asset": "a_6b8b696cd9a5ac1dce005ac840bb421b", "sku_id": "1447654090866401121", "expires_at": null}, "collectibles": {"nameplate": {"sku_id": "1447654090923726029", "asset": "nameplates/zodiac/cancer/", "label": "COLLECTIBLES_ZODIAC_CANCER_NP_A11Y", "palette": "cobalt"}}, "display_name_styles": {"font_id": 14, "effect_id": 4, "colors": [6888941]}, "vad_colors": null, "banner_color": null, "clan": {"identity_guild_id": "320053294635012987", "identity_enabled": true, "tag": "BOLA", "badge": "7b839e26f83a22d7f9e6e0af4e1ea953"}, "primary_guild": {"identity_guild_id": "320053294635012987", "identity_enabled": true, "tag": "BOLA", "badge": "7b839e26f83a22d7f9e6e0af4e1ea953"}}], "mention_roles": [], "flags": 0}], "ancestors": [], "reference_messages": [{"id": "1552150095600794694", "channel_id": "672208888016632122", "type": 0, "content": "im just happy that the game is far more responsive", "timestamp": "2026-09-23T02:50:20.345000+00:00", "author": {"id": "999258398684701506", "username": "77orchard", "global_name": "moravin", "avatar": "a_6ba056cfe2f94fcb22af8208c783db52"}, "attachments": [], "embeds": [], "mentions": [], "mention_roles": [], "flags": 0}], "has_more_messages": false}
"""#

    @Test("A conversation decodes to its title, raised, and its span")
    func conversation() throws {
        let list = try DiscordREST.decoder.decode(ConversationListDTO.self, from: Data(Self.list.utf8))
        let topics = list.conversations.compactMap(\.domain)
        #expect(topics.map(\.title) == ["CS Prime benefits", "New VAC update"])
        let first = try #require(topics.first)
        #expect(first.id == ConversationTopicID(rawValue: 1_552_274_688_480_944_573))
        #expect(first.startMessageID == MessageID(rawValue: 1_552_274_688_480_944_573))
        #expect(first.endMessageID == MessageID(rawValue: 1_552_276_154_090_292_646))
        #expect(first.messageCount == 15)
        #expect(first.summary?.hasPrefix("CS Prime is a one-time purchase") == true)
    }

    @Test("A conversation with no titled summary is not a topic")
    func untitled() throws {
        let json = #"{"id":"1","start_message_id":"1","end_message_id":"2","message_count":2,"summary_map":{"entries":[{"summary_type":"TOPIC_EXTRACTION_SUMMARY","content_json":"{\"brief_summary\":\"x\"}"}]}}"#
        let dto = try DiscordREST.decoder.decode(ConversationDTO.self, from: Data(json.utf8))
        #expect(dto.domain == nil)
        let bare = #"{"id":"1","start_message_id":"1","end_message_id":"2"}"#
        #expect(try DiscordREST.decoder.decode(ConversationDTO.self, from: Data(bare.utf8)).domain == nil)
    }

    @Test("Every reply in a topic can draw its header — inside the topic or out")
    func repliesResolve() throws {
        let answer = try DiscordREST.decoder.decode(
            ConversationMessagesDTO.self, from: Data(Self.messages.utf8)
        )
        var page = DiscordREST.page(from: answer.messages, reversed: false)
        let quoted = DiscordREST.page(from: answer.reference_messages ?? [], reversed: false)
        page.authors.merge(quoted.authors) { own, _ in own }
        // Unresolved, both replies say their target is gone.
        #expect(page.messages[1].reference?.isUnavailable == true)
        #expect(page.messages[2].reference?.isUnavailable == true)

        let resolved = DiscordREST.resolvingReplies(
            in: page.messages, among: page.messages + quoted.messages, authors: page.authors
        )
        let inside = try #require(resolved[1].reference)
        #expect(inside.authorID == page.messages[0].authorID)
        #expect(inside.excerpt == "and the state of the game now is terrible")
        let outside = try #require(resolved[2].reference)
        #expect(outside.authorID == quoted.messages.first?.authorID)
        #expect(outside.excerpt.hasPrefix("im just happy that the game is far more responsive"))
        // The quoted author is known, so the header has a name and a face.
        #expect(page.authors[try #require(outside.authorID)] != nil)
    }
}
