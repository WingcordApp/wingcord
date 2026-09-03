import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// `GET /users/@me/settings-proto/2`, the table the Recents row is drawn from.
///
/// **The bytes below are the account's own, not a reconstruction.** Three map
/// entries lifted verbatim out of the 27,536-byte blob in `activities123.har`
/// and re-framed as field 9 of a `FrecencyUserSettings`; every varint inside
/// them is exactly what Discord sent. A protobuf read with the wrong field
/// numbers does not fail, it answers plausible nonsense — so the check is that
/// the numbers this reader produces match the ones the capture's own client
/// acted on.
@Suite("Application frecency")
struct FrecencyProtoTests {

    private let blob = """
    SjkKEjk0OTQ3OTMzODI3NTkxMzc5ORIjCAMSEubB3K/9M9/Lk4OBNN/Lk4OBNBj///////////8BIEZK\
    ZQoTMTIxMTc4MTQ4OTkzMTQ1MjQ0NxJOCBsSPMDPoIT/M8DPoIT/M8DPoIT/M6uQoYT/M6uQoYT/M6uQ\
    oYT/M6+WqoT/M6+WqoT/M6+WqoT/M8eKn6b/Mxj///////////8BIOgHSmQKEjg4MDIxODM5NDE5OTIy\
    MDMzNBJOCGoSPOW4x5eGNKq+x5eGNKq+x5eGNPWxyJeGNPWxyJeGNKG0yJeGNKG0yJeGNOzAyJeGNOzA\
    yJeGNI6RzZeGNBj///////////8BIOgH
    """

    private func entries() -> [FrecencyProto.Entry] {
        FrecencyProto.decode(base64: blob)
    }

    @Test("Every map entry decodes")
    func decodesAllEntries() {
        #expect(entries().count == 3)
    }

    /// The account's most-launched activity by a wide margin, and the values
    /// the reference client's own Recents row put first.
    @Test("Use counts and scores match the capture")
    func countsAndScores() throws {
        let byID = Dictionary(
            entries().map { ($0.applicationID.description, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let watch = try #require(byID["880218394199220334"])
        #expect(watch.totalUses == 106)
        #expect(watch.score == 1000)

        let wordle = try #require(byID["1211781489931452447"])
        #expect(wordle.totalUses == 27)
        #expect(wordle.score == 1000)

        // Three launches scoring 70 where three launches elsewhere score 300:
        // the score carries time decay, so it is read rather than derived.
        let quote = try #require(byID["949479338275913799"])
        #expect(quote.totalUses == 3)
        #expect(quote.score == 70)
    }

    /// `recent_uses` is a packed repeated **varint**, not the packed
    /// `fixed64` every id list in `PreloadedUserSettings` uses. Read as
    /// fixed64 the timestamps come out as garbage on any length that happens
    /// to divide by eight.
    @Test("recent_uses decodes as packed varints, in milliseconds")
    func recentUsesAreMilliseconds() throws {
        let byID = Dictionary(
            entries().map { ($0.applicationID.description, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let watch = try #require(byID["880218394199220334"])
        let last = try #require(watch.lastUsedAt)
        // 1788366506126 ms. Read as seconds it would land in the year 58,000;
        // read as fixed64 it would not land anywhere.
        #expect(abs(last.timeIntervalSince1970 - 1_788_366_506.126) < 0.001)

        let wordle = try #require(byID["1211781489931452447"])
        let wordleLast = try #require(wordle.lastUsedAt)
        #expect(wordleLast < last)
    }

    /// Garbage in, empty out. The rail-goes-blank failure `ProtobufReader`
    /// exists to prevent applies here too: one bad byte must cost the Recents
    /// row, never the launcher.
    @Test("Malformed input yields no entries rather than throwing")
    func malformedInputIsEmpty() {
        #expect(FrecencyProto.decode(base64: "not base64 at all!!").isEmpty)
        #expect(FrecencyProto.decode(base64: "").isEmpty)
        #expect(FrecencyProto.decode(base64: "SgUKAwoBAQ==").isEmpty)
    }
}
