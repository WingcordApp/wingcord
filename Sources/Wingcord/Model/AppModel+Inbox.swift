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
        var result: [Channel] = []
        for (guildID, _) in guilds {
            guard !mutedGuildIDs.contains(guildID) else { continue }
            for channelID in channelIndex.channelIDs(inGuild: guildID) {
                guard let channel = consider(channelID) else { continue }
                result.append(channel)
                if firstOnly { return result }
            }
        }
        for channelID in channelIndex.privateChannelIDs() {
            guard let channel = consider(channelID) else { continue }
            result.append(channel)
            if firstOnly { return result }
        }
        result.sort { ($0.lastMessageID?.rawValue ?? 0) > ($1.lastMessageID?.rawValue ?? 0) }
        return result
    }

    /// One channel, or nil when it does not belong in the list.
    private func consider(_ channelID: ChannelID) -> Channel? {
        guard !inbox.acknowledgedChannelIDs.contains(channelID),
              let channel = channelIndex[channelID],
              // A category has no messages and a voice room's unread is its
              // text side, which is the channel itself — `isConversation` is
              // what the sidebar uses to decide the same thing.
              channel.kind.isConversation
        else { return nil }
        let state = unreadState(of: channel)
        guard state.unread, !state.muted else { return nil }
        guard permissionGate.canView(channelID) else { return nil }
        return channel
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
            let unread = (messageBoxes[channel.id]?.messages ?? [])
                .filter { $0.id.rawValue > (anchor?.rawValue ?? 0) }
                .prefix(Self.unreadsPerChannel)

            // **One excerpt, not one card per message.** A card stands alone and
            // forces `[.head, .tail]`, so four consecutive lines from one person
            // repeat the avatar, the name and the timestamp four times. The
            // excerpt runs them through `TimelineReducer`, which is the app's
            // one definition of a run.
            let card = MessageCard.excerpt(
                of: Array(unread),
                unreadAnchor: anchor,
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
