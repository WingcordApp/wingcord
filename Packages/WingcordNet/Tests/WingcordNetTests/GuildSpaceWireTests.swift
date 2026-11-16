import Foundation
import Testing
@testable import WingcordCore
@testable import WingcordNet

/// The Server Hub on the wire, in the shapes Discord's web client reads and
/// writes (docs/BETA2.md, phase 9).
struct GuildSpaceWireTests {

    private let guildID = GuildID(rawValue: 42)

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test("A space decodes its channel, banner and widgets, in column order")
    func space() throws {
        let dto = try decode(GuildSpaceDTO.self, """
        {"guild_id":"42","channel_id":"900","header":{"custom_banner_hash":"abc"},
         "widgets":[
           {"id":"7","type":"popular_games","position":{"column":1,"order":0},"requires_hydration":true,
            "default_title":"Popular Games","locked":false,"config":{"type":"popular_games","extra":3}},
           {"id":"5","type":"image_text","position":{"column":0,"order":1},"requires_hydration":false,
            "config":{"type":"image_text","title":"Hi","text":"Larp Ipsum","image_hash":"img"}},
           {"id":"6","type":"leaderboard","position":{"column":0,"order":0},"requires_hydration":true,
            "config":{"type":"leaderboard"}},
           {"id":"8","type":"mystery_widget","position":{"column":0,"order":2},"config":{"type":"mystery_widget"}}
         ]}
        """)
        let space = dto.domain(guildID: guildID)
        #expect(space.channelID == ChannelID(rawValue: 900))
        #expect(space.customBannerHash == "abc")
        #expect(space.widgets.map(\.id) == ["6", "5", "8", "7"])
        let text = try #require(space.widgets.first { $0.id == "5" })
        #expect(text.config.title == "Hi")
        #expect(text.config.imageHash == "img")
        #expect(text.config.rawJSON == nil)
        // Kinds this client doesn't draw are kept, to be saved back unchanged.
        #expect(space.widgets.contains { $0.kind.rawValue == "mystery_widget" })
        let games = try #require(space.widgets.first { $0.id == "7" })
        #expect(games.requiresHydration)
        #expect(games.config.rawJSON != nil)
    }

    @Test("A save leaves a new widget's id off, and sends Image + Text's picture only when it changed")
    func saveBody() throws {
        var kept = GuildSpaceWidget(id: "5", kind: .imageText, position: .init(column: 0, order: 0))
        kept.config.title = "Hi"
        kept.config.imageHash = "img"
        var fresh = GuildSpaceWidget(id: GuildSpaceWidget.draftPrefix + "x", kind: .imageText, position: .init(column: 1, order: 0))
        fresh.config.text = "New"
        fresh.config.imageChange = .replaced(dataURL: "data:image/png;base64,AA==")
        var other = GuildSpaceWidget(id: "7", kind: .popularGames, position: .init(column: 1, order: 1))
        other.config.rawJSON = Data(#"{"type":"popular_games","extra":3}"#.utf8)

        let body = GuildSpaceSaveBody(banner: .remove, widgets: [kept, fresh, other])
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        let header = try #require(json["header"] as? [String: Any])
        #expect(header["custom_banner"] is NSNull)
        let widgets = try #require(json["widgets"] as? [[String: Any]])
        #expect(widgets.count == 3)
        #expect(widgets[0]["id"] as? String == "5")
        let keptConfig = try #require(widgets[0]["config"] as? [String: Any])
        #expect(keptConfig["title"] as? String == "Hi")
        #expect(keptConfig["text"] is NSNull)
        #expect(keptConfig["image"] == nil)
        #expect(widgets[1]["id"] == nil)
        let freshConfig = try #require(widgets[1]["config"] as? [String: Any])
        #expect(freshConfig["image"] as? String == "data:image/png;base64,AA==")
        let otherConfig = try #require(widgets[2]["config"] as? [String: Any])
        #expect(otherConfig["extra"] as? Double == 3)

        let unchanged = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(GuildSpaceSaveBody(banner: nil, widgets: []))
        ) as? [String: Any])
        #expect((unchanged["header"] as? [String: Any])?.isEmpty == true)
    }

    @Test("Hydration is told apart by the keys it carries")
    func hydration() throws {
        let response = try decode(GuildSpaceHydrateResponse.self, """
        {"widgets":[
          {"id":"6","data":{"stat":1,"next_stat":2,"week_start_ts":1800000000,"day_pt":"2027-01-15",
            "computed_at":"2027-01-15T09:00:00.000Z",
            "entries":[{"user_id":"10","rank":1,"value":161100000,"application_ids":["1400000000000000001"],"application_count":4}]}},
          {"id":"7","data":{"user_ids":["10","11"],"games":[{"application_id":"1400000000000000001","user_ids":["10"]}],
            "total_users":64,"total_games":9278}},
          {"id":"9","data":{"ranked_songs":[{"track_external_id":"t1","track_title":"Nights","artist_name":"Frank Ocean",
            "cover_art_hash":"ab67","plays":12,"facepile_user_ids":["10"]}],"ranked_artists":[],"top_listeners":[{"user_id":"10","plays":30}],
            "distinct_songs":128,"distinct_artists":57,"distinct_listeners":31}},
          {"id":"3","data":{"something":"else"}}
        ]}
        """)
        let byID = Dictionary(uniqueKeysWithValues: response.widgets.map { ($0.id, $0.data.domain) })
        guard case .leaderboard(let board) = byID["6"] else { Issue.record("no leaderboard"); return }
        #expect(board.stat == .hoursPlayed)
        #expect(board.entries.first?.applicationCount == 4)
        #expect(board.computedAt != nil)
        guard case .popularGames(let games) = byID["7"] else { Issue.record("no games"); return }
        #expect(games.totalGames == 9_278)
        #expect(games.hasEnoughData)
        guard case .popularMusic(let music) = byID["9"] else { Issue.record("no music"); return }
        #expect(music.songs.first?.title == "Nights")
        #expect(music.listeners.first?.plays == 30)
        #expect(byID["3"] == .other)
    }

    @Test("The catalog keeps each widget's limit and price")
    func catalog() throws {
        let entries = try decode(GuildSpaceCatalogResponse.self, """
        {"widgets":[{"type":"image_text","name":"Image + Text","max_instances":4,"boost_price":0,
          "assets":{"catalog_image_static_url":"https://cdn.example/a.png"}},
          {"type":"popular_music","name":"Popular Music","max_instances":1,"boost_price":2,"locked":true}]}
        """).domain
        #expect(entries.map(\.maxInstances) == [4, 1])
        #expect(entries[1].boostPrice == 2)
        #expect(entries[1].isLocked)
        #expect(entries[0].staticImageURL != nil)
    }

    @Test("A guild's hub settings decode, and junk is no hub rather than a failure")
    func settingsField() throws {
        struct Holder: Decodable { var guild_space_settings: GuildSpaceSettingsField? }
        let published = try decode(Holder.self, #"{"guild_space_settings":{"enabled":true,"publish_status":1}}"#)
        #expect(published.guild_space_settings?.settings == GuildSpaceSettings(isEnabled: true, publishStatus: .published))
        let null = try decode(Holder.self, #"{"guild_space_settings":null}"#)
        #expect(null.guild_space_settings?.settings == nil)
        let junk = try decode(Holder.self, #"{"guild_space_settings":"what"}"#)
        #expect(junk.guild_space_settings?.settings == nil)
    }

    @Test("A Server Hub message's data keeps only events Discord's own guards accept")
    func messageData() throws {
        let leader = try decode(GuildSpaceMessageDataField.self, """
        {"leaderboard":{"event":3,"stat":1,"user_id":"10","secondary_user_id":"11","value":161100000}}
        """).data
        #expect(leader?.leaderboard?.event == .leaderChanged)
        #expect(leader?.subjectUserID == UserID(rawValue: 10))
        let unknownStat = try decode(GuildSpaceMessageDataField.self, """
        {"leaderboard":{"event":3,"stat":0,"user_id":"10","value":1}}
        """).data
        #expect(unknownStat == nil)
        let board = try decode(GuildSpaceMessageDataField.self, """
        {"whiteboard_busy":{"sampled_user_ids":["4","5"],"connected_user_count":6}}
        """).data
        #expect(board?.whiteboard?.connectedUserCount == 6)
    }
}
