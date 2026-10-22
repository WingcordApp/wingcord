import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// One moment from everybody in the call (docs/CLIPS-PRESENCE.md, Phase
/// 7.3): when the reader's clip is announced, and where.
@MainActor
@Suite("Distributed clips")
struct DistributedClipsTests {

    @Test("Distributed clips follow the account's own assignment, variant 1")
    func assignment() {
        let model = AppModel()
        #expect(!model.distributedClipsEnabled)
        let hash = MurmurHash3.hash32("2026-05-distributed-clips")
        model.experiments = ExperimentSnapshot(apex: [ApexAssignment(hash: hash, variantID: 0, isOverride: false, revision: 1)])
        #expect(!model.distributedClipsEnabled, "the control variant is off")
        model.experiments = ExperimentSnapshot(apex: [ApexAssignment(hash: hash, variantID: 1, isOverride: false, revision: 1)])
        #expect(model.distributedClipsEnabled)
    }

    @Test("A moment is announced in a server that sees the reader's activity, or among friends")
    func whereAnnounced() {
        let model = AppModel()
        model.currentUserID = UserID(rawValue: 1)
        let guild = GuildID(rawValue: 50)
        let voice = ChannelID(rawValue: 500)
        let dm = ChannelID(rawValue: 501)
        let group = ChannelID(rawValue: 502)
        let friend = UserID(rawValue: 2)
        let stranger = UserID(rawValue: 3)
        model.channelIndex.replaceChannels([Channel(id: voice, kind: .voice, guildID: guild, name: "games")], inGuild: guild)
        model.channelIndex.replacePrivateChannels([
            Channel(id: dm, kind: .directMessage, recipientIDs: [friend]),
            Channel(id: group, kind: .groupDirectMessage, recipientIDs: [friend, stranger]),
        ])
        model.relationships[friend] = .friend

        #expect(model.mayAnnounceClips(in: voice))
        #expect(model.mayAnnounceClips(in: dm))
        #expect(!model.mayAnnounceClips(in: group), "not everybody there is a friend")

        model.activityPrivacy.activityRestrictedGuildIDs = [guild]
        #expect(!model.mayAnnounceClips(in: voice), "the reader hides their activity there")
    }
}
