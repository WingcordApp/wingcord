import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// `GET /emojis/{id}/source` and `GET /stickers/{id}/guild` — the only routes
/// that name the server behind an expression the reader is not in, which is the
/// only case anybody asks about.
///
/// **The two answer differently shaped payloads for the same idea**: the emoji
/// route nests the guild under `guild`, the sticker route sends it at the top
/// level. Both payloads below are captured from live responses, not invented.
@Suite("Expression sources")
struct ExpressionSourceTests {

    private func decode(_ json: String) throws -> ExpressionSource? {
        try JSONDecoder().decode(ExpressionSourceDTO.self, from: Data(json.utf8)).domain
    }

    private let Orbit Hub = """
    {"guild":{"id":"960000000000000001","name":"Orbit Hub",
      "icon":"80756ef1f066b1d3505158ea4cfcf66a",
      "emojis":[
        {"name":"DiscordKit","id":"1057967394723107016","animated":false,"available":true},
        {"name":"Orbit Hub","id":"1050000000000000001","animated":false,"available":true},
        {"name":"puffer","id":"1057969809863599024","animated":false,"available":true},
        {"name":"wumpus","id":"1057972025189167295","animated":false,"available":true}],
      "approximate_member_count":1916,"approximate_presence_count":596,
      "description":"The 100% native macOS/iPadOS Discord client.",
      "features":["AUTO_MODERATION","COMMUNITY","DISCOVERABLE","NEWS","PREVIEW_ENABLED"],
      "premium_subscription_count":1,"premium_tier":0},
     "application":null,"type":"GUILD"}
    """

    @Test("A guild source carries everything the card draws")
    func guildSource() throws {
        guard case .guild(let guild) = try #require(try decode(Orbit Hub)) else {
            Issue.record("expected a guild")
            return
        }
        #expect(guild.name == "Orbit Hub")
        #expect(guild.id == GuildID(rawValue: 960_000_000_000_000_001))
        #expect(guild.onlineCount == 596)
        #expect(guild.memberCount == 1916)
        #expect(guild.description?.isEmpty == false)
        #expect(guild.standing == .discoverable)
        #expect(guild.isPublic)
    }

    /// A strip, not the catalogue: the route sends every emoji the server has,
    /// and holding hundreds to draw four is a copy of somebody else's set per
    /// hover.
    @Test("The emoji sample is capped")
    func sampleIsCapped() throws {
        guard case .guild(let guild) = try #require(try decode(Orbit Hub)) else {
            Issue.record("expected a guild")
            return
        }
        #expect(guild.sampleEmoji.count == 4)
        #expect(guild.sampleEmoji.count <= ExpressionSourceDTO.sampleLimit)
        #expect(guild.sampleEmoji[1].name == "Orbit Hub")
        #expect(guild.sampleEmoji[1].id == EmojiID(rawValue: 1_050_000_000_000_000_001))
    }

    /// **A private server's details are not the reader's to see.** The route
    /// answers for one all the same, because it is scoped to the emoji rather
    /// than to the server.
    @Test("A server that is not open to look at is not public")
    func privateGuild() throws {
        guard case .guild(let guild) = try #require(try decode("""
        {"guild":{"id":"1","name":"A private place","features":["COMMUNITY"],
          "approximate_member_count":40},"type":"GUILD"}
        """)) else {
            Issue.record("expected a guild")
            return
        }
        #expect(!guild.isPublic)
        // The value is still decoded — the *card* is what withholds it, so the
        // rule lives in one place rather than in the decoder and the view both.
        #expect(guild.memberCount == 40)
    }

    @Test("An app's own emoji belongs to no server")
    func applicationSource() throws {
        guard case .application(let name, let icon) = try #require(try decode("""
        {"guild":null,"application":{"name":"Carl-bot","icon":"abc"},"type":"APPLICATION"}
        """)) else {
            Issue.record("expected an application")
            return
        }
        #expect(name == "Carl-bot")
        #expect(icon == "abc")
    }

    /// Branching on the payload rather than on `type`: the string is advisory,
    /// and a guild object with a name in it is a guild whatever it is labelled.
    @Test("A source with nothing in it is nil, not an empty card")
    func emptySource() throws {
        #expect(try decode(#"{"guild":null,"application":null,"type":"GUILD"}"#) == nil)
        #expect(try decode(#"{"guild":{"id":"1","name":""},"type":"GUILD"}"#) == nil)
    }

    // MARK: Stickers

    /// **A different shape for the same idea.** The sticker route answers with
    /// the guild directly where the emoji route nests it, so the two have
    /// separate readers rather than one that guesses.
    private func decodeSticker(_ json: String) throws -> ExpressionSource? {
        try JSONDecoder().decode(StickerSourceDTO.self, from: Data(json.utf8)).domain
    }

    private let groveStreet = """
    {"id":"334343104284852224","name":"Grove Street Families",
     "description":"Official Razed Mods Discord - game modding community.",
     "icon":"2e64a6615dae4b25c1bfc858906228c2",
     "approximate_presence_count":32248,"approximate_member_count":209627,
     "features":["COMMUNITY","DISCOVERABLE","PREVIEW_ENABLED","NEWS"],
     "stickers":[
       {"id":"859895397191810279","name":"Grove Street","format_type":1,"available":true},
       {"id":"859897873201679512","name":"Liberty City","format_type":1,"available":true},
       {"id":"861042711995944592","name":"NVE","format_type":2,"available":true}],
     "sticker_count":5}
    """

    @Test("A sticker's guild decodes from the top level")
    func stickerSource() throws {
        guard case .guild(let guild) = try #require(try decodeSticker(groveStreet)) else {
            Issue.record("expected a guild")
            return
        }
        #expect(guild.name == "Grove Street Families")
        #expect(guild.onlineCount == 32_248)
        #expect(guild.memberCount == 209_627)
        #expect(guild.standing == .discoverable)
        #expect(guild.isPublic)
        #expect(guild.sampleStickers.count == 3)
        #expect(guild.sampleStickers[2].format == .apng)
        // The two routes fill different strips, and neither fills the other's.
        #expect(guild.sampleEmoji.isEmpty)
    }

    @Test("A sticker source with no name is not a source")
    func namelessStickerSource() throws {
        #expect(try decodeSticker(#"{"id":"1"}"#) == nil)
    }
}
