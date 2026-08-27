import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The mention table's memo.
///
/// **A memo that is never hit is invisible**, which is why this asserts the key
/// rather than the answer: two calls returning equal dictionaries proves nothing
/// about whether the second one rebuilt them.
///
/// The table is proportional to the whole account — every user in the session,
/// with a per-user member lookup and a fresh dictionary of that many strings —
/// and `TimelineCoordinator.runLayout` asks for it on **every inbound message**.
/// Unmemoized, one message anywhere walked the entire user table. So the
/// property that matters is not "there is a cache" but "a message arriving does
/// not invalidate it".
@MainActor
struct MentionContextMemoTests {

    private func model(users count: Int) -> AppModel {
        let model = AppModel()
        for index in 0..<count {
            let id = UserID(rawValue: UInt64(index + 1))
            model.users[id] = User(
                id: id,
                username: "user\(index)",
                displayName: "User \(index)",
                avatarHash: nil,
                discriminator: "0",
                flags: [],
                isBot: false,
                isSystem: false,
                decoration: nil
            )
        }
        return model
    }

    @Test("The first call populates the cache")
    func populatesCache() {
        let model = model(users: 8)
        #expect(model.mentionCache == nil)
        _ = model.mentionContext()
        #expect(model.mentionCache != nil)
    }

    @Test("A message arriving does not invalidate it")
    func messagesDoNotInvalidate() {
        // This is the whole point. `messageContentRevision` moves on every
        // inbound message, every edit and every reaction; none of them can
        // rename anybody, so none of them may cost a rebuild.
        let model = model(users: 8)
        _ = model.mentionContext()
        let before = model.mentionCache?.key

        model.messageContentRevision &+= 1
        _ = model.mentionContext()
        let after = model.mentionCache?.key

        #expect(before == after)
    }

    @Test("A name change does invalidate it")
    func identityChangeInvalidates() {
        // The other half: a memo that never misses is a bug of the opposite
        // kind, and it renders `@user` forever.
        let model = model(users: 8)
        _ = model.mentionContext()
        let before = model.mentionCache?.key

        model.identityRevision &+= 1
        _ = model.mentionContext()
        let after = model.mentionCache?.key

        #expect(before != after)
    }

    @Test("The answer still tracks the table it caches")
    func answerIsCorrect() {
        let model = model(users: 3)
        let context = model.mentionContext()
        #expect(context.userNames.count == 3)
        #expect(context.userNames[UserID(rawValue: 1)] == "User 0")

        // Rename, move the revision, and the next answer must reflect it.
        model.users[UserID(rawValue: 1)] = User(
            id: UserID(rawValue: 1),
            username: "user0",
            displayName: "Renamed",
            avatarHash: nil,
            discriminator: "0",
            flags: [],
            isBot: false,
            isSystem: false,
            decoration: nil
        )
        model.identityRevision &+= 1
        #expect(model.mentionContext().userNames[UserID(rawValue: 1)] == "Renamed")
    }
}

/// Memory pressure has to actually bound the tables that grow without one.
@MainActor
struct MemoryPressureTests {

    @Test("Pressure drops other guilds' rosters and keeps the open one")
    func prunesRosters() {
        let model = AppModel()
        let kept = GuildID(rawValue: 1)
        let dropped = GuildID(rawValue: 2)
        model.members[kept] = [
            UserID(rawValue: 10): Member(userID: UserID(rawValue: 10), nickname: "kept")
        ]
        model.members[dropped] = [
            UserID(rawValue: 20): Member(userID: UserID(rawValue: 20), nickname: "dropped")
        ]
        model.selectedGuildID = kept

        model.relieveMemoryPressure()

        #expect(model.members[kept] != nil)
        #expect(model.members[dropped] == nil)
    }

    @Test("Pressure discards every memo, so none describes a dropped table")
    func clearsMemos() {
        // A surviving memo over a pruned table is worse than no memo: it is
        // present, wrong, and served in preference to rebuilding.
        let model = AppModel()
        model.selectedGuildID = GuildID(rawValue: 1)
        _ = model.mentionContext()
        _ = model.rosterSections
        #expect(model.mentionCache != nil)

        model.relieveMemoryPressure()

        #expect(model.mentionCache == nil)
        #expect(model.rosterCache == nil)
        #expect(model.railCache == nil)
        #expect(model.sidebarCache == nil)
    }
}
