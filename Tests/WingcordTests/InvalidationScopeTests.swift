import Foundation
import Observation
import Synchronization
import Testing
@testable import Wingcord
@testable import WingcordCore

/// What does NOT move when something unrelated happens.
///
/// On a real account these were a third of the main thread: every member batch
/// wiped the permission cache, and every message and presence rebuilt lists that
/// could not have changed. docs/PERFORMANCE.md.
@MainActor
@Suite("Invalidation scope")
struct InvalidationScopeTests {
    private let reader = UserID(rawValue: 1)
    private let stranger = UserID(rawValue: 2)
    private let partner = UserID(rawValue: 3)
    private let guildA = GuildID(rawValue: 100)
    private let guildB = GuildID(rawValue: 200)
    private let channelA = ChannelID(rawValue: 101)
    private let channelB = ChannelID(rawValue: 201)
    private let conversation = ChannelID(rawValue: 301)

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = reader
        model.users[reader] = User(id: reader, username: "reader")
        model.guilds[guildA] = Guild(id: guildA, name: "A", ownerID: reader)
        model.guilds[guildB] = Guild(id: guildB, name: "B", ownerID: reader)
        var index = ChannelIndex()
        index.replaceChannels([Channel(id: channelA, kind: .text, guildID: guildA, name: "a")], inGuild: guildA)
        index.replaceChannels([Channel(id: channelB, kind: .text, guildID: guildB, name: "b")], inGuild: guildB)
        index.replacePrivateChannels([
            Channel(id: conversation, kind: .directMessage, recipientIDs: [reader, partner]),
        ])
        model.channelIndex = index
        model.members[guildA] = [reader: Member(userID: reader, roleIDs: [])]
        return model
    }

    private func walk(_ model: AppModel) {
        _ = GuildBadgeWalk(model: model).badge(for: guildA)
    }

    @Test("Somebody else's member record leaves the permission cache alone")
    func strangerKeepsTheCache() {
        let model = model()
        walk(model)
        let resolutions = model.permissionGate.resolutions
        let roleRevision = model.roleRevision

        model.sessionController.ingestMembers(
            [stranger: Member(userID: stranger, roleIDs: [])],
            users: [stranger: User(id: stranger, username: "stranger")],
            presences: [:],
            inGuild: guildA
        )
        walk(model)

        #expect(model.permissionGate.resolutions == resolutions)
        #expect(model.roleRevision == roleRevision)
        #expect(model.members[guildA]?[stranger] != nil)
    }

    @Test("The reader's own record does throw it away")
    func readerInvalidatesTheCache() {
        let model = model()
        walk(model)
        let resolutions = model.permissionGate.resolutions
        let roleRevision = model.roleRevision

        model.sessionController.ingestMembers(
            [reader: Member(userID: reader, roleIDs: [RoleID(rawValue: 7)])],
            users: [:], presences: [:], inGuild: guildA
        )
        walk(model)

        #expect(model.permissionGate.resolutions > resolutions)
        #expect(model.roleRevision != roleRevision)
    }

    @Test("A record that says what was already known moves nothing")
    func unchangedRecordMovesNothing() {
        let model = model()
        let member = Member(userID: stranger, roleIDs: [])
        model.sessionController.ingestMembers([stranger: member], users: [:], presences: [:], inGuild: guildA)
        let memberRevision = model.memberRevision

        model.sessionController.ingestMembers([stranger: member], users: [:], presences: [:], inGuild: guildA)

        #expect(model.memberRevision == memberRevision)
    }

    @Test("A stranger's presence leaves the conversations alone, a partner's moves them")
    func presenceScope() {
        let model = model()
        let before = model.directMessagePresenceRevision

        model.notePresencesChanged(for: [stranger])
        #expect(model.directMessagePresenceRevision == before)

        model.notePresencesChanged(for: [partner])
        #expect(model.directMessagePresenceRevision != before)
    }

    @Test("A read mark moves its own list only")
    func readMarkScope() {
        let model = model()
        let (a, b, home) = (
            model.readRevision(ofList: guildA),
            model.readRevision(ofList: guildB),
            model.readRevision(ofList: nil)
        )

        model.noteReadStateChanged(in: channelB)
        #expect(model.readRevision(ofList: guildA) == a)
        #expect(model.readRevision(ofList: guildB) != b)
        #expect(model.readRevision(ofList: nil) == home)

        model.noteReadStateChanged(in: conversation)
        #expect(model.readRevision(ofList: nil) != home)
    }

    @Test("A message in one server leaves another server's channel list in its memo")
    func sidebarKeepsItsMemo() {
        let model = model()
        _ = model.sidebarPresentation(for: guildA)
        let key = model.sidebarCache?.key

        model.channelIndex.patchLastMessage(MessageID(rawValue: 9), in: channelB)
        model.noteReadStateChanged(in: channelB)
        _ = model.sidebarPresentation(for: guildA)

        #expect(model.sidebarCache?.key == key)
    }

    @Test("A message in the channel on screen does rebuild its list")
    func sidebarFollowsItsOwnChannels() {
        let model = model()
        _ = model.sidebarPresentation(for: guildA)
        let key = model.sidebarCache?.key

        model.channelIndex.patchLastMessage(MessageID(rawValue: 9), in: channelA)
        _ = model.sidebarPresentation(for: guildA)

        #expect(model.sidebarCache?.key != key)
    }

    @Test("Reading one channel's box is not told about another channel's")
    func boxObservationIsPerChannel() {
        let model = model()
        let fired = Mutex(false)
        withObservationTracking {
            _ = model.messageBoxes[channelA]
        } onChange: {
            fired.withLock { $0 = true }
        }

        model.mutateBox(channelB) { $0.draft = "elsewhere" }
        let afterElsewhere = fired.withLock { $0 }
        #expect(afterElsewhere == false)

        model.mutateBox(channelA) { $0.draft = "here" }
        let afterHere = fired.withLock { $0 }
        #expect(afterHere)
    }

    @Test("A message anywhere leaves the other transcripts' rows in their memo")
    func timelineKeepsItsMemo() {
        let model = model()
        model.selectedChannelID = channelA
        _ = model.timelineRows(for: channelA)
        let key = model.timelineCache?.key

        model.noteMessageChanged(in: channelB)
        _ = model.timelineRows(for: channelA)
        #expect(model.timelineCache?.key == key)

        model.noteMessageChanged(in: channelA)
        _ = model.timelineRows(for: channelA)
        #expect(model.timelineCache?.key != key)
    }

    @Test("Opening more servers than the limit lets go of the oldest one's people, not the reader's record")
    func oldestServerForgetsItsPeople() {
        let model = model()
        var guilds: [GuildID] = [guildA]
        for number in 1...AppModel.residentGuildLimit { guilds.append(GuildID(rawValue: 1000 + UInt64(number))) }
        for guildID in guilds {
            model.members[guildID] = [
                reader: Member(userID: reader, roleIDs: [RoleID(rawValue: 7)]),
                stranger: Member(userID: stranger, roleIDs: []),
            ]
            model.selectedGuildID = guildID
        }

        #expect(model.members[guildA]?[stranger] == nil)
        #expect(model.members[guildA]?[reader]?.roleIDs == [RoleID(rawValue: 7)])
        #expect(model.members[guilds.last!]?[stranger] != nil)
    }

    @Test("A server with a call in it stays resident however long ago it was opened")
    func callKeepsItsServer() {
        let model = model()
        model.connectedVoiceChannelID = channelA
        model.members[guildA] = [
            reader: Member(userID: reader, roleIDs: []),
            stranger: Member(userID: stranger, roleIDs: []),
        ]
        model.selectedGuildID = guildA
        for number in 1...(AppModel.residentGuildLimit + 1) {
            model.selectedGuildID = GuildID(rawValue: 1000 + UInt64(number))
        }

        #expect(model.members[guildA]?[stranger] != nil)
    }

    @Test("The badge counts what the reader can see and has not muted")
    func badgeRules() {
        let model = model()
        let hidden = ChannelID(rawValue: 102)
        let muted = ChannelID(rawValue: 103)
        var index = model.channelIndex
        index.replaceChannels([
            Channel(id: channelA, kind: .text, guildID: guildA, name: "a", lastMessageID: MessageID(rawValue: 50)),
            Channel(id: hidden, kind: .text, guildID: guildA, name: "hidden", lastMessageID: MessageID(rawValue: 51)),
            Channel(id: muted, kind: .text, guildID: guildA, name: "muted", lastMessageID: MessageID(rawValue: 52)),
        ], inGuild: guildA)
        model.channelIndex = index
        model.readStates[channelA] = ReadState(lastAcknowledgedID: MessageID(rawValue: 10), mentionCount: 2)
        model.readStates[muted] = ReadState(lastAcknowledgedID: MessageID(rawValue: 10), mentionCount: 9, isMuted: true)
        // The owner sees everything, so the walk and the direct path can be
        // compared on one account.
        let badge = GuildBadgeWalk(model: model).badge(for: guildA)

        #expect(badge.unread)
        #expect(badge.mentions == 2 + (model.readStates[hidden]?.mentionCount ?? 0))
        #expect(model.guildBadge(for: guildA).mentions == badge.mentions)
    }
}
