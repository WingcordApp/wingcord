import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// More Active Posts (BETA2.md phase 7): what the flyout beside a forum or a
/// channel lists.
@MainActor
@Suite("More Active Posts")
struct ActivePostsFlyoutTests {

    private let guildID = GuildID(rawValue: 1)
    private let forumID = ChannelID(rawValue: 100)
    private let me = UserID(rawValue: 7)

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = me
        model.guilds[guildID] = Guild(id: guildID, name: "g", ownerID: me)
        model.channelIndex.replaceChannels(
            [Channel(id: forumID, kind: .forum, guildID: guildID, name: "bug-reports")],
            inGuild: guildID
        )
        return model
    }

    /// A post whose newest message was sent `millis` after Discord's epoch.
    private func post(_ id: UInt64, lastAt millis: UInt64, archived: Bool = false) -> Channel {
        Channel(
            id: ChannelID(rawValue: id),
            kind: .publicThread,
            guildID: guildID,
            name: "post\(id)",
            parentID: forumID,
            lastMessageID: MessageID(rawValue: millis << 22),
            threadMetadata: ThreadMetadata(isArchived: archived)
        )
    }

    @Test("Newest message first, followed and archived posts left out, five at most")
    func listsUnlistedActivePosts() {
        let model = model()
        let times: [(UInt64, UInt64)] = [
            (10, 1_000), (11, 5_000), (12, 3_000), (13, 9_000), (14, 2_000), (15, 7_000), (16, 8_000),
        ]
        for (id, millis) in times {
            model.channelIndex.upsertThread(post(id, lastAt: millis))
        }
        model.channelIndex.upsertThread(post(17, lastAt: 9_500, archived: true))
        // Followed: the channel list draws it under the forum already.
        let followed = ChannelID(rawValue: 13)
        model.threadMemberships[followed] = ThreadMember(id: followed, userID: me)

        let ids = model.activePosts(in: forumID, limit: 5).map(\.id.rawValue)
        #expect(ids == [16, 15, 11, 12, 14])
    }

    @Test("A channel offers the flyout only for threads the list does not show")
    func offersOnlyUnlistedThreads() {
        let model = model()
        let text = ChannelID(rawValue: 200)
        model.channelIndex.upsert(Channel(id: text, kind: .text, guildID: guildID, name: "general"))
        #expect(!model.hasUnlistedActiveThreads(in: text))

        var thread = post(20, lastAt: 1_000)
        thread.parentID = text
        model.channelIndex.upsertThread(thread)
        #expect(model.hasUnlistedActiveThreads(in: text))

        model.threadMemberships[thread.id] = ThreadMember(id: thread.id, userID: me)
        #expect(!model.hasUnlistedActiveThreads(in: text))
    }
}
