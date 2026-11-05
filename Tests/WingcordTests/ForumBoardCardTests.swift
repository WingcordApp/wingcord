import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore
@testable import WingcordNet

/// What a board's cards say, through `forumPresentation` — the value the view
/// reads: Discord's stand-ins for an opening message (`ep`), its "NEW"
/// (`isNewForumThread`), and its gallery columns (`sk`).
@MainActor
@Suite("Forum board cards")
struct ForumBoardCardTests {

    private let guildID = GuildID(rawValue: 1)
    private let forumID = ChannelID(rawValue: 100)
    private let me = UserID(rawValue: 7)
    private let author = UserID(rawValue: 8)

    /// A snowflake minted at a moment after Discord's epoch.
    private func snowflake(_ seconds: Double) -> UInt64 { UInt64(seconds * 1000) << 22 }

    private func model(joined: Double = 0) -> AppModel {
        let model = AppModel()
        model.currentUserID = me
        model.guilds[guildID] = Guild(
            id: guildID,
            name: "g",
            ownerID: me,
            joinedAt: Date(timeIntervalSince1970: 1_420_070_400 + joined)
        )
        model.channelIndex.replaceChannels(
            [Channel(id: forumID, kind: .forum, guildID: guildID, name: "bug-reports")],
            inGuild: guildID
        )
        model.users[author] = User(id: author, username: "ana")
        return model
    }

    private func post(_ id: UInt64) -> Channel {
        Channel(
            id: ChannelID(rawValue: id),
            kind: .publicThread,
            guildID: guildID,
            name: "post",
            parentID: forumID,
            lastMessageID: MessageID(rawValue: id),
            ownerID: author,
            threadMetadata: ThreadMetadata()
        )
    }

    private func live(_ posts: [Channel], openers: [ChannelID: Message] = [:], in model: AppModel) {
        model.applyActiveThreads(
            ForumPage(
                posts: posts,
                memberships: [],
                firstMessages: openers,
                authors: [:],
                members: [:],
                hasMore: false,
                totalResults: posts.count
            ),
            in: forumID
        )
    }

    private func opener(of post: Channel) -> Message {
        Message(
            id: MessageID(rawValue: post.id.rawValue),
            channelID: post.id,
            authorID: author,
            content: "the app crashes"
        )
    }

    @Test("A blocked author's opening message is not shown, nor named")
    func blockedOpener() {
        let model = model()
        let post = post(snowflake(10))
        live([post], openers: [post.id: opener(of: post)], in: model)
        model.blockedUserIDs = [author]

        let card = model.forumPresentation(for: forumID).posts.first
        #expect(card.map { String($0.preview.characters) } == "Post contains a blocked message")
        #expect(card?.media.isEmpty == true)
    }

    @Test("An ignored author is named before Discord's line")
    func ignoredOpener() {
        let model = model()
        let post = post(snowflake(10))
        live([post], openers: [post.id: opener(of: post)], in: model)
        model.ignoredUserIDs = [author]

        let preview = model.forumPresentation(for: forumID).posts.first.map { String($0.preview.characters) }
        #expect(preview == "ana: Post contains an ignored message")
    }

    @Test("An opening message post-data answered without is a deleted one; one not asked about is loading")
    func deletedOpener() {
        let model = model()
        let post = post(snowflake(10))
        live([post], in: model)
        #expect(model.forumPresentation(for: forumID).posts.first.map { String($0.preview.characters) } == "ana")

        model.applyForumPostDetails([:], requested: [post.id], in: forumID)
        let preview = model.forumPresentation(for: forumID).posts.first.map { String($0.preview.characters) }
        #expect(preview == "ana: Original message was deleted")
    }

    @Test("NEW: past the forum's mark as the board opened, unopened, after joining")
    func newPosts() {
        let model = model(joined: 5)
        let seen = post(snowflake(10))
        let fresh = post(snowflake(30))
        let opened = post(snowflake(40))
        live([seen, fresh, opened], in: model)
        model.readStates[forumID] = ReadState(lastAcknowledgedID: MessageID(rawValue: snowflake(20)))
        model.readStates[opened.id] = ReadState(lastAcknowledgedID: MessageID(rawValue: opened.id.rawValue))
        model.openForum(forumID)

        let new = model.forumPresentation(for: forumID).posts.filter(\.isNew).map(\.id)
        #expect(new == [fresh.id])
    }

    @Test("Discord's gallery: as many columns as the midpoint of 320 and 450 allows")
    func galleryColumns() {
        #expect(ForumGallery.columns(forWidth: 300) == 1)
        #expect(ForumGallery.columns(forWidth: 700) == 1)
        #expect(ForumGallery.columns(forWidth: 1000) == 2)
        #expect(ForumGallery.columns(forWidth: 1400) == 3)
    }
}
