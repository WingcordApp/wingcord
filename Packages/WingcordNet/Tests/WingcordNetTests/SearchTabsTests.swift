import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The tabs search — Discord's `createRequestPayload` (`956467`) and the
/// filters per tab (`768570`: `su`, `B7`, `us`).
@Suite("Search tabs")
struct SearchTabsTests {

    private func json(_ body: SearchTabsQueryBody) throws -> [String: Any] {
        let data = try JSONEncoder().encode(body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Every tab is asked; the one on show pages, the rest count")
    func shape() throws {
        var query = MessageSearchQuery(scope: .guild(GuildID(rawValue: 1)))
        query.content = "patch notes"
        query.authorIDs = [UserID(rawValue: 7)]
        query.tab = .media
        query.page = 3
        let body = try json(DiscordREST.tabsBody(for: query))
        #expect(body["track_exact_total_hits"] as? Bool == true)
        // Not sent unless the reader agreed to the server's age gate, as the
        // classic search never sends it either.
        #expect(body["include_nsfw"] == nil)
        let tabs = try #require(body["tabs"] as? [String: [String: Any]])
        #expect(Set(tabs.keys) == ["messages", "media", "links", "files"])

        let media = try #require(tabs["media"])
        #expect(media["limit"] as? Int == 25)
        #expect(media["offset"] as? Int == 50)
        #expect(media["has"] as? [String] == ["image", "video"])
        #expect(media["content"] as? String == "patch notes")
        #expect(media["author_id"] as? [String] == ["7"])
        #expect(media["sort_by"] as? String == "timestamp")
        #expect(media["sort_order"] as? String == "desc")

        let messages = try #require(tabs["messages"])
        #expect(messages["limit"] as? Int == 1)
        #expect(messages["offset"] as? Int == 0)
        #expect(messages["has"] == nil)
        #expect(tabs["links"]?["has"] as? [String] == ["link"])
        #expect(tabs["files"]?["has"] as? [String] == ["file"])
    }

    @Test("The question's own has wins over the tab's, as Discord spreads it after")
    func ownHasWins() throws {
        var query = MessageSearchQuery(scope: .channel(ChannelID(rawValue: 5)))
        query.has = [.poll]
        let tabs = try #require(try json(DiscordREST.tabsBody(for: query))["tabs"] as? [String: [String: Any]])
        for name in ["messages", "media", "links", "files"] {
            #expect(tabs[name]?["has"] as? [String] == ["poll"], "\(name)")
        }
    }

    @Test("A guild's channel filter rides at the top as channel_ids; a DM sends none")
    func channels() throws {
        var guild = MessageSearchQuery(scope: .guild(GuildID(rawValue: 1)))
        guild.content = "x"
        guild.channelIDs = [ChannelID(rawValue: 42)]
        #expect(try json(DiscordREST.tabsBody(for: guild))["channel_ids"] as? [String] == ["42"])
        var direct = MessageSearchQuery(scope: .channel(ChannelID(rawValue: 5)))
        direct.content = "x"
        direct.channelIDs = [ChannelID(rawValue: 42)]
        #expect(try json(DiscordREST.tabsBody(for: direct))["channel_ids"] == nil)
    }

    @Test("An answer is the shown tab's page with every tab's count")
    func answerDecodes() throws {
        let answer = """
        {"analytics_id":"a","doing_deep_historical_index":false,
         "tabs":{
          "messages":{"total_results":120,"messages":[[
            {"id":"1545896271576775658","type":0,"content":"hey","channel_id":"1528177367079189287","hit":true,
             "timestamp":"2026-09-01T12:00:00.000000+00:00",
             "author":{"id":"811641072529494819","username":"vexlor","discriminator":"0"},
             "attachments":[],"embeds":[],"mentions":[],"mention_roles":[],"pinned":false}]]},
          "media":{"total_results":8,"messages":[]},
          "links":{"total_results":3,"messages":[]},
          "files":{"total_results":0,"messages":[]}}}
        """
        let dto = try DiscordREST.decoder.decode(SearchTabsPageDTO.self, from: Data(answer.utf8))
        let shown = try #require(dto.tabs?["messages"]).domain
        #expect(shown.messages.count == 1)
        #expect(shown.totalResults == 120)
        #expect(dto.tabs?["media"]?.total_results == 8)
        #expect(dto.tabs?["files"]?.total_results == 0)
    }
}
