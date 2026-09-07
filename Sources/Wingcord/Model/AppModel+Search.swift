import Foundation
import WingcordCore

// MARK: - Searching messages

extension AppModel {

    /// Whether the search panel is the supplementary column right now.
    var isSearchShown: Bool { messageSearch != nil }

    /// What the panel would search if it were opened here.
    ///
    /// A server when one is selected, otherwise the conversation — which is the
    /// same split the two routes have. Nil at Home with nothing open, where
    /// there is nothing to search and the control is therefore not offered.
    var searchScope: MessageSearchScope? {
        if let guildID = selectedGuildID { return .guild(guildID) }
        guard let channelID = selectedChannelID else { return nil }
        return .channel(channelID)
    }

    /// Opens the panel, or closes it if this scope is already open.
    ///
    /// **Reused rather than rebuilt when the scope matches**, so toggling the
    /// control does not throw away a search somebody is halfway through reading.
    func toggleSearch() {
        guard let scope = searchScope else { return }
        if messageSearch?.scope == scope {
            closeSearch()
            return
        }
        messageSearch = MessageSearchState(scope: scope)
    }

    func closeSearch() {
        messageSearch = nil
        sessionController.cancelSearch()
    }

    /// Keeps the panel pointed at what the reader is looking at.
    ///
    /// **Called when the selected server changes, not the channel.** Moving
    /// between channels inside a server must leave the results alone — that is
    /// the whole point of clicking a result — but a panel still showing another
    /// server's hits after the rail moved is a list about somewhere else.
    func searchScopeDidChange() {
        guard let state = messageSearch, let scope = searchScope else {
            if messageSearch != nil { closeSearch() }
            return
        }
        guard state.scope != scope else { return }
        messageSearch = MessageSearchState(scope: scope)
        sessionController.cancelSearch()
    }

    // MARK: Editing

    var searchText: String {
        get { messageSearch?.draft.content ?? "" }
        set { messageSearch?.draft.content = newValue }
    }

    /// Runs what is in the field, from page one.
    ///
    /// **The text is the query.** `from: alex` in the field is an `author_id` on
    /// the wire, not three words to look for — so the field is parsed and
    /// resolved here rather than sent as `content`. See `resolvedQuery(from:)`.
    ///
    /// **Always page one.** A new question with the old page number asks for
    /// results 826–850 of a search that may have twelve, which the route answers
    /// with an empty page — and an empty page reads as "nothing found" rather
    /// than "you are past the end".
    func runSearch() {
        guard let state = messageSearch else { return }
        var query = resolvedQuery(from: state.draft.content)
        query.sort = state.draft.sort
        query.order = state.draft.order
        query.page = 1
        guard !query.isEmpty else { return }
        // The draft keeps the raw text — it is what the field shows — while the
        // resolved query is what goes out and what the answer is checked against.
        messageSearch?.draft = query.keepingText(state.draft.content)
        sessionController.runSearch(query)
    }

    /// The field's text as a query.
    ///
    /// **Unresolvable filters are dropped rather than guessed at.** A roster is
    /// loaded lazily, so `from: someone-not-loaded` is an ordinary thing to
    /// type; sending it as `content` would search for the literal words and
    /// inventing an id would search for the wrong person. The token stays
    /// visible in the field, so nothing is hidden — it simply narrows nothing.
    func resolvedQuery(from text: String) -> MessageSearchQuery {
        guard let scope = searchScope else {
            return MessageSearchQuery(scope: .guild(GuildID(rawValue: 0)))
        }
        // `endsOpen: false` — this is a submission, so a trailing bare `from:`
        // is an unfinished thought rather than the token being edited.
        let parsed = MessageSearchTokenizer.parse(text, endsOpen: false)
        var query = MessageSearchQuery(scope: scope)
        query.content = parsed.content

        for token in parsed.tokens {
            switch token.kind {
            case .from:
                if let id = userID(forHandle: token.value, in: scope) { query.authorIDs.append(id) }
            case .mentions:
                if let id = userID(forHandle: token.value, in: scope) { query.mentionIDs.append(id) }
            case .channel:
                if let id = channelID(named: token.value, in: scope) { query.channelIDs.append(id) }
            case .has:
                if let value = MessageSearchHas(rawValue: token.value.lowercased()) {
                    query.has.insert(value)
                }
            case .pinned:
                switch token.value.lowercased() {
                case "true", "yes": query.isPinned = true
                case "false", "no": query.isPinned = false
                default: break
                }
            case .before, .after, .during:
                guard let date = Self.dateFormatter.date(from: token.value) else { break }
                let clause: MessageSearchDate = switch token.kind {
                case .before: .before(date)
                case .after: .after(date)
                default: .during(date)
                }
                query.dates.append(clause)
            }
        }
        return query
    }

    /// A handle, or a display name, to somebody in this scope.
    ///
    /// The handle first: it is what the suggestion list inserts and what
    /// uniquely names an account. A display name is accepted because somebody
    /// typing by hand will use it, and it is matched case-insensitively.
    private func userID(forHandle handle: String, in scope: MessageSearchScope) -> UserID? {
        let needle = handle.lowercased()
        guard !needle.isEmpty else { return nil }
        let ids: any Sequence<UserID> = switch scope {
        case .guild(let guildID): (members[guildID] ?? [:]).keys
        case .channel(let channelID): channelIndex[channelID]?.recipientIDs ?? []
        }
        if let currentUserID, let me = users[currentUserID],
           me.handle.lowercased() == needle || me.preferredName.lowercased() == needle
        {
            return currentUserID
        }
        for id in ids {
            guard let user = users[id] else { continue }
            if user.handle.lowercased() == needle { return id }
        }
        for id in ids {
            guard let user = users[id] else { continue }
            if user.preferredName.lowercased() == needle { return id }
        }
        return nil
    }

    private func channelID(named name: String, in scope: MessageSearchScope) -> ChannelID? {
        guard case .guild(let guildID) = scope else { return nil }
        let needle = name.lowercased()
        for id in channelIndex.channelIDs(inGuild: guildID) {
            guard let channel = channelIndex[id], channel.kind.isConversation else { continue }
            if displayName(of: channel).lowercased() == needle { return id }
        }
        return nil
    }

    /// Fetches a different page of the search already on screen.
    ///
    /// Built from `submitted`, never from the draft: the page controls belong to
    /// the answer, and paging must not quietly adopt edits nobody asked to run.
    func goToSearchPage(_ page: Int) {
        guard let state = messageSearch, let submitted = state.submitted else { return }
        let next = submitted.onPage(page)
        guard next.page != submitted.page else { return }
        sessionController.runSearch(next)
    }

    /// Applies the sheet's answer and re-runs.
    ///
    /// **The sheet writes tokens back into the field**, because the field is the
    /// query — see `runSearch()`. Keeping a second structured copy beside the
    /// text is how the two end up disagreeing about what is being searched.
    func applySearchFilters(_ query: MessageSearchQuery) {
        guard messageSearch != nil else { return }
        messageSearch?.draft = query.keepingText(render(query))
        runSearch()
    }

    /// A query as the field would show it: the filters as tokens, then the words.
    func render(_ query: MessageSearchQuery) -> String {
        var parts: [String] = []
        for id in query.authorIDs {
            if let handle = users[id]?.handle { parts.append("from: \(handle)") }
        }
        for id in query.mentionIDs {
            if let handle = users[id]?.handle { parts.append("mentions: \(handle)") }
        }
        for id in query.channelIDs {
            if let channel = channelIndex[id] { parts.append("in: \(displayName(of: channel))") }
        }
        for value in query.has.map(\.rawValue).sorted() { parts.append("has: \(value)") }
        if let isPinned = query.isPinned { parts.append("pinned: \(isPinned)") }
        for date in query.dates {
            parts.append("\(date.keyword): \(Self.dateFormatter.string(from: date.day))")
        }
        let content = query.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty { parts.append(content) }
        return parts.joined(separator: " ")
    }

    func setSearchSort(_ sort: MessageSearchSort, order: MessageSearchOrder) {
        guard var state = messageSearch else { return }
        state.draft.sort = sort
        state.draft.order = order
        messageSearch = state
        // Sorting is a property of the answer, so it re-asks immediately rather
        // than waiting for Return — there is nothing to type.
        guard !state.draft.isEmpty else { return }
        runSearch()
    }

    /// Opens a result where it was written.
    ///
    /// **The panel stays open**, which is the point: a search is a list somebody
    /// works through, and closing it on the first result makes them run it again
    /// for the second. `jumpToMessage` selects the channel and asks the
    /// transcript to scroll; neither touches `messageSearch`.
    func openSearchResult(_ messageID: MessageID, in channelID: ChannelID) {
        sessionController.jumpToMessage(messageID, in: channelID)
    }

    // MARK: Presentation

    var searchPresentation: MessageSearchPresentation? {
        guard let state = messageSearch else { return nil }
        var results: [MessageSearchPresentation.Result] = []
        results.reserveCapacity(state.results.count)
        for message in state.results {
            let channel = channelIndex[message.channelID]
            results.append(.init(
                id: message.id,
                message: message,
                channelID: message.channelID,
                channelName: channel.map(displayName(of:)) ?? "unknown",
                channelSymbolName: channel?.kind.symbolName ?? "number",
                // The category above the channel, which is what Discord draws
                // on the right of each group header. Absent for a channel with
                // no parent, and for every DM.
                categoryName: channel?.parentID.flatMap { channelIndex[$0]?.name }
            ))
        }

        return MessageSearchPresentation(
            scopeTitle: scopeTitle(for: state.scope),
            text: state.draft.content,
            results: results,
            totalResults: state.totalResults,
            currentPage: state.currentPage,
            pageCount: state.pageCount,
            activeFilterCount: state.draft.activeFilterCount,
            sort: state.draft.sort,
            order: state.draft.order,
            isLoading: state.isLoading,
            isIndexing: state.isIndexing,
            isDeepIndexing: state.page?.isDeepIndexing ?? false,
            isDirty: state.isDirty,
            hasAnswer: state.hasAnswer,
            failure: state.failure
        )
    }

    /// What the field's prompt names — "Search Forza Official", which is what
    /// Discord's own field says. Falls back to the app's name at Home, where
    /// there is nothing selected to name.
    var searchScopeTitle: String {
        searchScope.map(scopeTitle(for:)) ?? "Wingcord"
    }

    private func scopeTitle(for scope: MessageSearchScope) -> String {
        switch scope {
        case .guild(let guildID):
            guilds[guildID]?.name ?? "this server"
        case .channel(let channelID):
            channelIndex[channelID].map(displayName(of:)) ?? "this conversation"
        }
    }
}

/// What the search panel draws.
struct MessageSearchPresentation: Hashable, Sendable {
    /// The server or conversation being searched, for the field's prompt —
    /// "Search Forza Official", which is what Discord's own field says.
    var scopeTitle: String
    var text: String
    var results: [Result]
    var totalResults: Int
    var currentPage: Int
    var pageCount: Int
    var activeFilterCount: Int
    var sort: MessageSearchSort
    var order: MessageSearchOrder
    var isLoading: Bool
    /// Discord is building the index. Its own state, because it is neither a
    /// failure nor an empty result and reads as both if it is drawn as either.
    var isIndexing: Bool
    /// The guild is being back-filled — results are real but incomplete.
    var isDeepIndexing: Bool
    /// The field has been edited since these results were fetched.
    var isDirty: Bool
    var hasAnswer: Bool
    var failure: String?

    /// One hit, with the channel it was written in.
    ///
    /// **The message travels whole**, not as a rendered string: the panel paints
    /// it with the transcript's own engine so an embed, an attachment, a
    /// forwarded message or a join notice draws exactly as it does in the
    /// channel — which a bespoke "author, time, text" row could never do.
    struct Result: Hashable, Sendable, Identifiable {
        var id: MessageID
        var message: Message
        var channelID: ChannelID
        var channelName: String
        var channelSymbolName: String
        var categoryName: String?
    }
}

// MARK: - Drawing the results

/// One hit, laid out by the transcript's own engine.
///
/// **The card is the real renderer at a narrower width**, which is the whole
/// reason `MessageCard` exists — its own note says "the pinned pane today, a
/// search result tomorrow". A bespoke author/time/text row would draw a blank
/// line for every forward, embed, attachment, poll, sticker and join notice,
/// because those are not text and nothing but the painter knows how to draw
/// them.
struct SearchResultCard: Identifiable, Sendable {
    var id: MessageID { card.id }
    var card: MessageCard
    var channelID: ChannelID
    var channelName: String
    var channelSymbolName: String
    /// The category above the channel, drawn on the right of a group's header
    /// exactly as Discord does. Nil for a channel with no parent, and for a DM.
    var categoryName: String?
}

/// What a set of search cards was laid out against.
struct SearchCardKey: Hashable, Sendable {
    var width: CGFloat
    var revision: UInt64
    /// The query the results belong to. Two searches can return the same
    /// messages in a different order, and the cache has to notice.
    var query: MessageSearchQuery?
}

extension AppModel {

    /// The results, laid out once per width and presentation.
    ///
    /// Mirrors `pinnedCards` deliberately — same memo shape, same one-engine
    /// batch, same `[.head, .tail]` per card, so the two surfaces cannot drift.
    func searchCards(width: CGFloat) -> [SearchResultCard] {
        // **Every observable input is read before the early return.** A memo
        // that returns its cache without touching them registers no dependency,
        // so its reader is never invalidated — §2.
        let state = messageSearch
        let messages = state?.results ?? []
        let revision = PresentationRevision.shared.value
        let key = SearchCardKey(width: width, revision: revision, query: state?.submitted)
        if let searchCardCache,
           searchCardCache.key == key,
           searchCardCache.messages == messages
        {
            return searchCardCache.value
        }
        guard !messages.isEmpty else {
            searchCardCache = (key, messages, [])
            return []
        }

        let style = PresentationRevision.shared.style
        let settings = PresentationRevision.shared.timeline
        let engine = TimelineLayoutEngine(presentationRevision: revision)
        let items = messages.map {
            TimelineItem.message(TimelineMessage(message: $0, flags: [.head, .tail]))
        }
        // One resolve for the whole page rather than one per card: results very
        // often repeat an author, and the lookups are over the same tables.
        let authors = authorInfo(for: items, authorFont: style.authorFont)
        let mentions = mentionContext()

        let value = messages.map { message in
            let channel = channelIndex[message.channelID]
            let name = channel.map(displayName(of:)) ?? "unknown"
            return SearchResultCard(
                card: MessageCard.card(
                    for: message,
                    width: width,
                    engine: engine,
                    style: style,
                    settings: settings,
                    mentions: mentions,
                    // **Each card's own channel**, not the searched one: a hit
                    // carries the channel it was written in, and a card headed
                    // with the wrong one is worse than no header at all.
                    channelName: name,
                    authors: authors
                ),
                channelID: message.channelID,
                channelName: name,
                channelSymbolName: channel?.kind.symbolName ?? "number",
                categoryName: channel?.parentID.flatMap { channelIndex[$0]?.name }
            )
        }
        searchCardCache = (key, messages, value)
        return value
    }
}
