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
        // A server's own page has no inbox in its bar — Discord's has none
        // either — so the shortcut has nothing to open there.
        guard !inbox.isShown, !workspacePresentation.primary.isServerPage else { return }
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
            cardRevision: cardRevision,
            tab: inbox.tab,
            showsFriendRequests: inbox.isShowingFriendRequests,
            width: width,
            inboxRevision: inbox.revision,
            presentationRevision: presentationRevision,
            // The transcript's own tables move under these lists: a message
            // edited, an author's name resolved, a channel renamed.
            messageRevision: messageContentRevision &+ inboundMessageRevision,
            identityRevision: identityRevision,
            // **Read states, and leaving it out was a bug.** `MESSAGE_ACK`
            // moves `sidebarRevision` and `railRevision` and nothing else — so
            // a channel the reader marked read on their phone would stay in the
            // Unreads list here until some unrelated counter happened to move.
            // `sidebarRevision` is the one that tracks read state; `railRevision`
            // deliberately does *not* move when a message lands in a guild that
            // is already unread, which makes it the wrong one to key on.
            sidebarRevision: sidebarRevision &+ readRevision
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

    /// What the Unreads tab lists: a channel, or a server's new scheduled
    /// events.
    enum UnreadEntry {
        case channel(Channel)
        /// Discord's `guild-events` row: the events created after
        /// `oldestRead`, up to `newest`.
        case events(GuildID, oldestRead: UInt64, newest: UInt64)
    }

    /// Every channel the Unreads tab lists, in Discord's order.
    func unreadInboxChannels() -> [Channel] {
        unreadInboxEntries(firstOnly: false).compactMap {
            if case .channel(let channel) = $0 { channel } else { nil }
        }
    }

    /// **Discord's own builder, ported rather than inferred** — the inbox
    /// chunk's walk (`n7`) and filter (`n4`), `7361192fd4542113.js`:
    ///
    /// ```
    /// conversations, then each server in rail order, its channels in the
    /// order its list draws them, each followed by the threads the reader
    /// follows under it, then the server's Events — then a STABLE sort by rank
    /// ```
    ///
    /// The insertion order is what survives inside a rank, which is why the
    /// walk and the sort are two steps rather than one comparator.
    ///
    /// - Parameter firstOnly: stop at the first hit and skip the sort — what
    ///   `canMarkAllInboxRead` asks on every pass of the flyout's header.
    func unreadInboxEntries(firstOnly: Bool) -> [UnreadEntry] {
        var rows: [(entry: UnreadEntry, rank: Int)] = []
        let now = Date.now
        for channelID in channelIndex.privateChannelIDs() {
            guard let row = consider(channelID, inGuild: nil, now: now) else { continue }
            if firstOnly { return [.channel(row.channel)] }
            rows.append((.channel(row.channel), row.rank))
        }
        for guildID in orderedGuildIDs {
            for channelID in sidebarOrderedChannelIDs(inGuild: guildID) {
                if let row = consider(channelID, inGuild: guildID, now: now) {
                    if firstOnly { return [.channel(row.channel)] }
                    rows.append((.channel(row.channel), row.rank))
                }
                for threadID in sidebarThreadIDs(inParent: channelID) {
                    guard let row = consider(threadID, inGuild: guildID, now: now) else { continue }
                    if firstOnly { return [.channel(row.channel)] }
                    rows.append((.channel(row.channel), row.rank))
                }
            }
            // Discord's `guild-events` row, at its own rank of 5.
            if let events = unreadEvents(inGuild: guildID) {
                let entry = UnreadEntry.events(guildID, oldestRead: events.oldestRead, newest: events.newest)
                if firstOnly { return [entry] }
                rows.append((entry, 5))
            }
        }
        // `enumerated` keeps it stable: Swift's `sort` is not, and an unstable
        // sort here would reshuffle equal-ranked rows between two identical
        // payloads — the list twitching every time anything moved.
        return rows.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map(\.element.entry)
    }

    /// A server's events the reader has not seen — Discord's test for the
    /// `guild-events` row: not muted, nor its new events, and the newest event
    /// past the events cursor (or, with no cursor, past the day they joined).
    private func unreadEvents(inGuild guildID: GuildID) -> (oldestRead: UInt64, newest: UInt64)? {
        guard !inbox.acknowledgedEventGuildIDs.contains(guildID),
              !mutedGuildIDs.contains(guildID),
              guildUserSettings[guildID]?.muteScheduledEvents != true,
              let newest = scheduledEvents[guildID]?.lazy.map(\.id).max(),
              let cursor = guildEventAcks[guildID]?.rawValue
                ?? guilds[guildID]?.joinedAt.map({ MessageID(before: $0).rawValue }),
              newest > cursor
        else { return nil }
        return (cursor, newest)
    }

    private static let day: TimeInterval = 24 * 60 * 60

    /// One channel and the rank it sorts under, or nil when it does not belong
    /// — Discord's `n4`, every guard in its order.
    ///
    /// ```
    ///  0  a favourited channel          4  quiet, recent, All Messages
    ///  1  a conversation                5  quiet, recent, anything else
    ///  2  mentioned                     6  older than two days
    ///  3  mentioned, low importance     7  set to Nothing
    ///                                   8  older than ten days
    /// ```
    ///
    /// **Rank 3 is folded into rank 2**: a read state carries a mention count,
    /// not whether the mention was an `@everyone`.
    private func consider(
        _ channelID: ChannelID,
        inGuild guildID: GuildID?,
        now: Date
    ) -> (channel: Channel, rank: Int)? {
        guard !inbox.acknowledgedChannelIDs.contains(channelID),
              let channel = channelIndex[channelID],
              channel.kind.isConversation
        else { return nil }

        // **The mute first**, so a muted channel is dropped even when somebody
        // named the reader. Discord exempts conversations from it.
        if !channel.kind.isPrivate, isMutedForInbox(channel, inGuild: guildID) { return nil }

        let mentions = readStates[channelID]?.mentionCount ?? 0
        if channel.kind.isPrivate {
            guard mentions > 0 else { return nil }
        } else {
            // **The quiet half of the list** — the predicate the last port left
            // open, read out of module `455234`: a channel with nothing naming
            // the reader is listed when it is unread AND its unread setting
            // resolves to All Messages.
            guard mentions > 0 || isQuietlyListed(channel, inGuild: guildID, now: now) else {
                return nil
            }
            guard permissionGate.permissions(in: channelID).contains(.readMessageHistory) else {
                return nil
            }
        }

        guard let cursor = unreadCursor(of: channel, inGuild: guildID),
              let newest = channel.lastMessageID,
              newest.rawValue > cursor.rawValue
        else { return nil }
        return (channel, rank(for: channel, mentions: mentions, newest: newest, inGuild: guildID, now: now))
    }

    /// Where the reader's reading stops: the read cursor, or — for a channel
    /// with none — **the day they joined**, so nothing from before they
    /// arrived counts. A server with no join date has no cursor at all.
    func unreadCursor(of channel: Channel, inGuild guildID: GuildID?) -> MessageID? {
        readStates[channel.id]?.lastAcknowledgedID
            ?? guildID.flatMap { guilds[$0]?.joinedAt }.map(MessageID.init(before:))
    }

    /// The server, the category or the channel — or, for a thread, the
    /// reader's own membership.
    private func isMutedForInbox(_ channel: Channel, inGuild guildID: GuildID?) -> Bool {
        if let guildID, mutedGuildIDs.contains(guildID) { return true }
        if notificationPreferences.mutedChannelIDs.contains(channel.id) { return true }
        if let parent = channel.parentID {
            if notificationPreferences.mutedChannelIDs.contains(parent) { return true }
            // A thread's category is its parent's.
            if channel.kind.isThread,
               let category = channelIndex[parent]?.parentID,
               notificationPreferences.mutedChannelIDs.contains(category)
            {
                return true
            }
        }
        return channel.kind.isThread && threadMemberships[channel.id]?.isMutedNow() == true
    }

    /// Discord's `455234`: unread, and set to count every message.
    private func isQuietlyListed(_ channel: Channel, inGuild guildID: GuildID?, now: Date) -> Bool {
        guard canBeUnread(channel, inGuild: guildID, now: now),
              let newest = channel.lastMessageID,
              let cursor = unreadCursor(of: channel, inGuild: guildID),
              newest.rawValue > cursor.rawValue
        else { return false }
        return resolvedUnreadSetting(of: channel, inGuild: guildID) == .allMessages
    }

    /// Discord's `canBeUnread`: a thread must be one the reader follows; in a
    /// server showing only opted-in channels, a channel quiet for a week
    /// cannot be unread, nor can one the reader has not opted into, read in
    /// the last three days or been named in.
    private func canBeUnread(_ channel: Channel, inGuild guildID: GuildID?, now: Date) -> Bool {
        if channel.kind.isThread { return threadMemberships[channel.id] != nil }
        guard let guildID, hidesUnfollowedChannels(inGuild: guildID) else { return true }
        let lastActivity = channel.lastMessageID?.timestamp ?? .distantPast
        guard now.timeIntervalSince(lastActivity) <= 7 * Self.day else { return false }
        let isOptedIn = followedChannelIDs.contains(channel.id)
            || channel.parentID.map(followedChannelIDs.contains) == true
        guard !isOptedIn else { return true }
        let state = readStates[channel.id]
        let readLately = state?.lastAcknowledgedID
            .map { now.timeIntervalSince($0.timestamp) < 3 * Self.day } ?? false
        return readLately || (state?.mentionCount ?? 0) > 0
    }

    /// Which messages count as unread in a channel — Discord's
    /// `resolveUnreadSetting`, a separate question from which ones notify.
    ///
    /// A conversation, a thread, and every channel of an account still on the
    /// older notification settings count everything. Otherwise the channel's
    /// own choice, then its category's, then the server's, then the server's
    /// notification level: All Messages counts everything, anything else only
    /// mentions.
    func resolvedUnreadSetting(of channel: Channel, inGuild guildID: GuildID?) -> UnreadSetting {
        guard let guildID, !channel.kind.isThread, usesNewNotifications else { return .allMessages }
        let settings = guildUserSettings[guildID]
        if let own = UnreadSetting(channelFlags: settings?.channelOverrides[channel.id]?.flags) {
            return own
        }
        if let parent = channel.parentID,
           let inherited = UnreadSetting(channelFlags: settings?.channelOverrides[parent]?.flags)
        {
            return inherited
        }
        if let flags = settings?.flags {
            if flags & GuildUserSettingsFlags.unreadsAllMessages != 0 { return .allMessages }
            if flags & GuildUserSettingsFlags.unreadsOnlyMentions != 0 { return .onlyMentions }
        }
        return notificationLevel(of: channel, inGuild: guildID) == .allMessages
            ? .allMessages
            : .onlyMentions
    }

    private func notificationLevel(of channel: Channel, inGuild guildID: GuildID?) -> MessageNotificationLevel {
        NotificationPolicy.resolvedLevel(
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
    }

    private func rank(
        for channel: Channel,
        mentions: Int,
        newest: MessageID,
        inGuild guildID: GuildID?,
        now: Date
    ) -> Int {
        if pinnedChannelIDs.contains(channel.id) { return 0 }
        if channel.kind.isPrivate { return 1 }
        if mentions > 0 { return 2 }
        let age = now.timeIntervalSince(newest.timestamp)
        if age > 10 * Self.day { return 8 }
        if age > 2 * Self.day { return 6 }
        // A thread ranks by the reader's own setting on it.
        if channel.kind.isThread {
            let flags = threadMemberships[channel.id]?.flags ?? []
            if flags.contains(.allMessages) { return 4 }
            if flags.contains(.noMessages) { return 7 }
            return 5
        }
        switch notificationLevel(of: channel, inGuild: guildID) {
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
    func sidebarOrderedChannelIDs(inGuild guildID: GuildID) -> [ChannelID] {
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

    private func unreadGroups(width: CGFloat, presentationRevision: UInt64) -> [InboxGroup] {
        let entries = unreadInboxEntries(firstOnly: false)
        guard !entries.isEmpty else { return [] }

        let style = PresentationRevision.shared.style
        let settings = PresentationRevision.shared.timeline
        let engine = TimelineLayoutEngine(presentationRevision: presentationRevision)
        let mentions = mentionContext()

        return entries.enumerated().compactMap { index, entry in
            let channel: Channel
            switch entry {
            case .events(let guildID, let oldestRead, let newest):
                return eventsGroup(guildID, oldestRead: oldestRead, newest: newest, occurrence: index)
            case .channel(let unread):
                channel = unread
            }
            // **Only what is actually unread, and only what is already loaded.**
            // The bodies come from the transcript's own box when the channel has
            // been opened this session and are fetched otherwise — by the row,
            // when it appears. A tab that fetched every unread channel up front
            // would make sixty requests on open.
            let anchor = unreadCursor(of: channel, inGuild: channel.guildID)
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
            // **The box only when it holds the unread part.** A box the
            // transcript filled around an older position — a jump, a search —
            // is not empty and has nothing unread in it, and taking it here
            // drew the header over nothing while the fetch below never ran.
            let box = messageBoxes[channel.id]?.messages ?? []
            let loaded = Self.holdsUnreads(box, after: anchor)
                ? box
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

    /// A server's Events group: the events created since the cursor, oldest
    /// first — Discord's `su`, which draws each as the event's own card.
    private func eventsGroup(
        _ guildID: GuildID,
        oldestRead: UInt64,
        newest: UInt64,
        occurrence: Int
    ) -> InboxGroup? {
        guard let guild = guilds[guildID] else { return nil }
        let events = (scheduledEvents[guildID] ?? [])
            .filter { $0.id > oldestRead && $0.id <= newest }
            .sorted { $0.id < $1.id }
        guard !events.isEmpty else { return nil }
        // Discord keys the row by the server's id standing in for a channel's.
        let channelID = ChannelID(rawValue: guildID.rawValue)
        return InboxGroup(
            id: InboxGroupID(channelID: channelID, occurrence: occurrence),
            channelID: channelID,
            name: "Events",
            symbolName: "calendar",
            breadcrumb: guild.name,
            iconURL: guild.iconHash.flatMap { CDN.guildIcon(guildID: guildID, hash: $0, side: Metrics.avatarRow) },
            monogram: guild.monogram,
            mentionCount: 0,
            canOpen: true,
            rows: [],
            eventsGuildID: guildID,
            events: events
        )
    }

    /// Whether loaded messages reach past the read cursor — the part an
    /// Unreads group shows. With no cursor, any page will do.
    static func holdsUnreads(_ messages: [Message], after anchor: MessageID?) -> Bool {
        guard !messages.isEmpty else { return false }
        guard let anchor else { return true }
        return messages.contains { $0.id.rawValue > anchor.rawValue }
    }

    /// Whether a channel's transcript already holds what its Unreads group
    /// shows, so the group needs no fetch of its own.
    func hasLoadedUnreads(in channelID: ChannelID) -> Bool {
        guard let channel = channelIndex[channelID] else { return false }
        return Self.holdsUnreads(
            messageBoxes.peek(channelID)?.messages ?? [],
            after: unreadCursor(of: channel, inGuild: channel.guildID)
        )
    }

    /// How many messages one unread channel shows before it is a transcript
    /// rather than a summary. Discord's own inbox caps around here, and past it
    /// the reader should be opening the channel.
    static let unreadsPerChannel = 25

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
        let extras = cardExtras
        let guildID = channelIndex.guildID(of: channelID)
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
                    authors: authors,
                    extras: extras,
                    guildID: guildID
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
        // Discord's `markAllRead`: every row, each with its own read-state type.
        let updates = unreadInboxEntries(firstOnly: false).compactMap { entry -> ReadStateUpdate? in
            switch entry {
            case .channel(let channel):
                guard let newest = channel.lastMessageID else { return nil }
                inbox.acknowledgedChannelIDs.insert(channel.id)
                return ReadStateUpdate(channelID: channel.id, messageID: newest)
            case .events(let guildID, _, let newest):
                inbox.acknowledgedEventGuildIDs.insert(guildID)
                guildEventAcks[guildID] = MessageID(rawValue: newest)
                return ReadStateUpdate(
                    channelID: ChannelID(rawValue: guildID.rawValue),
                    messageID: MessageID(rawValue: newest),
                    kind: .guildEvent
                )
            }
        }
        guard !updates.isEmpty else { return }
        inbox.revision &+= 1
        sessionController.acknowledgeAll(updates)
    }

    /// Marks a server's Events group read — a `GUILD_EVENT` acknowledgement of
    /// its newest event, which is what Discord's inbox sends.
    func markInboxEventsRead(_ guildID: GuildID) {
        guard let newest = scheduledEvents[guildID]?.lazy.map(\.id).max(),
              inbox.acknowledgedEventGuildIDs.insert(guildID).inserted
        else { return }
        guildEventAcks[guildID] = MessageID(rawValue: newest)
        inbox.revision &+= 1
        sessionController.acknowledgeAll([ReadStateUpdate(
            channelID: ChannelID(rawValue: guildID.rawValue),
            messageID: MessageID(rawValue: newest),
            kind: .guildEvent
        )])
    }

    /// Shows the rows a refused mark-all-read hid.
    func revertInboxAcknowledgement(of channelIDs: [ChannelID]) {
        inbox.acknowledgedChannelIDs.subtract(channelIDs)
        // An Events row is acknowledged under its server's id.
        inbox.acknowledgedEventGuildIDs.subtract(channelIDs.map { GuildID(rawValue: $0.rawValue) })
        inbox.revision &+= 1
    }

    /// Whether the Unreads tab has anything to mark read — what the header's
    /// tick gates on. A control that cannot do anything must not be offered.
    ///
    /// Short-circuits: this is asked on every pass of the flyout's header, and
    /// the answer is almost always yes on the first channel it looks at.
    var canMarkAllInboxRead: Bool { !unreadInboxEntries(firstOnly: true).isEmpty }

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

    /// Whether a request's note is shown at all — Settings' "Show personalized
    /// messages", and Discord's fallback where it was never set.
    var showsFriendRequestNotes: Bool {
        messagingPrivacy.resolvedShowsFriendRequestNotes(isNSFWAllowed: isNSFWAllowed)
    }

    /// What somebody wrote with their request, if the reader takes those —
    /// Discord's `z` (`420825`).
    func friendRequestNote(of userID: UserID) -> String? {
        guard showsFriendRequestNotes else { return nil }
        return relationshipFacts[userID]?.note
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
    /// Also a direct message head's Ignore Request — see `performHeadAction`.
    func declineFriendRequest(_ userID: UserID) {
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
    /// Fetched extras landing — an invite resolved, a hosted card measured —
    /// see `MessageCardExtras`.
    var cardRevision: UInt64 = 0
    var tab: InboxTab
    var showsFriendRequests: Bool
    var width: CGFloat
    var inboxRevision: UInt64
    var presentationRevision: UInt64
    var messageRevision: UInt64
    var identityRevision: UInt64
    var sidebarRevision: UInt64
}
