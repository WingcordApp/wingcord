import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Discover › Games' requests (docs/QUEUE-NOV19.md §1): the routes and query
/// Discord's page sends, and the answers read as its code reads them.
@Suite("Games in Discover on the wire")
struct GameDiscoveryWireTests {
    @Test("Trending reads rank, change, categories by rank and the official server")
    func trending() async throws {
        let body = """
        {"week":"2026-11-16","games":[
          {"game_id":"42","rank":2,"total_players_pct_change":-0.05,"categories":[{"id":12,"rank":2},{"id":1,"rank":1}],
           "official_guild":{"id":"7","name":"Official","icon_url":"https://cdn.discordapp.com/icons/7/a.png",
             "invite_link_url":"https://discord.gg/abc","is_verified":true,"approximate_online_count":357400}},
          {"game_id":"43","rank":1,"total_players_pct_change":0.12,"categories":[]}]}
        """
        let (rest, token) = await RequestRecorder.client(body: body)
        let trending = try await rest.trendingGames()
        #expect(RequestRecorder.requests(for: token).first?.path == "/api/v9/games/trending")
        #expect(trending.week == "2026-11-16")
        #expect(trending.entries.map(\.rank) == [1, 2])
        let second = trending.entries[1]
        #expect(second.playersChange == -0.05)
        #expect(second.categories == [1, 12])
        #expect(second.officialGuild?.isVerified == true)
        #expect(second.officialGuild?.inviteURL?.lastPathComponent == "abc")
        #expect(second.officialGuild?.onlineCount == 357_400)
    }

    @Test("Search sends the showcase group, sorted filters and the page, and reads the facets")
    func search() async throws {
        let body = """
        {"games":[{"id":"42","name":"Hades"}],"total_count":61,
         "facets":{"genres":[{"value":5,"count":3}],"platform_availability":[{"value":"desktop","count":60}]}}
        """
        let (rest, token) = await RequestRecorder.client(body: body)
        let page = try await rest.discoverGames(query: "shade", genres: [9, 5], platforms: ["mobile"], offset: 25)
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.path == "/api/v9/games/search")
        let items = request.queryItems.map { "\($0.name)=\($0.value ?? "")" }
        #expect(items == ["q=shade", "filter_group=showcase", "genres=5", "genres=9", "platform_availability=mobile", "offset=25", "limit=25"])
        #expect(page.games.first?.name == "Hades")
        #expect(page.totalCount == 61)
        #expect(page.genreCounts.first?.value == 5)
        #expect(page.platformCounts.first?.count == 60)
    }

    @Test("Play statistics come newest first")
    func playStatistics() async throws {
        let body = """
        [{"application_id":"1","last_played_at":"2026-11-01T10:00:00+00:00","total_duration":600},
         {"application_id":"2","last_played_at":"2026-11-10T10:00:00+00:00","total_duration":7200}]
        """
        let (rest, token) = await RequestRecorder.client(body: body)
        let played = try await rest.playStatistics()
        #expect(RequestRecorder.requests(for: token).first?.path == "/api/v9/users/@me/activities/statistics/applications")
        #expect(played.map(\.applicationID.rawValue) == [2, 1])
        #expect(played.first?.totalDuration == 7_200)
    }

    @Test("Guide progress reads completed steps, and a step is posted to its route")
    func guideProgress() async throws {
        let (rest, token) = await RequestRecorder.client(
            body: #"{"channel_actions":{"10":{"completed":true},"11":{"completed":false}}}"#
        )
        let done = try await rest.guideProgress(of: GuildID(rawValue: 1))
        #expect(done == [ChannelID(rawValue: 10)])
        #expect(RequestRecorder.requests(for: token).first?.path == "/api/v9/guilds/1/new-member-actions")

        let (post, postToken) = await RequestRecorder.client(status: 204, body: "")
        try await post.completeGuideStep(ChannelID(rawValue: 10), in: GuildID(rawValue: 1))
        let request = try #require(RequestRecorder.requests(for: postToken).first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v9/guilds/1/new-member-action/10")
    }
}

/// The Void's two requests (docs/QUEUE-NOV19.md §2).
@Suite("The Void on the wire")
struct OrbVoidWireTests {
    @Test("Its status reads the snapshot, eligibility and the batch cap")
    func status() async throws {
        let (rest, token) = await RequestRecorder.client(
            body: #"{"snapshot":{"balance":1200,"total_burned":340},"eligible":true,"max_batch_quantity":50}"#
        )
        let status = try await rest.orbVoidStatus()
        #expect(RequestRecorder.requests(for: token).first?.path == "/api/v9/users/@me/virtual-currency/orb-void")
        #expect(status == OrbVoidStatus(balance: 1200, totalBurned: 340, isEligible: true, maxBatchQuantity: 50))
    }

    @Test("A batch posts its sink, quantity and time, and reads the new totals")
    func batch() async throws {
        let (rest, token) = await RequestRecorder.client(body: #"{"snapshot":{"balance":1190,"total_burned":350}}"#)
        let answer = try await rest.throwOrbs(sinkID: "abc", quantity: 10, at: Date(timeIntervalSince1970: 0))
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "POST")
        #expect(request.json?["sink_id"] as? String == "abc")
        #expect(request.json?["quantity"] as? Int == 10)
        #expect((request.json?["batch_timestamp"] as? String)?.hasPrefix("1970-01-01T00:00:00") == true)
        #expect(answer.balance == 1190)
        #expect(answer.totalBurned == 350)
    }

    @Test("Server errors and no answer are retried; refusals are not")
    func retryable() {
        #expect(DiscordREST.Failure.api(status: 503, code: nil, message: nil).isRetryable)
        #expect(DiscordREST.Failure.api(status: 429, code: nil, message: nil).isRetryable)
        #expect(DiscordREST.Failure.transport("offline").isRetryable)
        #expect(!DiscordREST.Failure.api(status: 400, code: nil, message: nil).isRetryable)
        #expect(!DiscordREST.Failure.forbidden(code: nil).isRetryable)
    }
}
