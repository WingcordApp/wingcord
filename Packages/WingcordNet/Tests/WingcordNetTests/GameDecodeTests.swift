import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// `GET /games`, against the captured payload for The Sims 4.
///
/// **Two things here fail silently if they are wrong.** `media` is a tagged
/// union whose two tags need different resolution and whose values look alike;
/// and `first_release_date` arrives as midnight UTC with **no** fractional
/// seconds, which the formatter every other route needs rejects outright — the
/// symptom is a Details table with no Release Date row rather than an error.
@Suite("Game decode")
struct GameDecodeTests {

    private let sims = """
    [{
      "id": "359509007423242240",
      "name": "The Sims 4",
      "description": "Unleash your imagination and create a unique world of Sims.",
      "icon_hash": "912bd1dd19dfd2ef3b0191985f942a40",
      "banner_hash": "4bf8d6cfe112edc9295cb7e8d93db7a6",
      "media": {
        "cover_url": "https://images-ext-1.discordapp.net/external/x/co3h3l.jpg",
        "artwork_hashes": ["4bf8d6cfe112edc9295cb7e8d93db7a6"],
        "icon": { "type": "hash", "value": "912bd1dd19dfd2ef3b0191985f942a40" },
        "banner": { "type": "hash", "value": "4bf8d6cfe112edc9295cb7e8d93db7a6" },
        "cover": { "type": "url", "value": "https://images-ext-1.discordapp.net/external/x/co3h3l.jpg" },
        "artwork": [{ "type": "hash", "value": "4bf8d6cfe112edc9295cb7e8d93db7a6" }]
      },
      "first_release_date": "2014-09-02T00:00:00+00:00",
      "genres": [20, 28],
      "platforms": [0, 1, 2, 7],
      "themes": ["Action", "Fantasy"],
      "screenshot_urls": ["https://images-ext-1.discordapp.net/external/x/scbtf2.jpg"],
      "trailers": [{
        "id": "1486746055503192909",
        "application_id": "359509007423242240",
        "width": 1920, "height": 1080, "mime_type": "video/mp4", "size": 68386357
      }],
      "websites": [
        { "url": "https://discord.com/invite/thesims", "category": 18 },
        { "url": "https://store.steampowered.com/app/1222670/The_Sims_4", "category": 13 },
        { "url": "https://www.ea.com/games/the-sims/the-sims-4/features", "category": 1 },
        { "url": "https://en.wikipedia.org/wiki/The_Sims_4", "category": 3 },
        { "url": "https://twitter.com/TheSims", "category": 5 }
      ],
      "companies": [
        { "name": "Electronic Arts", "roles": [1] },
        { "name": "The Sims Studio", "roles": [2] },
        { "name": "Maxis", "roles": [2] }
      ],
      "reviews": {
        "steam": {
          "rating": 86.0, "rating_count": 199981,
          "recent_rating": 80.0, "recent_rating_count": 1717,
          "localized_rating": 86.0, "localized_rating_count": 106026
        },
        "opencritic": {
          "top_critic_rating": 69.96923065185547,
          "top_critic_rating_count": 71,
          "tier": 3
        }
      },
      "opencritic_url": "https://opencritic.com/game/572/the-sims-4",
      "l30_rank": 43
    }]
    """

    private func decode(_ json: String) throws -> Game {
        try #require(
            try JSONDecoder().decode([GameDTO].self, from: Data(json.utf8)).first?.domain
        )
    }

    @Test("The whole store page decodes")
    func simsDecodes() throws {
        let game = try decode(sims)
        #expect(game.name == "The Sims 4")
        #expect(game.genreLine == "Role-Playing, Simulation")
        #expect(game.globalRank == 43)
        #expect(game.publishers == ["Electronic Arts"])
        #expect(game.developers == ["The Sims Studio", "Maxis"])
        #expect(game.themes == ["Action", "Fantasy"])
        #expect(game.screenshotURLs.count == 1)
        #expect(game.trailers.first?.id == "1486746055503192909")
    }

    @Test("A media hash and a media URL both survive as what they are")
    func mediaUnion() throws {
        let game = try decode(sims)
        #expect(game.media.icon == .hash("912bd1dd19dfd2ef3b0191985f942a40"))
        #expect(game.media.banner == .hash("4bf8d6cfe112edc9295cb7e8d93db7a6"))
        if case .url(let url)? = game.media.cover {
            #expect(url.absoluteString.hasSuffix("co3h3l.jpg"))
        } else {
            Issue.record("a url-tagged cover must not decode as a hash")
        }
    }

    @Test("A media entry with a tag nothing has seen resolves to nothing")
    func unknownMediaTag() throws {
        let game = try decode("""
        [{ "id": "1", "name": "x", "media": { "icon": { "type": "blob", "value": "zzz" } } }]
        """)
        #expect(game.media.icon == nil)
    }

    @Test("The flat hashes stand in when the structured block is absent")
    func flatHashFallback() throws {
        let game = try decode("""
        [{ "id": "1", "name": "x", "icon_hash": "aa", "banner_hash": "bb" }]
        """)
        #expect(game.media.icon == .hash("aa"))
        #expect(game.media.banner == .hash("bb"))
    }

    @Test("A release date with no fractional seconds still parses")
    func releaseDate() throws {
        let game = try decode(sims)
        let date = try #require(game.releaseDate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        #expect(parts.year == 2014)
        #expect(parts.month == 9)
        #expect(parts.day == 2)
    }

    @Test("Reviews come through with all three Steam aggregates")
    func reviews() throws {
        let game = try decode(sims)
        let reviews = try #require(game.reviews)
        #expect(reviews.steam?.recentRatingCount != nil)
        #expect(reviews.steam?.localizedRatingCount != nil)
        #expect(reviews.steam?.ratingCount != nil)
        #expect(reviews.steamRows(hasStorePage: game.steamStoreURL != nil).map(\.title) == ["Recent", "English"])
        #expect(reviews.openCritic?.tier == .fair)
        #expect(reviews.openCritic?.score == 69)
    }

    @Test("Websites keep their categories, and the Discord one yields a code")
    func websites() throws {
        let game = try decode(sims)
        #expect(game.communityInviteCode == "thesims")
        #expect(game.steamURL?.absoluteString.contains("1222670") == true)
        // Wikipedia is a category the row deliberately does not draw.
        #expect(game.socialLinks.map(\.category) == [.official, .twitter])
    }

    // MARK: Third-party SKUs

    /// `GET /games?game_ids=1158877933042143272`, trimmed to the fields this
    /// section is about and otherwise byte for byte.
    ///
    /// **Counter-Strike 2 is the useful one**: four SKUs of which exactly one
    /// is a storefront this client addresses, plus the `steam_release_status`
    /// that no other route sends.
    private let counterStrike = """
    [{
      "id": "1158877933042143272",
      "name": "Counter-Strike 2",
      "third_party_skus": [
        { "distributor": "igdb", "id": "242408" },
        { "distributor": "opencritic", "id": "15609" },
        { "distributor": "steam", "id": "730" },
        { "distributor": "gop", "id": "110013" }
      ],
      "websites": [{ "url": "https://store.steampowered.com/app/730", "category": 13 }],
      "steam_release_status": 3
    }]
    """

    @Test("Every SKU survives the decode, catalogue ids included")
    func skusDecode() throws {
        let game = try decode(counterStrike)
        #expect(
            game.thirdPartySkus.map(\.distributor) == ["igdb", "opencritic", "steam", "gop"]
        )
        #expect(game.thirdPartySkus.map(\.id) == ["242408", "15609", "730", "110013"])
        #expect(game.steamReleaseStatus == .postRelease)
        #expect(
            game.storeOffers.map(\.url.absoluteString)
                == ["https://store.steampowered.com/app/730"]
        )
    }

    @Test("A distributor nobody has named keeps its name rather than being dropped")
    func unknownDistributor() throws {
        // The list is a record of what the route sent. Deciding what is a store
        // happens once, in `Game.storeOffers`, not at the decode.
        let game = try decode("""
        [{ "id": "1", "name": "x",
           "third_party_skus": [{ "distributor": "newstore", "id": "7" }] }]
        """)
        #expect(game.thirdPartySkus == [GameSKU(distributor: "newstore", id: "7")])
        #expect(game.storeOffers.isEmpty)
    }

    @Test("A release status outside the enum is nil rather than a default")
    func unknownReleaseStatus() throws {
        let game = try decode("""
        [{ "id": "1", "name": "x", "steam_release_status": 99 }]
        """)
        #expect(game.steamReleaseStatus == nil)
    }

    @Test("A SKU with no distributor is not a SKU")
    func malformedSKU() throws {
        let game = try decode("""
        [{ "id": "1", "name": "x",
           "third_party_skus": [{ "id": "7" }, { "distributor": "steam" },
                                { "distributor": "steam", "id": "620980" }] }]
        """)
        #expect(game.thirdPartySkus.map(\.id) == ["620980"])
    }

    @Test("A game with neither a name nor an id is dropped rather than blank")
    func incompleteGameDropped() throws {
        let games = try JSONDecoder()
            .decode([GameDTO].self, from: Data("""
            [{ "id": "1" }, { "name": "nameless" }, { "id": "2", "name": "ok" }]
            """.utf8))
            .compactMap(\.domain)
        #expect(games.map(\.name) == ["ok"])
    }

    // MARK: Announcements

    @Test("An empty announcements envelope is a real answer")
    func emptyAnnouncements() throws {
        // Beat Saber's own response, verbatim.
        let payload = try JSONDecoder().decode(
            GameAnnouncementsDTO.self,
            from: Data("""
            { "guild_id": null, "channel_id": null, "messages": [] }
            """.utf8)
        )
        #expect(payload.guild_id == nil)
        #expect(payload.messages?.isEmpty == true)
    }

    @Test("Announcements decode through the ordinary message reader")
    func announcementsDecode() throws {
        let payload = try JSONDecoder().decode(
            GameAnnouncementsDTO.self,
            from: Data("""
            {
              "guild_id": "950244160687585111",
              "channel_id": "1462906695109862977",
              "messages": [{
                "id": "1545374058386510605",
                "channel_id": "1462906695109862977",
                "type": 0,
                "content": "",
                "timestamp": "2026-09-04T10:04:47.180000+00:00",
                "flags": 32769,
                "author": { "id": "1536231714596242197", "username": "Delta Bot", "discriminator": "0000", "bot": true },
                "components": [
                  { "type": 17, "id": 1, "components": [
                    { "type": 10, "id": 4, "content": "## Map Tools Update" }
                  ]}
                ],
                "reactions": [
                  { "emoji": { "id": "1438449427789706229", "name": "ChenLeak" }, "count": 16 }
                ]
              }]
            }
            """.utf8)
        )
        let messages = (payload.messages ?? []).map(\.domain)
        let message = try #require(messages.first)
        #expect(message.reactions.first?.count == 16)
        #expect(!message.displayComponents.isEmpty)
    }

    // MARK: Similar games

    @Test("Similar games decode to ids and nothing else")
    func similarGames() throws {
        let payload = try JSONDecoder().decode(
            SimilarGamesDTO.self,
            from: Data("""
            { "game_id": "1461154307171811401", "similar_games": ["762434991307121812", "1247227126416146462"] }
            """.utf8)
        )
        #expect(payload.similar_games?.count == 2)
    }
}
