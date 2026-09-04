import Foundation
import Testing
@testable import WingcordCore

/// The index's contract.
///
/// The revision tests are the important ones. `structureRevision` is what every
/// memo over the channel tree keys on, and the whole point of the type is that a
/// `lastMessageID` write — which happens on *every inbound message* — does not
/// move it. A test that only checked the lookups would pass on an implementation
/// that rebuilds the world several times a second.
@Suite("Channel index")
struct ChannelIndexTests {

    private let guildID = GuildID(rawValue: 10)

    private func channel(
        _ id: UInt64,
        kind: ChannelKind = .text,
        parent: UInt64? = nil,
        position: Int = 0,
        lastMessage: UInt64? = nil
    ) -> Channel {
        Channel(
            id: ChannelID(rawValue: id),
            kind: kind,
            guildID: guildID,
            name: "c\(id)",
            parentID: parent.map { ChannelID(rawValue: $0) },
            position: position,
            lastMessageID: lastMessage.map { MessageID(rawValue: $0) }
        )
    }

    @Test("Lookup by id, and by owning guild")
    func lookups() {
        var index = ChannelIndex()
        index.replaceChannels([channel(1), channel(2)], inGuild: guildID)
        #expect(index[ChannelID(rawValue: 1)]?.name == "c1")
        #expect(index.guildID(of: ChannelID(rawValue: 2)) == guildID)
        #expect(index[ChannelID(rawValue: 99)] == nil)
    }

    @Test("Channels come back in list order")
    func listOrder() {
        var index = ChannelIndex()
        index.replaceChannels(
            [channel(3, position: 2), channel(1, position: 0), channel(2, position: 1)],
            inGuild: guildID
        )
        #expect(index.channelIDs(inGuild: guildID).map(\.rawValue) == [1, 2, 3])
    }

    @Test("Equal positions break on id, so the order is stable across payloads")
    func stableTieBreak() {
        var index = ChannelIndex()
        index.replaceChannels(
            [channel(7, position: 0), channel(3, position: 0), channel(5, position: 0)],
            inGuild: guildID
        )
        #expect(index.channelIDs(inGuild: guildID).map(\.rawValue) == [3, 5, 7])
    }

    /// The reason this type exists.
    @Test("A lastMessage patch does NOT move the structure revision")
    func patchDoesNotMoveStructure() {
        var index = ChannelIndex()
        index.replaceChannels([channel(1)], inGuild: guildID)
        let structureBefore = index.structureRevision
        let valueBefore = index.valueRevision

        index.patchLastMessage(MessageID(rawValue: 555), in: ChannelID(rawValue: 1))

        #expect(index.structureRevision == structureBefore)
        #expect(index.valueRevision != valueBefore)
        #expect(index[ChannelID(rawValue: 1)]?.lastMessageID == MessageID(rawValue: 555))
    }

    @Test("A patch to the same value moves nothing at all")
    func redundantPatchIsFree() {
        var index = ChannelIndex()
        index.replaceChannels([channel(1, lastMessage: 5)], inGuild: guildID)
        let valueBefore = index.valueRevision
        index.patchLastMessage(MessageID(rawValue: 5), in: ChannelID(rawValue: 1))
        #expect(index.valueRevision == valueBefore)
    }

    @Test("Adding a channel IS structural")
    func upsertIsStructural() {
        var index = ChannelIndex()
        index.replaceChannels([channel(1)], inGuild: guildID)
        let before = index.structureRevision
        index.upsert(channel(2))
        #expect(index.structureRevision != before)
        #expect(index.channelIDs(inGuild: guildID).count == 2)
    }

    @Test("Removing a channel clears BOTH indexes")
    func removeClearsBothIndexes() {
        var index = ChannelIndex()
        index.replaceChannels([channel(1), channel(2)], inGuild: guildID)
        index.remove(ChannelID(rawValue: 1))
        #expect(index[ChannelID(rawValue: 1)] == nil)
        #expect(index.guildID(of: ChannelID(rawValue: 1)) == nil)
        #expect(index.channelIDs(inGuild: guildID).map(\.rawValue) == [2])
    }

    /// A channel deleted while the app was away must not linger.
    @Test("Replacing a guild's channels drops the ones that are gone")
    func replaceDropsStaleChannels() {
        var index = ChannelIndex()
        index.replaceChannels([channel(1), channel(2), channel(3)], inGuild: guildID)
        index.replaceChannels([channel(1)], inGuild: guildID)
        #expect(index[ChannelID(rawValue: 2)] == nil)
        #expect(index.guildID(of: ChannelID(rawValue: 3)) == nil)
        #expect(index.count == 1)
    }

    @Test("A channel moved between guilds leaves the first one")
    func moveBetweenGuilds() {
        let other = GuildID(rawValue: 20)
        var index = ChannelIndex()
        index.replaceChannels([channel(1)], inGuild: guildID)

        var moved = channel(1)
        moved.guildID = other
        index.upsert(moved)

        #expect(index.guildID(of: ChannelID(rawValue: 1)) == other)
        #expect(index.channelIDs(inGuild: guildID).isEmpty)
        #expect(index.channelIDs(inGuild: other).map(\.rawValue) == [1])
    }

    @Test("Private channels sort by recency, newest first")
    func privateChannelRecency() {
        var index = ChannelIndex()
        index.replacePrivateChannels([
            Channel(id: ChannelID(rawValue: 1), kind: .directMessage,
                    lastMessageID: MessageID(rawValue: 100)),
            Channel(id: ChannelID(rawValue: 2), kind: .directMessage,
                    lastMessageID: MessageID(rawValue: 300)),
            Channel(id: ChannelID(rawValue: 3), kind: .directMessage,
                    lastMessageID: MessageID(rawValue: 200)),
        ])
        #expect(index.privateChannelIDs().map(\.rawValue) == [2, 3, 1])
    }

    @Test("A DM patched with a newer message moves to the top")
    func privateChannelReorderOnPatch() {
        var index = ChannelIndex()
        index.replacePrivateChannels([
            Channel(id: ChannelID(rawValue: 1), kind: .directMessage,
                    lastMessageID: MessageID(rawValue: 100)),
            Channel(id: ChannelID(rawValue: 2), kind: .directMessage,
                    lastMessageID: MessageID(rawValue: 300)),
        ])
        index.patchLastMessage(MessageID(rawValue: 999), in: ChannelID(rawValue: 1))
        #expect(index.privateChannelIDs().map(\.rawValue) == [1, 2])
    }

    @Test("A never-used DM sorts last but stably")
    func neverUsedPrivateChannelsAreStable() {
        var index = ChannelIndex()
        index.replacePrivateChannels([
            Channel(id: ChannelID(rawValue: 5), kind: .directMessage),
            Channel(id: ChannelID(rawValue: 9), kind: .directMessage),
            Channel(id: ChannelID(rawValue: 1), kind: .directMessage,
                    lastMessageID: MessageID(rawValue: 10)),
        ])
        #expect(index.privateChannelIDs().first?.rawValue == 1)
        #expect(index.privateChannelIDs().count == 3)
    }

    @Test("Patching a channel that is not held does nothing")
    func patchUnknownChannel() {
        var index = ChannelIndex()
        let before = index.valueRevision
        index.patchLastMessage(MessageID(rawValue: 1), in: ChannelID(rawValue: 404))
        #expect(index.valueRevision == before)
    }

    // MARK: Threads
    //
    // A thread's parent is a CHANNEL, not a category, so the partition it lives
    // in is the whole point: every test below fails on an implementation that
    // files threads through `upsert`.

    private func thread(
        _ id: UInt64,
        parent: UInt64,
        lastMessage: UInt64? = nil
    ) -> Channel {
        Channel(
            id: ChannelID(rawValue: id),
            kind: .publicThread,
            guildID: guildID,
            name: "t\(id)",
            parentID: ChannelID(rawValue: parent),
            lastMessageID: lastMessage.map { MessageID(rawValue: $0) }
        )
    }

    @Test("A thread resolves by id but never joins the guild's channel list")
    func threadsStayOutOfTheGuildList() {
        var index = ChannelIndex()
        index.replaceChannels([channel(1), channel(2)], inGuild: guildID)
        index.upsertThread(thread(100, parent: 1))

        // Resolvable — the timeline and the chrome look a thread up this way.
        #expect(index[ChannelID(rawValue: 100)]?.name == "t100")
        #expect(index.guildID(of: ChannelID(rawValue: 100)) == guildID)
        #expect(index.parentID(ofThread: ChannelID(rawValue: 100))?.rawValue == 1)

        // But absent from the list the sidebar and the browse page build from.
        #expect(index.channelIDs(inGuild: guildID).map(\.rawValue) == [1, 2])
        #expect(index.threadIDs(inParent: ChannelID(rawValue: 1)).map(\.rawValue) == [100])
    }

    @Test("Replacing a guild's channels keeps the threads of parents that survive")
    func replaceChannelsKeepsLivingThreads() {
        var index = ChannelIndex()
        index.replaceChannels([channel(1), channel(2)], inGuild: guildID)
        index.upsertThread(thread(100, parent: 1))
        index.upsertThread(thread(200, parent: 2))

        // The same channels arrive again, as they do on every GUILD_CREATE.
        index.replaceChannels([channel(1), channel(2)], inGuild: guildID)

        #expect(index[ChannelID(rawValue: 100)] != nil)
        #expect(index.threadIDs(inParent: ChannelID(rawValue: 1)).count == 1)
        #expect(index.threadIDs(inParent: ChannelID(rawValue: 2)).count == 1)
    }

    @Test("A parent that does not come back takes its threads with it")
    func replaceChannelsDropsOrphanedThreads() {
        var index = ChannelIndex()
        index.replaceChannels([channel(1), channel(2)], inGuild: guildID)
        index.upsertThread(thread(100, parent: 1))
        index.upsertThread(thread(200, parent: 2))

        // Channel 2 was deleted while the app was away.
        index.replaceChannels([channel(1)], inGuild: guildID)

        #expect(index[ChannelID(rawValue: 100)] != nil)
        // Left behind, 200 would be an unreachable row whose parent no longer
        // resolves.
        #expect(index[ChannelID(rawValue: 200)] == nil)
        #expect(index.threadIDs(inParent: ChannelID(rawValue: 2)).isEmpty)
        #expect(index.parentID(ofThread: ChannelID(rawValue: 200)) == nil)
    }

    @Test("Removing a channel cascades to its threads")
    func removingAParentCascades() {
        var index = ChannelIndex()
        index.replaceChannels([channel(1)], inGuild: guildID)
        index.upsertThread(thread(100, parent: 1))

        index.remove(ChannelID(rawValue: 1))

        #expect(index[ChannelID(rawValue: 100)] == nil)
        #expect(index.threadIDs(inParent: ChannelID(rawValue: 1)).isEmpty)
    }

    @Test("Removing a thread leaves its parent alone")
    func removingAThreadIsLocal() {
        var index = ChannelIndex()
        index.replaceChannels([channel(1)], inGuild: guildID)
        index.upsertThread(thread(100, parent: 1))
        index.upsertThread(thread(101, parent: 1))

        index.remove(ChannelID(rawValue: 100))

        #expect(index[ChannelID(rawValue: 1)] != nil)
        #expect(index.threadIDs(inParent: ChannelID(rawValue: 1)).map(\.rawValue) == [101])
        #expect(index.channelIDs(inGuild: guildID).map(\.rawValue) == [1])
    }

    @Test("Threads sort by recent activity, newest first, stably")
    func threadsSortByActivity() {
        var index = ChannelIndex()
        index.replaceChannels([channel(1)], inGuild: guildID)
        index.upsertThread(thread(100, parent: 1, lastMessage: 50))
        index.upsertThread(thread(101, parent: 1, lastMessage: 90))
        index.upsertThread(thread(102, parent: 1, lastMessage: 70))

        #expect(index.threadIDs(inParent: ChannelID(rawValue: 1)).map(\.rawValue) == [101, 102, 100])
    }

    @Test("A message in a thread re-sorts it without moving the structure")
    func threadActivityIsNotStructural() {
        var index = ChannelIndex()
        index.replaceChannels([channel(1)], inGuild: guildID)
        index.upsertThread(thread(100, parent: 1, lastMessage: 50))
        index.upsertThread(thread(101, parent: 1, lastMessage: 90))

        let structure = index.structureRevision
        index.patchLastMessage(MessageID(rawValue: 999), in: ChannelID(rawValue: 100))

        // The order changed — a thread's order genuinely is recency.
        #expect(index.threadIDs(inParent: ChannelID(rawValue: 1)).map(\.rawValue) == [100, 101])
        // The SET did not, so the sidebar's memo must not be cleared. Moving
        // this counter here would clear it on every message in every thread.
        #expect(index.structureRevision == structure)
    }

    @Test("A sync of named parents leaves other parents untouched")
    func listSyncScopedToParents() {
        var index = ChannelIndex()
        index.replaceChannels([channel(1), channel(2)], inGuild: guildID)
        index.upsertThread(thread(100, parent: 1))
        index.upsertThread(thread(200, parent: 2))

        index.replaceThreads(
            [thread(101, parent: 1)],
            inParents: [ChannelID(rawValue: 1)],
            guildID: guildID
        )

        #expect(index.threadIDs(inParent: ChannelID(rawValue: 1)).map(\.rawValue) == [101])
        #expect(index[ChannelID(rawValue: 100)] == nil)
        // Channel 2 was not in the sync, so its thread stands.
        #expect(index.threadIDs(inParent: ChannelID(rawValue: 2)).map(\.rawValue) == [200])
    }

    @Test("A sync with no parents named clears the whole guild")
    func listSyncNilParentsClearsGuild() {
        var index = ChannelIndex()
        index.replaceChannels([channel(1), channel(2)], inGuild: guildID)
        index.upsertThread(thread(100, parent: 1))
        index.upsertThread(thread(200, parent: 2))

        // Nil is "every parent", not "no parents" — reading it the other way
        // leaves every stale thread the event was sent to clear.
        index.replaceThreads([thread(101, parent: 1)], inParents: nil, guildID: guildID)

        #expect(index.threadIDs(inParent: ChannelID(rawValue: 1)).map(\.rawValue) == [101])
        #expect(index.threadIDs(inParent: ChannelID(rawValue: 2)).isEmpty)
        #expect(index[ChannelID(rawValue: 200)] == nil)
    }

    @Test("A thread with no parent is dropped rather than filed under nothing")
    func parentlessThreadIsDropped() {
        var index = ChannelIndex()
        index.replaceChannels([channel(1)], inGuild: guildID)
        let orphan = Channel(
            id: ChannelID(rawValue: 100), kind: .publicThread, guildID: guildID, name: "t100"
        )
        index.upsertThread(orphan)

        #expect(index[ChannelID(rawValue: 100)] == nil)
        #expect(index.channelIDs(inGuild: guildID).map(\.rawValue) == [1])
    }

    @Test("Upserting a thread twice does not duplicate it")
    func threadUpsertIsIdempotent() {
        var index = ChannelIndex()
        index.replaceChannels([channel(1)], inGuild: guildID)
        index.upsertThread(thread(100, parent: 1))
        index.upsertThread(thread(100, parent: 1, lastMessage: 5))

        #expect(index.threadIDs(inParent: ChannelID(rawValue: 1)).map(\.rawValue) == [100])
        #expect(index[ChannelID(rawValue: 100)]?.lastMessageID?.rawValue == 5)
    }
}
