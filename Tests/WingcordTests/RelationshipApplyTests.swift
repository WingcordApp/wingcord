import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// What the store keeps for a relationship event — Discord's
/// `RelationshipStore`, where a block is the kind and an ignore outlives it.
@MainActor
@Suite("Applying a relationship")
struct RelationshipApplyTests {
    private let person = UserID(rawValue: 21)

    @Test("an ignored friend is ignored and not blocked")
    func ignoredFriend() {
        let model = AppModel()
        model.applyRelationship(.friend, isIgnored: true, for: person)
        #expect(model.isIgnored(person))
        #expect(!model.isBlocked(person))
        #expect(model.relationships[person] == .friend)
    }

    @Test("an event that no longer says ignored lifts it")
    func ignoreLifted() {
        let model = AppModel()
        model.applyRelationship(.friend, isIgnored: true, for: person)
        model.applyRelationship(.friend, isIgnored: false, for: person)
        #expect(!model.isIgnored(person))
    }

    @Test("a removal drops the block and keeps an ignore the event names")
    func removalKeepsIgnore() {
        let model = AppModel()
        model.applyRelationship(.blocked, isIgnored: false, for: person)
        #expect(model.isBlocked(person))

        model.applyRelationship(.none, isIgnored: true, for: person)
        #expect(!model.isBlocked(person))
        #expect(model.isIgnored(person))
        #expect(model.relationships[person] == nil)

        model.applyRelationship(.none, isIgnored: false, for: person)
        #expect(!model.isIgnored(person))
    }

    @Test("the member list starts on the server's own groups")
    func memberListDefault() {
        #expect(MemberListOrganization.standard == .roles)
        // A conversation with no roles still has an honest arrangement.
        #expect(MemberListOrganization.standard.resolved(hasRoles: false, isWhole: true) == .activeNow)
    }
}
