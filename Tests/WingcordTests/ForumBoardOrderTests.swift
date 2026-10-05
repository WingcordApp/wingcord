import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore
@testable import WingcordNet

/// What a forum board is made of.
///
/// **A board is two halves**, and only one of them comes from the route that
/// builds it: `threads/search?archived=true` selects the archived, and the live
/// posts are fetched separately and merged in front. The merge lived in a
/// function that was written, committed twice, and never actually called — the
/// board shipped showing nothing but posts a fortnight old while the code that
/// would have fixed it sat one line away, unreferenced. These tests exist so
/// that cannot happen quietly again: they go through `forumPresentation`, which
/// is what the view reads, rather than through the helper directly.
@MainActor
@Suite("Forum board order")
struct ForumBoardOrderTests {

    private let guildID = GuildID(rawValue: 1)
    private let forumID = ChannelID(rawValue: 100)

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = UserID(rawValue: 7)
        model.guilds[guildID] = Guild(id: guildID, name: "g", ownerID: UserID(rawValue: 7))
        model.channelIndex.replaceChannels(
            [Channel(id: forumID, kind: .forum, guildID: guildID, name: "bug-reports")],
            inGuild: guildID
        )
        return model
    }

    private func post(
        _ id: UInt64,
        archived: Bool?,
        lastMessage: UInt64
    ) -> Channel {
        Channel(
            id: ChannelID(rawValue: id),
            kind: .publicThread,
            guildID: guildID,
            name: "post\(id)",
            parentID: forumID,
            lastMessageID: MessageID(rawValue: lastMessage),
            threadMetadata: archived.map { ThreadMetadata(isArchived: $0) }
        )
    }

    /// The failure that shipped: a board with live posts in the index showing
    /// only the archived page.
    @Test("Live posts come before the archived page, which is its own section")
    func liveBeforeArchived() {
        let model = model()
        // The archived half, as `threads/search?archived=true` delivers it.
        model.applyForumPage(
            ForumPage(
                posts: [post(10, archived: true, lastMessage: 10)],
                memberships: [],
                firstMessages: [:],
                authors: [:],
                members: [:],
                hasMore: false,
                totalResults: 1
            ),
            in: forumID,
            replacing: true
        )
        // The live half, from its own request.
        model.applyActiveThreads(
            ForumPage(
                posts: [post(20, archived: false, lastMessage: 20)],
                memberships: [],
                firstMessages: [:],
                authors: [:],
                members: [:],
                hasMore: false,
                totalResults: 1
            ),
            in: forumID
        )

        // Discord's two sections: the live post, then the archived page
        // under "Older Posts".
        let board = model.forumPresentation(for: forumID)
        #expect(board.posts.map(\.id.rawValue) == [20])
        #expect(board.olderPosts.map(\.id.rawValue) == [10])
    }

    @Test("A thread with no metadata is live, not archived")
    func missingMetadataIsLive() {
        let model = model()
        // Read as archived, such a post vanishes from the board entirely — so
        // the absence of a statement must not be read as one.
        model.applyActiveThreads(
            ForumPage(
                posts: [post(30, archived: nil, lastMessage: 30)],
                memberships: [],
                firstMessages: [:],
                authors: [:],
                members: [:],
                hasMore: false,
                totalResults: 1
            ),
            in: forumID
        )
        #expect(model.forumPresentation(for: forumID).posts.map(\.id.rawValue) == [30])
    }

    @Test("A post in both halves is kept once, in its live position")
    func noDuplicateAcrossHalves() {
        let model = model()
        model.applyForumPage(
            ForumPage(
                posts: [post(10, archived: true, lastMessage: 10), post(20, archived: false, lastMessage: 20)],
                memberships: [],
                firstMessages: [:],
                authors: [:],
                members: [:],
                hasMore: false,
                totalResults: 2
            ),
            in: forumID,
            replacing: true
        )
        model.applyActiveThreads(
            ForumPage(
                posts: [post(20, archived: false, lastMessage: 20)],
                memberships: [],
                firstMessages: [:],
                authors: [:],
                members: [:],
                hasMore: false,
                totalResults: 1
            ),
            in: forumID
        )

        // Discord's two sections: the live post, then the archived page
        // under "Older Posts".
        let board = model.forumPresentation(for: forumID)
        #expect(board.posts.map(\.id.rawValue) == [20])
        #expect(board.olderPosts.map(\.id.rawValue) == [10])
    }

    @Test("Live posts are newest first")
    func liveOrderedByActivity() {
        let model = model()
        model.applyActiveThreads(
            ForumPage(
                posts: [
                    post(40, archived: false, lastMessage: 40),
                    post(41, archived: false, lastMessage: 90),
                    post(42, archived: false, lastMessage: 70),
                ],
                memberships: [],
                firstMessages: [:],
                authors: [:],
                members: [:],
                hasMore: false,
                totalResults: 3
            ),
            in: forumID
        )
        #expect(model.forumPresentation(for: forumID).posts.map(\.id.rawValue) == [41, 42, 40])
    }

    /// **The board is not the sidebar.** Loading a forum puts every one of its
    /// posts into the index; nesting them all under the channel is what the
    /// membership table exists to prevent.
    @Test("Loading a board follows nothing")
    func boardDoesNotImplyMembership() {
        let model = model()
        model.applyActiveThreads(
            ForumPage(
                posts: [post(50, archived: false, lastMessage: 50)],
                memberships: [],
                firstMessages: [:],
                authors: [:],
                members: [:],
                hasMore: false,
                totalResults: 1
            ),
            in: forumID
        )
        #expect(!model.forumPresentation(for: forumID).posts.isEmpty)
        #expect(model.sidebarThreadIDs(inParent: forumID).isEmpty)
    }
}
