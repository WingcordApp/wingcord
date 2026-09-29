import AppKit
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
        // The summary's mark before the topic's where both begin at one
        // message — the order Discord's stream pushes them in. Empty, which
        // allocates nothing, for nearly every channel.
        var marks: [TimelineMark] = []
        if let summary = summaryMark(in: channelID) { marks.append(summary) }
        if let topic = openTopic, topic.channelID == channelID {
            marks.append(TimelineMark(
                kind: .topic,
                id: topic.topic.id.rawValue,
                title: topic.topic.title,
                startMessageID: topic.topic.startMessageID,
                messageCount: topic.topic.messageCount
            ))
        }
        let key = TimelineMemoKey(
            channelID: channelID,
            messageCount: box?.messages.count ?? 0,
            newestID: box?.messages.last?.id,
            oldestID: box?.messages.first?.id,
            anchor: readState?.lastAcknowledgedID,
            hasMoreHistory: box?.hasMoreHistory ?? false,
            hasMoreNewer: box?.hasMoreNewer ?? false,
            marks: marks,
            failure: box?.historyFailure,
            contentRevision: messageContentRevision
        )
        if let timelineCache, timelineCache.key == key { return timelineCache.value }

        let value = TimelineReducer.rows(
            messages: box?.messages ?? [],
            unreadAnchor: readState?.lastAcknowledgedID,
            mentionedIDs: mentionable,
            hasMoreHistory: box?.hasMoreHistory ?? false,
            hasMoreNewer: box?.hasMoreNewer ?? false,
            marks: marks,
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
    /// - Parameter authorFont: the face names are set in, so a styled one can be
    ///   resolved at the same size. Taken rather than rebuilt, because there is
    ///   exactly one right answer and `MessageTextStyle` already holds it.
    /// - Parameter guildID: the server whose roles, nicknames and per-guild
    ///   avatars these authors are resolved against — **the server the messages
    ///   are IN**, which is not always the one the rail is pointing at.
    ///
    ///   This used to be `selectedChannelID`'s guild, and in the main window the
    ///   two are the same by construction: a direct message is only ever open at
    ///   Home. Three surfaces broke that and the overlay broke it visibly — a
    ///   chat window over a game draws a conversation while a server is
    ///   selected, so every author in that DM wore the selected server's role
    ///   colour, its nickname for them and their per-guild face. The inbox and
    ///   the search pane had the same fault more quietly: both list messages
    ///   from servers other than the open one.
    ///
    ///   Nil means no server — a direct message — and resolves to the account's
    ///   own name, colour and avatar, which is the correct answer there.
    func authorInfo(
        for items: [TimelineItem],
        inGuild guildID: GuildID?,
        authorFont: NSFont
    ) -> [UserID: TimelineLayoutEngine.AuthorInfo] {
        let authorPointSize = authorFont.pointSize
        // Hoisted for the reason the roster's is: an observable read per author
        // is a tracked access per row of the page, for a value that cannot move
        // while one is being laid out.
        let saturation = userColorSaturation
        var result: [UserID: TimelineLayoutEngine.AuthorInfo] = [:]
        let guildRoles = guildID.flatMap { roles[$0] } ?? [:]

        for item in items {
            guard case .message(let message) = item else { continue }
            // **Both the author and whoever the message quotes.** The reply
            // header draws a name, a face and a role colour, and it resolves
            // them from this table — a quoted author left out of it draws
            // "Unknown" over a grey circle on a person the store already knows.
            resolve(message.message.authorID, into: &result)
            // Whoever ran the command, for the "alex used launch" header —
            // which is a *different* person from the app that posted the row.
            if let invoker = message.message.interaction?.userID {
                resolve(invoker, into: &result)
            }
            if let quoted = message.message.reference?.authorID {
                resolve(quoted, into: &result)
            }
        }
        return result

        func resolve(
            _ userID: UserID,
            into result: inout [UserID: TimelineLayoutEngine.AuthorInfo]
        ) {
            guard result[userID] == nil else { return }
            guard let user = users[userID] else {
                result[userID] = TimelineLayoutEngine.AuthorInfo(
                    name: "Unknown",
                    colorValue: nil,
                    avatarURL: nil,
                    monogram: "?",
                    decorationURL: nil,
                    isBot: false
                )
                return
            }
            let member = guildID.flatMap { members[$0]?[userID] }
            // Asked once. The icon and the emoji come off the SAME role — the
            // rule `nameColorRole` already states — and two walks of the role
            // list would be two walks per author per page for one answer.
            let iconRole = member
                .flatMap { RoleResolver.iconRole(of: $0.roleIDs, in: guildRoles) }
            // One role answers for the colour AND the gradient, so a gradient
            // can never be drawn over a different role's colour — the rule
            // `RoleResolver.nameColorRole` states and the roster already
            // follows.
            let coloured = member
                .flatMap { RoleResolver.nameColorRole(of: $0.roleIDs, in: guildRoles) }
            let style = cosmetics(of: user)?.displayNameStyle
            let styleFont = style?.font
            let face = styleFont.flatMap {
                DisplayNameFontRegistry.font($0, size: authorPointSize)
            }
            result[userID] = TimelineLayoutEngine.AuthorInfo(
                name: member?.resolvedName(user: user) ?? user.preferredName,
                colorValue: roleColor(
                    member.flatMap {
                        RoleResolver.nameColorValue(of: $0.roleIDs, in: guildRoles)
                    }
                ),
                avatarURL: avatarURL(
                    forUserID: userID,
                    inGuild: guildID,
                    side: Metrics.avatarMessage
                ),
                monogram: user.monogram,
                decorationURL: cosmetics(of: user)?.avatarDecorationHash
                    .flatMap { CDN.avatarDecoration(hash: $0) },
                isBot: user.isBot,
                // **The tag the roster has always drawn, in the transcript at
                // last.** `primaryGuildTag` and its badge were on the wire and
                // read by two surfaces out of three: the member list and the
                // direct-message list drew the chip and the message header did
                // not. Same fields, same resolution, so a person cannot look
                // like two people in one window.
                tag: cosmetics(of: user)?.primaryGuildTag,
                tagBadgeURL: cosmetics(of: user).flatMap { decoration in
                    guard let guildID = decoration.primaryGuildID,
                          let hash = decoration.primaryGuildBadgeHash
                    else { return nil }
                    return CDN.guildTagBadge(guildID: guildID, hash: hash)
                },
                // **The highest role that HAS an icon**, which is not
                // necessarily their highest role — the same rule the name
                // colour already follows, so a senior plain role cannot blank
                // out a junior decorated one.
                roleIconURL: iconRole.flatMap { role in
                    role.iconHash.flatMap {
                        CDN.roleIcon(
                            roleID: role.id,
                            hash: $0,
                            side: TimelineMetrics.roleIconSide
                        )
                    }
                },
                roleEmoji: iconRole?.unicodeEmoji,
                // Resolved here, on the main actor, and only for authors
                // actually on screen — which is what keeps a face off the
                // registry until somebody who wears it is visible.
                nameFace: face,
                nameTracking: face == nil ? 0 : (styleFont?.letterSpacing ?? 0) * authorPointSize,
                // **A server suppresses the account's own name colours, and
                // lends its role's instead.** That is the rule the member list
                // already states — "a server's enhanced role beats the app's
                // ink" — and the transcript has to match it, or one person
                // reads two different ways in one window depending on which
                // list you point at.
                //
                // So the effect is a **direct-message** thing: there is no role
                // there to be beaten, which is exactly the case this was built
                // for. The styled *face* still carries everywhere, as it does
                // in the roster.
                //
                // Only a style with colours in it, too: nearly every styled
                // account picked a face and left the colour alone, and those
                // already draw correctly through `nameFace`.
                gradient: coloured?.colors
                    .flatMap { RoleColors.wrappedStops($0) }?
                    .map { UserColor.desaturated($0, by: saturation) },
                nameStyle: guildID != nil
                    ? nil
                    : style.flatMap { DisplayNameEffectPainter.paints($0) ? $0 : nil }
            )
        }
    }

    /// Every channel the account knows, named for a chip, and every server's
    /// name.
    ///
    /// **The whole account, and still cheap.** Discord names a link into any
    /// server the reader is in, so a table of the selected server's channels
    /// could not draw its chips. What made the whole account expensive was
    /// rebuilding it with every roster change, and it is not rebuilt then: this
    /// memo keys on the channel tree, the roles and the servers only, and a
    /// mention context rebuilt for anything else hands on the same buffer.
    func linkChannelTable() -> LinkChannelTable {
        let key = LinkTableKey(
            structureRevision: channelIndex.structureRevision,
            roleRevision: roleRevision,
            expressionRevision: expressionRevision
        )
        if let linkTableCache, linkTableCache.key == key { return linkTableCache.value }

        var table = LinkChannelTable()
        table.channels.reserveCapacity(channelIndex.count)
        for channel in channelIndex.allChannels {
            let isConversation = channel.kind == .directMessage
                || channel.kind == .groupDirectMessage
            let parentKind = channel.parentID.flatMap { channelIndex[$0]?.kind }
            table.channels[channel.id] = LinkChannel(
                name: isConversation ? displayName(of: channel) : channel.name,
                guildID: channel.guildID,
                kind: channel.kind,
                canView: isConversation || permissionGate.canView(channel.id),
                isPost: channel.kind.isThread && (parentKind == .forum || parentKind == .media),
                parentID: channel.parentID
            )
        }
        table.guildNames.reserveCapacity(guilds.count)
        for (guildID, guild) in guilds { table.guildNames[guildID] = guild.name }
        linkTableCache = (key, table)
        return table
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
            roleRevision: roleRevision,
            expressionRevision: expressionRevision,
            // A role's colour goes through the reader's role-colour settings
            // and the room's ink, both of which move this.
            presentationRevision: PresentationRevision.shared.value
        )
        if let mentionCache, mentionCache.key == key { return mentionCache.value }

        var context = MentionContext()
        context.selfIDs = mentionableIDs
        // **Every input a laid-out row can name, in the one number the row
        // cache compares.** A row that names a channel or a server has to be
        // rebuilt when either is renamed or its access moves — keyed on the
        // people alone, a renamed channel kept its old chip for the life of the
        // cached row. All four only ever grow, so the weighted sum moves
        // whenever any of them does.
        context.token = identityRevision &* 1_000_003
            &+ channelIndex.structureRevision &* 8_191
            &+ roleRevision &* 131
            &+ expressionRevision
        context.currentGuildID = guildID
        // Shared, not copied: the table is memoized on the channel tree alone.
        let table = linkChannelTable()
        context.channels = table.channels
        context.guildNames = table.guildNames

        // **Every server's roles, keyed by id** — Discord resolves a role
        // mention against the message's own server, and a role id belongs to
        // exactly one. A table of the selected server's drew the inbox, search
        // and every forwarded message from elsewhere as "@role". A few hundred
        // entries on a large account, rebuilt only when this memo misses.
        for table in roles.values {
            for (roleID, role) in table {
                context.roles[roleID] = MentionRole(
                    name: role.name,
                    color: roleColor(role.displayColorValue),
                    gradient: role.colors.flatMap(RoleColors.wrappedStops).flatMap { stops in
                        // The same projection as the flat colour, stop by stop;
                        // nil when the reader has role colours off.
                        let projected = stops.compactMap(roleColor)
                        return projected.count == stops.count ? projected : nil
                    }
                )
            }
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
        historyLoader?(channelID, .older(before: box.messages.first?.id))
    }

    /// Asks for the page below a window cut off from the present. Guarded the
    /// way the page above is, and for the same reason.
    func loadLaterHistory(in channelID: ChannelID) {
        guard var box = messageBoxes[channelID], box.hasMoreNewer, !box.isLoadingNewer,
              !box.newerPageFailed, let last = box.messages.last?.id
        else { return }
        box.isLoadingNewer = true
        setMessages(box, in: channelID)
        historyLoader?(channelID, .newer(after: last))
    }

    /// Takes a transcript to its foot.
    ///
    /// **One entry point for the control, for Escape and for a send**, and it
    /// does one of two things. A window that reaches the present is scrolled —
    /// the coordinator owns that, so this only asks. One cut off from it cannot
    /// be scrolled there: the newest page is fetched in its place, which is
    /// Discord's own `jumpToPresent` (module `148494`) without the cache of
    /// trimmed pages it keeps to skip the fetch.
    func jumpToPresent(in channelID: ChannelID) {
        presentToken &+= 1
        presentRequest = PresentRequest(channelID: channelID, token: presentToken)
        guard var box = messageBoxes[channelID], box.hasMoreNewer else { return }
        box.isLoadingNewer = true
        box.newerPageFailed = false
        setMessages(box, in: channelID)
        historyLoader?(channelID, .present)
    }

    /// Escape's last step in the composer, for the transcript behind it: a
    /// topic's panel goes first, then a transcript cut off from the present
    /// goes back to it — Discord's own last binding (module `92960`).
    ///
    /// - Returns: whether it did anything, so a press that found nothing to
    ///   do can fall through.
    func escapeTranscript(in channelID: ChannelID) -> Bool {
        if let open = openTopic, open.channelID == channelID, open.showsPanel {
            closeTopicPanel()
            return true
        }
        guard messageBoxes[channelID]?.hasMoreNewer == true else { return false }
        jumpToPresent(in: channelID)
        return true
    }

    /// Records whether one transcript is away from its channel's foot. See
    /// `viewersAwayFromFoot`.
    func setTranscript(
        _ channelID: ChannelID,
        isAwayFromFoot: Bool,
        viewer: ObjectIdentifier
    ) {
        if isAwayFromFoot {
            viewersAwayFromFoot[channelID, default: []].insert(viewer)
        } else if viewersAwayFromFoot[channelID]?.remove(viewer) != nil,
                  viewersAwayFromFoot[channelID]?.isEmpty == true
        {
            viewersAwayFromFoot[channelID] = nil
        }
    }

    /// Whether a live message may trim the oldest of this channel's window.
    func mayTrimOldest(in channelID: ChannelID) -> Bool {
        viewersAwayFromFoot[channelID] == nil
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
    /// Moves when a server is added, removed or renamed — the chips name them.
    var expressionRevision: UInt64
    var presentationRevision: UInt64
}

/// What the channel chips' table is built from.
struct LinkTableKey: Hashable, Sendable {
    var structureRevision: UInt64
    /// Whether the reader may open a channel is part of its chip.
    var roleRevision: UInt64
    var expressionRevision: UInt64
}

/// Every channel the account knows, named for a chip, and every server's name.
struct LinkChannelTable: Sendable {
    var channels: [ChannelID: LinkChannel] = [:]
    var guildNames: [GuildID: String] = [:]
}

struct TimelineMemoKey: Hashable, Sendable {
    var channelID: ChannelID
    var messageCount: Int
    var newestID: MessageID?
    var oldestID: MessageID?
    var anchor: MessageID?
    var hasMoreHistory: Bool
    var hasMoreNewer: Bool
    /// The marks themselves, titles included: a refreshed summary re-titles
    /// its mark without anything else here moving.
    var marks: [TimelineMark]
    var failure: String?
    /// Moves when a message's *content* changes without the set changing — an
    /// edit, a reaction, an embed unfurling. Without it, editing a message in
    /// the middle of a page changes nothing the key can see and the transcript
    /// keeps showing the old text.
    var contentRevision: UInt64
}

// MARK: - Messages drawn outside the transcript

extension AppModel {
    /// The channel's pinned messages, laid out as cards.
    ///
    /// **Memoized, because a layout is framesetting.** The pane's body runs
    /// again on every hover of every row in it, and re-laying out fifty pinned
    /// messages per pointer move is exactly the cost the transcript's own row
    /// cache exists to avoid.
    ///
    /// The key carries the *messages*, not their count: a pin whose body was
    /// edited or whose embed unfurled has the same id and a different layout —
    /// the trap `INVARIANTS.md` §2 records against the transcript's first cache.
    /// `Array ==` short-circuits on buffer identity, so the common case is a
    /// pointer compare.
    func pinnedCards(in channelID: ChannelID, width: CGFloat) -> [MessageCard] {
        // **Every observable input is read before the early return.** A memo
        // that returns its cache without touching them registers no dependency,
        // so its reader is never invalidated — §2.
        let messages = pinnedMessages[channelID] ?? []
        let revision = PresentationRevision.shared.value
        let key = PinnedCardKey(channelID: channelID, width: width, revision: revision)
        if let pinnedCardCache,
           pinnedCardCache.key == key,
           pinnedCardCache.messages == messages
        {
            return pinnedCardCache.value
        }
        guard !messages.isEmpty else {
            pinnedCardCache = (key, messages, [])
            return []
        }

        let style = PresentationRevision.shared.style
        let settings = PresentationRevision.shared.timeline
        let engine = TimelineLayoutEngine(presentationRevision: revision)
        let items = messages.map {
            TimelineItem.message(TimelineMessage(message: $0, flags: [.head, .tail]))
        }
        // One resolve for the whole set rather than one per card: the lookups
        // are over the same tables and most pins share authors.
        let authors = authorInfo(
            for: items,
            inGuild: channelIndex.guildID(of: channelID),
            authorFont: style.authorFont
        )
        let mentions = mentionContext()
        let channelName = channelIndex[channelID].map(displayName(of:)) ?? ""
        let value = messages.map { message in
            MessageCard.card(
                for: message,
                width: width,
                engine: engine,
                style: style,
                settings: settings,
                mentions: mentions,
                channelName: channelName,
                authors: authors
            )
        }
        pinnedCardCache = (key, messages, value)
        return value
    }
}

/// What a set of pinned cards was laid out against.
struct PinnedCardKey: Hashable, Sendable {
    var channelID: ChannelID
    var width: CGFloat
    var revision: UInt64
}
