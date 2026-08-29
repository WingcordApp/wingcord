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
            failure: box?.historyFailure,
            contentRevision: messageContentRevision
        )
        if let timelineCache, timelineCache.key == key { return timelineCache.value }

        let value = TimelineReducer.rows(
            messages: box?.messages ?? [],
            unreadAnchor: readState?.lastAcknowledgedID,
            mentionedIDs: mentionable,
            hasMoreHistory: box?.hasMoreHistory ?? false,
            failure: box?.historyFailure
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
        // Hoisted for the reason the roster's is: an observable read per author
        // is a tracked access per row of the page, for a value that cannot move
        // while one is being laid out.
        let saturation = userColorSaturation
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
                colorValue: member
                    .flatMap { RoleResolver.nameColorValue(of: $0.roleIDs, in: guildRoles) }
                    .map { UserColor.desaturated($0, by: saturation) },
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
        // Read before the cache is consulted, so a hit still registers the
        // dependency its reader needs.
        let key = MentionMemoKey(
            guildID: guildID,
            identityRevision: identityRevision,
            memberRevision: memberRevision,
            structureRevision: channelIndex.structureRevision,
            roleRevision: roleRevision
        )
        if let mentionCache, mentionCache.key == key { return mentionCache.value }

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

        // The DMs as well, so a message link into a conversation can be named.
        //
        // **This table stays the selected guild's plus the DMs, deliberately.**
        // A message link can point anywhere the account can reach, and naming
        // every one of them would mean copying five thousand channel names into
        // a value rebuilt whenever the channel tree, the roster or a role moves
        // — proportional to the account rather than to the page, which is the
        // exact shape this memo exists to avoid. A link into a third server
        // therefore stays a URL rather than becoming a chip, and still navigates
        // in-app when it is clicked: the opener has the whole index in hand and
        // the renderer does not.
        for channelID in channelIndex.privateChannelIDs() {
            guard let channel = channelIndex[channelID] else { continue }
            context.channelNames[channelID] = displayName(of: channel)
            context.directMessageChannelIDs.insert(channelID)
        }
        // **Every user in the session, and this is why it is memoized.**
        //
        // `runLayout` calls this, and `runLayout` runs on every inbound message.
        // Unmemoized, a single message anywhere in the account walked the whole
        // user table — tens of thousands of entries on an account this size —
        // did a per-user member lookup, and built a fresh dictionary of that
        // many strings, all to redraw one row. That is a full table walk several
        // times a second at rest.
        //
        // Nicknames are resolved once here rather than per lookup because the
        // builder is `nonisolated` and cannot reach the store at all.
        context.userNames.reserveCapacity(users.count)
        let guildMembers = guildID.flatMap { members[$0] }
        for (userID, user) in users {
            context.userNames[userID] = guildMembers?[userID]?.nickname ?? user.preferredName
        }

        mentionCache = (key, context)
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
        box.historyFailure = nil
        box.isLoadingHistory = true
        setMessages(box, in: channelID)
        historyLoader?(channelID, box.messages.first?.id)
    }
}

/// What can change a mention's rendered form.
///
/// Deliberately narrow. `messageContentRevision` is NOT here: a message arriving
/// cannot rename anybody, and keying on it would make the memo miss on exactly
/// the event it exists to survive.
struct MentionMemoKey: Hashable, Sendable {
    var guildID: GuildID?
    var identityRevision: UInt64
    var memberRevision: UInt64
    var structureRevision: UInt64
    var roleRevision: UInt64
}

struct TimelineMemoKey: Hashable, Sendable {
    var channelID: ChannelID
    var messageCount: Int
    var newestID: MessageID?
    var oldestID: MessageID?
    var anchor: MessageID?
    var hasMoreHistory: Bool
    var failure: String?
    /// Moves when a message's *content* changes without the set changing — an
    /// edit, a reaction, an embed unfurling. Without it, editing a message in
    /// the middle of a page changes nothing the key can see and the transcript
    /// keeps showing the old text.
    var contentRevision: UInt64
}
