import CoreGraphics
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
    /// Posts `post-data` has answered for. One answered with no opening
    /// message has lost it — Discord's "Original message was deleted" — where
    /// one merely asked for is still loading.
    var detailsAnswered: Set<ChannelID> = []
    var hasMore = false
    /// How many posts the server says there are — the Threads browser's count.
    var totalResults = 0
    var isLoading = false
    /// Set when a page failed, so the board can offer a retry rather than
    /// spinning for ever. Cleared by the next successful page.
    var loadFailed = false

    /// The live posts in the order they were last put in: what keeps a row from
    /// moving under somebody reading it. See `ForumOrder.heldPosts`.
    var liveOrder: [ChannelID] = []
    /// Other people's new posts since then, waiting behind "N New Posts".
    var waitingPostIDs: Set<ChannelID> = []

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

    /// How a thread opens — Discord's `openThreadSidebarForViewing` and the
    /// plain transition beside it.
    enum ThreadOpening {
        /// Where the reader's "Open threads in split view" says: in the panel
        /// beside the channel or board it hangs off, or as the page. A thread
        /// chip under a message, a post on its board and the Threads browser
        /// all open this way.
        case automatic
        /// As the page — the channel list's own row, and "Open in Full View".
        case fullView
        /// Beside its parent — "Open in Split View".
        case splitView
    }

    /// Opens a thread, beside whatever it hangs off or as the page.
    ///
    /// **Split view keeps the parent selected.** A post opened beside its
    /// board leaves the board lit in the sidebar — the way back on screen —
    /// and `selectedThreadID` is its own property rather than a second meaning
    /// for `selectedChannelID` precisely so the parent survives.
    ///
    /// **Full view selects the thread itself**, as Discord's channel list does:
    /// the followed post or joined thread under its channel is lit, and the
    /// toolbar names its parent before it.
    func openThread(_ threadID: ChannelID, as opening: ThreadOpening = .automatic) {
        guard let thread = channelIndex[threadID], permissionGate.canView(threadID) else { return }
        let splits = switch opening {
        case .fullView: false
        case .splitView: true
        // Mod View holds the column, and Discord opens a thread full-size
        // where another sidebar already has it.
        case .automatic: syncedPreferences.opensThreadsInSplitView && openModViewUserID == nil
        }
        // A thread opened replaces a thread being written, as Discord's
        // sidebar does — see `abandonNewThread`.
        newThread = nil
        if splits, let parentID = thread.parentID {
            if selectedChannelID != parentID { selectChannel(parentID) }
            selectedThreadID = threadID
        } else {
            selectedThreadID = nil
            selectChannel(threadID)
        }
        // Neither case has a transcript yet: a board holds only each post's
        // opening message, and a thread reached from a chip has never been
        // opened. Both need the newest page fetched.
        sessionController.openChannel(threadID)
    }

    /// Discord's "Open threads in split view", here at once and on the
    /// account.
    func setOpensThreadsInSplitView(_ opens: Bool) {
        guard syncedPreferences.opensThreadsInSplitView != opens else { return }
        let previous = syncedPreferences
        syncedPreferences.opensThreadsInSplitView = opens
        sessionController.writeSyncedPreference(.opensThreadsInSplitView(opens), restoring: previous)
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
            if LaunchOptions.current.usesDemoFixtures {
                threadSearchResults = channelIndex.threadIDs(inParent: channelID).filter {
                    channelIndex[$0]?.name.localizedCaseInsensitiveContains(phrase) == true
                }
                isSearchingThreads = false
                threadRevision &+= 1
                return
            }
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

    /// Opens a board: its first page, unless it is already loaded or loading —
    /// and Discord's read of it.
    ///
    /// **The forum's own read state is noted, then acknowledged**, as Discord's
    /// is on selecting the channel (`ackMessageIdAtChannelSelect`, then the
    /// automatic `ACK_FORUM_ACTIVE_THREADS`). The note is what "NEW" is measured
    /// against for as long as the board is open — see `ForumOrder.isNew` — and
    /// the acknowledgement is what makes the next visit's "NEW" only what
    /// arrived since this one. It also clears the forum's unread mark in the
    /// channel list, which nothing else ever did.
    func openForum(_ channelID: ChannelID) {
        forumReadMarks[channelID] = readStates[channelID]?.lastAcknowledgedID
        if let forum = channelIndex[channelID], let newest = forum.lastMessageID,
           unreadState(of: forum).unread
        {
            sessionController.acknowledge(newest, in: channelID)
        }
        loadThreadList(channelID)
        refreshForumOrder(channelID)
        requestForumUnreads(in: channelID)
        if LaunchOptions.current.usesDemoFixtures { DemoFixtures.scheduleForumArrivals(in: channelID, model: self) }
    }

    /// Puts a board's live posts back in order, and shows what was waiting: Discord's
    /// `refreshThreadIds`, on opening a board, its query changing, a thread list
    /// syncing, and "N New Posts".
    func refreshForumOrder(_ channelID: ChannelID) {
        var board = forumBoard(for: channelID)
        let live = channelIndex.threadIDs(inParent: channelID)
            .compactMap { channelIndex[$0] }
            .filter { $0.threadMetadata?.isArchived != true }
        board.liveOrder = ForumOrder.livePosts(live, query: board.query)
        board.waitingPostIDs = []
        forumBoards[channelID] = board
        threadRevision &+= 1
    }

    // MARK: How many are new

    /// Asks how many messages each post the reader has opened has past their mark:
    /// Discord's `D` in `435470`, at most 180 at a time, and each post once per
    /// connection. **Op 28**, `s.REQUEST_FORUM_UNREADS` in the web build.
    func requestForumUnreads(in channelID: ChannelID) {
        // Only on a session that's up: an op on a socket that hasn't identified or
        // resumed yet is a 4003, which is a reconnect. Until then they say "1+".
        guard connectionState == .ready, let socket = sessionController.socket,
              let guildID = channelIndex.guildID(of: channelID)
        else { return }
        let board = forumBoard(for: channelID)
        var wanted: [(threadID: ChannelID, ackMessageID: MessageID)] = []
        for postID in board.liveOrder where wanted.count < 180 {
            guard forumPostUnreadCounts[postID] == nil, !forumUnreadsRequested.contains(postID),
                  let post = channelIndex[postID], let state = readStates[postID],
                  let mark = state.lastAcknowledgedID, state.isUnread(newest: post.lastMessageID)
            else { continue }
            wanted.append((postID, mark))
        }
        guard !wanted.isEmpty else { return }
        forumUnreadsRequested.formUnion(wanted.map(\.threadID))
        Task { await socket.requestForumUnreads(guildID: guildID, channelID: channelID, threads: wanted) }
    }

    /// `FORUM_UNREADS`, the answer.
    func applyForumUnreads(_ counts: [ChannelID: Int]) {
        guard !counts.isEmpty else { return }
        forumPostUnreadCounts.merge(counts) { _, new in new }
        threadRevision &+= 1
    }

    /// A message arriving counts up on a post that has a count, as Discord's
    /// `MESSAGE_CREATE` handler has it. One with none says "1+" until asked.
    func countForumPostMessage(_ message: Message) {
        guard message.authorID != currentUserID, forumPostUnreadCounts[message.channelID] != nil else { return }
        forumPostUnreadCounts[message.channelID, default: 0] += 1
        threadRevision &+= 1
    }

    /// The post's been read: nothing past the mark, and counting from there.
    func noteForumPostRead(_ channelID: ChannelID) {
        guard let parentID = channelIndex[channelID]?.parentID, channelIndex[parentID]?.isForumLike == true else { return }
        forumPostUnreadCounts[channelID] = 0
        threadRevision &+= 1
    }

    /// More Active Posts' way to the same first page — see
    /// `AppModel.preloadActivePosts`.
    func loadThreadListForFlyout(_ channelID: ChannelID) {
        loadThreadList(channelID)
    }

    /// The shared loader behind the board and the flyout.
    private func loadThreadList(_ channelID: ChannelID) {
        var board = forumBoard(for: channelID)
        guard board.postIDs.isEmpty, !board.isLoading, !LaunchOptions.current.usesDemoFixtures else {
            forumBoards[channelID] = board
            return
        }
        board.isLoading = true
        board.loadFailed = false
        forumBoards[channelID] = board
        threadRevision &+= 1
        sessionController.loadForumPage(channelID, query: board.query, offset: 0, replacing: true)
        // The live half. Separate request, separate failure — see
        // `SessionController.loadActiveThreads`.
        sessionController.loadActiveThreads(channelID, query: board.query)
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
        let needsFetch = !board.query.matchesFetch(query) && !LaunchOptions.current.usesDemoFixtures
        board.query = query
        defer {
            refreshForumOrder(channelID)
            refreshMenuContext()
        }

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
            sessionController.loadActiveThreads(channelID, query: query)
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
    func beginForumPost(in channelID: ChannelID, title: String? = nil) {
        guard let channel = channelIndex[channelID], channel.isForumLike else { return }
        guard permissionGate.canSend(in: channelID) else { return }
        if let title { forumPostDrafts[channelID, default: ForumPostDraft()].title = title }
        // The forum's own template, where the box is still empty.
        if let template = channel.template, !template.isEmpty, messages(in: channelID)?.draft.isEmpty != false {
            mutateBox(channelID) { $0.draft = template }
        }
        composingPostIn = channelID
    }

    /// Whether a post was started here and left: anything beyond the forum's own
    /// template. See `ForumPostDraft`.
    func hasForumPostDraft(in channelID: ChannelID) -> Bool {
        let box = messages(in: channelID)
        let words = (box?.draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let template = (channelIndex[channelID]?.template ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return forumPostDrafts[channelID]?.isEmpty == false
            || box?.attachments.isEmpty == false
            || (!words.isEmpty && words != template)
    }

    /// Leaves the card, and the post where it is: the next New Post comes back to it.
    func cancelForumPost() { composingPostIn = nil }

    /// Throws the started post away.
    func discardForumPost(in channelID: ChannelID) {
        forumPostDrafts[channelID] = nil
        mutateBox(channelID) { box in
            box.draft = ""
            box.attachments = []
            box.attachmentRefusal = nil
        }
        composingPostIn = nil
    }

    /// Discord's checks (`ix`), before the round trip: a title, and something to say.
    /// The button is already off for most of these; this is for ⌘Return, and for a
    /// card that came up already holding a draft.
    func forumPostProblems(in channelID: ChannelID) -> ForumPostRefusal? {
        let draft = forumPostDrafts[channelID] ?? ForumPostDraft()
        let box = messages(in: channelID)
        var refusal = ForumPostRefusal()
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            refusal.titleError = "A title is required"
        }
        let hasWords = !(box?.draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasFiles = !(box?.attachments ?? []).isEmpty || draft.thumbnail != nil
        if !hasWords, !hasFiles, draft.stickerID == nil {
            refusal.messageError = "A message is required"
        }
        if channelIndex[channelID]?.requiresTag == true, draft.tags.isEmpty {
            refusal.tagError = "A tag is required to create a post in this channel"
        }
        return refusal.isEmpty ? nil : refusal
    }

    /// Sends the post in a forum's card, and answers with why it wasn't made.
    ///
    /// **The card stays up until the server answers**, because a post is a channel:
    /// there's no optimistic row to hold it, and a card that closed on the press
    /// took everything written with it when the server said no. Nil means it's made
    /// and the card has gone.
    func submitForumPost(in channelID: ChannelID) async -> ForumPostRefusal? {
        if let problems = forumPostProblems(in: channelID) { return problems }
        guard let channel = channelIndex[channelID] else {
            return ForumPostRefusal(generalError: "An error occurred, please try again.")
        }
        guard !holdsForSlowmode(channelID) else { return ForumPostRefusal() }
        let draft = forumPostDrafts[channelID] ?? ForumPostDraft()
        let box = messages(in: channelID)
        let content = (box?.draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // A thumbnail goes up first, as Discord's does.
        let files = (draft.thumbnail.map { [$0] } ?? []) + (box?.attachments ?? [])
        defer { forumPostUploadProgress[channelID] = nil }
        do {
            let post: Channel
            if LaunchOptions.current.usesDemoFixtures {
                post = try await DemoFixtures.createForumPost(draft, content: content, files: files, in: channel, model: self)
            } else {
                post = try await sessionController.createForumPost(
                    in: channelID,
                    name: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    content: content,
                    tags: Array(draft.tags),
                    // The forum's own default, so a post inherits what the channel
                    // was set up with: Discord's `268761`, three days otherwise.
                    autoArchiveMinutes: channel.defaultAutoArchiveDuration ?? 4320,
                    stickerIDs: draft.stickerID.map { [$0] } ?? [],
                    attachments: PendingAttachment.anonymising(files)
                )
            }
            startSlowmode(afterSendIn: channelID)
            markForumGuidelinesSeen(in: channelID)
            forumPostDrafts[channelID] = nil
            mutateBox(channelID) { box in
                box.draft = ""
                box.attachments = []
                box.attachmentRefusal = nil
            }
            composingPostIn = nil
            applyCreatedForumPost(post, in: channelID)
            return nil
        } catch {
            sessionController.traceForumPostFailure(error, in: channelID)
            return forumPostRefusal(for: error, in: channelID)
        }
    }

    /// Discord's `Y` and the form's `catch`: AutoMod and a bad name under their own
    /// fields, the cap and the rate limit in its words, and a wait set for slowmode.
    private func forumPostRefusal(for error: any Error, in channelID: ChannelID) -> ForumPostRefusal {
        switch error {
        case DiscordREST.Failure.slowmode(let retryAfter):
            applySlowmodeRefusal(retryAfter: retryAfter, in: channelID)
            return ForumPostRefusal()
        case DiscordREST.Failure.api(_, 20016?, _):
            applySlowmodeRefusal(retryAfter: nil, in: channelID)
            return ForumPostRefusal()
        case DiscordREST.Failure.api(_, 200_001?, let message):
            return ForumPostRefusal(titleError: message ?? ForumPostRefusal.blocked)
        case DiscordREST.Failure.api(_, 200_000?, let message):
            return ForumPostRefusal(messageError: message ?? ForumPostRefusal.blocked)
        case DiscordREST.Failure.api(_, 50035?, _):
            return ForumPostRefusal(titleError: "A title is required")
        case DiscordREST.Failure.api(_, 160_006?, _):
            return ForumPostRefusal(
                generalError: "This server has reached the maximum number of active posts. Free up space by archiving a post."
            )
        case DiscordREST.Failure.api(429, _, _):
            return ForumPostRefusal(generalError: "You are being rate limited.")
        case DiscordREST.Failure.api(_, _, let message?) where !message.isEmpty:
            return ForumPostRefusal(generalError: message)
        case DemoFixtures.ForumPostError.blockedTitle:
            return ForumPostRefusal(titleError: ForumPostRefusal.blocked)
        default:
            return ForumPostRefusal(generalError: "An error occurred, please try again.")
        }
    }

    // MARK: Adding to a post

    /// Whether to offer a post's author to put a picture on the post itself, instead
    /// of sending it as the post's first reply: Discord's `xz` (`256265`). The author's
    /// own post, nobody has answered it, and it has no picture yet, which is what the
    /// board would otherwise show nothing for.
    func offersAddingMedia(_ files: [PendingAttachment], to channelID: ChannelID) -> Bool {
        guard files.contains(where: { $0.isImage || $0.isVideo }),
              let post = channelIndex[channelID],
              ThreadGate.isForumPost(post, parent: post.parentID.flatMap { channelIndex[$0] }),
              post.ownerID == currentUserID,
              (post.threadMessageCount ?? 0) == 0,
              let opener = message(MessageID(rawValue: channelID.rawValue), in: channelID)
        else { return false }
        return !opener.attachments.contains(where: ForumPostCard.isPictureOrVideo)
    }

    /// "Add to Post". The files go on the opening message and leave the composer; the
    /// words stay in it, as Discord's do, because nothing has said them yet.
    func addMediaToPost() async {
        guard let prompt = forumAddMediaPrompt, !prompt.isUploading else { return }
        forumAddMediaPrompt?.isUploading = true
        forumAddMediaPrompt?.failure = nil
        do {
            let updated = if LaunchOptions.current.usesDemoFixtures {
                try await DemoFixtures.addMediaToPost(prompt.files, postID: prompt.postID, model: self)
            } else {
                try await sessionController.addMedia(prompt.files, toPost: prompt.postID)
            }
            mutateBox(prompt.postID) { box in
                box.upsert(updated)
                box.attachments = []
                box.attachmentRefusal = nil
            }
            messageContentRevision &+= 1
            applyOpenerUpdated(updated)
            forumAddMediaPrompt = nil
        } catch {
            forumAddMediaPrompt?.isUploading = false
            forumAddMediaPrompt?.failure = SessionController.describe(error)
        }
    }

    /// The post as its row would show it with the files on it: what the prompt draws.
    func forumAddMediaPreview(_ prompt: ForumAddMediaPrompt) -> ForumPostPresentation? {
        guard let forumID = channelIndex[prompt.postID]?.parentID else { return nil }
        let board = forumPresentation(for: forumID)
        guard var row = (board.posts + board.olderPosts).first(where: { $0.id == prompt.postID }) else { return nil }
        row.media = prompt.files
            .filter { $0.isImage || $0.isVideo }
            .prefix(1)
            .map { ForumPostMedia(url: $0.url, isSpoiler: $0.isSpoiler, isVideo: $0.isVideo) }
        return row
    }

    // MARK: Guidelines

    /// Whether a post's card opens with the guidelines showing: the first post in
    /// a forum, as Discord's `hasSeen` keeps it.
    func hasSeenForumGuidelines(in channelID: ChannelID) -> Bool {
        (UserDefaults.standard.array(forKey: Self.seenGuidelinesKey) as? [String])?
            .contains(String(channelID.rawValue)) ?? false
    }

    func markForumGuidelinesSeen(in channelID: ChannelID) {
        var seen = UserDefaults.standard.array(forKey: Self.seenGuidelinesKey) as? [String] ?? []
        guard !seen.contains(String(channelID.rawValue)) else { return }
        seen.append(String(channelID.rawValue))
        UserDefaults.standard.set(seen, forKey: Self.seenGuidelinesKey)
    }

    private static var seenGuidelinesKey: String { "forum.seenGuidelines" }

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
        // Anything waiting comes in with it, as Discord's `RESORT_THREADS` does:
        // the reader's own post at the top of an otherwise frozen board isn't what
        // the board now looks like.
        refreshForumOrder(channelID)
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
        if replacing { refreshForumOrder(channelID) }

        applyThreadPeople(users: page.authors, members: page.members, guildID: channelIndex.guildID(of: channelID))
        for membership in page.memberships { threadMemberships[membership.id] = membership }

        threadRevision &+= 1
        sidebarRevision &+= 1
    }

    /// A forum's live posts, straight into the index.
    ///
    /// **No board order is written here.** `browseOrder` reads the live threads
    /// out of the index and puts them in front of the archived pages, so this
    /// only has to make them *known* — which is also what makes the same rows
    /// arrive correctly when the gateway supplies them instead.
    func applyActiveThreads(_ page: ForumPage, in channelID: ChannelID) {
        guard !page.posts.isEmpty else { return }
        var board = forumBoard(for: channelID)
        for post in page.posts { channelIndex.upsertThread(post) }
        board.firstMessages.merge(page.firstMessages) { _, new in new }
        forumBoards[channelID] = board

        applyThreadPeople(
            users: page.authors,
            members: page.members,
            guildID: channelIndex.guildID(of: channelID)
        )
        for membership in page.memberships { threadMemberships[membership.id] = membership }
        refreshForumOrder(channelID)
        requestForumUnreads(in: channelID)
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

    /// - Parameter requested: every post asked about — answered for whether or
    ///   not the reply carried its opening message.
    func applyForumPostDetails(
        _ details: [ChannelID: ForumPostDetail],
        requested: [ChannelID],
        in channelID: ChannelID
    ) {
        var board = forumBoard(for: channelID)
        var authors: [UserID: User] = [:]
        for (postID, detail) in details {
            if let message = detail.firstMessage { board.firstMessages[postID] = message }
            if let author = detail.author { authors[author.id] = author }
        }
        board.detailsAnswered.formUnion(requested)
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

    // MARK: The head of a thread's transcript

    /// Which of Discord's heads a transcript opens with (`aE`): a forum post's
    /// title and tags, a thread's "Started by", or a channel's welcome.
    func channelHead(for channel: Channel) -> ChannelHead {
        switch channel.kind {
        case .directMessage: return directMessageHead(channel)
        case .groupDirectMessage:
            return .groupDirectMessage(iconURL: channel.iconHash.flatMap {
                CDN.channelIcon(channelID: channel.id, hash: $0, side: 80)
            })
        default: break
        }
        guard channel.kind.isThread else { return .channel }
        let parent = channel.parentID.flatMap { channelIndex[$0] }
        if ThreadGate.isForumPost(channel, parent: parent) {
            let tagsByID = Dictionary(
                (parent?.availableTags ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
            )
            return .post(
                tags: channel.appliedTags.compactMap { tagsByID[$0] },
                openerDeleted: isOpenerDeleted(channel)
            )
        }
        let owner = channel.ownerID.flatMap { ownerID -> String? in
            let user = users[ownerID]
            let member = channel.guildID.flatMap { members[$0]?[ownerID] }
            return member?.resolvedName(user: user) ?? user?.preferredName
        }
        return .thread(startedBy: owner, isPrivate: channel.kind == .privateThread)
    }

    /// Discord's head of a direct message (`aS`, `sc`, `af`): the person,
    /// the servers in common, and the controls their relationship calls for
    /// (`au`, `ad`) — or Discord's own sentence for its system account.
    private func directMessageHead(_ channel: Channel) -> ChannelHead {
        guard let partner = channel.recipientIDs.first(where: { $0 != currentUserID }) else {
            return .directMessage(DirectMessageHead(
                avatarURL: nil, monogram: "?", username: nil, incomingRequestFrom: nil,
                mutualIcons: [], mutualCount: 0, actions: []
            ))
        }
        let user = users[partner]
        let avatar = avatarURL(forUserID: partner, inGuild: nil, side: 80)
        if user?.isSystem == true { return .systemDirectMessage(avatarURL: avatar) }

        let relationship = isBlocked(partner) ? .blocked : relationship(with: partner)
        let actions: [HeadAction] = if user?.isBot == true {
            // An app is not befriended or blocked from here. Discord's own
            // (`sJ`): Mute and Deauthorize on a grant the reader holds, and
            // Report Spam on its first message.
            appHeadActions(in: channel, app: partner)
        } else {
            switch relationship {
            case .friend: [.removeFriend, .block]
            case .blocked: [.unblock]
            case .incomingRequest: [.acceptRequest, .ignoreRequest, .block]
            case .outgoingRequest: [.friendRequestSent, .block]
            case .none: [.addFriend, .block]
            }
        }
        let mutual = user?.decoration?.mutualGuilds ?? []
        let username = user?.username
        return .directMessage(DirectMessageHead(
            avatarURL: avatar,
            monogram: user?.monogram ?? "?",
            // Under the name — once, not twice for somebody with no other.
            username: username == displayName(of: channel) ? nil : username,
            incomingRequestFrom: relationship == .incomingRequest ? user?.preferredName : nil,
            mutualIcons: mutual.prefix(3).compactMap { entry in
                guard let guild = guilds[entry.id] else { return nil }
                return DirectMessageHead.MutualMark(
                    iconURL: guild.iconHash.flatMap { CDN.guildIcon(guildID: guild.id, hash: $0, side: 20) },
                    monogram: guild.monogram
                )
            },
            mutualCount: mutual.count,
            actions: actions
        ))
    }

    /// An app's controls under its DM head.
    private func appHeadActions(in channel: Channel, app: UserID) -> [HeadAction] {
        var actions: [HeadAction] = []
        if appGrant(for: app) != nil {
            actions = [unreadState(of: channel).muted ? .unmute : .mute, .deauthorize]
        }
        if firstMessage(from: app, in: channel.id) != nil { actions.append(.reportSpam) }
        return actions
    }

    /// The reader's grant to the app behind a bot, if they hold one.
    private func appGrant(for bot: UserID) -> AuthorizedApp? {
        guard let application = users[bot]?.decoration?.application else { return nil }
        return authorizedApps?.first { $0.applicationID == application.id }
    }

    /// The first message somebody sent here, once the history reaches it.
    private func firstMessage(from userID: UserID, in channelID: ChannelID) -> Message? {
        guard let box = messageBoxes[channelID], !box.hasMoreHistory else { return nil }
        return box.messages.first { $0.authorID == userID }
    }

    /// One of a conversation head's controls.
    func performHeadAction(_ action: HeadAction, in channelID: ChannelID, anchor: CGRect) {
        switch action {
        case .inviteToGroup: groupInvite = channelID; return
        case .editGroup: groupRename = channelID; return
        case .mute: setDirectMessageMuted(.untilTurnedBackOn, channelID: channelID); return
        case .unmute: setDirectMessageMuted(nil, channelID: channelID); return
        default: break
        }
        guard let channel = channelIndex[channelID],
              let partner = channel.recipientIDs.first(where: { $0 != currentUserID })
        else { return }
        switch action {
        case .addFriend, .acceptRequest, .removeFriend: toggleFriend(with: partner)
        case .ignoreRequest: declineFriendRequest(partner)
        case .block: setBlocked(true, userID: partner)
        case .unblock: setBlocked(false, userID: partner)
        case .mutualServers: openProfile(partner, anchor: anchor, depth: .full, tab: .mutuals)
        case .deauthorize: headDeauthorization = appGrant(for: partner)
        case .reportSpam:
            guard let message = firstMessage(from: partner, in: channelID) else { return }
            requestReport(of: message.id, in: channelID, isFirstDirectMessage: true)
        case .friendRequestSent, .inviteToGroup, .editGroup, .mute, .unmute: break
        }
    }

    /// Whether a post's opening message is known to be gone: `post-data`
    /// answered without it, or the transcript reaches the post's start and it
    /// is not there. Its id is the post's own.
    func isOpenerDeleted(_ post: Channel) -> Bool {
        if let forumID = post.parentID, let board = forumBoards[forumID],
           board.detailsAnswered.contains(post.id)
        {
            return board.firstMessages[post.id] == nil
        }
        guard let box = messageBoxes[post.id], !box.hasMoreHistory, !box.messages.isEmpty else { return false }
        return !box.messages.contains { $0.id.rawValue == post.id.rawValue }
    }

    // MARK: A post's bar

    /// Discord's bar under a forum post's opening message (`rg`), or nil for
    /// anything that is not a post.
    func postActions(for channelID: ChannelID) -> PostActions? {
        guard let post = channelIndex[channelID],
              ThreadGate.isForumPost(post, parent: post.parentID.flatMap { channelIndex[$0] })
        else { return nil }
        let openerID = MessageID(rawValue: channelID.rawValue)
        let opener = message(openerID, in: channelID)
        return PostActions(
            openerID: openerID,
            openerDeleted: isOpenerDeleted(post),
            isFollowing: threadMemberships[channelID] != nil,
            offersFollow: guildPreview?.guildID != post.guildID,
            // Discord's "React to Post" stands in for reactions the opening
            // message does not have yet.
            offersReaction: opener.map { opener in
                opener.reactions.isEmpty && actions(for: openerID, in: channelID).contains(.addReaction)
            } ?? false,
            isLinkCopied: copiedPostLinkID == channelID
        )
    }

    /// One of the bar's buttons. Copy Link says "Copied" for two seconds, as
    /// Discord's does.
    func performPostAction(_ action: PostActionsSlot.Action, postID: ChannelID, anchor: CGRect) {
        switch action {
        case .react:
            openReactionPicker(for: MessageID(rawValue: postID.rawValue), in: postID, anchor: anchor)
        case .follow:
            setThreadFollowed(!followsThread(postID), threadID: postID, location: "Forum Toolbar")
        case .copyLink:
            guard let guildID = channelIndex.guildID(of: postID) else { return }
            Self.copy("https://discord.com/channels/\(guildID.rawValue)/\(postID.rawValue)")
            copiedPostLinkID = postID
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, copiedPostLinkID == postID else { return }
                copiedPostLinkID = nil
            }
        }
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

    /// - Parameter isNewlyCreated: the gateway's `newly_created`, which is the only
    ///   thing that says a post didn't exist a moment ago. Somebody else's waits
    ///   behind the board's "N New Posts", as Discord's `THREAD_CREATE` handler has it,
    ///   and it starts a count of its own.
    func applyThreadUpsert(_ thread: Channel, membership: ThreadMember?, isNewlyCreated: Bool = false) {
        channelIndex.upsertThread(thread)
        if let membership { threadMemberships[membership.id] = membership }
        if isNewlyCreated, let parentID = thread.parentID, channelIndex[parentID]?.isForumLike == true {
            forumPostUnreadCounts[thread.id] = 0
            if thread.ownerID != currentUserID, forumBoards[parentID] != nil {
                forumBoards[parentID]?.waitingPostIDs.insert(thread.id)
            }
        }
        permissionGate.invalidate()
        threadRevision &+= 1
        sidebarRevision &+= 1
    }

    /// A post's opening message is gone — its id is the post's own. The card
    /// then says so, as Discord's does, rather than keeping a preview of words
    /// that no longer exist.
    func applyOpenerDeleted(_ messageID: MessageID, in channelID: ChannelID) {
        guard messageID.rawValue == channelID.rawValue,
              let forumID = channelIndex[channelID]?.parentID,
              var board = forumBoards[forumID]
        else { return }
        board.firstMessages[channelID] = nil
        board.detailsAnswered.insert(channelID)
        forumBoards[forumID] = board
        threadRevision &+= 1
    }

    /// A post's opening message changed. Merged as a transcript merges one, since an
    /// edit arrives partial: what the board shows of it is otherwise what it said
    /// when the board opened.
    func applyOpenerUpdated(_ message: Message) {
        guard message.id.rawValue == message.channelID.rawValue,
              let forumID = channelIndex[message.channelID]?.parentID,
              var merged = forumBoards[forumID]?.firstMessages[message.channelID]
        else { return }
        merged.content = message.content
        merged.editedAt = message.editedAt
        merged.flags = message.flags
        if let payload = message.payload { merged.payload = payload }
        forumBoards[forumID]?.firstMessages[message.channelID] = merged
        threadRevision &+= 1
    }

    func applyThreadRemoval(_ threadID: ChannelID) {
        // A thread open as the page leaves the reader in the channel it hung
        // off, not on a page that no longer resolves.
        if selectedChannelID == threadID, let parentID = channelIndex[threadID]?.parentID {
            selectChannel(parentID)
        }
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
        // The board on screen starts over, as Discord's `THREAD_LIST_SYNC` handler
        // has it. The others do when they're next opened.
        if let selected = selectedChannelID, channelIndex[selected]?.isForumLike == true,
           channelIndex.guildID(of: selected) == guildID
        {
            refreshForumOrder(selected)
        }
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
