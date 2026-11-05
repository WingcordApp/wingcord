import Foundation
import SwiftUI
import WingcordCore

// MARK: - What the board needs to draw itself
//
// A plain value snapshot with no model reference, handed to a pure view by one
// thin container — `INVARIANTS.md` §2. Everything a row needs about a post is
// resolved here, once, rather than looked up per row per evaluation: a tag id
// against the forum's own tag list, a role colour against the guild's roles, an
// author against the user table.

/// One post, as a row.
struct ForumPostPresentation: Hashable, Sendable, Identifiable {
    var id: ChannelID
    var title: String
    /// Resolved against the forum's `availableTags` — a post carries only ids,
    /// and an id nothing matches is dropped rather than drawn as a number.
    var tags: [ForumTag]
    var authorName: String
    /// The author's role colour. Read by the gallery card's byline, which draws
    /// the name on its own — the list row gets it inside `preview` instead,
    /// because there the name and the line after it have to wrap as one
    /// paragraph.
    var authorColorValue: UInt32?
    var avatarURL: URL?
    var monogram: String
    /// "author: the first line of the post", with the author in their role
    /// colour and the line after it in metadata ink.
    ///
    /// **One attributed string rather than two `Text`s.** The name and the line
    /// that follows it have to wrap as one paragraph — an `HStack` of two would
    /// keep the name on its own line at any narrow width — and `Text` + `Text`
    /// is deprecated as of macOS 26. Composed here rather than in the row
    /// because it is per-post work with one answer, and §2's rule is that
    /// anything a row needs is precomputed in the model.
    ///
    /// Empty until `post-data` answers, which is why the row is laid out to look
    /// finished without it.
    var preview: AttributedString
    /// The opening message's words alone, for a gallery card that has already said
    /// who wrote them.
    var openingWords: String
    /// The title, with what a search matched lit.
    var titleText: AttributedString
    /// What the opening message leads with: the first is a list row's thumbnail,
    /// and a gallery card lays out the first four.
    var media: [ForumPostMedia]
    /// The reaction its row offers. See `ForumPostReaction`.
    var reaction: ForumPostReaction?
    var messageCount: Int
    /// When the post last had a message. Falls back to its own creation time,
    /// which the id carries.
    var lastActivity: Date
    /// When the post was opened.
    ///
    /// **Distinct from `lastActivity`, and the gallery is why.** A list row says
    /// how long ago somebody last replied; a gallery card says when the post was
    /// *made* — "Posted 4m ago" — which for a busy post is a different number.
    /// A snowflake carries its own creation time, so this costs no field on the
    /// wire.
    var postedAt: Date
    var isPinned: Bool
    var isArchived: Bool
    var isLocked: Bool
    var isFollowed: Bool
    var isMuted: Bool
    /// Discord's "NEW" — see `ForumOrder.isNew`.
    var isNew: Bool
    /// Whether it has anything the reader hasn't read: new, or answered since they
    /// opened it. Discord dims a read post's title; here a read one is lighter in
    /// weight, because pale text is what it would otherwise take.
    var isUnread: Bool
    /// Discord's "(N New)": how many, in its words, on a post they've opened.
    var unreadWords: String?
    /// The post's tags the board's filter has lit, drawn emphasised as
    /// Discord's are. Carried on the post so a row comparing only its post
    /// still redraws when the filter changes.
    var filteredTagIDs: Set<ForumTagID>
}

/// The one reaction a post's row offers: Discord's `eC` and `eS`.
///
/// **The most-used one, or the forum's own default where nobody has reacted yet.**
/// One chip rather than the transcript's two for an emoji with both kinds, so its
/// number is everybody who reacted with it.
struct ForumPostReaction: Hashable, Sendable {
    var emoji: EmojiRef
    /// The kind a click would add or take off.
    var kind: ReactionKind
    /// Nil for a default nobody has used, which shows no number.
    var count: Int?
    var isMine: Bool
    /// A super reaction's colours, where somebody sent one.
    var palette: SuperReactionPalette?
    /// On a locked archive, or for a reader who can only look.
    var isReadOnly: Bool
}

/// The whole board.
struct ForumPresentation: Hashable, Sendable {
    var channelID: ChannelID
    var name: String
    var query: ForumQuery
    /// The live posts in Discord's order — the pinned post first — or a
    /// search's results.
    var posts: [ForumPostPresentation]
    /// The archived pages, under Discord's "Older Posts". Empty while
    /// searching: a search's results are one list.
    var olderPosts: [ForumPostPresentation]
    var isLoading: Bool
    var loadFailed: Bool
    var hasMore: Bool
    /// Whether the reader may open a post here at all.
    var canPost: Bool
    /// A media channel, which leads with its pictures at 16:9.
    var isMedia: Bool
    /// Other people's posts waiting behind "N New Posts".
    var newPostCount: Int
    /// What is in the board's search field.
    var searchText: String
    /// Whether `posts` is a set of search results rather than the browse list.
    var isSearching: Bool

    static func empty(_ channelID: ChannelID) -> ForumPresentation {
        ForumPresentation(
            channelID: channelID,
            name: "",
            query: ForumQuery(),
            posts: [],
            olderPosts: [],
            isLoading: false,
            loadFailed: false,
            hasMore: false,
            canPost: false,
            isMedia: false,
            newPostCount: 0,
            searchText: "",
            isSearching: false
        )
    }
}

/// What can change a board's answer.
struct ForumMemoKey: Hashable, Sendable {
    var channelID: ChannelID
    /// The board's own contents: a page arriving, a filter changing, a follow.
    var threadRevision: UInt64
    /// A post appearing or going.
    var structureRevision: UInt64
    /// **A post's last-message pointer moves on this and on nothing else**, and
    /// the row draws its age from it — so a board with a stale key shows "5d
    /// ago" on a post somebody answered a minute ago. It is the counter that
    /// moves most often in the app, which is why every other memo here avoids
    /// it; a board is the one surface whose answer genuinely depends on it.
    var valueRevision: UInt64
    /// Author names and colours.
    var identityRevision: UInt64
    var memberRevision: UInt64
    /// Role colours, and whether the reader may post here at all.
    var roleRevision: UInt64
    /// The board shows search results instead of the browse list while this is
    /// non-empty, so a memo that left it out would keep answering with the list
    /// the reader has just searched away from.
    var searchText: String
    var isSearchingThreads: Bool
    var threadSearchFailed: Bool
    /// "NEW" goes when a post is first opened, which is when it first has a
    /// read state — and against the forum's mark as the board opened.
    var readStateCount: Int
    var readMark: MessageID?
    /// A post's "(N New)" and its title's weight go when it's read, which moves no
    /// count. Every read cursor moves this one.
    var sidebarRevision: UInt64
    /// Whether anything is drawn from a post's embeds.
    var showsEmbeds: Bool
    /// An opening message from somebody blocked or ignored is not previewed.
    var blockedUserIDs: Set<UserID>
    var ignoredUserIDs: Set<UserID>
}

extension AppModel {

    /// Builds the board's snapshot.
    ///
    /// **Memoized, because every post the board has loaded is walked.** A board
    /// four pages deep is a hundred rows, each one a tag join, an author lookup
    /// and a role-colour resolve — and the container's body re-evaluates on far
    /// more than the handful of things that can actually move the answer.
    ///
    /// The inputs are read into the key BEFORE the cache is consulted, without
    /// exception: a memo that returns early registers no observation dependency,
    /// and its reader is then never invalidated. That failure looks like a board
    /// that does not update until something unrelated happens.
    func forumPresentation(for channelID: ChannelID) -> ForumPresentation {
        let key = ForumMemoKey(
            channelID: channelID,
            threadRevision: threadRevision,
            structureRevision: channelIndex.structureRevision,
            valueRevision: channelIndex.valueRevision,
            identityRevision: identityRevision,
            memberRevision: memberRevision,
            roleRevision: roleRevision,
            searchText: threadSearchText,
            isSearchingThreads: isSearchingThreads,
            threadSearchFailed: threadSearchFailed,
            readStateCount: readStates.count,
            readMark: forumReadMarks[channelID],
            sidebarRevision: sidebarRevision,
            showsEmbeds: AppSettings.shared.showsEmbeds,
            blockedUserIDs: blockedUserIDs,
            ignoredUserIDs: ignoredUserIDs
        )
        if let forumCache, forumCache.key == key { return forumCache.value }

        let value = buildForumPresentation(for: channelID)
        forumCache = (key, value)
        return value
    }

    private func buildForumPresentation(for channelID: ChannelID) -> ForumPresentation {
        guard let channel = channelIndex[channelID], channel.isForumLike else {
            return .empty(channelID)
        }
        let board = forumBoard(for: channelID)
        let guildID = channel.guildID
        let guildRoles = guildID.flatMap { roles[$0] } ?? [:]
        let saturation = userColorSaturation

        // One pass over the forum's tags, so resolving a post's five is five
        // lookups rather than five scans of twenty.
        var tagsByID: [ForumTagID: ForumTag] = [:]
        tagsByID.reserveCapacity(channel.availableTags.count)
        for tag in channel.availableTags { tagsByID[tag.id] = tag }

        // **Search results are not a subset of the browse list.** The route
        // searches the whole forum, so a hit is very often a post no page
        // reached — see `DiscordREST.searchThreads`.
        let phrase = threadSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearching = !phrase.isEmpty
        let sections = isSearching
            ? (live: threadSearchResults, older: [])
            : browseSections(of: channelID, board: board)

        let readMark = forumReadMarks[channelID]
        let joinedAt = guildID.flatMap { guilds[$0]?.joinedAt }
        let isMedia = channel.kind == .media
        // A row's thumbnail is small and a gallery's picture isn't, and the CDN
        // is asked for what'll be drawn.
        let mediaWidth = board.query.layout == .gallery ? ForumGallery.maximumWidth : Metrics.forumThumbnail
        let showsEmbeds = AppSettings.shared.showsEmbeds
        let defaultReaction = usableDefaultReaction(of: channel)

        func present(_ postID: ChannelID) -> ForumPostPresentation? {
            guard let post = channelIndex[postID] else { return nil }
            let firstMessage = board.firstMessages[postID]
            let authorID = firstMessage?.authorID ?? post.ownerID
            let user = authorID.flatMap { users[$0] }
            let member = guildID.flatMap { guild in authorID.flatMap { members[guild]?[$0] } }
            // `preferredName` falls back to the username; `displayName` is
            // optional and would leave the byline blank for any account that
            // has never set a global name.
            let name = member?.resolvedName(user: user) ?? user?.preferredName ?? ""
            let color = member.map {
                RoleResolver.nameColorValue(of: $0.roleIDs, in: guildRoles)
            }?.map { UserColor.desaturated($0, by: saturation) }
            // Discord's card (`ep`): an opening message from somebody blocked
            // or ignored is not shown, and one that is gone says so.
            let opener: Opener = if let firstMessage {
                blockedUserIDs.contains(firstMessage.authorID) ? .blocked
                    : ignoredUserIDs.contains(firstMessage.authorID) ? .ignored
                    : .shown(firstMessage)
            } else if board.detailsAnswered.contains(postID) {
                .deleted
            } else {
                .loading
            }
            // An applied tag the forum no longer defines is dropped: a deleted
            // tag leaves its id on every post that had it.
            let tags = post.appliedTags.compactMap { tagsByID[$0] }
            let isArchived = post.threadMetadata?.isArchived ?? false
            let isNew = ForumOrder.isNew(
                post, readMark: readMark, isOpened: readStates[postID] != nil, joinedAt: joinedAt
            )
            // Discord's `yz`: opened, with a mark, and something past it.
            let readState = readStates[postID]
            let hasTrackedUnread = !isArchived && readState?.lastAcknowledgedID != nil
                && readState?.isUnread(newest: post.lastMessageID) == true
            let messageCount = post.threadMessageCount ?? 0
            // Nothing of a hidden author's message is drawn: its picture least of all.
            let shownOpener: Message? = if case .shown(let message) = opener { message } else { nil }

            return ForumPostPresentation(
                id: postID,
                title: post.name,
                tags: tags,
                authorName: name,
                authorColorValue: color,
                avatarURL: authorID.map {
                    avatarURL(forUserID: $0, inGuild: guildID, side: Metrics.avatarRow)
                } ?? nil,
                monogram: user?.monogram ?? "",
                preview: Self.previewLine(author: name, colorValue: color, opener: opener),
                openingWords: Self.openerWords(opener) ?? "",
                titleText: Self.highlighted(post.name, matching: isSearching ? phrase : ""),
                media: shownOpener.map {
                    ForumPostCard.media(of: $0, isMediaChannel: isMedia, width: mediaWidth, showsEmbeds: showsEmbeds)
                } ?? [],
                reaction: firstMessage.flatMap { message in
                    forumReaction(on: message, of: post, defaultReaction: defaultReaction)
                },
                messageCount: messageCount,
                // `lastMessageID` is a snowflake, so its own timestamp is the
                // last activity — there is no separate date field, and the
                // post's id is the fallback for one that has never been
                // replied to.
                lastActivity: post.lastMessageID?.timestamp ?? postID.timestamp,
                postedAt: post.threadMetadata?.createdAt ?? postID.timestamp,
                isPinned: post.isPinnedPost,
                isArchived: isArchived,
                isLocked: post.threadMetadata?.isLocked ?? false,
                isFollowed: threadMemberships[postID] != nil,
                isMuted: threadMemberships[postID]?.isMutedNow() ?? false,
                isNew: isNew,
                isUnread: isNew || hasTrackedUnread,
                unreadWords: hasTrackedUnread
                    ? ForumPostCard.unreadWords(count: forumPostUnreadCounts[postID], total: messageCount)
                    : nil,
                filteredTagIDs: board.query.tags.intersection(tags.map(\.id))
            )
        }

        let posts = sections.live.compactMap(present)
        let olderPosts = sections.older.compactMap(present)

        return ForumPresentation(
            channelID: channelID,
            name: channel.name,
            query: board.query,
            posts: posts,
            olderPosts: olderPosts,
            isLoading: isSearching ? isSearchingThreads : board.isLoading,
            loadFailed: isSearching ? threadSearchFailed : board.loadFailed,
            // A search does not page: its query carries no offset to advance,
            // and running the browse pager underneath results it did not fetch
            // would splice the two lists together.
            hasMore: board.hasMore && !isSearching,
            canPost: permissionGate.canSend(in: channelID),
            isMedia: isMedia,
            // A post the filter would hide isn't news to this board.
            newPostCount: isSearching ? 0 : board.waitingPostIDs.count { postID in
                channelIndex[postID].map { ForumOrder.matches($0, query: board.query) } ?? false
            },
            searchText: threadSearchText,
            isSearching: isSearching
        )
    }

    /// What the card can say about a post's opening message.
    private enum Opener {
        case shown(Message)
        /// Not here yet — `post-data` has not answered.
        case loading
        /// Discord's "Original message was deleted".
        case deleted
        case blocked
        case ignored
    }

    /// The author, then the opening message reduced to one line — or Discord's
    /// words for why it is not there (`ep`): "Post contains a blocked message"
    /// alone, without the name; an ignored author named before "Post contains
    /// an ignored message"; "Original message was deleted".
    private static func previewLine(author: String, colorValue: UInt32?, opener: Opener) -> AttributedString {
        let words = openerWords(opener)
        var line = AttributedString()
        if case .blocked = opener {} else if !author.isEmpty {
            var name = AttributedString(author)
            name.foregroundColor = colorValue.map { Color(hex: $0) } ?? InkColor.secondary
            line.append(name)
            if words != nil {
                var separator = AttributedString(": ")
                separator.foregroundColor = InkColor.secondary
                line.append(separator)
            }
        }
        guard let words else { return line }
        var body = AttributedString(words)
        body.foregroundColor = InkColor.secondary
        line.append(body)
        return line
    }

    /// What the opening message comes to as words, or Discord's for why it can't.
    private static func openerWords(_ opener: Opener) -> String? {
        switch opener {
        case .shown(let message): excerpt(message)
        case .loading: nil
        case .deleted: "Original message was deleted"
        case .blocked: "Post contains a blocked message"
        case .ignored: "Post contains an ignored message"
        }
    }

    /// A board's two sections: the live posts in Discord's order, then the
    /// archived pages under "Older Posts".
    ///
    /// **`threads/search?archived=true` returns only the archived**, which is
    /// half a board — `forums.har` proves it: every thread the search answered
    /// with was archived, and the ten ids the client fetched `post-data` for
    /// immediately beforehand do not appear in it at all. Those ten are the live
    /// posts, and the client already had them, because active threads arrive
    /// over the gateway rather than on any route.
    ///
    /// So the live ones come out of the index — where READY, GUILD_CREATE,
    /// THREAD_LIST_SYNC and the active fetch put them — and are filtered and
    /// sorted here, on the client, as Discord's are: the server never saw the
    /// board's question about them. See `ForumOrder`.
    ///
    /// A thread in both is kept once, as live: a post opened again since its
    /// archived page was fetched belongs at the top, and one the tag filter
    /// leaves out belongs nowhere.
    private func browseSections(of channelID: ChannelID, board: ForumBoard) -> (live: [ChannelID], older: [ChannelID]) {
        // `!= true`, not `== false`: a thread whose payload carried no
        // `thread_metadata` is one nothing has told us is archived, and reading
        // that as archived would drop it off the board entirely.
        let liveThreads = channelIndex.threadIDs(inParent: channelID)
            .compactMap { channelIndex[$0] }
            .filter { $0.threadMetadata?.isArchived != true }
        let live = ForumOrder.heldPosts(
            liveThreads, query: board.query, held: board.liveOrder, waiting: board.waitingPostIDs
        )
        let liveIDs = Set(liveThreads.map(\.id))
        // The server already filtered these for the board's own question; a page
        // from before a filter changed is what the second test is for.
        let older = board.postIDs.filter { postID in
            !liveIDs.contains(postID)
                && (channelIndex[postID].map { ForumOrder.matches($0, query: board.query) } ?? true)
        }
        return (live, older)
    }

    /// The opening message reduced to one line.
    ///
    /// **Newlines collapse rather than truncate.** A post whose first line is
    /// blank — a picture, then the text — would otherwise preview as nothing at
    /// all, which is indistinguishable from a preview that has not loaded.
    private static func excerpt(_ message: Message) -> String {
        // The words as they read, not as they were typed: `**` is markup, and
        // Discord's row draws it.
        let collapsed = MarkdownParser().parse(message.content).plainText
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if !collapsed.isEmpty { return collapsed }
        // A post that is only an image still has something to say about itself.
        if let attachment = message.attachments.first { return attachment.filename }
        return ""
    }

    /// A title with a search's words lit, as Discord's does.
    private static func highlighted(_ title: String, matching phrase: String) -> AttributedString {
        var text = AttributedString(title)
        guard !phrase.isEmpty else { return text }
        for match in ForumPostCard.matches(of: phrase, in: title) {
            guard let start = AttributedString.Index(match.lowerBound, within: text),
                  let end = AttributedString.Index(match.upperBound, within: text)
            else { continue }
            text[start..<end].backgroundColor = Palette.accent.opacity(0.28)
        }
        return text
    }

    /// The forum's default reaction, if the reader could use it: Discord's `Ck`. A
    /// custom one arrives with only its id, so its name comes from the server's list,
    /// and one that isn't there isn't offered.
    private func usableDefaultReaction(of forum: Channel) -> EmojiRef? {
        guard let emoji = forum.defaultReaction else { return nil }
        guard let id = emoji.id else { return emoji.name.isEmpty ? nil : emoji }
        return forum.guildID.flatMap { guildEmojis[$0] }?.first { $0.id == id }
    }

    /// What a post's row offers to react with: Discord's `eC` and `eS`.
    private func forumReaction(
        on opener: Message,
        of post: Channel,
        defaultReaction: EmojiRef?
    ) -> ForumPostReaction? {
        let isLockedArchive = post.threadMetadata.map { $0.isArchived && $0.isLocked } ?? false
        let allowed = permissionGate.actions(for: opener)
        guard let top = ForumPostCard.topReaction(of: opener.reactions) else {
            guard let defaultReaction, isLockedArchive || allowed.contains(.addReaction) else { return nil }
            return ForumPostReaction(
                emoji: defaultReaction, kind: .normal, count: nil, isMine: false,
                palette: nil, isReadOnly: isLockedArchive
            )
        }
        return ForumPostReaction(
            emoji: top.emoji,
            kind: top.isMineBurst ? .burst : .normal,
            count: top.count + top.burstCount,
            isMine: top.isMine || top.isMineBurst,
            palette: top.burstCount > 0 ? SuperReactionPalette(colors: top.burstColors) : nil,
            isReadOnly: isLockedArchive || !allowed.contains(.joinReaction)
        )
    }
}

/// A post started and not yet sent: Discord's `ThreadSettings` draft, the title and
/// the tags, with what else this one holds. The message and its files are the forum's
/// own message box, as any channel's draft is.
struct ForumPostDraft: Hashable, Sendable {
    var title = ""
    var tags: Set<ForumTagID> = []
    /// A sticker picked for the post: Discord's sticker preview.
    var stickerID: UInt64?
    /// A media post's own picture for the board (`l$`).
    var thumbnail: PendingAttachment?

    var isEmpty: Bool { title.isEmpty && tags.isEmpty && stickerID == nil && thumbnail == nil }
}

/// "Add media to the original post?", while it's open.
struct ForumAddMediaPrompt {
    var postID: ChannelID
    var files: [PendingAttachment]
    /// "Don't Add": sends them as the reply they were going to be.
    var sendAnyway: () -> Void
    var isUploading = false
    var failure: String?

    init(postID: ChannelID, files: [PendingAttachment], sendAnyway: @escaping () -> Void) {
        self.postID = postID
        self.files = files
        self.sendAnyway = sendAnyway
    }
}

/// Why a post wasn't made, by where it's said.
struct ForumPostRefusal: Equatable, Sendable {
    /// Discord's `ipgKDg`, where AutoMod didn't say more.
    static let blocked = "This post cannot be sent because it contains content blocked by this community. "
        + "Please revise your post and try again."

    var titleError: String?
    var messageError: String?
    var tagError: String?
    var generalError: String?

    var isEmpty: Bool { titleError == nil && messageError == nil && tagError == nil && generalError == nil }
}
