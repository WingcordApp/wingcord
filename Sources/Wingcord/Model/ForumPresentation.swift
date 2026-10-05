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
    /// The first image on the opening message, for the row's thumbnail.
    var thumbnailURL: URL?
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
    /// The post's tags the board's filter has lit, drawn emphasised as
    /// Discord's are. Carried on the post so a row comparing only its post
    /// still redraws when the filter changes.
    var filteredTagIDs: Set<ForumTagID>
    /// The reaction Discord offers on every post here, when the forum sets one.
    var defaultReaction: EmojiRef?
}

/// The whole board.
struct ForumPresentation: Hashable, Sendable {
    var channelID: ChannelID
    var name: String
    /// A forum's `topic` is its guidelines, shown above the list rather than in
    /// the header — it is prose, not a subtitle.
    var guidelines: String?
    var query: ForumQuery
    var availableTags: [ForumTag]
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
    var requiresTag: Bool
    /// What is in the board's search field.
    var searchText: String
    /// Whether `posts` is a set of search results rather than the browse list.
    var isSearching: Bool

    static func empty(_ channelID: ChannelID) -> ForumPresentation {
        ForumPresentation(
            channelID: channelID,
            name: "",
            guidelines: nil,
            query: ForumQuery(),
            availableTags: [],
            posts: [],
            olderPosts: [],
            isLoading: false,
            loadFailed: false,
            hasMore: false,
            canPost: false,
            requiresTag: false,
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
                thumbnailURL: firstMessage.flatMap { message in
                    // Nothing of a hidden author's message is drawn — its
                    // picture least of all.
                    if case .shown = opener { Self.thumbnailURL(message) } else { nil }
                },
                messageCount: post.threadMessageCount ?? 0,
                // `lastMessageID` is a snowflake, so its own timestamp is the
                // last activity — there is no separate date field, and the
                // post's id is the fallback for one that has never been
                // replied to.
                lastActivity: post.lastMessageID?.timestamp ?? postID.timestamp,
                postedAt: post.threadMetadata?.createdAt ?? postID.timestamp,
                isPinned: post.isPinnedPost,
                isArchived: post.threadMetadata?.isArchived ?? false,
                isLocked: post.threadMetadata?.isLocked ?? false,
                isFollowed: threadMemberships[postID] != nil,
                isMuted: threadMemberships[postID]?.isMutedNow() ?? false,
                isNew: ForumOrder.isNew(
                    post, readMark: readMark, isOpened: readStates[postID] != nil, joinedAt: joinedAt
                ),
                filteredTagIDs: board.query.tags.intersection(tags.map(\.id)),
                defaultReaction: channel.defaultReaction
            )
        }

        let posts = sections.live.compactMap(present)
        let olderPosts = sections.older.compactMap(present)

        return ForumPresentation(
            channelID: channelID,
            name: channel.name,
            guidelines: channel.topic?.isEmpty == false ? channel.topic : nil,
            query: board.query,
            availableTags: channel.availableTags,
            posts: posts,
            olderPosts: olderPosts,
            isLoading: isSearching ? isSearchingThreads : board.isLoading,
            loadFailed: isSearching ? threadSearchFailed : board.loadFailed,
            // A search does not page: its query carries no offset to advance,
            // and running the browse pager underneath results it did not fetch
            // would splice the two lists together.
            hasMore: board.hasMore && !isSearching,
            canPost: permissionGate.canSend(in: channelID),
            requiresTag: channel.requiresTag,
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
        let words: String? = switch opener {
        case .shown(let message): Self.excerpt(message)
        case .loading: nil
        case .deleted: "Original message was deleted"
        case .blocked: "Post contains a blocked message"
        case .ignored: "Post contains an ignored message"
        }
        var line = AttributedString()
        if case .blocked = opener {} else if !author.isEmpty {
            var name = AttributedString(author)
            name.foregroundColor = colorValue.map { Color(hex: $0) } ?? InkColor.secondary
            line.append(name)
            if words != nil {
                var separator = AttributedString(": ")
                separator.foregroundColor = InkColor.tertiary
                line.append(separator)
            }
        }
        guard let words else { return line }
        var body = AttributedString(words)
        body.foregroundColor = InkColor.tertiary
        line.append(body)
        return line
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
        let live = ForumOrder.livePosts(liveThreads, query: board.query)
        let liveIDs = Set(liveThreads.map(\.id))
        return (live, board.postIDs.filter { !liveIDs.contains($0) })
    }

    /// The opening message reduced to one line.
    ///
    /// **Newlines collapse rather than truncate.** A post whose first line is
    /// blank — a picture, then the text — would otherwise preview as nothing at
    /// all, which is indistinguishable from a preview that has not loaded.
    private static func excerpt(_ message: Message) -> String {
        let collapsed = message.content
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if !collapsed.isEmpty { return collapsed }
        // A post that is only an image still has something to say about itself.
        if let attachment = message.attachments.first { return attachment.filename }
        return ""
    }

    /// The first image on a post's opening message.
    ///
    /// The **proxy** URL, as everywhere else in this app: Discord's own CDN
    /// proxy is what serves a resized variant, and the original is the full
    /// upload — a row thumbnail pulling a 4 MB photograph is the same fault as
    /// decoding one on the main thread.
    private static func thumbnailURL(_ message: Message) -> URL? {
        for attachment in message.attachments {
            guard attachment.contentType?.hasPrefix("image/") == true,
                  !attachment.isSpoiler
            else { continue }
            return URL(string: attachment.proxyURL)
        }
        return nil
    }
}
