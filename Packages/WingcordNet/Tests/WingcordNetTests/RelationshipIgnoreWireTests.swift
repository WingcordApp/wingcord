import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// An ignore is `user_ignored`, in READY and in all three relationship events.
///
/// It was read as `is_ignored`, a name Discord sends nowhere: no ignore loaded
/// at launch, and every event said "not ignored" about somebody who was.
@Suite("Ignored and blocked on the wire")
struct RelationshipIgnoreWireTests {

    private static func snapshot(_ json: String) throws -> ReadySnapshot {
        ReadySnapshot(payload: try JSONDecoder().decode(ReadyPayload.self, from: Data(json.utf8)))
    }

    private static func update(_ json: String) throws -> GatewayUpdate? {
        let frame = try JSONDecoder().decode(GatewayFrame.self, from: Data(json.utf8))
        return GatewayUpdate(frame.payload)
    }

    @Test("READY loads the blocked by type and the ignored by flag, each alone")
    func readyLoadsBoth() throws {
        let snapshot = try Self.snapshot("""
        { "session_id": "s",
          "user": { "id": "1", "username": "reader" },
          "relationships": [
            { "id": "10", "type": 2 },
            { "id": "11", "type": 1, "user_ignored": true },
            { "id": "12", "type": 1, "user_ignored": false },
            { "id": "13", "type": 0, "user_ignored": true }
          ] }
        """)
        #expect(snapshot.blockedUserIDs == [UserID(rawValue: 10)])
        #expect(snapshot.ignoredUserIDs == [UserID(rawValue: 11), UserID(rawValue: 13)])
        // An ignored friend is still a friend.
        #expect(snapshot.relationships[UserID(rawValue: 11)] == .friend)
    }

    @Test("RELATIONSHIP_ADD carries the ignore")
    func addCarriesIt() throws {
        let update = try Self.update("""
        { "op": 0, "t": "RELATIONSHIP_ADD", "s": 1,
          "d": { "id": "11", "type": 1, "user_ignored": true } }
        """)
        guard case .relationshipChanged(let userID, let kind, let isIgnored, _, _) = update else {
            Issue.record("expected a relationship change")
            return
        }
        #expect(userID == UserID(rawValue: 11))
        #expect(kind == .friend)
        #expect(isIgnored)
    }

    @Test("RELATIONSHIP_REMOVE leaves an ignore the event still names")
    func removeKeepsIt() throws {
        let kept = try Self.update("""
        { "op": 0, "t": "RELATIONSHIP_REMOVE", "s": 1,
          "d": { "id": "11", "type": 1, "user_ignored": true } }
        """)
        guard case .relationshipChanged(_, let kind, let isIgnored, _, _) = kept else {
            Issue.record("expected a relationship change")
            return
        }
        #expect(kind == .none)
        #expect(isIgnored)

        let dropped = try Self.update("""
        { "op": 0, "t": "RELATIONSHIP_REMOVE", "s": 1, "d": { "id": "11", "type": 1 } }
        """)
        guard case .relationshipChanged(_, _, let stillIgnored, _, _) = dropped else {
            Issue.record("expected a relationship change")
            return
        }
        #expect(!stillIgnored)
    }

    @Test("RELATIONSHIP_UPDATE is the whole relationship: kind, ignore and nickname")
    func updateCarriesAll() throws {
        let update = try Self.update("""
        { "op": 0, "t": "RELATIONSHIP_UPDATE", "s": 1,
          "d": { "id": "11", "type": 1, "nickname": "Ada", "user_ignored": true } }
        """)
        guard case .relationshipUpdated(let userID, let kind, let isIgnored, let nickname, _) = update else {
            Issue.record("expected a relationship update")
            return
        }
        #expect(userID == UserID(rawValue: 11))
        #expect(kind == .friend)
        #expect(isIgnored)
        #expect(nickname == "Ada")
    }

    @Test("a stranger request is read under either of Discord's two names")
    func strangerUnderBothNames() throws {
        let rest = try DiscordREST.decoder.decode(
            RelationshipDTO.self, from: Data(#"{"id": "1", "type": 3, "stranger_request": true}"#.utf8)
        )
        let gateway = try DiscordREST.decoder.decode(
            RelationshipDTO.self, from: Data(#"{"id": "1", "type": 3, "is_stranger_request": true}"#.utf8)
        )
        #expect(rest.facts?.isStranger == true)
        #expect(gateway.facts?.isStranger == true)
    }
}
