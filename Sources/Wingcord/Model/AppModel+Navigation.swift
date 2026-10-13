import Foundation
import WingcordCore

// MARK: - Keyboard navigation
//
// Everything a menu command or a key press needs, expressed over the projections
// the window already builds. Nothing here walks the store a second time: the
// sidebar's ordered rows and the rail's ordered items are memoized values, and
// stepping through one is an index arithmetic problem rather than a search.
//
// All of it is a no-op when there is nowhere to go, so a command can be bound
// unconditionally and still be honest — a menu item that is always enabled and
// sometimes silently does nothing is the "control that cannot work" §5.5 warns
// about, so the commands ask `canNavigate` before drawing themselves enabled.

extension AppModel {

    /// The channels the sidebar is currently showing, in its own order.
    ///
    /// Categories and guild actions are skipped: they are not destinations, and a
    /// reader pressing "next channel" twice and landing on a heading in between
    /// has been made to press it three times.
    private var navigableChannelIDs: [ChannelID] {
        sidebarPresentation.rows.compactMap {
            guard case .channel(let channel) = $0 else { return nil }
            return channel.id
        }
    }

    /// Every guild in rail order, folders flattened.
    ///
    /// Flattened rather than folder-aware on purpose: a keyboard step through the
    /// rail should visit every server once, and a collapsed folder that swallowed
    /// four of them would make two of the nine number keys unreachable.
    private var navigableGuildIDs: [GuildID] {
        railItems.flatMap { item -> [GuildID] in
            switch item {
            case .guild(let guild): [guild.id]
            case .folder(let folder): folder.guilds.map(\.id)
            }
        }
    }

    /// Whether any of the commands below would do something.
    var canNavigate: Bool { connectionState == .ready || !railItems.isEmpty }

    /// Moves `offset` channels through the list the sidebar is showing.
    ///
    /// Clamped, not wrapped. Wrapping means the last channel's "next" is the
    /// first, which reads as the list having jumped rather than as having ended.
    func stepChannel(by offset: Int) {
        let channels = navigableChannelIDs
        guard !channels.isEmpty else { return }
        guard let current = selectedChannelID,
              let index = channels.firstIndex(of: current)
        else {
            // Nothing selected yet: the first one going forward, the last going
            // back, so both keys do something useful from a cold start.
            selectChannel(offset >= 0 ? channels[0] : channels[channels.count - 1])
            return
        }
        let next = min(channels.count - 1, max(0, index + offset))
        guard next != index else { return }
        selectChannel(channels[next])
    }

    /// Discord's Navigate between unread channels (⌥⇧↑↓) and its mentions-only
    /// form (⇧⌥⌘↑↓): the next channel the sidebar shows with something unread —
    /// or a mention — wrapping round the list. A muted channel is never one.
    func stepUnreadChannel(by offset: Int, mentionsOnly: Bool) {
        let channels = navigableChannelIDs
        guard !channels.isEmpty else { return }
        let start = selectedChannelID.flatMap { channels.firstIndex(of: $0) } ?? (offset > 0 ? -1 : 0)
        for step in 1...channels.count {
            let index = ((start + offset * step) % channels.count + channels.count) % channels.count
            guard let channel = channelIndex[channels[index]] else { continue }
            let state = unreadState(of: channel)
            guard !state.muted, mentionsOnly ? state.mentions > 0 : state.unread else { continue }
            selectChannel(channel.id)
            return
        }
    }

    /// Discord's Toggle between last server and DMs (⌥⌘→): the direct
    /// messages, or back to the server the reader was in before them.
    func toggleDirectMessages() {
        if let guildID = selectedGuildID {
            guildBeforeDirectMessages = guildID
            selectGuild(nil)
        } else if let guildID = guildBeforeDirectMessages, guilds[guildID] != nil {
            selectGuild(guildID)
        }
    }

    /// Discord's Navigate to current call (⇧⌥⌘V).
    func goToCurrentCall() {
        guard let channelID = connectedVoiceChannelID else { return }
        selectGuild(channelIndex.guildID(of: channelID))
        selectChannel(channelID)
    }

    /// Discord's Mark top inbox channel read (⇧⌘E).
    func markTopInboxChannelRead() {
        guard let channel = unreadInboxChannels().first else { return }
        markRead(channel.id)
    }

    /// Discord's Jump to oldest unread message (⇧PageUp): where the open
    /// channel's unread begins — the new-messages bar's own jump.
    func jumpToOldestUnread() {
        guard let channelID = selectedChannelID,
              let first = newMessagesBanner(in: channelID)?.firstUnread
        else { return }
        sessionController.jumpToMessage(first, in: channelID, highlights: false)
    }

    /// Discord's ⇧⌘A (`151199`): every category in the open server collapsed —
    /// or, when every one already is, every one opened.
    func toggleAllCategories() {
        guard let guildID = selectedGuildID else { return }
        let categories = channelIndex.channelIDs(inGuild: guildID).filter { channelIndex[$0]?.kind == .category }
        if categories.contains(where: { !collapsedCategoryIDs.contains($0) }) {
            collapsedCategoryIDs.formUnion(categories)
        } else {
            collapsedCategoryIDs.subtract(categories)
        }
    }

    /// Moves `offset` servers through the rail, then opens that server.
    func stepGuild(by offset: Int) {
        let guilds = navigableGuildIDs
        guard !guilds.isEmpty else { return }
        guard let current = selectedGuildID,
              let index = guilds.firstIndex(of: current)
        else {
            selectGuild(offset >= 0 ? guilds[0] : guilds[guilds.count - 1])
            return
        }
        let next = index + offset
        // Stepping back off the front lands on the direct-message home, which is
        // a real destination above the first server rather than a wall.
        if next < 0 { selectGuild(nil); return }
        guard next < guilds.count, next != index else { return }
        selectGuild(guilds[next])
    }

    /// ⌘1 through ⌘9. One-based, because the keys are.
    ///
    /// The ninth is the ninth server, not the last — a shortcut whose meaning
    /// changes with how many servers you have joined is one nobody can learn.
    func selectGuild(atOrdinal ordinal: Int) {
        let guilds = navigableGuildIDs
        guard ordinal >= 1, ordinal <= guilds.count else { return }
        selectGuild(guilds[ordinal - 1])
    }

    /// Replies to the newest message in the open channel.
    ///
    /// Bound to Up in an empty composer, where every other chat client puts it.
    /// Returns whether it did anything, so the key press can fall through to the
    /// text view when there is nothing to reply to — swallowing Up in an empty
    /// composer that cannot reply is a dead key.
    @discardableResult
    func replyToLatestMessage() -> Bool {
        guard let channelID = selectedChannelID,
              let latest = messages(in: channelID)?.messages.last
        else { return false }
        mutateBox(channelID) {
            $0.replyingTo = latest.id
            $0.replyPings = latest.authorID != currentUserID
        }
        return true
    }
}
