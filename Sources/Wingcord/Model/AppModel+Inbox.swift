import Foundation
import WingcordCore
import WingcordNet

// MARK: - The inbox
//
// Five lists and a sixth pane behind one flyout. What is worth knowing before
// reading this file:
//
//  - **Four of the five tabs are one shape.** A time-ordered list of messages,
//    grouped into runs by channel (`InboxGrouping`), each run drawn as a header
//    over `MessageCard`s. `groups(width:)` is the single place that happens.
//  - **Unreads has no route.** It is derived here from `readStates` and the
//    channel index, which the client already holds — so it is instant, and it
//    costs a fetch only for the message bodies of groups the reader scrolls to.
//  - **Bookmarks and Reminders are one fetch.** `GET /users/@me/saved-messages`
//    answers both; `due_at` partitions them.
//  - **Every card is the transcript's own renderer**, at the flyout's width.
//    That is what gives embeds, bot tags, custom emoji, mentions, polls,
//    forwards and attachments for free, and what stops the inbox drifting from
//    the channel it mirrors. See `MessageCard`.

extension AppModel {

    // MARK: Opening and closing

    var isInboxShown: Bool { inbox.isShown }

    func toggleInbox() {
        if inbox.isShown { closeInbox() } else { openInbox() }
    }

    func openInbox() {
        guard !inbox.isShown else { return }
        dismissMessageSurfaces()
        inbox.isShown = true
        // The pane the reader was last on is *not* restored — a flyout that
        // opens onto friend requests because that is where it was left is a
        // surprise every time. The tab is, because Discord persists it.
        inbox.isShowingFriendRequests = false
        loadInboxTab(inbox.tab)
    }

    func closeInbox() {
        guard inbox.isShown else { return }
        inbox.isShown = false
        inbox.discardFetched()
    }

    /// Switches lists, and asks for the one being switched to.
    func selectInboxTab(_ tab: InboxTab) {
        inbox.isShowingFriendRequests = false
        guard inbox.tab != tab else { return }
        inbox.tab = tab
        inbox.revision &+= 1
        loadInboxTab(tab)
        // Remembered for every client on the account. Deliberately not awaited
        // and deliberately not surfaced on failure — see `setInboxTab`.
        sessionController.writeInboxTab(tab)
    }

    func showFriendRequests(_ shown: Bool) {
        guard inbox.isShowingFriendRequests != shown else { return }
        inbox.isShowingFriendRequests = shown
        inbox.revision &+= 1
    }

    /// Asks for a list, once.
    ///
    /// The "absent means not asked" rule lives here rather than in the
    /// controller, so a tab the reader flips back to does not re-request.
    func loadInboxTab(_ tab: InboxTab) {
        guard !inbox.hasLoaded(tab) || inbox.failures[tab] != nil else { return }
        sessionController.loadInbox(tab)
    }

    /// Asks again for a list that refused.
    func retryInboxTab(_ tab: InboxTab) {
        inbox.failures[tab] = nil
        inbox.revision &+= 1
        sessionController.loadInbox(tab)
    }

    // MARK: What each tab is made of

    /// Whether a list is still being fetched **and has nothing to show yet.**
    ///
    /// A refetch over rows that are already on screen must not raise a spinner
    /// in place of them — the reader loses their scroll position and the list
    /// flashes.
    func isInboxLoading(_ tab: InboxTab) -> Bool {
        inbox.loading.contains(tab) && !inbox.hasLoaded(tab)
    }

    func inboxFailure(_ tab: InboxTab) -> String? { inbox.failures[tab] }

    /// The whole current tab, laid out.
    ///
    /// Memoised on everything that can change what it produces. Without the
    /// memo this re-lays every message in the list on every SwiftUI pass — a
    /// pointer moving over one row would re-frameset the whole flyout's ink.
    func inboxGroups(width: CGFloat) -> [InboxGroup] {
        // **Every observable input is read before the early return.** A memo
        // that answers from its cache without touching them registers no
        // dependency, so its reader is never invalidated again — the trap
        // `INVARIANTS.md` §2 records.
        let presentationRevision = PresentationRevision.shared.value
        let key = InboxCardKey(
            tab: inbox.tab,
            showsFriendRequests: inbox.isShowingFriendRequests,
            width: width,
            inboxRevision: inbox.revision,
            presentationRevision: presentationRevision,
            // The transcript's own tables move under these lists: a message
            // edited, an author's name resolved, a channel renamed.
            messageRevision: messageContentRevision,
            identityRevision: identityRevision,
            // **Read states, and leaving it out was a bug.** `MESSAGE_ACK`
            // moves `sidebarRevision` and `railRevision` and nothing else — so
            // a channel the reader marked read on their phone would stay in the
            // Unreads list here until some unrelated counter happened to move.
            // `sidebarRevision` is the one that tracks read state; `railRevision`
            // deliberately does *not* move when a message lands in a guild that
            // is already unread, which makes it the wrong one to key on.
            sidebarRevision: sidebarRevision
        )
        if let inboxCardCache, inboxCardCache.key == key { return inboxCardCache.value }

        let value = buildInboxGroups(width: width, presentationRevision: presentationRevision)
        inboxCardCache = (key, value)
        return value
    }

    private func buildInboxGroups(
        width: CGFloat,
        presentationRevision: UInt64
    ) -> [InboxGroup] {
        switch inbox.tab {
        case .unreads:
            return unreadGroups(width: width, presentationRevision: presentationRevision)
        case .mentions:
            let messages = (inbox.mentions ?? [])
                .filter { !inbox.dismissedMentionIDs.contains($0.id) }
            return messageGroups(
                InboxGrouping.runs(of: messages),
                width: width,
                presentationRevision: presentationRevision
            )
        case .bookmarks, .reminders:
            let list = inbox.saved ?? []
            let selected = inbox.tab == .bookmarks ? list.bookmarks : list.reminders
            return savedGroups(
                InboxGrouping.runs(of: selected),
                width: width,
                presentationRevision: presentationRevision
            )
        case .scheduled:
            return scheduledGroups(inbox.scheduled ?? [])
        }
    }

    // MARK: Unreads — derived, not fetched

    /// Every channel with something unread in it, newest activity first.
    ///
    /// **Three exclusions, and each removes a row that would be noise:**
    ///
    ///  1. **Muted channels and muted servers.** Muting is the reader saying
    ///     they do not want to be told; an inbox that lists them anyway is the
    ///     one place the mute does not hold.
    ///  2. **Channels the reader cannot read.** A stale read state outlives
    ///     losing access, and the row would open onto a refusal.
    ///  3. **Channels acknowledged from here this session**, which have not yet
    ///     been confirmed by the socket.
    ///
    /// Ordered by the channel's newest message — the reader's question is "what
    /// happened most recently", and the channel-list order answers a different
    /// one.
    func unreadInboxChannels() -> [Channel] {
        unreadInboxChannels(firstOnly: false)
    }

    /// **Walked over the channels, not over `readStates`** — and the difference
    /// is a defect a test caught rather than a preference. A channel the reader
    /// has never opened has *no read state at all*, and the sidebar already
    /// counts one with a `lastMessageID` as unread (`unreadState(of:)` returns
    /// `channel.lastMessageID != nil` for a missing entry). Iterating the read
    /// states instead would never visit it, so every channel in a freshly
    /// joined server showed unread on the rail and was invisible in the inbox —
    /// which is exactly the "two definitions of unread" that `ReadState`'s own
    /// note warns about.
    ///
    /// `unreadState(of:)` is that single definition and is what decides here.
    /// The two things it does not know about are added on top: a muted *server*,
    /// and a channel acknowledged from this flyout a moment ago.
    ///
    /// - Parameter firstOnly: stop at the first hit and skip the sort. What
    ///   `canMarkAllInboxRead` needs, and it turns a walk over every channel on
    ///   the account into a walk over a handful — the flyout's header asks that
    ///   question on every pass, including every hover.
    private func unreadInboxChannels(firstOnly: Bool) -> [Channel] {
        var rows: [(channel: Channel, rank: Int)] = []
        // **Conversations first, then the rail — and then a STABLE sort by
        // rank.** The insertion order is what survives inside a rank, which is
        // why the walk and the sort are two steps rather than one comparator.
        for channelID in channelIndex.privateChannelIDs() {
            guard let row = consider(channelID, inGuild: nil) else { continue }
            rows.append(row)
            if firstOnly { return [row.channel] }
        }
        for guildID in orderedGuildIDs {
            for channelID in sidebarOrderedChannelIDs(inGuild: guildID) {
                guard let row = consider(channelID, inGuild: guildID) else { continue }
                rows.append(row)
                if firstOnly { return [row.channel] }
            }
        }
        // `enumerated` keeps it stable: Swift's `sort` is not, and an unstable
        // sort here would reshuffle equal-ranked rows between two identical
        // payloads — the list twitching every time anything moved.
        return rows.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map(\.element.channel)
    }

    /// How long a channel stays in the recent ranks before it sinks.
    private static let inboxRecentWindow: TimeInterval = 2 * 24 * 60 * 60
    private static let inboxStaleWindow: TimeInterval = 10 * 24 * 60 * 60

    /// One channel and the rank it sorts under, or nil when it does not belong.
    ///
    /// **Ported from Discord's own inbox rather than inferred.** Every rule
    /// below is one line of its unread builder, and the four this client had
    /// wrong are marked. The ranks are its own, and they are a *stable* sort
    /// over the rail walk above — which is why a run of one server's channels
    /// stays together.
    ///
    /// ```
    ///  0  a favourited channel
    ///  1  a conversation
    ///  2  mentioned
    ///  3  mentioned, low importance            (not modelled — see below)
    ///  4  quiet, recent, set to All Messages
    ///  5  quiet, recent, anything else
    ///  6  older than two days
    ///  7  set to Nothing
    ///  8  older than ten days
    /// ```
    ///
    /// **The mute is checked before the mention gate**, so a muted channel is
    /// dropped even when somebody named the reader. This client had the
    /// opposite rule on a guess and it was wrong.
    ///
    /// **A conversation needs a mention too**, which is what keeps a chat
    /// nobody is waiting on out: a conversation read years ago has no mentions
    /// left on its read state, so it drops out rather than sitting above the
    /// servers that pinged somebody this morning.
    ///
    /// **A channel with no read cursor falls back to the reader's JOIN DATE**,
    /// and a server with no join date is skipped entirely. That is the whole of
    /// the "unread messages from 2021" fault: with no cursor every message ever
    /// posted counts as unread, so the summary opened on a server's founding
    /// conversation. Nothing before the reader arrived can be unread to them.
    ///
    /// **Rank 3 is folded into rank 2.** Discord separates a low-importance
    /// mention — an `@everyone` — from one that named the reader, and this
    /// client cannot tell them apart: the read state carries a count and not
    /// its provenance. Folding keeps the two adjacent, which is where they
    /// belong, and is the smaller error.
    ///
    /// **One predicate is unresolved.** Discord admits a *quiet* guild channel
    /// when a module this capture does not include answers true for it — which
    /// is what ranks 4 to 8 exist for. Every row observed carried a mention, so
    /// quiet channels are dropped here; if a channel that should be listed is
    /// missing, that predicate is where it went.
    private func consider(
        _ channelID: ChannelID,
        inGuild guildID: GuildID?
    ) -> (channel: Channel, rank: Int)? {
        guard !inbox.acknowledgedChannelIDs.contains(channelID),
              let channel = channelIndex[channelID],
              channel.kind.isConversation
        else { return nil }

        // Guild, category, or the channel itself.
        let muted = mutedGuildIDs.contains(where: { $0 == guildID })
            || notificationPreferences.mutedChannelIDs.contains(channelID)
            || channel.parentID.map(notificationPreferences.mutedChannelIDs.contains) == true
        guard !muted else { return nil }

        let state = unreadState(of: channel)
        guard state.mentions > 0 else { return nil }

        if !channel.kind.isPrivate {
            guard permissionGate.canView(channelID) else { return nil }
        }

        // The cursor, or the day the reader joined.
        let cursor = readStates[channelID]?.lastAcknowledgedID
            ?? guildID.flatMap { guilds[$0]?.joinedAt }.map(MessageID.init(before:))
        guard let cursor, let newest = channel.lastMessageID else { return nil }
        guard newest.rawValue > cursor.rawValue else { return nil }

        return (channel, rank(for: channel, newest: newest, inGuild: guildID))
    }

    private func rank(for channel: Channel, newest: MessageID, inGuild guildID: GuildID?) -> Int {
        if pinnedChannelIDs.contains(channel.id) { return 0 }
        if channel.kind.isPrivate { return 1 }
        // Folded — see `consider`.
        if unreadState(of: channel).mentions > 0 { return 2 }
        let age = Date.now.timeIntervalSince(newest.timestamp)
        if age > Self.inboxStaleWindow { return 8 }
        if age > Self.inboxRecentWindow { return 6 }
        let level = NotificationPolicy.resolvedLevel(
            NotificationPolicy.Subject(
                channelID: channel.id,
                guildID: guildID,
                guildDefault: guildID
                    .flatMap { guilds[$0] }
                    .map { MessageNotificationLevel(guildDefault: $0.defaultMessageNotifications) }
                    ?? .allMessages
            ),
            preferences: notificationPreferences
        )
        switch level {
        case .allMessages: return 4
        case .nothing: return 7
        case .onlyMentions, .inherit: return 5
        }
    }

    /// One guild's channels in the order the **sidebar** draws them.
    ///
    /// **Not `channelIndex.channelIDs(inGuild:)`, which is a flat position
    /// sort.** Discord's Unreads walks a server the way its channel list does:
    /// the uncategorised channels first, then each category followed by its
    /// own. Measured on `CL Studio`, whose eight rows come out
    /// `UPDATES` (no category), then `• HELP •`, then three under
    /// `Server information`, then four under `Roblox Studio` — categories in
    /// order, never interleaved.
    ///
    /// The same one-pass walk `buildGuildSidebar` makes, and it relies on the
    /// same fact: the flat list is already position-sorted, so each bucket
    /// comes out in the order the sidebar would draw it.
    private func sidebarOrderedChannelIDs(inGuild guildID: GuildID) -> [ChannelID] {
        var byParent: [ChannelID?: [ChannelID]] = [:]
        var categories: [ChannelID] = []
        for channelID in channelIndex.channelIDs(inGuild: guildID) {
            guard let channel = channelIndex[channelID] else { continue }
            if channel.kind == .category {
                categories.append(channelID)
            } else {
                byParent[channel.parentID, default: []].append(channelID)
            }
        }
        var ordered = byParent[nil] ?? []
        ordered.reserveCapacity(channelIndex.channelIDs(inGuild: guildID).count)
        for categoryID in categories {
            ordered.append(contentsOf: byParent[categoryID] ?? [])
        }
        return ordered
    }

    /// One channel, or nil when it does not belong in the list.
    ///
    /// **The filter is the notification policy, and that is the whole reason
    /// this tab was a wall of noise.** Every row in Discord's own Unreads
    /// carries a red mention count — six of six in the capture — and that is
    /// not a coincidence about those servers: a large server defaults to
    /// *Only @mentions*, so an unread channel in one earns a place here only
    /// when somebody named the reader. Listing every channel with anything
    /// unread instead put a bot spamming a feed channel above a person asking
    /// a question, and on an account this size that is most of the list.
    ///
    /// `NotificationPolicy.resolvedLevel` is the same resolution the banners
    /// use — channel, then server, then the server's own default, with
    /// `inherit` a step rather than an answer. One definition of "would this
    /// have told me", asked by two surfaces, because two would drift.
    ///
    /// - Parameter guildMuted: whether the whole server is muted. Passed in so
    ///   the caller's loop can keep walking a muted server's channels: **a mute
    ///   silences a channel, it does not hide somebody typing your name.**
    private func consider(_ channelID: ChannelID, guildMuted: Bool) -> Channel? {
        guard !inbox.acknowledgedChannelIDs.contains(channelID),
              let channel = channelIndex[channelID],
              // A category has no messages and a voice room's unread is its
              // text side, which is the channel itself — `isConversation` is
              // what the sidebar uses to decide the same thing.
              channel.kind.isConversation
        else { return nil }
        let state = unreadState(of: channel)
        guard state.unread else { return nil }
        guard permissionGate.canView(channelID) else { return nil }

        // A conversation has no levels at all — Discord offers none — so the
        // mute is its only control, exactly as the policy has it.
        if channel.kind.isPrivate { return state.muted ? nil : channel }

        let named = state.mentions > 0
        guard named || !(state.muted || guildMuted) else { return nil }

        let level = NotificationPolicy.resolvedLevel(
            NotificationPolicy.Subject(
                channelID: channelID,
                guildID: channel.guildID,
                guildDefault: channel.guildID
                    .flatMap { guilds[$0] }
                    .map { MessageNotificationLevel(guildDefault: $0.defaultMessageNotifications) }
                    ?? .allMessages
            ),
            preferences: notificationPreferences
        )
        switch level {
        case .nothing:
            return nil
        case .allMessages:
            return channel
        case .onlyMentions, .inherit:
            // `.inherit` cannot survive `resolvedLevel`; treated as the quieter
            // of the two rather than trapped, for the reason the policy gives.
            return named ? channel : nil
        }
    }

    private func unreadGroups(width: CGFloat, presentationRevision: UInt64) -> [InboxGroup] {
        let channels = unreadInboxChannels()
        guard !channels.isEmpty else { return [] }

        let style = PresentationRevision.shared.style
        let settings = PresentationRevision.shared.timeline
        let engine = TimelineLayoutEngine(presentationRevision: presentationRevision)
        let mentions = mentionContext()

        return channels.enumerated().compactMap { index, channel in
            // **Only what is actually unread, and only what is already loaded.**
            // The bodies come from the transcript's own box when the channel has
            // been opened this session and are fetched otherwise — by the row,
            // when it appears. A tab that fetched every unread channel up front
            // would make sixty requests on open.
            let anchor = readStates[channel.id]?.lastAcknowledgedID
            // **`prefix`, not `suffix` — the OLDEST unread first.** Checked
            // against `unreads.har`: Discord anchors its `?around=` on the read
            // cursor and reads forward from it, so the first thing under the
            // header is the first message the reader has not seen. Taking the
            // last twelve instead shows the newest and silently hides the gap
            // the reader opened the tab to close.
            // **The live box first, the inbox's own copy second.** A channel
            // the reader has open is kept current by the socket, so its box is
            // the better answer; everything else was fetched by the row and
            // lives in `inbox.unreadBodies`, which is outside the transcript's
            // three-slot LRU. Reading only the boxes is what limited this tab
            // to three populated groups at a time.
            let loaded = messageBoxes[channel.id]?.messages.isEmpty == false
                ? (messageBoxes[channel.id]?.messages ?? [])
                : (inbox.unreadBodies[channel.id] ?? [])
            // **Which end of the run to show depends on whether there is a
            // cursor at all, and that is the whole of the 2025 bug.**
            //
            // With a cursor, the first thing the reader has not seen is the
            // right thing to lead with — `prefix`, confirmed against Discord's
            // own inbox, whose first row for a channel acknowledged on the
            // 17th begins on the 18th. Taking the newest instead silently
            // hides the gap the reader opened the tab to close.
            //
            // **Without one there is no position, so there is no "first
            // unread".** Everything in the channel qualifies, and the oldest
            // twelve of everything is the channel's founding conversation —
            // which is how a server that had been busy all week rendered as
            // messages from 2025. The reader's question there is "what
            // happened", and the answer is the recent end.
            let unread: ArraySlice<Message>
            if let anchor {
                unread = loaded
                    .filter { $0.id.rawValue > anchor.rawValue }
                    .prefix(Self.unreadsPerChannel)
            } else {
                unread = loaded.suffix(Self.unreadsPerChannel)
            }

            // **One excerpt, not one card per message.** A card stands alone and
            // forces `[.head, .tail]`, so four consecutive lines from one person
            // repeat the avatar, the name and the timestamp four times. The
            // excerpt runs them through `TimelineReducer`, which is the app's
            // one definition of a run.
            let card = MessageCard.excerpt(
                of: Array(unread),
                // **No unread divider in here, and Discord draws none
                // either.** The red rule plus its NEW pill is the transcript's
                // way of saying "you have read down to this line" in a channel
                // somebody is scrolling. Every message under an inbox header is
                // unread by construction — that is what put the group in this
                // list — so the divider marks the top of every group and says
                // nothing, while claiming the reader has a position in a
                // channel they have not opened. Discord's own inbox shows the
                // day separators and no rule; checked against its Unreads tab.
                unreadAnchor: nil,
                width: width,
                engine: engine,
                style: style,
                settings: settings,
                mentions: mentions,
                mentionedIDs: mentionableIDs,
                channelName: displayName(of: channel),
                authors: authorInfo(
                    for: unread.map {
                        TimelineItem.message(TimelineMessage(message: $0, flags: []))
                    },
                    inGuild: channel.guildID,
                    authorFont: style.authorFont
                )
            )
            return header(
                for: channel,
                occurrence: index,
                rows: card.map {
                    [InboxRow(id: $0.id, card: $0, channelID: channel.id)]
                } ?? []
            )
        }
    }

    /// How many messages one unread channel shows before it is a transcript
    /// rather than a summary. Discord's own inbox caps around here, and past it
    /// the reader should be opening the channel.
    static let unreadsPerChannel = 12

    // MARK: Building a group

    /// A run of independent messages — mentions — each as its own card.
    ///
    /// **Standalone cards here, an excerpt in Unreads**, and the split is what
    /// each tab needs rather than an inconsistency: a mention carries a per-row
    /// action and is usually the only message from its author in the run, so it
    /// earns its own header; an unread channel is a stretch of transcript and
    /// wants the transcript's run grouping.
    private func messageGroups(
        _ runs: [[Message]],
        width: CGFloat,
        presentationRevision: UInt64
    ) -> [InboxGroup] {
        guard !runs.isEmpty else { return [] }
        let style = PresentationRevision.shared.style
        let settings = PresentationRevision.shared.timeline
        let engine = TimelineLayoutEngine(presentationRevision: presentationRevision)
        let mentions = mentionContext()
        var seen: [ChannelID: Int] = [:]
        return runs.compactMap { run in
            guard let first = run.first else { return nil }
            let channelID = first.channelID
            let occurrence = seen[channelID, default: 0]
            seen[channelID] = occurrence + 1
            return header(
                for: channelIndex[channelID],
                fallbackChannelID: channelID,
                occurrence: occurrence,
                rows: cards(
                    for: run,
                    width: width,
                    engine: engine,
                    style: style,
                    settings: settings,
                    mentions: mentions
                )
            )
        }
    }

    private func savedGroups(
        _ runs: [[SavedMessage]],
        width: CGFloat,
        presentationRevision: UInt64
    ) -> [InboxGroup] {
        guard !runs.isEmpty else { return [] }
        let style = PresentationRevision.shared.style
        let settings = PresentationRevision.shared.timeline
        let engine = TimelineLayoutEngine(presentationRevision: presentationRevision)
        let mentions = mentionContext()
        var seen: [ChannelID: Int] = [:]
        return runs.compactMap { run in
            guard let first = run.first else { return nil }
            let channelID = first.saveData.channelID
            let occurrence = seen[channelID, default: 0]
            seen[channelID] = occurrence + 1
            // **Built from the saves, not from the messages.** A save whose
            // message is gone has nothing to lay out and must still be drawn —
            // it is the only place the reader can take the bookmark off.
            let laidOut = cards(
                for: run.compactMap(\.message),
                width: width,
                engine: engine,
                style: style,
                settings: settings,
                mentions: mentions
            )
            let byID = Dictionary(
                laidOut.map { ($0.id, $0.card) },
                uniquingKeysWith: { first, _ in first }
            )
            return header(
                for: channelIndex[channelID],
                fallbackChannelID: channelID,
                occurrence: occurrence,
                rows: run.map { item in
                    InboxRow(
                        id: item.id,
                        card: byID[item.id] ?? nil,
                        channelID: channelID,
                        dueAt: item.saveData.dueAt
                    )
                }
            )
        }
    }

    private func scheduledGroups(_ messages: [ScheduledMessage]) -> [InboxGroup] {
        // **No cards.** A scheduled message has not been sent, so there is no
        // message object for the transcript's renderer to lay out — only the
        // reader's own draft text. The row draws that directly.
        var runs: [[ScheduledMessage]] = []
        for message in messages.upcoming {
            if var last = runs.last, last[0].channelID == message.channelID {
                last.append(message)
                runs[runs.count - 1] = last
            } else {
                runs.append([message])
            }
        }
        var seen: [ChannelID: Int] = [:]
        return runs.compactMap { run in
            guard let first = run.first else { return nil }
            let occurrence = seen[first.channelID, default: 0]
            seen[first.channelID] = occurrence + 1
            return header(
                for: channelIndex[first.channelID],
                fallbackChannelID: first.channelID,
                occurrence: occurrence,
                rows: run.map {
                    InboxRow(
                        id: $0.id,
                        card: nil,
                        channelID: $0.channelID,
                        scheduledAt: $0.scheduledAt,
                        draft: $0.content,
                        failureReason: $0.failureReason
                    )
                }
            )
        }
    }

    /// One standalone card per message.
    ///
    /// - Parameter engine: shared across the whole list, so the pass pays for
    ///   one engine rather than one per group.
    private func cards(
        for messages: [Message],
        width: CGFloat,
        engine: TimelineLayoutEngine,
        style: MessageTextStyle,
        settings: TimelineSettings,
        mentions: MentionContext
    ) -> [InboxRow] {
        guard let channelID = messages.first?.channelID else { return [] }
        // **The channel name is per group, not per list.** The pins pane can
        // resolve one name for its whole set because every pin is in one
        // channel; an inbox spans dozens, and a single name would label every
        // `#channel` chip in the flyout with whichever one came first.
        let channelName = channelIndex[channelID].map(displayName(of:)) ?? ""
        let items = messages.map {
            TimelineItem.message(TimelineMessage(message: $0, flags: [.head, .tail]))
        }
        let authors = authorInfo(
            for: items,
            inGuild: channelIndex.guildID(of: channelID),
            authorFont: style.authorFont
        )
        return messages.map { message in
            InboxRow(
                id: message.id,
                card: MessageCard.card(
                    for: message,
                    width: width,
                    engine: engine,
                    style: style,
                    settings: settings,
                    mentions: mentions,
                    channelName: channelName,
                    authors: authors
                ),
                channelID: message.channelID
            )
        }
    }

    /// The header over a group, with rows the caller has already built.
    private func header(
        for channel: Channel?,
        fallbackChannelID: ChannelID? = nil,
        occurrence: Int,
        rows: [InboxRow]
    ) -> InboxGroup? {
        guard let channelID = channel?.id ?? fallbackChannelID else { return nil }
        return InboxGroup(
            id: InboxGroupID(channelID: channelID, occurrence: occurrence),
            channelID: channelID,
            name: channel.map(displayName(of:)) ?? "Unknown channel",
            symbolName: headerSymbol(for: channel),
            breadcrumb: channel.flatMap(breadcrumb(for:)),
            iconURL: channel.flatMap(headerIcon(for:)),
            monogram: channel.map(headerMonogram(for:)) ?? "?",
            mentionCount: readStates[channelID].map { $0.isMuted ? 0 : $0.mentionCount } ?? 0,
            canOpen: channel != nil,
            rows: rows
        )
    }

    // MARK: What a header says

    /// The glyph beside the name. **Nil for a conversation**, which shows a
    /// face instead — a `#` in front of somebody's name reads as a channel.
    private func headerSymbol(for channel: Channel?) -> String? {
        guard let channel, !channel.kind.isPrivate else { return nil }
        return channel.kind.symbolName
    }

    /// `nice server › nicealts.com`: the server, then the category the channel
    /// sits in. Nil for a direct message, which has neither.
    ///
    /// A thread names its parent rather than its category, because the parent
    /// is the thing the reader would look for.
    private func breadcrumb(for channel: Channel) -> String? {
        guard let guildID = channel.guildID, let guild = guilds[guildID] else { return nil }
        let parentID = channel.parentID
        guard let parent = parentID.flatMap({ channelIndex[$0] }) else { return guild.name }
        return "\(guild.name) › \(displayName(of: parent))"
    }

    /// The server's icon, or the other person's face.
    private func headerIcon(for channel: Channel) -> URL? {
        if let guildID = channel.guildID {
            return guilds[guildID]?.iconHash.flatMap {
                CDN.guildIcon(guildID: guildID, hash: $0, side: Metrics.avatarRow)
            }
        }
        switch channel.kind {
        case .directMessage:
            return channel.recipientIDs.first { $0 != currentUserID }
                .flatMap { users[$0] }
                .flatMap { avatarURL(for: $0, side: Metrics.avatarRow) }
        case .groupDirectMessage:
            return channel.iconHash.flatMap {
                CDN.channelIcon(channelID: channel.id, hash: $0, side: Metrics.avatarRow)
            }
        default:
            return nil
        }
    }

    /// What the plate draws when there is no picture.
    private func headerMonogram(for channel: Channel) -> String {
        if let guildID = channel.guildID, let guild = guilds[guildID] { return guild.monogram }
        let name = displayName(of: channel)
        return name.first.map { String($0).uppercased() } ?? "?"
    }

    // MARK: Acting on a row

    /// Sends the reader to the message, and closes the flyout.
    ///
    /// **Closed rather than left open**, because the thing they asked to look at
    /// is behind it.
    func openInboxRow(_ messageID: MessageID, in channelID: ChannelID) {
        guard canOpen(channelID) else { return }
        closeInbox()
        // **The server first, then the message.** `jumpToMessage` selects the
        // channel but not the guild, so a mention in a server the reader is not
        // standing in would open the transcript with the rail still on the
        // server they came from — the same ordering the quick switcher uses.
        selectGuild(channelIndex.guildID(of: channelID))
        sessionController.jumpToMessage(messageID, in: channelID)
    }

    func openInboxChannel(_ channelID: ChannelID) {
        guard canOpen(channelID) else { return }
        closeInbox()
        selectGuild(channelIndex.guildID(of: channelID))
        selectChannel(channelID)
    }

    /// Takes one mention off the list.
    ///
    /// Optimistic, and put back by the controller if the route refuses — the
    /// row is under the reader's cursor and a dismissal that takes a round trip
    /// to appear reads as the click having missed.
    func dismissMention(_ messageID: MessageID) {
        guard inbox.dismissedMentionIDs.insert(messageID).inserted else { return }
        inbox.revision &+= 1
        sessionController.dismissMention(messageID)
    }

    func revertMentionDismissal(_ messageID: MessageID) {
        inbox.dismissedMentionIDs.remove(messageID)
        inbox.revision &+= 1
    }

    /// Marks one channel read from the inbox.
    func markInboxGroupRead(_ channelID: ChannelID) {
        guard let channel = channelIndex[channelID], let newest = channel.lastMessageID else {
            return
        }
        guard inbox.acknowledgedChannelIDs.insert(channelID).inserted else { return }
        inbox.revision &+= 1
        sessionController.acknowledge(newest, in: channelID)
    }

    /// Marks everything in the Unreads tab read, in one request.
    ///
    /// **One `ack-bulk`, not one ack per channel.** Sixty channels through the
    /// per-channel route is sixty requests through a rate limiter, which is a
    /// visible stall and then a 429.
    func markAllInboxRead() {
        let updates = unreadInboxChannels().compactMap { channel -> ReadStateUpdate? in
            guard let newest = channel.lastMessageID else { return nil }
            return ReadStateUpdate(channelID: channel.id, messageID: newest)
        }
        guard !updates.isEmpty else { return }
        for update in updates { inbox.acknowledgedChannelIDs.insert(update.channelID) }
        inbox.revision &+= 1
        sessionController.acknowledgeAll(updates)
    }

    /// Whether the Unreads tab has anything to mark read — what the header's
    /// tick gates on. A control that cannot do anything must not be offered.
    ///
    /// Short-circuits: this is asked on every pass of the flyout's header, and
    /// the answer is almost always yes on the first channel it looks at.
    var canMarkAllInboxRead: Bool { !unreadInboxChannels(firstOnly: true).isEmpty }

    /// Removes a bookmark or a reminder.
    func removeSavedMessage(_ messageID: MessageID, in channelID: ChannelID) {
        guard inbox.savesInFlight.insert(messageID).inserted else { return }
        // Applied at once. The route answers 204 and the socket echoes
        // `SAVED_MESSAGE_DELETE`; waiting for either leaves the row under the
        // cursor after it was dismissed.
        inbox.saved?.removeAll { $0.id == messageID }
        bookmarkedMessageIDs.remove(messageID)
        inbox.revision &+= 1
        messageContentRevision &+= 1
        sessionController.unsaveMessage(messageID, in: channelID)
    }

    /// Sends a queued message now, rather than at its time.
    ///
    /// **The row goes immediately and does not come back on success**, because
    /// the route's answer is the *sent message*: there is no scheduled record
    /// left for a refetch to find. A refusal restores the list by asking for
    /// it again, which is the only honest way back — the row's place in the
    /// list is decided by `send_at_timestamp` and rebuilding that here would be
    /// a second copy of the ordering rule.
    func sendScheduledMessageNow(_ id: MessageID) {
        guard inbox.savesInFlight.insert(id).inserted else { return }
        inbox.scheduled?.removeAll { $0.id == id }
        inbox.revision &+= 1
        sessionController.sendScheduledMessageNow(id)
    }

    /// Rewrites what a queued message will say.
    ///
    /// **Not applied optimistically.** The other two acts on this row remove
    /// it, where the reader has already seen the outcome they asked for; an
    /// edit leaves the row on screen, so showing the new text before Discord
    /// has taken it would be the one case where a refusal silently leaves a
    /// lie under the cursor. The reply carries the whole element and replaces
    /// the row.
    func editScheduledMessage(_ id: MessageID, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              inbox.scheduled?.first(where: { $0.id == id })?.content != trimmed,
              inbox.savesInFlight.insert(id).inserted
        else { return }
        inbox.revision &+= 1
        sessionController.editScheduledMessage(id, content: trimmed)
    }

    /// Moves when a queued message will be sent.
    func rescheduleScheduledMessage(_ id: MessageID, to date: Date) {
        guard inbox.scheduled?.first(where: { $0.id == id })?.scheduledAt != date,
              inbox.savesInFlight.insert(id).inserted
        else { return }
        inbox.revision &+= 1
        sessionController.rescheduleMessage(id, to: date)
    }

    /// Replaces one row with what the route answered.
    ///
    /// The element both `PATCH` forms reply with is the same one the list
    /// sends, so there is nothing to merge — and re-sorting is left to
    /// `upcoming`, which the projection already applies, so a rescheduled row
    /// moves to its new place without this knowing the ordering rule.
    func applyScheduledMessage(_ message: ScheduledMessage) {
        guard let index = inbox.scheduled?.firstIndex(where: { $0.id == message.id }) else {
            return
        }
        inbox.scheduled?[index] = message
        inbox.revision &+= 1
    }

    /// Cancels a scheduled message.
    func cancelScheduledMessage(_ id: MessageID) {
        guard inbox.savesInFlight.insert(id).inserted else { return }
        inbox.scheduled?.removeAll { $0.id == id }
        inbox.revision &+= 1
        sessionController.cancelScheduledMessage(id)
    }

    // MARK: Quotas

    /// How many reminders the account holds, or nil when the list has never
    /// been fetched. Nil is what makes the gate fail open — see `InboxQuota`.
    var reminderCount: Int? { inbox.saved?.reminders.count }
    var scheduledCount: Int? { inbox.scheduled?.count }

    var canAddReminder: Bool {
        InboxQuota.canAddReminder(current: reminderCount, hasNitro: hasNitro)
    }

    var canAddScheduledMessage: Bool {
        InboxQuota.canAddScheduledMessage(current: scheduledCount, hasNitro: hasNitro)
    }

    /// The line a tab shows when the account is at a cap.
    ///
    /// Nil for a tab with no cap and — crucially — for a list that has not been
    /// fetched: a notice about a limit this client has not measured would be a
    /// claim it cannot support.
    func inboxLimitNotice(for tab: InboxTab) -> String? {
        switch tab {
        case .reminders:
            guard !canAddReminder else { return nil }
        case .scheduled:
            guard !canAddScheduledMessage else { return nil }
        case .unreads, .mentions, .bookmarks:
            return nil
        }
        return InboxQuota.limitMessage(for: tab, hasNitro: hasNitro)
    }

    // MARK: Reminders

    /// Sets a reminder on a message, from the transcript's own menu.
    ///
    /// **The same write as a bookmark with `due_at` set.** One route, one
    /// argument different — which is why this sits beside `toggleBookmark`
    /// rather than in a machinery of its own.
    ///
    /// The clock is read here, at the moment of choosing, and the preset turns
    /// it into a date. A preset that carried its own absolute time would be
    /// stale by however long the menu was open.
    func setReminder(_ preset: ReminderPreset, on messageID: MessageID, in channelID: ChannelID) {
        guard actions(for: messageID, in: channelID).contains(.remindMe) else { return }
        guard canAddReminder else {
            reportActionFailure(
                InboxQuota.limitMessage(for: .reminders, hasNitro: hasNitro)
                    ?? "That reminder could not be set."
            )
            return
        }
        // A reminder implies the message is saved, so the menu must agree at
        // once — otherwise it offers Bookmark Message on something now held.
        bookmarkedMessageIDs.insert(messageID)
        messageContentRevision &+= 1
        // **The fetched list is dropped, not appended to.** Where the new
        // reminder sits is decided by its due date against the others, and
        // rebuilding that here would be a second copy of the ordering rule.
        inbox.saved = nil
        inbox.revision &+= 1
        dismissMessageSurfaces()
        sessionController.writeBookmark(
            true,
            messageID: messageID,
            in: channelID,
            dueAt: preset.dueDate(from: .now)
        )
    }

    /// Moves when a reminder is due, from the inbox's own row.
    ///
    /// **No quota check, unlike `setReminder`.** The cap is on how many
    /// reminders the account holds and this one already exists — refusing to
    /// move a reminder because the account is at its limit would refuse the one
    /// act that cannot make it worse.
    ///
    /// The same `PUT` with the same `due_at` the menu's presets send; Discord
    /// has no separate edit route and the capture shows the save and the move
    /// as one shape — see `saveMessage`.
    func rescheduleReminder(_ messageID: MessageID, in channelID: ChannelID, to date: Date) {
        guard inbox.saved?.first(where: { $0.id == messageID })?.saveData.dueAt != date,
              inbox.savesInFlight.insert(messageID).inserted
        else { return }
        // Dropped rather than patched: where the row sits is decided by its due
        // date against the others, and rebuilding that here would be a second
        // copy of the ordering rule.
        inbox.saved = nil
        inbox.revision &+= 1
        sessionController.writeBookmark(true, messageID: messageID, in: channelID, dueAt: date)
    }

    // MARK: Friend requests

    /// The requests outstanding, incoming first.
    var friendRequests: [FriendRequest] {
        FriendRequest.friendRequests(from: relationships, facts: relationshipFacts)
    }

    /// What the inbox's friend-request button wears.
    var incomingFriendRequestCount: Int {
        FriendRequest.incomingCount(of: relationships)
    }

    /// Accepts an incoming request, or withdraws an outgoing one.
    ///
    /// Both go through `toggleFriend`, which is the one place the four acts on
    /// a relationship are resolved from its current state — a second decision
    /// here would be a second copy of that table.
    func answerFriendRequest(_ userID: UserID, accept: Bool) {
        let current = relationship(with: userID)
        switch (current, accept) {
        case (.incomingRequest, true), (.incomingRequest, false), (.outgoingRequest, false):
            if accept {
                toggleFriend(with: userID)
            } else {
                declineFriendRequest(userID)
            }
        default:
            break
        }
    }

    /// Says no to a request, or cancels one.
    ///
    /// **`DELETE`, which is the same route for both** — Discord has no separate
    /// decline. `toggleFriend` sends it whenever the relationship is not one it
    /// would add to, and an incoming request is one it *would*, so declining
    /// cannot go through it and needs its own path.
    private func declineFriendRequest(_ userID: UserID) {
        let current = relationship(with: userID)
        guard current == .incomingRequest || current == .outgoingRequest else { return }
        guard relationshipsInFlight.insert(userID).inserted else { return }
        relationships[userID] = nil
        relationshipFacts[userID] = nil
        identityRevision &+= 1
        sessionController.writeFriend(false, userID: userID, revertingTo: current)
    }
}

/// What a set of inbox groups was laid out against.
///
/// Every field is something that changes what `buildInboxGroups` produces. A
/// key missing one of them is a memo that answers with stale ink — the trap
/// `INVARIANTS.md` §2 names, and the reason `messageContentRevision` is in here
/// rather than only `inbox.revision`: an edit lands on the transcript's tables,
/// not on the inbox's.
struct InboxCardKey: Hashable {
    var tab: InboxTab
    var showsFriendRequests: Bool
    var width: CGFloat
    var inboxRevision: UInt64
    var presentationRevision: UInt64
    var messageRevision: UInt64
    var identityRevision: UInt64
    var sidebarRevision: UInt64
}
