import Foundation
import Testing
@testable import WingcordCore

/// Snowflake decoding.
///
/// The both-forms test is the one that matters: Discord documents snowflakes as
/// strings and does not always send them that way, and because a gateway payload
/// is ONE JSON document, a single unexpected number seven megabytes in throws
/// away the entire bootstrap.
@Suite("Snowflake")
struct SnowflakeTests {
    private struct Box: Codable, Equatable {
        var id: MessageID
    }

    private let decoder = JSONDecoder()

    @Test("Decodes the documented string form")
    func stringForm() throws {
        let box = try decoder.decode(Box.self, from: Data(#"{"id":"1328958026344282157"}"#.utf8))
        #expect(box.id.rawValue == 1_328_958_026_344_282_157)
    }

    /// Observed live, in READY, on `read_state.entries[…].last_message_id`.
    @Test("Decodes a bare number, which Discord also sends")
    func numberForm() throws {
        let box = try decoder.decode(Box.self, from: Data(#"{"id":1328958026344282157}"#.utf8))
        #expect(box.id.rawValue == 1_328_958_026_344_282_157)
    }

    @Test("A large snowflake survives the number form exactly")
    func numberFormKeepsEveryBit() throws {
        // Past 2^53 — the point where a `Double` would silently round the low
        // digits away and produce an id belonging to nothing.
        let raw: UInt64 = 9_007_199_254_740_995
        let box = try decoder.decode(Box.self, from: Data(#"{"id":\#(raw)}"#.utf8))
        #expect(box.id.rawValue == raw)
    }

    @Test("Encodes back to the string form Discord expects")
    func encodesAsString() throws {
        let data = try JSONEncoder().encode(Box(id: MessageID(rawValue: 42)))
        #expect(String(data: data, encoding: .utf8) == #"{"id":"42"}"#)
    }

    @Test("Refuses anything that is not an integer")
    func rejectsNonIntegers() {
        #expect(throws: (any Error).self) {
            try decoder.decode(Box.self, from: Data(#"{"id":"not a number"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try decoder.decode(Box.self, from: Data(#"{"id":true}"#.utf8))
        }
    }

    @Test("The timestamp comes out of the id itself")
    func timestamp() {
        let id = MessageID(rawValue: 175_928_847_300_319_682)
        // 2016-04-30T11:18:25.796Z, the example in Discord's own documentation.
        #expect(abs(id.timestamp.timeIntervalSince1970 - 1_462_015_105.796) < 0.001)
    }
}
