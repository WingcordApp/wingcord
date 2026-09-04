import Foundation
import WingcordCore
import WingcordNet

// MARK: - Threads, and the boards forum posts arrive on
//
// A forum post and a thread off a message are the same object — see
// `ThreadMetadata` — so everything here serves both. What differs is only where
// the reader meets them: a post on a board, a thread in a panel beside the
// transcript.

/// One forum's post list, as far as it has been read.
///
/// Held per forum rather than on the selection, so paging back to a board that
/// was already open does not start from an empty list and a spinner.
///
/// **The posts themselves are not here.** They live in `channelIndex` like every
/// other channel, because a post is a channel the reader can open, and holding a
/// second copy is how the board and the transcript come to disagree about a
/// post's name. This holds the *order* the server returned them in, which is the
/// one thing the index cannot answer.
struct ForumBoard {
    var query: ForumQuery
    /// Post ids in the order the server returned them.
    var postIDs: [ChannelID] = []
    /// Ids already in `postIDs`, so appending a page is a set test per post
    /// rather than a scan of everything loaded so far.
    ///
    /// **Paging is by offset, and offsets over a list ordered by activity can
    /// repeat a row** — a post bumped between two requests moves onto the page
    /// that was already read. See `DiscordREST.forumPosts`.
    var seen: Set<ChannelID> = []
    /// The opening message of each post, from `first_messages` or `post-data`.
    var firstMessages: [ChannelID: Message] = [:]
    /// Posts whose preview line has been asked for, so a row scrolling in and
    /// out again does not re-request it.
    var detailsRequested: Set<ChannelID> = []
    var hasMore = false
    var totalResults = 0
    var isLoading = false
    /// Set when a page failed, so the board can offer a retry rather than
    /// spinning for ever. Cleared by the next successful page.
    var loadFailed = false

    /// How many posts the server has handed over, duplicates included.
    ///
    /// **Not `postIDs.count`, and the difference is load-bearing.** Paging is by
    /// offset over a list ordered by activity, so a post bumped between two
    /// requests arrives on a page that was already read and is dropped by the
    /// de-duplicate. Offsetting by the de-duplicated count would then ask for
    /// the overlap again, drop it again, and advance more slowly each page —
    /// a list that stalls short of the end while `hasMore` stays true.
    var servedCount = 0

    /// What the next page's `offset` should be.
    var nextOffset: Int { servedCount }
}

extension AppModel {

    // MARK: Reading

    /// The board for a forum, creating one at the channel's own defaults if this
    /// is the first time it has been opened.
    func forumBoard(for channelID: ChannelID) -> ForumBoard {
        if let existing = forumBoards[channelID] { return existing }
        guard let channel = channelIndex[channelID] else { return ForumBoard(query: ForumQuery()) }
        return ForumBoard(query: ForumQuery(defaultsOf: channel))
    }

    /// Whether the account follows this thread.
    func followsThread(_ threadID: ChannelID) -> Bool {
        threadMemberships[threadID] != nil
    }

    /// The threads shown under a channel in the sidebar.
    ///
    /// **Followed threads only.** A forum's whole board is loaded into the index
    /// the moment it is opened, and nesting all of it would put thirty-six rows
    /// under one channel — see `threadMemberships`.
    func sidebarThreadIDs(inParent parentID: ChannelID) -> [ChannelID] {
        channelIndex.threadIDs(inParent: parentID).filter { threadMemberships[$0] != nil }
    }

    // MARK: Opening one

    /// Opens a thread, in the panel beside whatever it hangs off.
    ///
    /// **A post opens beside its board, not instead of it** — the same place a
    /// thread opens beside its channel. Discord does this too, and the reason is
    /// not symmetry: a post that *replaced* the board would strand the reader.
    /// The post is not in the sidebar unless they follow it, and the forum row
    /// would no longer be the selection, so there would be nothing lit to click
    /// back to. Keeping the parent selected keeps the way back on screen.
    ///
    /// So both cases are one: select the parent, and put the thread in the
    /// panel. `selectedThreadID` is its own property rather than a second
    /// meaning for `selectedChannelID` precisely so the parent survives.
    func openThread(_ threadID: ChannelID) {
        guard let thread = channelIndex[threadID] else { return }
        guard permissionGate.canView(threadID) else { return }

        if let parentID = thread.parentID, selectedChannelID != parentID {
            selectChannel(parentID)
        }
        selectedThreadID = threadID
        // Neither case has a transcript yet: a board holds only each post's
        // opening message, and a thread reached from a chip has never been
        // opened. Both need the newest page fetched.
        sessionController.openChannel(threadID)
    }

    /// Closes the thread panel, leaving the channel underneath it selected.
    func closeThread() {
        guard selectedThreadID != nil else { return }
        selectedThreadID = nil
    }

    // MARK: Opening a board

    // MARK: The Threads flyout

    /// Opens the Threads flyout over a channel, loading its first page.
    ///
    /// **The same route the board uses**, and the capture is what says so:
    /// `threads toolbar.har` opens this flyout on an *announcement* channel and
    /// sends `GET /channels/{id}/threads/search` with exactly the parameters a
    /// forum board sends. The published reference calls that route forum-only;
    /// it is wrong, and the capture wins. So the flyout and the board share one
    /// fetch, one page store and one pager — they are the same question asked
    /// about two kinds of channel.
    ///
    /// The one difference in the reply is that a text channel's carries no
    /// `first_messages`, which `ThreadSearchDTO` already treats as optional.
    func openThreadBrowser(_ channelID: ChannelID) {
        guard canBrowseThreads(in: channelID) else { return }
        threadSearchText = ""
        openThreadsChannelID = channelID
        loadThreadList(channelID)
    }

    func closeThreadBrowser() {
        openThreadsChannelID = nil
        clearThreadSearch()
    }

    /// Types into the flyout's field, and asks the server about it.
    ///
    /// **Debounced, because the search is a request.** The capture sends one
    /// `?name=…` for the phrase rather than one per keystroke, and a client that
    /// fires per character is a client rate-limited off the route. The in-flight
    /// task is cancelled by the next keystroke, so only the last phrase survives.
    ///
    /// An empty field is not an empty search — it is *no* search, and the browse
    /// pages underneath are still loaded, so clearing costs nothing.
    func setThreadSearch(_ text: String, in channelID: ChannelID) {
        guard threadSearchText != text else { return }
        threadSearchText = text
        threadSearchTask?.cancel()

        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else {
            threadSearchTask = nil
            threadSearchResults = []
            isSearchingThreads = false
            threadSearchFailed = false
            return
        }

        isSearchingThreads = true
        threadSearchFailed = false
        threadSearchTask = Task { [weak self] in
            // Long enough that a typed word is one request, short enough that
            // the list does not feel like it is lagging behind the field.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await sessionController.searchThreads(in: channelID, name: phrase)
        }
    }

    func clearThreadSearch() {
        threadSearchTask?.cancel()
        threadSearchTask = nil
        threadSearchText = ""
        threadSearchResults = []
        isSearchingThreads = false
        threadSearchFailed = false
    }

    /// What a search came back with.
    ///
    /// The threads go into the index like any others — the rows have to resolve,
    /// and a hit is very often a thread no page had reached. The *ids* are held
    /// separately so the browse list underneath survives.
    func applyThreadSearch(_ page: ForumPage, phrase: String, in channelID: ChannelID) {
        // The reader may have typed on while this was in flight. Applying a
        // stale answer would put the previous phrase's hits under the current
        // one's text.
        guard threadSearchText.trimmingCharacters(in: .whitespacesAndNewlines) == phrase else {
            return
        }
        for thread in page.posts { channelIndex.upsertThread(thread) }
        applyThreadPeople(
            users: page.authors,
            members: page.members,
            guildID: channelIndex.guildID(of: channelID)
        )
        for membership in page.memberships { threadMemberships[membership.id] = membership }

        threadSearchResults = page.posts.map(\.id)
        isSearchingThreads = false
        threadSearchFailed = false
        threadRevision &+= 1
    }

    func applyThreadSearchFailure(phrase: String) {
        guard threadSearchText.trimmingCharacters(in: .whitespacesAndNewlines) == phrase else {
            return
        }
        isSearchingThreads = false
        threadSearchFailed = true
    }

    /// Whether a channel can have threads at all.
    ///
    /// A forum's threads *are* its whole surface, so it gets no flyout — the
    /// board is the list. A voice channel and a DM have none.
    func canBrowseThreads(in channelID: ChannelID) -> Bool {
        guard let channel = channelIndex[channelID] else { return false }
        return (channel.kind == .text || channel.kind == .announcement)
            && permissionGate.canReadHistory(channelID)
    }

    /// Loads a forum's first page, unless it is already loaded or loading.
    func openForum(_ channelID: ChannelID) { loadThreadList(channelID) }

    /// The shared loader behind the board and the flyout.
    private func loadThreadList(_ channelID: ChannelID) {
        var board = forumBoard(for: channelID)
        guard board.postIDs.isEmpty, !board.isLoading else {
            forumBoards[channelID] = board
            return
        }
        board.isLoading = true
        board.loadFailed = false
        forumBoards[channelID] = board
        threadRevision &+= 1
        sessionController.loadForumPage(channelID, query: board.query, offset: 0, replacing: true)
    }

    /// Asks for the next page. A no-op while one is in flight or at the end.
    func loadMoreForumPosts(in channelID: ChannelID) {
        var board = forumBoard(for: channelID)
        guard board.hasMore, !board.isLoading else { return }
        board.isLoading = true
        forumBoards[channelID] = board
        threadRevision &+= 1
        sessionController.loadForumPage(
            channelID, query: board.query, offset: board.nextOffset, replacing: false
        )
    }

    /// Changes what the board is asking for.
    ///
    /// **A layout change does not refetch.** List and gallery are the same posts
    /// arranged differently, and throwing away four loaded pages to redraw them
    /// is a spinner over a purely visual change — see `ForumQuery.matchesFetch`.
    func setForumQuery(_ query: ForumQuery, in channelID: ChannelID) {
        var board = forumBoard(for: channelID)
        guard board.query != query else { return }
        let needsFetch = !board.query.matchesFetch(query)
        board.query = query

        if needsFetch {
            board.postIDs = []
            board.seen = []
            board.servedCount = 0
            board.detailsRequested = []
            board.hasMore = false
            board.isLoading = true
            board.loadFailed = false
            forumBoards[channelID] = board
            threadRevision &+= 1
            sessionController.loadForumPage(channelID, query: query, offset: 0, replacing: true)
        } else {
            forumBoards[channelID] = board
            threadRevision &+= 1
        }
    }

    /// Fills in the preview line and author for posts about to be drawn.
    ///
    /// **Coalesced, and asked for once per post.** `threads/search` returns
    /// opening messages only for the page it just built, so a post the board
    /// learned about another way — a followed thread from READY, a
    /// `THREAD_LIST_SYNC` — has none, and `post-data` is the only route that
    /// answers for an arbitrary set.
    ///
    /// Rows report themselves one at a time as they scroll in, and a call per
    /// row would be a request per row — which is the entire thing the batch
    /// route exists to avoid. Ids gather here and go out together on the next
    /// turn of the main actor, which is one request for everything that arrived
    /// in the same scroll. The capture batches the same way: ten, then five,
    /// then one.
    func requestForumPostDetails(_ postIDs: [ChannelID], in channelID: ChannelID) {
        var board = forumBoard(for: channelID)
        let wanted = postIDs.filter {
            board.firstMessages[$0] == nil && !board.detailsRequested.contains($0)
        }
        guard !wanted.isEmpty else { return }
        // Marked as requested at gather time, not at send time: a row that
        // appears twice before the flush must not be asked for twice.
        board.detailsRequested.formUnion(wanted)
        forumBoards[channelID] = board
        pendingPostDetails[channelID, default: []].formUnion(wanted)

        guard !isFlushingPostDetails else { return }
        isFlushingPostDetails = true
        Task { [weak self] in
            // One hop, no timer: `Task` on the main actor resumes after the
            // current run of view updates, by which point every row that
            // appeared in this pass has reported itself.
            await Task.yield()
            guard let self else { return }
            isFlushingPostDetails = false
            let batches = pendingPostDetails
            pendingPostDetails = [:]
            for (forumID, ids) in batches where !ids.isEmpty {
                // Sorted so the request is deterministic — a `Set`'s order is
                // not stable between runs, and an unstable body defeats any
                // caching in front of it.
                sessionController.loadForumPostDetails(ids.sorted(), in: forumID)
            }
        }
    }

    // MARK: Opening a post

    /// Opens the New Post sheet, if the reader may post here at all.
    ///
    /// Gated here as well as where the button is drawn: dimming a control is a
    /// statement and a click is an action — §5.5.
    func beginForumPost(in channelID: ChannelID) {
        guard let channel = channelIndex[channelID], channel.isForumLike else { return }
        guard permissionGate.canSend(in: channelID) else { return }
        composingPostIn = channelID
    }

    func cancelForumPost() { composingPostIn = nil }

    /// Sends a new post, and opens it.
    ///
    /// **Not optimistic, and deliberately not.** A post is a channel: an
    /// optimistic one would have an id this client invented, which the sidebar,
    /// the index and any click on it would then be holding. The sheet closes and
    /// the board shows the post when the server answers — which is one round
    /// trip, on an action that already involved typing a title.
    func submitForumPost(title: String, body: String, tags: Set<ForumTagID>) {
        guard let channelID = composingPostIn else { return }
        guard let channel = channelIndex[channelID] else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // The forum's own rule, enforced before the round trip rather than after
        // a 400: a forum with `REQUIRE_TAG` refuses a post with none.
        guard !channel.requiresTag || !tags.isEmpty else { return }

        composingPostIn = nil
        sessionController.createForumPost(
            in: channelID,
            name: name,
            content: body,
            tags: Array(tags),
            // The forum's own default, so a post inherits what the channel was
            // set up with rather than a constant chosen here.
            autoArchiveMinutes: channel.threadMetadata?.autoArchiveMinutes ?? 4320
        )
    }

    /// A post the server just made. Put on the board, and opened.
    func applyCreatedForumPost(_ post: Channel, in channelID: ChannelID) {
        channelIndex.upsertThread(post)
        var board = forumBoard(for: channelID)
        // At the head: every sort this board offers puts the newest post first,
        // and a post the reader just wrote appearing at position forty is a post
        // they will assume failed.
        if board.seen.insert(post.id).inserted { board.postIDs.insert(post.id, at: 0) }
        board.totalResults += 1
        forumBoards[channelID] = board
        if let currentUserID {
            // Opening a post joins it — Discord's own client does, and the
            // author of a post is in it by definition.
            threadMemberships[post.id] = ThreadMember(
                id: post.id, userID: currentUserID, joinedAt: .now
            )
        }
        threadRevision &+= 1
        sidebarRevision &+= 1
        openThread(post.id)
    }

    // MARK: Applying what came back

    func applyForumPage(_ page: ForumPage, in channelID: ChannelID, replacing: Bool) {
        var board = forumBoard(for: channelID)
        board.isLoading = false
        board.loadFailed = false
        if replacing {
            board.postIDs = []
            board.seen = []
            board.servedCount = 0
        }
        board.servedCount += page.posts.count

        for post in page.posts {
            // Into the index, so opening a post resolves it like any channel.
            channelIndex.upsertThread(post)
            guard board.seen.insert(post.id).inserted else { continue }
            board.postIDs.append(post.id)
        }
        board.firstMessages.merge(page.firstMessages) { _, new in new }
        board.hasMore = page.hasMore
        board.totalResults = page.totalResults
        forumBoards[channelID] = board

        applyThreadPeople(users: page.authors, members: page.members, guildID: channelIndex.guildID(of: channelID))
        for membership in page.memberships { threadMemberships[membership.id] = membership }

        threadRevision &+= 1
        sidebarRevision &+= 1
    }

    func applyForumPageFailure(in channelID: ChannelID) {
        var board = forumBoard(for: channelID)
        board.isLoading = false
        board.loadFailed = true
        forumBoards[channelID] = board
        threadRevision &+= 1
    }

    func applyForumPostDetails(
        _ details: [ChannelID: ForumPostDetail],
        in channelID: ChannelID
    ) {
        var board = forumBoard(for: channelID)
        var authors: [UserID: User] = [:]
        for (postID, detail) in details {
            if let message = detail.firstMessage { board.firstMessages[postID] = message }
            if let author = detail.author { authors[author.id] = author }
        }
        forumBoards[channelID] = board
        applyThreadPeople(users: authors, members: [:], guildID: channelIndex.guildID(of: channelID))
        threadRevision &+= 1
    }

    /// A post's author or owner, merged into the shared tables.
    ///
    /// **Merged, never replaced** — the same rule `guildAvailable` follows. A
    /// user record from a forum row carries no bio, banner or badges, and
    /// writing one straight over a profile-fetched record wipes the card the
    /// reader may be looking at.
    func applyThreadPeople(
        users: [UserID: User],
        members: [UserID: Member],
        guildID: GuildID?
    ) {
        if !users.isEmpty {
            self.users.merge(users) { existing, new in new.merged(over: existing) }
        }
        if let guildID, !members.isEmpty {
            self.members[guildID, default: [:]].merge(members) { _, new in new }
            memberRevision &+= 1
        }
        if !users.isEmpty { identityRevision &+= 1 }
    }

    // MARK: Following, muting, notifying

    /// Follows or unfollows a thread.
    ///
    /// Applied optimistically: the control is the only feedback the click has,
    /// and the sidebar gains or loses a row on the same write. A refusal puts it
    /// back — see `SessionController.writeThreadMembership`.
    func setThreadFollowed(_ followed: Bool, threadID: ChannelID, location: String) {
        guard followed != followsThread(threadID) else { return }
        guard let currentUserID else { return }
        let previous = threadMemberships[threadID]

        if followed {
            threadMemberships[threadID] = ThreadMember(
                id: threadID, userID: currentUserID, joinedAt: .now
            )
        } else {
            threadMemberships[threadID] = nil
        }
        threadRevision &+= 1
        sidebarRevision &+= 1
        sessionController.writeThreadMembership(
            followed, threadID: threadID, location: location, previous: previous
        )
    }

    /// Sets which messages in a thread are worth a notification.
    ///
    /// **Following is implied.** Discord's own client joins the thread before
    /// changing the setting — the capture's join carries
    /// `location=Change Notification Settings` — because a member row is what
    /// the setting lives on, and there is nothing to PATCH without one.
    func setThreadNotification(_ setting: ThreadNotification, threadID: ChannelID) {
        guard let currentUserID else { return }
        let previous = threadMemberships[threadID]
        var membership = previous ?? ThreadMember(
            id: threadID, userID: currentUserID, joinedAt: .now
        )
        guard membership.notification != setting || previous == nil else { return }

        // The three notification bits are mutually exclusive; anything else the
        // member carries — `hasInteracted` — is left alone.
        membership.flags.subtract([.allMessages, .onlyMentions, .noMessages])
        membership.flags.formUnion(setting.wireFlags)
        threadMemberships[threadID] = membership
        threadRevision &+= 1
        sidebarRevision &+= 1

        sessionController.writeThreadNotification(
            setting, threadID: threadID, joinFirst: previous == nil, previous: previous
        )
    }

    /// Mutes a thread for a while, or takes the mute off with a nil duration.
    func setThreadMute(_ duration: MuteDuration?, threadID: ChannelID) {
        guard let currentUserID else { return }
        let previous = threadMemberships[threadID]
        var membership = previous ?? ThreadMember(
            id: threadID, userID: currentUserID, joinedAt: .now
        )
        if let duration {
            membership.isMuted = true
            membership.muteConfig = ThreadMuteConfig(
                endTime: duration.endTime(), selectedTimeWindow: duration.rawValue
            )
        } else {
            membership.isMuted = false
            membership.muteConfig = nil
        }
        threadMemberships[threadID] = membership
        threadRevision &+= 1
        sidebarRevision &+= 1

        sessionController.writeThreadMute(
            duration, threadID: threadID, joinFirst: previous == nil, previous: previous
        )
    }

    // MARK: What the gateway says

    /// The threads a page of messages carried inline.
    ///
    /// **Known, not followed.** These arrive because a message on the page
    /// started one — so they go into the index, which is what makes the chip's
    /// click resolve, and they get no membership row. The sidebar still shows
    /// only what the reader follows; see `sidebarThreadIDs(inParent:)`.
    ///
    /// Silent when there is nothing to do, which is the overwhelmingly common
    /// case: most pages carry no threads at all, and bumping a revision for an
    /// empty array would relayout the transcript on every page of history.
    func applyThreadsFromMessages(_ threads: [Channel]) {
        guard !threads.isEmpty else { return }
        var changed = false
        for thread in threads {
            // A thread already held is left alone unless something moved. The
            // index would re-sort its parent's array on every upsert, and a
            // page of history re-delivers the same threads every time it is
            // paged back over.
            guard channelIndex[thread.id] != thread else { continue }
            channelIndex.upsertThread(thread)
            changed = true
        }
        guard changed else { return }
        threadRevision &+= 1
        sidebarRevision &+= 1
    }

    func applyThreadUpsert(_ thread: Channel, membership: ThreadMember?) {
        channelIndex.upsertThread(thread)
        if let membership { threadMemberships[membership.id] = membership }
        permissionGate.invalidate()
        threadRevision &+= 1
        sidebarRevision &+= 1
    }

    func applyThreadRemoval(_ threadID: ChannelID) {
        channelIndex.remove(threadID)
        threadMemberships[threadID] = nil
        // A board holding it must forget it too, or the row stays on screen
        // pointing at a channel that no longer resolves.
        for (forumID, var board) in forumBoards where board.seen.contains(threadID) {
            board.postIDs.removeAll { $0 == threadID }
            board.seen.remove(threadID)
            board.firstMessages[threadID] = nil
            board.detailsRequested.remove(threadID)
            forumBoards[forumID] = board
        }
        if selectedThreadID == threadID { selectedThreadID = nil }
        permissionGate.invalidate()
        threadRevision &+= 1
        sidebarRevision &+= 1
    }

    func applyThreadListSync(
        _ threads: [Channel],
        parentIDs: [ChannelID]?,
        memberships: [ThreadMember],
        guildID: GuildID?
    ) {
        channelIndex.replaceThreads(threads, inParents: parentIDs, guildID: guildID)
        for membership in memberships { threadMemberships[membership.id] = membership }
        permissionGate.invalidate()
        threadRevision &+= 1
        sidebarRevision &+= 1
    }

    func applyThreadMembership(_ membership: ThreadMember) {
        threadMemberships[membership.id] = membership
        threadRevision &+= 1
        sidebarRevision &+= 1
    }

    /// Somebody else joined or left. Only the count moves.
    func applyThreadMemberCount(_ count: Int?, in threadID: ChannelID) {
        guard let count, var thread = channelIndex[threadID] else { return }
        guard thread.memberCount != count else { return }
        thread.memberCount = count
        channelIndex.upsertThread(thread)
        threadRevision &+= 1
    }
}
