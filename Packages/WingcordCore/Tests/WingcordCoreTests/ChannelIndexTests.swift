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
}
