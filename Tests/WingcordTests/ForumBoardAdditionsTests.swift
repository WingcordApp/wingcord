import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore
@testable import WingcordNet

/// What docs/FORUMS-INVITES.md D9 and D10 added to a board, through
/// `forumPresentation`, the value the view reads.
@MainActor
@Suite("Forum board additions")
struct ForumBoardAdditionsTests {

    private let guildID = GuildID(rawValue: 1)
    private let forumID = ChannelID(rawValue: 100)
    private let me = UserID(rawValue: 7)
    private let author = UserID(rawValue: 8)

    private func snowflake(_ seconds: Double) -> UInt64 { UInt64(seconds * 1000) << 22 }

    private func model(kind: ChannelKind = .forum, configure: (inout Channel) -> Void = { _ in }) -> AppModel {
        let model = AppModel()
        model.currentUserID = me
        model.guilds[guildID] = Guild(id: guildID, name: "g", ownerID: me)
        var forum = Channel(id: forumID, kind: kind, guildID: guildID, name: "bug-reports")
        configure(&forum)
        model.channelIndex.replaceChannels([forum], inGuild: guildID)
        model.users[author] = User(id: author, username: "ana")
        return model
    }

    private func post(
        _ id: UInt64,
        lastMessage: UInt64? = nil,
        owner: UserID? = nil,
        name: String = "post",
        messages: Int = 5,
        archived: Bool = false,
        locked: Bool = false,
        tags: [ForumTagID] = []
    ) -> Channel {
        Channel(
            id: ChannelID(rawValue: id),
            kind: .publicThread,
            guildID: guildID,
            name: name,
            parentID: forumID,
            lastMessageID: MessageID(rawValue: lastMessage ?? id),
            ownerID: owner ?? author,
            messageCount: messages,
            threadMetadata: ThreadMetadata(isArchived: archived, isLocked: locked),
            appliedTags: tags
        )
    }

    private func opener(of post: Channel, reactions: [Reaction] = [], attachments: [WingcordCore.Attachment] = []) -> Message {
        Message(
            id: MessageID(rawValue: post.id.rawValue),
            channelID: post.id,
            authorID: post.ownerID ?? author,
            content: "the app crashes",
            payload: MessagePayload(attachments: attachments, reactions: reactions)
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

    private func card(_ post: Channel, in model: AppModel) -> ForumPostPresentation? {
        model.forumPresentation(for: forumID).posts.first { $0.id == post.id }
    }

    private func picture(_ id: UInt64) -> WingcordCore.Attachment {
        WingcordCore.Attachment(
            id: AttachmentID(rawValue: id),
            filename: "a.png",
            url: "https://cdn.discordapp.com/attachments/1/2/a.png",
            proxyURL: "https://media.discordapp.net/attachments/1/2/a.png",
            contentType: "image/png",
            width: 800,
            height: 600
        )
    }

    // MARK: Held order

    @Test("An answered post stays put until the board is refreshed")
    func holdsOrder() {
        let model = model()
        let older = post(snowflake(10))
        let newer = post(snowflake(20))
        live([older, newer], in: model)
        #expect(model.forumPresentation(for: forumID).posts.map(\.id) == [newer.id, older.id])

        model.channelIndex.patchLastMessage(MessageID(rawValue: snowflake(30)), in: older.id)
        #expect(model.forumPresentation(for: forumID).posts.map(\.id) == [newer.id, older.id])

        model.refreshForumOrder(forumID)
        #expect(model.forumPresentation(for: forumID).posts.map(\.id) == [older.id, newer.id])
    }

    @Test("Somebody else's new post waits behind the pill, and the pill brings it in")
    func newPostWaits() {
        let model = model()
        let existing = post(snowflake(10))
        live([existing], in: model)
        let arrived = post(snowflake(20))
        model.applyThreadUpsert(arrived, membership: nil, isNewlyCreated: true)

        var board = model.forumPresentation(for: forumID)
        #expect(board.posts.map(\.id) == [existing.id])
        #expect(board.newPostCount == 1)

        model.refreshForumOrder(forumID)
        board = model.forumPresentation(for: forumID)
        #expect(board.posts.map(\.id) == [arrived.id, existing.id])
        #expect(board.newPostCount == 0)
    }

    @Test("The reader's own new post doesn't wait, and a re-announced one isn't new")
    func notWaiting() {
        let model = model()
        let existing = post(snowflake(10))
        live([existing], in: model)
        let mine = post(snowflake(20), owner: me)
        model.applyThreadUpsert(mine, membership: nil, isNewlyCreated: true)
        // Gained access to one: `newly_created` is absent.
        let reannounced = post(snowflake(30))
        model.applyThreadUpsert(reannounced, membership: nil)

        let board = model.forumPresentation(for: forumID)
        #expect(board.newPostCount == 0)
        #expect(Set(board.posts.map(\.id)) == [existing.id, mine.id, reannounced.id])
    }

    @Test("A post the filter hides isn't news to this board")
    func filteredArrival() {
        let tag = ForumTagID(rawValue: 5)
        let model = model { $0.availableTags = [ForumTag(id: tag, name: "UI")] }
        live([post(snowflake(10), tags: [tag])], in: model)
        var query = model.forumBoard(for: forumID).query
        query.tags = [tag]
        model.setForumQuery(query, in: forumID)

        model.applyThreadUpsert(post(snowflake(20)), membership: nil, isNewlyCreated: true)
        #expect(model.forumPresentation(for: forumID).newPostCount == 0)
        model.applyThreadUpsert(post(snowflake(30), tags: [tag]), membership: nil, isNewlyCreated: true)
        #expect(model.forumPresentation(for: forumID).newPostCount == 1)
    }

    @Test("Changing the sort puts the board in its new order")
    func queryRefreshes() {
        let model = model()
        let older = post(snowflake(10), lastMessage: snowflake(40))
        let newer = post(snowflake(20))
        live([older, newer], in: model)
        #expect(model.forumPresentation(for: forumID).posts.map(\.id) == [older.id, newer.id])

        var query = model.forumBoard(for: forumID).query
        query.sortOrder = .creationDate
        model.setForumQuery(query, in: forumID)
        #expect(model.forumPresentation(for: forumID).posts.map(\.id) == [newer.id, older.id])
    }

    // MARK: Unread

    @Test("Opened and answered since: unread, and \"1+\" until somebody says how many")
    func unreadWords() {
        let model = model()
        let answered = post(snowflake(10), lastMessage: snowflake(30))
        let read = post(snowflake(11), lastMessage: snowflake(12))
        live([answered, read], in: model)
        model.readStates[answered.id] = ReadState(lastAcknowledgedID: MessageID(rawValue: snowflake(20)))
        model.readStates[read.id] = ReadState(lastAcknowledgedID: MessageID(rawValue: snowflake(12)))

        let unread = card(answered, in: model)
        #expect(unread?.isUnread == true)
        #expect(unread?.unreadWords == "1+")
        let settled = card(read, in: model)
        #expect(settled?.isUnread == false)
        #expect(settled?.unreadWords == nil)
    }

    @Test("The count comes from the gateway, counts up, and stops at reading")
    func unreadCount() {
        let model = model()
        let post = post(snowflake(10), lastMessage: snowflake(30), messages: 40)
        live([post], in: model)
        model.readStates[post.id] = ReadState(lastAcknowledgedID: MessageID(rawValue: snowflake(20)))

        model.applyForumUnreads([post.id: 3])
        #expect(card(post, in: model)?.unreadWords == "3")

        let reply = Message(
            id: MessageID(rawValue: snowflake(31)), channelID: post.id, authorID: author, content: "same here"
        )
        model.countForumPostMessage(reply)
        #expect(card(post, in: model)?.unreadWords == "4")
        // The reader's own isn't news.
        let own = Message(id: MessageID(rawValue: snowflake(32)), channelID: post.id, authorID: me, content: "ok")
        model.countForumPostMessage(own)
        #expect(card(post, in: model)?.unreadWords == "4")

        model.readStates[post.id] = ReadState(lastAcknowledgedID: MessageID(rawValue: snowflake(30)))
        model.noteForumPostRead(post.id)
        #expect(card(post, in: model)?.unreadWords == nil)
        #expect(model.forumPostUnreadCounts[post.id] == 0, "counting from here")
    }

    @Test("A message on a post nobody has counted doesn't start a count")
    func uncountedPost() {
        let model = model()
        let post = post(snowflake(10))
        live([post], in: model)
        model.countForumPostMessage(Message(
            id: MessageID(rawValue: snowflake(11)), channelID: post.id, authorID: author, content: "hi"
        ))
        #expect(model.forumPostUnreadCounts[post.id] == nil)
    }

    @Test("A post made while the board is open starts its own count at nothing")
    func newPostCount() {
        let model = model()
        live([post(snowflake(10))], in: model)
        let arrived = post(snowflake(20))
        model.applyThreadUpsert(arrived, membership: nil, isNewlyCreated: true)
        #expect(model.forumPostUnreadCounts[arrived.id] == 0)
    }

    @Test("An archived post has nothing to catch up on")
    func archivedIsRead() {
        let model = model()
        let closed = post(snowflake(10), lastMessage: snowflake(30), archived: true)
        model.applyForumPage(
            ForumPage(
                posts: [closed], memberships: [], firstMessages: [:], authors: [:], members: [:],
                hasMore: false, totalResults: 1
            ),
            in: forumID,
            replacing: true
        )
        model.readStates[closed.id] = ReadState(lastAcknowledgedID: MessageID(rawValue: snowflake(20)))
        let row = model.forumPresentation(for: forumID).olderPosts.first
        #expect(row?.isUnread == false)
        #expect(row?.unreadWords == nil)
    }

    // MARK: Reactions

    @Test("The forum's default is offered where nobody has reacted, with no number")
    func defaultReaction() {
        let model = model { $0.defaultReaction = EmojiRef(name: "👍") }
        let post = post(snowflake(10))
        live([post], openers: [post.id: opener(of: post)], in: model)
        let reaction = card(post, in: model)?.reaction
        #expect(reaction?.emoji.name == "👍")
        #expect(reaction?.count == nil)
        #expect(reaction?.isMine == false)
        #expect(reaction?.isReadOnly == false)
    }

    @Test("A custom default needs a name from the server's list, or it isn't offered")
    func customDefaultReaction() {
        let id = EmojiID(rawValue: 55)
        let model = model { $0.defaultReaction = EmojiRef(id: id, name: "") }
        let post = post(snowflake(10))
        live([post], openers: [post.id: opener(of: post)], in: model)
        #expect(card(post, in: model)?.reaction == nil)

        model.guildEmojis[guildID] = [EmojiRef(id: id, name: "party")]
        model.threadRevision &+= 1
        #expect(card(post, in: model)?.reaction?.emoji.name == "party")
    }

    @Test("Where somebody has, the top one, everybody counted")
    func topReaction() {
        let model = model { $0.defaultReaction = EmojiRef(name: "👍") }
        let post = post(snowflake(10))
        let opener = opener(of: post, reactions: [
            Reaction(emoji: EmojiRef(name: "😢"), count: 2, isMine: false),
            Reaction(emoji: EmojiRef(name: "🔥"), count: 3, isMine: true, burstCount: 2, burstColors: [0xFF0000]),
        ])
        live([post], openers: [post.id: opener], in: model)
        let reaction = card(post, in: model)?.reaction
        #expect(reaction?.emoji.name == "🔥")
        #expect(reaction?.count == 5)
        #expect(reaction?.isMine == true)
        #expect(reaction?.kind == .normal, "what the reader's click would take off")
        #expect(reaction?.palette != nil)
    }

    @Test("A locked archive's chip can be read and not pressed")
    func lockedChip() {
        let model = model { $0.defaultReaction = EmojiRef(name: "👍") }
        let post = post(snowflake(10), archived: true, locked: true)
        model.applyForumPage(
            ForumPage(
                posts: [post], memberships: [], firstMessages: [post.id: opener(of: post)],
                authors: [:], members: [:], hasMore: false, totalResults: 1
            ),
            in: forumID,
            replacing: true
        )
        #expect(model.forumPresentation(for: forumID).olderPosts.first?.reaction?.isReadOnly == true)
    }

    @Test("A reaction arriving reaches a post nobody has opened")
    func reactionOnBoard() {
        let model = model()
        let post = post(snowflake(10))
        live([post], openers: [post.id: opener(of: post)], in: model)
        let openerID = MessageID(rawValue: post.id.rawValue)
        #expect(model.messages(in: post.id)?.messages.isEmpty != false, "no transcript")

        model.applyReaction(EmojiRef(name: "🔥"), kind: .normal, to: openerID, in: post.id, added: true, isMine: false)
        #expect(card(post, in: model)?.reaction?.count == 1)
        model.applyReaction(EmojiRef(name: "🔥"), kind: .normal, to: openerID, in: post.id, added: true, isMine: false)
        #expect(card(post, in: model)?.reaction?.count == 2)
        model.clearReactions(nil, on: openerID, in: post.id)
        #expect(card(post, in: model)?.reaction == nil)
    }

    @Test("Only the opening message is on the board")
    func replyReactionIgnored() {
        let model = model()
        let post = post(snowflake(10))
        live([post], openers: [post.id: opener(of: post)], in: model)
        model.applyReaction(
            EmojiRef(name: "🔥"), kind: .normal, to: MessageID(rawValue: snowflake(11)), in: post.id,
            added: true, isMine: false
        )
        #expect(card(post, in: model)?.reaction == nil)
    }

    @Test("A post's opening message can be looked up from its board, and a reply can't")
    func openerLookup() {
        let model = model()
        let post = post(snowflake(10))
        live([post], openers: [post.id: opener(of: post)], in: model)
        #expect(model.message(MessageID(rawValue: post.id.rawValue), in: post.id)?.content == "the app crashes")
        #expect(model.message(MessageID(rawValue: snowflake(11)), in: post.id) == nil)
    }

    // MARK: Pictures and words

    @Test("Pictures come off the opening message, sized for the view it's in")
    func mediaFollowsLayout() throws {
        let model = model()
        let post = post(snowflake(10))
        live([post], openers: [post.id: opener(of: post, attachments: [picture(1)])], in: model)
        let list = try #require(card(post, in: model)?.media.first)
        #expect(list.url.query?.contains("width=144") == true, "the row's 72, twice")

        var query = model.forumBoard(for: forumID).query
        query.layout = .gallery
        model.setForumQuery(query, in: forumID)
        let gallery = try #require(card(post, in: model)?.media.first)
        #expect(gallery.url.query?.contains("width=900") == true, "the gallery's widest, twice")
    }

    @Test("An edit reaches the board, and arrives partial")
    func openerEdit() {
        let model = model()
        let post = post(snowflake(10))
        live([post], openers: [post.id: opener(of: post, attachments: [picture(1)])], in: model)
        let edit = Message(
            id: MessageID(rawValue: post.id.rawValue), channelID: post.id, authorID: author, content: "edited"
        )
        model.applyOpenerUpdated(edit)
        #expect(card(post, in: model)?.openingWords == "edited")
        #expect(card(post, in: model)?.media.count == 1, "the picture it didn't mention stays")
    }

    @Test("A gallery's words are the message's alone, with no markup")
    func openingWords() {
        let model = model()
        let post = post(snowflake(10))
        var message = opener(of: post)
        message.content = "**bold** words\nand more"
        live([post], openers: [post.id: message], in: model)
        #expect(card(post, in: model)?.openingWords == "bold words and more")
    }

    @Test("A post that's only a card previews the card's words, where Discord's row says to click")
    func cardWords() {
        let model = model()
        let embedded = post(snowflake(10))
        let carded = post(snowflake(20))
        let titled = post(snowflake(30))
        func message(in post: Channel, _ payload: MessagePayload) -> Message {
            Message(id: MessageID(rawValue: post.id.rawValue), channelID: post.id, authorID: author, content: "", payload: payload)
        }
        live([embedded, carded, titled], openers: [
            // The reports bot's post: an embed and a link button.
            embedded.id: message(in: embedded, MessagePayload(embeds: [
                Embed(title: "🐛 Bug", description: "The call went **quiet**\n\n**Steps to reproduce**\nJoin a call"),
            ])),
            carded.id: message(in: carded, MessagePayload(displayComponents: [
                .container(accent: 0xFF7B1C, children: [
                    .text("### Calls go quiet"),
                    .row(ActionRow(components: [MessageComponent(id: "open", label: "Open", kind: .action(customID: "open"))])),
                ]),
            ])),
            titled.id: message(in: titled, MessagePayload(embeds: [Embed(title: "Only a title")])),
        ], in: model)
        #expect(card(embedded, in: model)?.openingWords == "The call went quiet Steps to reproduce Join a call")
        #expect(card(carded, in: model)?.openingWords == "Calls go quiet", "the text, never the buttons' labels")
        #expect(card(titled, in: model)?.openingWords == "Only a title")
    }

    @Test("A search lights its words in the title")
    func searchHighlight() {
        let model = model()
        let post = post(snowflake(10), name: "Crash on launch")
        live([post], in: model)
        #expect(card(post, in: model)?.titleText.runs.count == 1, "nothing to light")

        model.threadSearchText = "crash"
        model.threadSearchResults = [post.id]
        let title = model.forumPresentation(for: forumID).posts.first?.titleText
        #expect(title?.runs.filter { $0.backgroundColor != nil }.count == 1)
        #expect(title.map { String($0.characters) } == "Crash on launch")
    }

    // MARK: Add media to the original post

    /// A real file, because what a file is comes from what the system says about it.
    private func pending(_ name: String) -> PendingAttachment {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        FileManager.default.createFile(atPath: url.path, contents: Data([0]))
        return PendingAttachment(url: url)
    }

    private func ownPost(messages: Int = 0, owner: UserID? = nil, attachments: [WingcordCore.Attachment] = []) -> (AppModel, Channel) {
        let model = model()
        let post = post(snowflake(10), owner: owner ?? me, messages: messages)
        live([post], openers: [post.id: opener(of: post, attachments: attachments)], in: model)
        return (model, post)
    }

    @Test("The author, before anybody answers, of a post with no picture yet, sending one")
    func offersAddingMedia() {
        let (model, post) = ownPost()
        #expect(model.offersAddingMedia([pending("a.png")], to: post.id))
        #expect(model.offersAddingMedia([pending("a.txt"), pending("a.mp4")], to: post.id))
    }

    @Test("Not somebody else's post, an answered one, one with a picture, nor a plain file")
    func doesNotOfferAddingMedia() {
        let (others, othersPost) = ownPost(owner: author)
        #expect(!others.offersAddingMedia([pending("a.png")], to: othersPost.id))

        let (answered, answeredPost) = ownPost(messages: 1)
        #expect(!answered.offersAddingMedia([pending("a.png")], to: answeredPost.id))

        let (pictured, picturedPost) = ownPost(attachments: [picture(1)])
        #expect(!pictured.offersAddingMedia([pending("a.png")], to: picturedPost.id))

        let (plain, plainPost) = ownPost()
        #expect(!plain.offersAddingMedia([pending("a.txt")], to: plainPost.id))
        #expect(!plain.offersAddingMedia([], to: plainPost.id))
    }

    @Test("A thread off a text channel isn't a post")
    func threadIsNotPost() {
        let model = model()
        let text = ChannelID(rawValue: 200)
        model.channelIndex.upsert(Channel(id: text, kind: .text, guildID: guildID, name: "general"))
        var thread = post(snowflake(10), owner: me, messages: 0)
        thread.parentID = text
        model.channelIndex.upsertThread(thread)
        #expect(!model.offersAddingMedia([pending("a.png")], to: thread.id))
    }

    @Test("Asking leaves everything where it is, and Don't Add sends it")
    func prompts() throws {
        let (model, post) = ownPost()
        model.mutateBox(post.id) { $0.attachments = [pending("a.png")] }
        model.sendMessage("the picture", in: post.id)

        let prompt = try #require(model.forumAddMediaPrompt)
        #expect(prompt.postID == post.id)
        #expect(prompt.files.count == 1)
        #expect(model.messages(in: post.id)?.attachments.count == 1, "nothing has left the composer")
        #expect(model.messages(in: post.id)?.outbox.isEmpty == true, "nothing has been sent")

        let preview = try #require(model.forumAddMediaPreview(prompt))
        #expect(preview.media.count == 1)
        #expect(preview.id == post.id)

        // Don't Add: it goes as the reply it was going to be, without asking again.
        model.forumAddMediaPrompt = nil
        prompt.sendAnyway()
        #expect(model.forumAddMediaPrompt == nil)
        #expect(model.messages(in: post.id)?.outbox.count == 1)
        #expect(model.messages(in: post.id)?.attachments.isEmpty == true)
    }

    // MARK: New Post

    @Test("A post needs a title, something to say, and a tag where the forum asks for one")
    func postProblems() {
        let model = model { $0.flags.insert(.requireTag) }
        var problems = model.forumPostProblems(in: forumID)
        #expect(problems?.titleError != nil)
        #expect(problems?.messageError != nil)
        #expect(problems?.tagError != nil)

        model.forumPostDrafts[forumID] = ForumPostDraft(title: "A title", tags: [ForumTagID(rawValue: 1)])
        problems = model.forumPostProblems(in: forumID)
        #expect(problems?.titleError == nil)
        #expect(problems?.tagError == nil)
        #expect(problems?.messageError != nil, "a title alone is not a post")

        model.mutateBox(forumID) { $0.draft = "words" }
        #expect(model.forumPostProblems(in: forumID) == nil)
    }

    @Test("A draft is what's beyond the template, and Discard takes all of it")
    func drafts() {
        let model = model { $0.template = "**Steps**" }
        model.beginForumPost(in: forumID)
        #expect(model.composingPostIn == forumID)
        #expect(model.messages(in: forumID)?.draft == "**Steps**", "the forum's template")
        #expect(!model.hasForumPostDraft(in: forumID), "a template nobody touched isn't a draft")

        model.mutateBox(forumID) { $0.draft = "**Steps** and some" }
        #expect(model.hasForumPostDraft(in: forumID))

        model.cancelForumPost()
        #expect(model.composingPostIn == nil)
        #expect(model.hasForumPostDraft(in: forumID), "closing keeps it")

        model.discardForumPost(in: forumID)
        #expect(!model.hasForumPostDraft(in: forumID))
        #expect(model.messages(in: forumID)?.draft == "")
    }

    @Test("A search that found nothing can start a post with its words")
    func titledPost() {
        let model = model()
        model.beginForumPost(in: forumID, title: "voice drops")
        #expect(model.forumPostDrafts[forumID]?.title == "voice drops")
    }

    @Test("A refusal says what the server said, under the field at fault")
    func refusalWords() async {
        let model = model()
        model.forumPostDrafts[forumID] = ForumPostDraft(title: "")
        let refusal = await model.submitForumPost(in: forumID)
        #expect(refusal?.titleError == "A title is required")
        #expect(model.forumPostDrafts[forumID] != nil, "nothing is lost")
    }

    // MARK: Commands

    @Test("A forum's toolbar is also in the menu bar, and follows what's chosen")
    func menuContext() {
        let model = model(kind: .media) {
            $0.topic = "Guidelines"
            $0.availableTags = [ForumTag(id: ForumTagID(rawValue: 1), name: "UI")]
        }
        model.selectedChannelID = forumID
        model.refreshMenuContext()
        #expect(model.menuContext.forum?.isMedia == true)
        #expect(model.menuContext.forum?.hasTags == true)
        #expect(model.menuContext.forum?.hasGuidelines == true)
        #expect(model.menuContext.forum?.query.layout == .gallery)

        var query = model.forumBoard(for: forumID).query
        query.sortOrder = .creationDate
        model.setForumQuery(query, in: forumID)
        #expect(model.menuContext.forum?.query.sortOrder == .creationDate)
    }

    @Test("A text channel has none of it")
    func noForumMenu() {
        let model = model()
        let text = ChannelID(rawValue: 200)
        model.channelIndex.upsert(Channel(id: text, kind: .text, guildID: guildID, name: "general"))
        model.selectedChannelID = text
        model.refreshMenuContext()
        #expect(model.menuContext.forum == nil)
    }

    @Test("Create Thread on a forum starts a post")
    func createThreadShortcut() {
        let model = model()
        model.selectedChannelID = forumID
        model.refreshMenuContext()
        #expect(AppShortcut.createThread.isAvailable(in: model))
        AppShortcut.createThread.perform(in: model)
        #expect(model.composingPostIn == forumID)
    }
}
