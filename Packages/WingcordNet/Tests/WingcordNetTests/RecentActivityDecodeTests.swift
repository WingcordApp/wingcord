import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The two routes behind the profile's Activity tab, decoded from the capture
/// they were read out of.
///
/// **Every payload below is verbatim** — `GET /content-inventory/users/{id}
/// /outbox` and `GET /users/{id}/sessions/{sid}/activities/{app}/metadata`,
/// September 2026, on a live account playing Counter-Strike through Medal.
@Suite("Recent activity")
struct RecentActivityDecodeTests {

    private func decoded<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.withFraction.date(from: text) { return date }
            if let date = ISO8601DateFormatter.plain.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: text
            )
        }
        return try decoder.decode(type, from: Data(json.utf8))
    }

    /// The outbox's own entry: a live Counter-Strike session with a duration and
    /// an eight-day streak.
    @Test("A live played-game entry keeps its traits")
    func liveGame() throws {
        let payload = try decoded(
            """
            {"entries":[{"id":"1544918714722748240","author_id":"527068850309506916",
            "author_type":1,"content_type":1,
            "traits":[{"type":2,"duration_seconds":5400},{"type":3,"is_live":true},
            {"type":8,"streak_count_days":8}],
            "extra":{"type":"played_game_extra","game_name":"Counter-Strike 2",
            "application_id":"1158877933042143272","platform":0},
            "participants":["527068850309506916"],
            "expires_at":"2026-09-03T06:00:24.776486+00:00",
            "started_at":"2026-09-03T03:55:24.791000+00:00"}]}
            """,
            as: ContentOutboxDTO.self
        )
        let entry = try #require(payload.entries?.first?.domain)
        #expect(entry.id == "1544918714722748240")
        #expect(entry.subject == .game(
            name: "Counter-Strike 2",
            applicationID: ApplicationID(rawValue: 1_158_877_933_042_143_272)
        ))
        #expect(entry.isLive)
        #expect(entry.duration == 5_400)
        #expect(entry.traits.contains(.streak(days: 8)))
        // **No end, and that is the difference on the wire.** A live entry
        // carries `expires_at` instead, so what dates the row is its start.
        #expect(entry.endedAt == nil)
        #expect(entry.occurredAt == entry.startedAt)
    }

    /// `content_type: 8` with `launched_activity_extra` — an embedded activity,
    /// which is a different thing from a game and names its own field.
    @Test("A launched activity decodes from its own extra")
    func launchedActivity() throws {
        let payload = try decoded(
            """
            {"entries":[{"id":"1538245655768945047","author_id":"1511763194882797196",
            "content_type":8,"traits":[{"type":6,"marathon":true},{"type":1,"first_time":true}],
            "extra":{"type":"launched_activity_extra","activity_name":"Wordle",
            "application_id":"1211781489931452447"}}]}
            """,
            as: ContentOutboxDTO.self
        )
        let entry = try #require(payload.entries?.first?.domain)
        #expect(entry.subject.title == "Wordle")
        #expect(entry.subject.applicationID == ApplicationID(rawValue: 1_211_781_489_931_452_447))
        #expect(entry.traits.contains(.marathon))
        #expect(entry.traits.contains(.newPlayer))
    }

    /// A top-artist entry: the track is the nested media's, the artist is the
    /// entry's own, and the picture is Spotify's.
    @Test("A music entry names the track over the artist")
    func topArtist() throws {
        let payload = try decoded(
            """
            {"entries":[{"id":"2280903019","author_id":"733744997067723948","content_type":6,
            "traits":[{"type":4,"range":1},{"type":10,"count":10}],
            "extra":{"type":"top_artist_extra",
            "artist":{"external_id":"551","name":"Devon Hendryx"},
            "media":{"type":"listened_media_extra","provider":1,"media_type":0,
            "parent_title":"The Rockwood Escape Plan","title":"God & Earrings",
            "image_url":"https://i.scdn.co/image/ab67616d0000b273790"}}}]}
            """,
            as: ContentOutboxDTO.self
        )
        let entry = try #require(payload.entries?.first?.domain)
        #expect(entry.subject.title == "God & Earrings")
        #expect(entry.subject.subtitle == "Devon Hendryx")
        #expect(entry.subject.applicationID == nil)
        // Type 4 is Discord's `AGGREGATE_RANGE`, range 1 a week — what lets a
        // top artist card show at all (`420018`). Type 10
        // (`TOP_ITEM_TOTAL_COUNT`) draws nothing in Discord's cards, so it
        // decodes as nothing.
        #expect(entry.traits == [.week])
        #expect(entry.details.album == "The Rockwood Escape Plan")
        #expect(entry.details.artistExternalID == "551")
        #expect(entry.details.provider == 1)
    }

    /// An entry whose `extra.type` this client has never seen is dropped whole
    /// rather than drawn as a row with no subject.
    @Test("An unknown extra drops the row")
    func unknownExtra() throws {
        let payload = try decoded(
            """
            {"entries":[{"id":"1","author_id":"2","content_type":99,
            "extra":{"type":"watched_film_extra"}}]}
            """,
            as: ContentOutboxDTO.self
        )
        #expect(payload.entries?.compactMap(\.domain).isEmpty == true)
    }

    /// The metadata route, verbatim. Two buttons, two links.
    @Test("Button URLs decode in order")
    func buttonURLs() throws {
        let payload = try decoded(
            """
            {"button_urls":["https://medal.tv/u/Browhiskey?ref=discordrpc",
            "https://medal.tv/?ref=discordrpc"]}
            """,
            as: ActivityMetadataDTO.self
        )
        let urls = (payload.button_urls ?? []).compactMap(URL.init(string:))
        #expect(urls.count == 2)
        #expect(urls.first?.host == "medal.tv")
        #expect(urls.first?.path == "/u/Browhiskey")
    }
    /// The three kinds Discord's member list draws that no capture has shown
    /// yet, read off Discord's own switch on `content_type` (`420018`).
    @Test("Top game, watched media and a listening session decode by content type")
    func newKinds() throws {
        let payload = try decoded(
            """
            {"entries":[
            {"id":"1","author_id":"2","content_type":3,"traits":[{"type":4,"range":1},{"type":2,"duration_seconds":43200}],
             "extra":{"game_name":"Some Game","application_id":"1400000000000000501","platform":1}},
            {"id":"3","author_id":"2","content_type":2,"extra":{"media_title":"A Show","media_subtitle":"The Episode",
             "media_assets_large_text":"Season 1, Episode 3","url":"https://example.com/show","application_id":"1400000000000000502"}},
            {"id":"4","author_id":"2","content_type":5,"traits":[{"type":3,"is_live":true}],
             "extra":{"entries":[{"media":{"title":"A Track","provider":1,"image_url":"https://example.com/a.jpg",
             "artists":[{"name":"One"},{"name":"Two"}]}}]}}]}
            """,
            as: ContentOutboxDTO.self
        )
        let entries: [RecentActivity] = try #require(payload.entries).compactMap { $0.domain }
        #expect(entries.count == 3)
        #expect(entries[0].subject == RecentActivity.Subject.topGame(name: "Some Game", applicationID: ApplicationID(rawValue: 1_400_000_000_000_000_501)))
        #expect(entries[0].isWeekly)
        #expect(entries[0].duration == 43200)
        #expect(entries[0].details.platform == 1)
        #expect(entries[1].subject.title == "A Show")
        #expect(entries[1].subject.subtitle == "The Episode")
        #expect(entries[1].details.episodeMarker == "S1E3")
        #expect(entries[2].subject == RecentActivity.Subject.listeningSession(
            track: "A Track", artists: ["One", "Two"], artworkURL: URL(string: "https://example.com/a.jpg")
        ))
        #expect(entries[2].subject.subtitle == "One, Two")
        #expect(entries[2].isLive)
    }
}

/// The half of a rich presence this client used to throw away.
@Suite("Rich presence decoding")
struct PresenceActivityDecodeTests {

    @Test("An activity keeps its session, buttons, hover texts and end")
    func medalPresence() throws {
        let json = """
        {"name":"Counter-Strike 2 with Medal","type":0,
        "session_id":"684b846e670e76331b09709e92b25d31",
        "application_id":"307998818549172068",
        "details":"Clipping Counter-Strike 2","state":"with Medal",
        "buttons":["Follow on Medal","Download Medal","A third nobody sends"],
        "timestamps":{"start":1756900000000,"end":1756903600000},
        "assets":{"large_image":"cs2","large_text":"Counter-Strike 2",
        "large_url":"https://medal.tv/games/counter-strike-2?ref=discordrpc",
        "small_image":"medal","small_text":"Medal",
        "small_url":"https://medal.tv/?ref=discordrpc"}}
        """
        let dto = try JSONDecoder().decode(ActivityDTO.self, from: Data(json.utf8))
        let activity = try #require(dto.domain)
        #expect(activity.sessionID == "684b846e670e76331b09709e92b25d31")
        // Two at most: the wire caps it there and a third is a row the layout
        // has no space for.
        #expect(activity.buttons == ["Follow on Medal", "Download Medal"])
        #expect(activity.largeText == "Counter-Strike 2")
        #expect(activity.smallText == "Medal")
        #expect(activity.smallImageURL?.host == "medal.tv")
        // Milliseconds, both ends. Read as seconds they date to 1970.
        #expect(activity.startedAt == Date(timeIntervalSince1970: 1_756_900_000))
        #expect(activity.endsAt == Date(timeIntervalSince1970: 1_756_903_600))
    }

    /// The overwhelmingly common case: no buttons, no session, no hover text.
    @Test("A plain activity carries none of it")
    func plainPresence() throws {
        let json = #"{"name":"Xcode","type":0}"#
        let dto = try JSONDecoder().decode(ActivityDTO.self, from: Data(json.utf8))
        let activity = try #require(dto.domain)
        #expect(activity.buttons.isEmpty)
        #expect(activity.sessionID == nil)
        #expect(activity.endsAt == nil)
        #expect(activity.largeText == nil)
    }

}
