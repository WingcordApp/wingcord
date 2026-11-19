import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The reader's own member record in every server comes with READY, in
/// `merged_members` — one list per guild, in `guilds` order — and was never
/// read: "after READY, 97 of 97 servers have no own member record" (his log,
/// 2026-11-19; docs/BETA3.md §7, R3).
@Suite("READY's merged members")
struct ReadyMergedMembersTests {

    private static func snapshot(_ json: String) throws -> ReadySnapshot {
        ReadySnapshot(payload: try JSONDecoder().decode(ReadyPayload.self, from: Data(json.utf8)))
    }

    @Test("Each server gets the reader's own record, roles and all")
    func ownRecordPerServer() throws {
        let snapshot = try Self.snapshot("""
        { "session_id": "s",
          "user": { "id": "1", "username": "reader" },
          "guilds": [
            { "id": "100", "properties": { "id": "100", "name": "One" } },
            { "id": "200", "properties": { "id": "200", "name": "Two" } }
          ],
          "merged_members": [
            [ { "user_id": "1", "roles": ["7", "8"], "pending": false, "flags": 2 } ],
            [ { "user_id": "1", "roles": [], "pending": true } ]
          ] }
        """)
        let first = try #require(snapshot.membersByGuild[GuildID(rawValue: 100)]?[UserID(rawValue: 1)])
        #expect(first.roleIDs == [RoleID(rawValue: 7), RoleID(rawValue: 8)])
        let second = try #require(snapshot.membersByGuild[GuildID(rawValue: 200)]?[UserID(rawValue: 1)])
        #expect(second.isPending)
    }

    /// Positional to the end: a list that can't be read keeps its place, so
    /// the next server's record isn't filed under the wrong server.
    @Test("An unreadable list keeps its place")
    func unreadableListKeepsItsPlace() throws {
        let snapshot = try Self.snapshot("""
        { "session_id": "s",
          "user": { "id": "1", "username": "reader" },
          "guilds": [
            { "id": "100", "properties": { "id": "100", "name": "One" } },
            { "id": "200", "properties": { "id": "200", "name": "Two" } }
          ],
          "merged_members": [ "not a list", [ { "user_id": "1", "roles": ["9"] } ] ] }
        """)
        #expect(snapshot.membersByGuild[GuildID(rawValue: 100)]?[UserID(rawValue: 1)] == nil)
        #expect(snapshot.membersByGuild[GuildID(rawValue: 200)]?[UserID(rawValue: 1)]?.roleIDs == [RoleID(rawValue: 9)])
    }

    @Test("A count that doesn't match READY's servers is dropped, never misfiled")
    func mismatchedCountIsDropped() throws {
        let snapshot = try Self.snapshot("""
        { "session_id": "s",
          "user": { "id": "1", "username": "reader" },
          "guilds": [ { "id": "100", "properties": { "id": "100", "name": "One" } } ],
          "merged_members": [ [ { "user_id": "1", "roles": ["7"] } ], [] ] }
        """)
        #expect(snapshot.membersByGuild[GuildID(rawValue: 100)] == nil)
    }

    /// The payload Discord can't decode is never sent (R2).
    @Test("An encoded payload's op is read without decoding it")
    func opcodeIsRead() {
        #expect(GatewaySocket.opcode(in: Data(#"{"op":14,"d":{"guild_id":"1"}}"#.utf8)) == 14)
        #expect(GatewaySocket.opcode(in: Data(#"{"d":{},"op": 1}"#.utf8)) == 1)
        #expect(GatewaySocket.opcode(in: Data(#"{"d":{}}"#.utf8)) == nil)
    }
}
