import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The reader's activity feed, read off `first profile + the sims.har`.
struct ActivityInboxDecodeTests {

    private let captured = #"""
    {"request_id":"86aed4eea09e30bb834ebcc42a2d9f03","entries":[
     {"content":{"id":"1538208195229115405","author_id":"531840562732986303","author_type":1,"content_type":1,
       "traits":[{"type":2,"duration_seconds":809},{"type":1,"first_time":true},{"type":9,"trending":1}],
       "extra":{"type":"played_game_extra","game_name":"Tom Clancy's Rainbow Six Siege X","application_id":"356876590342454859","platform":0},
       "participants":["531840562732986303"],"ended_at":"2026-08-15T15:30:12.268000+00:00","started_at":"2026-08-15T15:16:43.268000+00:00",
       "signature":{"signature":"083b47a2e7e413187f4bfbf0d8b25aaa604c3466c37acbb291dcd5c577be0871","kid":"AtDT4Kx25Wmu5cfllPxAiwZKgPbmLsaeHitpx/duvPY=","version":1}},"rank":1},
     {"content":{"id":"2055703272","author_id":"733744997067723948","author_type":1,"content_type":6,
       "traits":[{"type":4,"range":1},{"type":10,"count":12},{"type":11,"count":59},{"type":12,"count":130}],
       "extra":{"type":"top_artist_extra","artist":{"external_id":"551EawRj5350YQYs1MC2Ot","name":"Devon Hendryx"},
         "media":{"type":"listened_media_extra","provider":1,"media_type":0,"parent_title":"The Rockwood Escape Plan","title":"God & Earrings","image_url":"https://i.scdn.co/image/ab67616d0000b2737905832361a25be8d74a5c65","artists":[],"external_id":"4BeW9OUBKGW2wFBw3nLlGj","external_parent_id":"3aQUFJHAamUpJdSHbNYMNw"}},
       "original_id":"1545533152455457379","participants":["733744997067723948"],
       "signature":{"signature":"f0b6ddfaf9291cad25c16574de4608bba12254bd33a6f0683d72b9da34104aea","kid":"AtDT4Kx25Wmu5cfllPxAiwZKgPbmLsaeHitpx/duvPY=","version":1}},"rank":3}],
     "entries_hash":0,"expired_at":"2026-09-05T05:44:23.063000+00:00","refresh_stale_inbox_after_ms":30000,
     "refresh_token":"eyJjcmVhdGVkX2F0IjogIjIwMjYtMDktMDVUMDU6Mjk6NDMuNzA0MjkwKzAwOjAwIn0=","wait_ms_until_next_fetch":879362}
    """#

    @Test("Ranked entries come through with their participants, traits and the refresh token")
    func inbox() throws {
        let inbox = try DiscordREST.decoder.decode(ContentInboxDTO.self, from: Data(captured.utf8))
        let entries = (inbox.entries ?? []).compactMap(\.domain)
        #expect(entries.count == 2)
        #expect(entries[0].rank == 1)
        #expect(entries[0].participants == [UserID(rawValue: 531_840_562_732_986_303)])
        #expect(entries[0].activity.traits.contains(.newPlayer))
        #expect(entries[1].activity.traits.contains(.weeklyCount(130)))
        #expect(inbox.refresh_token?.isEmpty == false)
        #expect(inbox.refresh_stale_inbox_after_ms == 30_000)
    }

    @Test("The entry is kept whole — signature and fields this client never reads")
    func rawIsWhole() throws {
        let inbox = try DiscordREST.decoder.decode(ContentInboxDTO.self, from: Data(captured.utf8))
        let entry = try #require((inbox.entries ?? []).compactMap(\.domain).first)
        let object = try #require(try JSONSerialization.jsonObject(with: entry.raw) as? [String: Any])
        #expect(object["author_type"] as? Int == 1)
        let signature = try #require(object["signature"] as? [String: Any])
        #expect(signature["kid"] as? String == "AtDT4Kx25Wmu5cfllPxAiwZKgPbmLsaeHitpx/duvPY=")
        let extra = try #require(object["extra"] as? [String: Any])
        #expect(extra["platform"] as? Int == 0)
    }
}
