import Foundation
import WingcordCore

// MARK: - Timeline projections

extension AppModel {

    /// The rows for one channel's transcript.
    ///
    /// Memoized on everything that can change the answer. The key is built and
    /// every observable input read **before** the cache is consulted, so a hit
    /// still registers the dependency its reader needs.
    func timelineRows(for channelID: ChannelID) -> [TimelineItem] {
        let box = messageBoxes[channelID]
        let readState = readStates[channelID]
        let mentionable = mentionableIDs
        let key = TimelineMemoKey(
            channelID: channelID,
            messageCount: box?.messages.count ?? 0,
            newestID: box?.messages.last?.id,
            oldestID: box?.messages.first?.id,
            anchor: readState?.lastAcknowledgedID,
            hasMoreHistory: box?.hasMoreHistory ?? false,
            contentRevision: messageContentRevision
        )
        if let timelineCache, timelineCache.key == key { return timelineCache.value }

        let value = TimelineReducer.rows(
            messages: box?.messages ?? [],
            unreadAnchor: readState?.lastAcknowledgedID,
            mentionedIDs: mentionable,
            hasMoreHistory: box?.hasMoreHistory ?? false
        )
        timelineCache = (key, value)
        return value
    }

    /// Everything the layout engine needs about the people in a page.
    ///
    /// Resolved here, once per layout, rather than inside the engine — the
    /// engine is `nonisolated` and must never reach into the store, and doing
    /// the lookups once per page beats doing them once per row.
    func authorInfo(for items: [TimelineItem]) -> [UserID: TimelineLayoutEngine.AuthorInfo] {
        var result: [UserID: TimelineLayoutEngine.AuthorInfo] = [:]
        let guildID = selectedChannelID.flatMap { channelIndex.guildID(of: $0) }
        let guildRoles = guildID.flatMap { roles[$0] } ?? [:]

        for item in items {
            guard case .message(let message) = item else { continue }
            let userID = message.message.authorID
            guard result[userID] == nil else { continue }
            guard let user = users[userID] else {
                result[userID] = TimelineLayoutEngine.AuthorInfo(
                    name: "Unknown",
                    colorValue: nil,
                    avatarURL: nil,
                    monogram: "?",
                    decorationURL: nil,
                    isBot: false
                )
                continue
            }
            let member = guildID.flatMap { members[$0]?[userID] }
            result[userID] = TimelineLayoutEngine.AuthorInfo(
                name: member?.resolvedName(user: user) ?? user.preferredName,
                colorValue: member.flatMap {
                    RoleResolver.nameColorValue(of: $0.roleIDs, in: guildRoles)
                },
                avatarURL: avatarURL(
                    forUserID: userID,
                    inGuild: guildID,
                    side: Metrics.avatarMessage
                ),
                monogram: user.monogram,
                decorationURL: user.decoration?.avatarDecorationHash
                    .flatMap { CDN.avatarDecoration(hash: $0) },
                isBot: user.isBot
            )
        }
        return result
    }

    /// What the text builder needs to turn a mention into a name.
    ///
    /// **The token has to move with every input.** A memo keyed on the message
    /// text alone serves whichever surface rendered it first — so a message
    /// rendered somewhere with no names resolved caches the placeholder form and
    /// the transcript then serves `@user` and `#channel` to everyone, forever.
    func mentionContext() -> MentionContext {
        let guildID = selectedChannelID.flatMap { channelIndex.guildID(of: $0) }
        var context = MentionContext()
        context.selfIDs = mentionableIDs
        context.token = identityRevision

        // Only what this guild needs. Copying every user in the session into
        // this value would make it proportional to the account rather than to
        // the page.
        if let guildID {
            for (roleID, role) in roles[guildID] ?? [:] {
                context.roleNames[roleID] = role.name
                context.roleColors[roleID] = role.displayColorValue
            }
            for channelID in channelIndex.channelIDs(inGuild: guildID) {
                guard let channel = channelIndex[channelID], channel.kind != .category else {
                    continue
                }
                context.channelNames[channelID] = channel.name
            }
        }
        for (userID, user) in users {
            context.userNames[userID] = guildID
                .flatMap { members[$0]?[userID]?.nickname }
                ?? user.preferredName
        }
        return context
    }

    /// Asks for the page of history above what is loaded.
    ///
    /// Guarded rather than debounced: the viewport reports its position on every
    /// scroll tick, and a debounce would either fire late — after the reader has
    /// already reached the end of the content — or repeatedly.
    func loadEarlierHistory(in channelID: ChannelID) {
        guard var box = messageBoxes[channelID], box.hasMoreHistory, !box.isLoadingHistory else {
            return
        }
        box.isLoadingHistory = true
        setMessages(box, in: channelID)
        historyLoader?(channelID, box.messages.first?.id)
    }
}

struct TimelineMemoKey: Hashable, Sendable {
    var channelID: ChannelID
    var messageCount: Int
    var newestID: MessageID?
    var oldestID: MessageID?
    var anchor: MessageID?
    var hasMoreHistory: Bool
    /// Moves when a message's *content* changes without the set changing — an
    /// edit, a reaction, an embed unfurling. Without it, editing a message in
    /// the middle of a page changes nothing the key can see and the transcript
    /// keeps showing the old text.
    var contentRevision: UInt64
}
