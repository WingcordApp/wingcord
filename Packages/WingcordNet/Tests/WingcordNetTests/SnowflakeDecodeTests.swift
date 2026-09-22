import Foundation
import Testing
@testable import WingcordCore
@testable import WingcordNet

/// Ids on the wire are **strings**, and a DTO that types one as an integer
/// accepts only the form Discord never sends.
///
/// **This is not a hypothetical.** `StageInstanceDTO.id` was `UInt64?`, which
/// made every payload carrying a live stage fail to decode — and because the
/// field it was on is part of `READY`, one server with the lights on in a stage
/// channel took the whole bootstrap down and left the app at the sign-in screen
/// saying it could not read what Discord sent.
///
/// **The value is never even read.** A stage is keyed on its channel, so `id`
/// is decoded and discarded; the only thing it could ever do was throw. That is
/// what makes this shape worth a test rather than a careful reviewer: a field
/// nobody uses is a field nobody checks.
@Suite("Snowflakes decode from strings")
struct SnowflakeDecodeTests {

    private func decode<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test("A stage instance decodes with its ids as strings")
    func stageInstanceTakesStringIDs() throws {
        // The shape Discord actually sends, ids and all.
        let stage = try decode(
            """
            {
              "id": "1234567890104688129",
              "guild_id": "9876543210987813669",
              "channel_id": "1111111111111111111",
              "topic": "Live",
              "privacy_level": 2,
              "guild_scheduled_event_id": "2222222222222222222"
            }
            """,
            as: StageInstanceDTO.self
        )
        #expect(stage.id?.rawValue == 1_234_567_890_123_456_789)
        #expect(stage.guild_scheduled_event_id?.rawValue == 2_222_222_222_222_222_222)

        let domain = try #require(stage.domain)
        #expect(domain.id == 1_234_567_890_123_456_789)
        #expect(domain.scheduledEventID == 2_222_222_222_222_222_222)
    }

    @Test("A stage with no id of its own still reads as a live stage")
    func stageWithoutAnIDIsStillLive() throws {
        // The instance's own id is not load-bearing — everything keys on the
        // channel — so a payload without one must not be discarded.
        let stage = try decode(
            """
            {"guild_id": "1", "channel_id": "2", "topic": ""}
            """,
            as: StageInstanceDTO.self
        )
        let domain = try #require(stage.domain)
        #expect(domain.id == 2)
        #expect(domain.scheduledEventID == nil)
    }

    @Test("A snowflake still takes a bare integer, for anything that sends one")
    func integersAreStillAccepted() throws {
        // `Snowflake` accepts both forms on purpose. The bug was never that
        // strings are hard to read — it was a field that bypassed this entirely.
        let stage = try decode(
            """
            {"id": 7, "guild_id": "1", "channel_id": "2"}
            """,
            as: StageInstanceDTO.self
        )
        #expect(stage.id?.rawValue == 7)
    }

    @Test("A guild folder's id is genuinely an integer, and stays one")
    func folderIDsAreNotSnowflakes() throws {
        // The counter-example, so the sweep that produced this suite does not
        // get repeated on a field that is right: Discord's folder id is an
        // `Int64Value`, not a snowflake, and sending it through `Snowflake`
        // would be the same mistake in the other direction.
        let settings = try decode(
            """
            {"guild_folders": [{"id": 12345, "name": "Games", "guild_ids": ["1"]}]}
            """,
            as: ClientSettingsDTO.self
        )
        #expect(settings.guild_folders?.first?.id == 12345)
    }
}
