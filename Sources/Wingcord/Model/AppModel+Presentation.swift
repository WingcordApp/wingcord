import Foundation
import WingcordCore

// MARK: - Memo keys

struct RailMemoKey: Hashable, Sendable {
    var revision: UInt64
    /// A server with an event happening now wears the calendar mark.
    var eventsRevision: UInt64 = 0
    /// The rail's badges count only channels the reader can see, so a role
    /// change moves the answer.
    var roleRevision: UInt64
    var selectedGuildID: GuildID?
    var expandedFolders: Set<UInt64>
    /// Whether badges are drawn at all. In the KEY, not merely read in the
    /// builder: a memo whose inputs it does not carry is a memo that keeps
    /// answering with the badges the reader just turned off.
    var showsUnreadCounts: Bool
    /// Moves when somebody joins, leaves, or changes a switch in any voice
    /// channel in the account. A tile draws whether there is something to watch
    /// in its server, so the rail depends on it.
    ///
    /// **`voiceRevision`, not the narrower `voicePresenceRevision` the sidebar
    /// uses.** That one moves on a *presence* — what somebody is playing — which
    /// no tile draws; this one moves on a voice state, which is exactly what the
    /// mark is about.
    var voiceRevision: UInt64
    /// A mark counts only rooms the reader can see, so a channel's overwrites
    /// moving can move it.
    var channelStructure: UInt64
    /// A muted server carries no mark, and blocked or ignored people count for
    /// nothing. Small sets, almost always empty, so comparing them is a count.
    var mutedGuildIDs: Set<GuildID>
    var blockedUserIDs: Set<UserID>
    var ignoredUserIDs: Set<UserID>
    /// The application marks on the reader's own servers — the value itself,
    /// which is empty for nearly every account and a handful for the rest.
    var applicationMarks: [GuildID: RailApplicationMark] = [:]
}

struct SidebarMemoKey: Hashable, Sendable {
    /// The events row: whether there is one, its count and its light.
    var eventsRow: SidebarEventsRow?
    /// The Boost progress bar — whether there is one, and its counts. Read from
    /// the experiments as well as the server, which no revision here covers.
    var boostGoal: SidebarBoostGoal? = nil
    var structureRevision: UInt64
    /// The DM list's order IS recency, so it has to key on the revision that
    /// moves when a `lastMessageID` does — the one the guild tree deliberately
    /// ignores. Without it the DM list is built once and never reorders again.
    var valueRevision: UInt64
    var sidebarRevision: UInt64
    /// Permissions decide which channels exist at all in this list, so a role
    /// change has to rebuild it. Leaving this out of the key is how a channel
    /// the reader has just lost access to stays on screen until something
    /// unrelated happens to invalidate the memo.
    var roleRevision: UInt64
    var guildID: GuildID?
    var collapsedCategories: Set<ChannelID>
    /// Moves when the reader follows or unfollows anything. The list is filtered
    /// by it, so it cannot be left out.
    var followRevision: UInt64
    /// Moves when somebody joins or leaves a voice channel. Voice channel rows
    /// draw who is in them, so the list depends on it — and it is a counter of
    /// its own rather than `railRevision`, which moves on every inbound message
    /// in the account and would rebuild the whole tree several times a second.
    var voiceRevision: UInt64
    /// Moves when the presence of somebody **who is in a voice channel** does.
    ///
    /// A voice row draws what its person is playing and the status they set, so
    /// the list depends on presence — but keying it on `presenceRevision` would
    /// rebuild every channel in the server five times a second on a busy
    /// account, for rows that almost never change. This counter moves only when
    /// a flushed presence belongs to somebody sitting in a room, which on most
    /// flushes is nobody. See `SessionController.flushPresences`.
    var voicePresenceRevision: UInt64
    /// Who is talking, which lights a chip under a row. Part of the key for the
    /// same reason the follow set is: the answer is drawn.
    var speakingIDs: Set<UserID>
    /// The selected channel, **but only when it would otherwise be hidden**.
    ///
    /// A channel opened from Browse Channels that the reader has opted out of is
    /// still shown, so the list depends on the selection — but only in that one
    /// case. Carrying the selection unconditionally would rebuild the whole
    /// channel list on every click in it, for an answer that did not change.
    var hiddenSelection: ChannelID?
    /// The rows above the first category. In the KEY because they arrive on
    /// their own routes after the list has already been built once — a memo
    /// that did not carry them would keep answering with the list from before
    /// the guide came back.
    var surfaceRows: [GuildSurface]
    /// Presence, **and only while the direct-message list is the one showing**.
    ///
    /// A DM row draws the other person: their dot, and what they are doing. A
    /// guild's channel rows draw neither, so carrying this unconditionally would
    /// rebuild a five-hundred-channel tree every time anybody in the account
    /// started a game. Zero here is "this list does not depend on presence",
    /// which is the truth for every server.
    var presenceRevision: UInt64
    /// Typing, on the same terms: only the DM list draws it, and only a direct
    /// message's typing moves this — see `AppModel.directMessageTypingRevision`.
    var typingRevision: UInt64
    /// The reader's conversation folders, which only the DM list draws —
    /// `DirectMessageFolders.revision`, zero for a server.
    var folderRevision: UInt64 = 0
    /// The conversations' newest messages, which only the DM list draws.
    var previewRevision: UInt64 = 0
    /// How often this list's own channels have changed read state.
    var readRevision: UInt64 = 0
    /// Names, faces and the Friends row's count: only the conversations draw
    /// them, and until this list stopped being rebuilt for every message in the
    /// account nothing had to say when they changed.
    var identityRevision: UInt64 = 0
    var pendingFriendRequests = 0
}

/// The inputs of a conversation row's preview line.
struct DirectMessagePreviewKey: Equatable {
    var messageID: MessageID
    var editedAt: Date?
    /// The names a mention in it would be drawn with.
    var identityRevision: UInt64
    var structureRevision: UInt64
}

// MARK: - Projections
//
// Each of these builds one surface's value snapshot, memoized.
//
// THE ORDER INSIDE THEM IS LOAD-BEARING. `withObservationTracking` records the
// properties a body actually READ — so a memo that consults its cache first and
// returns early reads nothing observable, registers no dependency, and its
// reader is never invalidated. The symptom is a click that does nothing until
// some unrelated event happens to re-run the view.
//
// Every observable input is therefore read into the key BEFORE the cache is
// consulted, and the key is built unconditionally.

extension AppModel {

    /// The guild rail.
    var railItems: [RailItem] {
        let key = RailMemoKey(
            revision: railRevision,
            eventsRevision: scheduledEventsRevision,
            roleRevision: roleRevision,
            selectedGuildID: selectedGuildID,
            expandedFolders: expandedFolderIDs,
            showsUnreadCounts: AppSettings.shared.showsUnreadCounts,
            voiceRevision: voiceRevision,
            channelStructure: channelIndex.structureRevision,
            mutedGuildIDs: mutedGuildIDs,
            blockedUserIDs: blockedUserIDs,
            ignoredUserIDs: ignoredUserIDs,
            applicationMarks: railApplicationMarks
        )
        // Reading `guilds` and `folders` here — not inside the builder — is what
        // registers the dependency on a cache hit. Arrays and dictionaries are
        // copy-on-write, so a `let` is a retain rather than a copy.
        let guildTable = guilds
        let folderList = folders

        if let railCache, railCache.key == key { return railCache.value }

        let walk = GuildBadgeWalk(model: self)
        let value = Signposts.interval("Server list build") {
            Self.buildRail(
                folders: folderList,
                guilds: guildTable,
                expanded: expandedFolderIDs,
                badge: { guildID in walk.badge(for: guildID) },
                connectedVoiceGuild: connectedVoiceChannelID.flatMap {
                    channelIndex.guildID(of: $0)
                },
                voiceMarks: voiceMarksByGuild,
                applicationMarks: key.applicationMarks
            )
        }
        railCache = (key, value)
        return value
    }

    /// The channel column for the selected guild.
    var sidebarPresentation: SidebarPresentation {
        sidebarPresentation(for: selectedGuildID)
    }

    /// One list: a server's channels, or — for nil — the direct messages.
    ///
    /// **Two memos, one per kind**, because the sidebar's pages show both at
    /// once (REDESIGN.md R8): the conversations on one, the last server opened
    /// on the next, whichever of them holds the selection.
    func sidebarPresentation(for guildID: GuildID?) -> SidebarPresentation {
        let key = SidebarMemoKey(
            eventsRow: guildID.flatMap(sidebarEventsRow(for:)),
            boostGoal: guildID.flatMap(sidebarBoostGoal(for:)),
            structureRevision: channelIndex.structureRevision,
            valueRevision: channelIndex.valueRevision(inGuild: guildID),
            sidebarRevision: sidebarRevision,
            roleRevision: roleRevision,
            guildID: guildID,
            collapsedCategories: collapsedCategoryIDs,
            followRevision: followRevision,
            voiceRevision: voiceRevision,
            voicePresenceRevision: voicePresenceRevision,
            // Only the server with the call in it draws who is talking.
            speakingIDs: guildID != nil && guildID == connectedVoiceChannelID.flatMap { channelIndex.guildID(of: $0) }
                ? speakingUserIDs : [],
            hiddenSelection: hiddenSelectedChannelID,
            surfaceRows: guildID.map(guildSurfaceRows(for:)) ?? [],
            presenceRevision: guildID == nil ? directMessagePresenceRevision : 0,
            typingRevision: guildID == nil ? directMessageTypingRevision : 0,
            folderRevision: guildID == nil ? DirectMessageFolders.shared.revision : 0,
            previewRevision: guildID == nil ? directMessagePreviewRevision : 0,
            readRevision: readRevision(ofList: guildID),
            identityRevision: guildID == nil ? identityRevision : 0,
            pendingFriendRequests: guildID == nil ? FriendRequest.incomingCount(of: relationships) : 0
        )
        let guildTable = guilds
        // Read before the early return, so a cache hit still registers the
        // dependency its reader needs.
        let userTable = users

        let cached = guildID == nil ? homeSidebarCache : sidebarCache
        if let cached, cached.key == key { return cached.value }

        let value: SidebarPresentation
        if let guildID {
            // A guild that is selected but has not arrived yet is a real state
            // during bootstrap. It gets an empty list, not the DM list.
            value = guildTable[guildID].map {
                buildGuildSidebar(guild: $0, eventsRow: key.eventsRow, boostGoal: key.boostGoal)
            } ?? .empty
            sidebarCache = (key, value)
        } else {
            value = Signposts.interval("Conversation list build") {
                buildDirectMessageSidebar(users: userTable)
            }
            homeSidebarCache = (key, value)
        }
        return value
    }

    /// The now bar.
    ///
    /// Not memoized: it is one small struct built from a handful of scalars, and
    /// a memo over it would cost more in key comparison than the build.
    var nowBarPresentation: NowBarPresentation {
        let user = currentUserID.flatMap { users[$0] }
        // **Resolved once, so the three halves of one plate cannot disagree.**
        // The palette used to be read unconditionally while the two URLs were
        // gated, which was harmless only for as long as nothing but the artwork
        // drew it — the bar's material now takes the colour, so a reader who
        // switched the plate off would have kept a violet capsule and lost the
        // picture.
        let plate = AppSettings.shared.showsNameplateInNowBar
            ? user.flatMap { cosmetics(of: $0)?.nameplate }
            : nil
        let worn = user.flatMap { cosmetics(of: $0) }
        return NowBarPresentation(
            userID: currentUserID ?? UserID(rawValue: 0),
            displayName: user?.preferredName ?? "Not signed in",
            handle: user?.handle ?? "",
            avatarURL: user.flatMap { avatarURL(for: $0, side: Metrics.avatarRow) },
            monogram: user?.monogram ?? "?",
            status: selfStatus,
            activityLine: nowBarActivityLine(user: user),
            isMuted: isSelfMuted,
            isDeafened: isSelfDeafened,
            // Offered only when the reader asked for it. The strip is fetched at
            // the bar's own width, which is what keeps a 672-pixel asset from
            // being decoded at CDN size for a 240-point capsule.
            nameplateURL: plate?.artworkURL,
            nameplateAnimatedURL: plate?.animatedArtworkURL,
            nameplatePalette: plate?.palette ?? .none,
            nameStyle: worn?.displayNameStyle,
            tag: worn?.primaryGuildTag,
            tagBadgeURL: worn.flatMap { decoration in
                guard let guildID = decoration.primaryGuildID,
                      let hash = decoration.primaryGuildBadgeHash
                else { return nil }
                return CDN.guildTagBadge(guildID: guildID, hash: hash)
            }
        )
    }

    /// What the detail column is showing.
    ///
    /// **One value, and the detail column is one view type that takes it.** The
    /// split view re-resolves its column widths on a structural detail swap and
    /// steals width from the sidebar every time; with the detail's type held
    /// constant there is no swap to fire on. Anything added later becomes a case
    /// on `Primary`, never a branch in the view builder.
    var workspacePresentation: WorkspacePresentation {
        // **Discovery outranks even the gate.** Everything else in this function
        // answers "what is the selected server showing"; discovery is not about
        // the selected server at all, so nothing below it can be the right
        // answer while it is open — including a gate belonging to a server the
        // reader stepped away from to go looking for another one.
        if isDiscoveryShown {
            return WorkspacePresentation(primary: .discovery, supplementary: nil)
        }
        // A server the reader is not in, picked out of the Pending
        // Applications folder: its page is about the application, and there is
        // no server here to show anything else of.
        if let guildID = shownJoinRequestGuildID {
            return WorkspacePresentation(primary: .joinRequest(guildID), supplementary: nil)
        }
        // The Friends page, on its own.
        if isFriendsShown {
            return WorkspacePresentation(primary: .friends, supplementary: nil)
        }
        // The home's own page, with the request being read beside it.
        if isMessageRequestsShown {
            return WorkspacePresentation(
                primary: .messageRequests,
                // Only while it is still a request: one accepted on another
                // client leaves the page's list, and its preview with it.
                supplementary: previewedChannelID.flatMap {
                    channelIndex[$0]?.messageRequest == nil ? nil : .messageRequestPreview($0)
                }
            )
        }
        // **The gate is checked first, and that is what makes it a gate.** It is
        // the server saying the reader may not use it yet, so it outranks every
        // other answer to "what is this column showing" — including a channel
        // the sidebar still has selected underneath it.
        if let gate = joinGate, gate.guildID == selectedGuildID {
            return WorkspacePresentation(primary: .joinGate(gate.guildID), supplementary: nil)
        }
        // A server page takes the whole column: it is about the server, so
        // there is no roster and no profile that belongs beside it.
        if let openGuildSurface, let guildID = selectedGuildID {
            return WorkspacePresentation(
                primary: .guildSurface(guildID, openGuildSurface),
                // The only things that belong beside a page about the server
                // are a channel the page pointed at and a person it opened in
                // Mod View. There is no roster here — the page is not a
                // conversation — and no profile.
                supplementary: openModViewUserID.map { isSearchShown ? .search : .modView($0) }
                    ?? previewedChannelID.map { .channelPreview($0) }
            )
        }
        guard let channelID = selectedChannelID, let channel = channelIndex[channelID] else {
            return .empty
        }
        let primary: WorkspacePresentation.Primary = switch channel.kind {
        case .forum, .media: .forum(channelID)
        case .voice: .voice(channelID)
        // **A stage is its own pane, not the voice pane with a filter.** Two
        // groups and a queue rather than one group of equals — see
        // `StagePane`.
        case .stage: .stage(channelID)
        default: .conversation(channelID)
        }
        return WorkspacePresentation(
            primary: primary,
            supplementary: supplementary(for: channel)
        )
    }

    /// What sits beside the transcript.
    ///
    /// A server channel offers its roster; a one-to-one conversation offers the
    /// person you are talking to. A group DM offers neither — it has several
    /// people and no roster route, and a pane showing one of them would be
    /// arbitrary.
    private func supplementary(for channel: Channel) -> WorkspacePresentation.Supplementary? {
        // **Mod View takes the column ahead of everything** — Discord opens it
        // as the server's sidebar, closing a thread on the way. Message
        // History is the search panel, which shows over it while it is open.
        if let userID = openModViewUserID, channel.guildID != nil {
            return isSearchShown ? .search : .modView(userID)
        }
        // **A thread being written takes the column**, as Discord's creation
        // sidebar replaces whatever thread was open beside the channel.
        if let newThread, newThread.parentID == channel.id {
            return .newThread(newThread)
        }
        // **An open thread takes the column ahead of everything.** It is the
        // thing the reader just opened, and it is read *beside* the channel it
        // came out of — which is the whole reason it is a column rather than a
        // destination. The roster is one click away again the moment it closes.
        //
        // A thread whose parent is no longer the selected channel is not shown:
        // moving to another channel with the panel open would otherwise leave a
        // thread from somewhere else beside it.
        if let selectedThreadID,
           let thread = channelIndex[selectedThreadID],
           thread.parentID == channel.id
        {
            return .thread(selectedThreadID)
        }
        // A call's column is its chat or nothing — never the roster: you are
        // looking at the people already, in tiles the size of faces, and the
        // thing you cannot see is what anybody wrote. Discord's call view has no
        // member list, so the member toggle's state from a text channel does
        // not follow the reader in here.
        if channel.kind == .voice || channel.kind == .stage {
            if isVoiceChatShown { return .voiceChat(channel.id) }
            return supplementary(orMembers: false)
        }
        if channel.guildID != nil {
            return supplementary(orMembers: isMemberListShown)
        }
        // A group DM has a roster — its recipients — and no single person, so it
        // takes the member list rather than the profile pane. The same toggle
        // drives it, because from the reader's side it is the same control:
        // "show me who is in here".
        if channel.kind == .groupDirectMessage {
            return supplementary(orMembers: isMemberListShown)
        }
        if isDirectMessageProfileShown, channel.kind == .directMessage,
           let partnerID = channel.recipientIDs.first(where: { $0 != currentUserID })
        {
            return supplementary(orMembers: false) ?? .userProfile(partnerID)
        }
        return supplementary(orMembers: false)
    }

    /// Which panel the supplementary column shows.
    ///
    /// **Search outranks the roster, and every other panel.** It is a list
    /// somebody is working through — clicking a hit changes the channel
    /// underneath it, and a column that handed itself back to the member list on
    /// that click would close the search on its first use, which is the one
    /// thing the panel exists not to do.
    private func supplementary(orMembers: Bool) -> WorkspacePresentation.Supplementary? {
        if isSearchShown { return .search }
        return orMembers ? .members : nil
    }

    /// A call can be started here: a conversation, and not one with an app
    /// or with Discord's own account — neither can answer.
    func canStartCall(in channelID: ChannelID) -> Bool {
        guard let channel = channelIndex[channelID], channel.kind.isPrivate else { return false }
        return !channel.recipientIDs.contains { users[$0]?.isBot == true || users[$0]?.isSystem == true }
    }

    /// Who Mod View is open on in the selected server, if anybody.
    var openModViewUserID: UserID? {
        guard let modView, modView.guildID == selectedGuildID else { return nil }
        return modView.userID
    }

    /// The toolbar's channel chrome.
    var channelChrome: ChannelChrome {
        // **The gate has no chrome at all.** It is a takeover, not a page inside
        // the app: naming a channel over it, or offering a roster toggle beside
        // it, describes a window the reader is not in. An empty name is already
        // how the header draws no title — see `DetailHeader`.
        if isColumnTakenOver { return .none }
        // The pill names whatever the column is showing, which on a server page
        // is the page. Its own branch rather than a nil channel, so the bar has
        // a title there instead of a hole its neighbours slide into.
        if let openGuildSurface, selectedGuildID != nil {
            return ChannelChrome(
                channelID: nil,
                name: openGuildSurface.title,
                symbolName: openGuildSurface.symbolName,
                topic: nil,
                isMemberListShown: false,
                canShowMemberList: false,
                isUserProfileShown: false,
                canShowUserProfile: false,
                canShowPins: false,
                arePinsShown: false,
                canShowThreads: false,
                areThreadsShown: false,
                canStartCall: false,
                isInCall: false,
                isCallOngoing: false,
                canShowVoiceChat: false,
                isVoiceChatShown: false
            )
        }
        // The home's own pages are named the same way: what is in the column
        // is the page, not the conversation selected behind it.
        if isFriendsShown || isMessageRequestsShown {
            return ChannelChrome(
                channelID: nil,
                name: isFriendsShown ? "Friends" : "Message Requests",
                symbolName: isFriendsShown ? "person.2.fill" : "envelope.fill",
                topic: nil,
                isMemberListShown: false,
                canShowMemberList: false,
                isUserProfileShown: false,
                canShowUserProfile: false,
                canShowPins: false,
                arePinsShown: false,
                canShowThreads: false,
                areThreadsShown: false,
                canStartCall: false,
                isInCall: false,
                isCallOngoing: false,
                canShowVoiceChat: false,
                isVoiceChatShown: false
            )
        }
        guard let channelID = selectedChannelID, let channel = channelIndex[channelID] else {
            return .none
        }
        // **A call has its own bar.** Discord's channel header has an empty
        // toolbar case for voice and stage channels, and the call view puts back
        // only its call items and Show Chat — no roster (the people are the
        // tiles), no pins, threads or summaries, and no search (`Primary.isCall`).
        let isCall = channel.kind == .voice || channel.kind == .stage
        return ChannelChrome(
            channelID: channelID,
            name: displayName(of: channel),
            parent: channel.kind.isThread
                ? channel.parentID.flatMap { id in
                    channelIndex[id].map {
                        ChannelCrumb(channelID: id, name: displayName(of: $0), symbolName: $0.kind.symbolName)
                    }
                }
                : nil,
            symbolName: channel.kind.symbolName,
            topic: channel.topic,
            isTopicShown: openTopicChannelID == channelID,
            isMemberListShown: isMemberListShown,
            canShowMemberList: !isCall
                && (channel.guildID != nil || channel.kind == .groupDirectMessage),
            isUserProfileShown: isDirectMessageProfileShown,
            canShowUserProfile: channel.guildID == nil && channel.kind == .directMessage,
            // A channel whose history the reader cannot load has pins they
            // cannot read either — the route answers 403, and a control that
            // opens onto a refusal is the inert control §5.5 is about.
            // A board has posts, each with its own pins, and none of its own.
            canShowPins: !isCall && !channel.isForumLike && permissionGate.canReadHistory(channelID),
            arePinsShown: openPinsChannelID == channelID,
            canShowThreads: !isCall && canBrowseThreads(in: channelID),
            areThreadsShown: openThreadsChannelID == channelID,
            // A conversation, not a channel: a guild's voice channel is joined
            // from its own pane, and a text channel has no call to start.
            canStartCall: canStartCall(in: channelID),
            isInCall: connectedVoiceChannelID == channelID,
            // Somebody else is sitting in it. Read from the voice states rather
            // than from `directCalls`, which survives the last person leaving.
            isCallOngoing: connectedVoiceChannelID != channelID
                && voiceStates.values.contains {
                    $0.channelID == channelID && $0.userID != currentUserID
                },
            canShowVoiceChat: channel.kind == .voice || channel.kind == .stage,
            isVoiceChatShown: isVoiceChatShown,
            canShowSummaries: !isCall && summariesApply(to: channelID) && !summaries(in: channelID).isEmpty,
            areSummariesShown: AppSettings.shared.showsSummaryBar
        )
    }

    // MARK: Building

    private static func buildRail(
        folders: [GuildFolder],
        guilds: [GuildID: Guild],
        expanded: Set<UInt64>,
        badge: (GuildID) -> (mentions: Int, unread: Bool, muted: Bool),
        connectedVoiceGuild: GuildID?,
        /// What each server's voice channels are doing.
        ///
        /// **Resolved once by the caller and handed in as a table.** A test per
        /// tile over the whole voice table is ninety-seven passes over five
        /// hundred states, in a memo that rebuilds whenever any message arrives
        /// anywhere in the account.
        voiceMarks: [GuildID: RailVoiceMark],
        /// How the reader's applications stand — `railApplicationMarks`.
        applicationMarks: [GuildID: RailApplicationMark]
    ) -> [RailItem] {
        var items: [RailItem] = []
        items.reserveCapacity(folders.count)
        func makeGuild(_ guildID: GuildID) -> RailGuild? {
            guard let guild = guilds[guildID] else { return nil }
            let state = badge(guildID)
            return RailGuild(
                id: guildID,
                name: guild.name,
                iconURL: guild.iconHash.flatMap {
                    CDN.guildIcon(guildID: guildID, hash: $0, side: Metrics.guildTile)
                },
                monogram: guild.monogram,
                mentionCount: state.mentions,
                hasUnread: state.unread,
                isMuted: state.muted,
                isConnectedToVoice: connectedVoiceGuild == guildID,
                voiceMark: voiceMarks[guildID],
                applicationMark: applicationMarks[guildID]
            )
        }

        for folder in folders {
            // An entry without an id is how the settings payload represents a
            // server sitting loose in the rail — `GuildArrangement`.
            guard folder.isRealFolder else {
                if let guildID = folder.guildIDs.first, let entry = makeGuild(guildID) {
                    items.append(.guild(entry))
                }
                continue
            }

            let members = folder.guildIDs.compactMap(makeGuild)
            guard !members.isEmpty else { continue }
            items.append(.folder(RailFolder(
                id: folder.id ?? 0,
                name: folder.name,
                colorValue: folder.colorValue,
                guilds: members,
                isExpanded: expanded.contains(folder.id ?? 0),
                mentionCount: members.reduce(0) { $0 + $1.mentionCount },
                hasUnread: members.contains(where: \.hasUnread)
            )))
        }

        return items
    }

    /// The direct-message home.
    ///
    /// **This is a destination, not the absence of one.** With no guild selected
    /// the sidebar used to answer `.empty`, which is why the column went blank:
    /// the 109 conversations READY delivers were in the index the whole time and
    /// nothing ever asked for them.
    ///
    /// No categories, no permission gate — a DM is visible to its participants
    /// by construction — and the order is `ChannelIndex`'s own, which is
    /// recency. That order is already maintained by `patchLastMessage`, so a new
    /// message moves a conversation to the top without this rebuilding anything.
    private func buildDirectMessageSidebar(users userTable: [UserID: User]) -> SidebarPresentation {
        // **Pinned first, and the rest keep the order they came in.** That
        // order is `ChannelIndex`'s own — recency, already maintained by
        // `patchLastMessage` — so this is a stable partition rather than a
        // sort: a pinned conversation rises to the top and the pinned ones
        // stay in recency order among themselves, which is what Discord does.
        //
        // Skipped entirely when nothing is pinned, which is most accounts and
        // every one before the reader has pinned anything.
        var channelIDs = channelIndex.privateChannelIDs()
        if !pinnedChannelIDs.isEmpty {
            let pinned = pinnedChannelIDs
            channelIDs = channelIDs.filter { pinned.contains($0) }
                + channelIDs.filter { !pinned.contains($0) }
        }
        var rows: [SidebarRow] = []
        rows.reserveCapacity(channelIDs.count + 2)
        // Friends first, always: the page of people, as Discord's home heads
        // its list with it (REDESIGN.md R12).
        rows.append(.friends(pending: FriendRequest.incomingCount(of: relationships)))
        // **Only while something is waiting**, requests or spam — Discord's
        // `309199`'s `SM`. The badge counts the requests alone.
        if !channelIndex.messageRequestIDs(.pending).isEmpty || !channelIndex.messageRequestIDs(.spam).isEmpty {
            rows.append(.messageRequests(pending: pendingMessageRequestCount))
        }

        func channelRow(_ channelID: ChannelID) -> SidebarRow? {
            guard let channel = channelIndex[channelID] else { return nil }
            let state = unreadState(of: channel)
            // The other person, for a one-to-one conversation. A group has no
            // single face, so it takes the group glyph and no presence dot.
            let partnerID = channel.kind == .directMessage
                ? channel.recipientIDs.first { $0 != currentUserID }
                : nil
            let partner = partnerID.flatMap { userTable[$0] }
            // **The reader's own name for them beats the one they chose.** A
            // friend nickname is a private renaming that travels with the
            // account, and being the name you see is the whole of what it is
            // for. A group has no single person and therefore no nickname.
            let name = partnerID.flatMap { friendNicknames[$0] } ?? displayName(of: channel)

            // **A group has a face too, and it is the group's own.** A group DM
            // carries an `icon` hash on a CDN path of its own — `/channel-icons`
            // — and a row built only for the one-to-one case leaves every group
            // in the account showing a bare "?" plate, which is what a hundred
            // identical grey circles in the DM list actually was.
            let avatarURL: URL? = switch channel.kind {
            case .directMessage:
                partner.flatMap { avatarURL(for: $0, side: Metrics.avatarDirectMessage) }
            case .groupDirectMessage:
                channel.iconHash.flatMap {
                    CDN.channelIcon(
                        channelID: channelID, hash: $0, side: Metrics.avatarDirectMessage
                    )
                }
            default:
                nil
            }

            // **The same facts the roster draws, in the same shapes.** A direct
            // message is a *person*, and the list is the only place their
            // identity has to be legible without opening anything — so the row
            // says what they are doing, what tag they wear, and what plate and
            // name style they chose, exactly as `AppModel+Roster` resolves them
            // for a server's member list. A group has none of it: there is no
            // single person for any of these to be about.
            let presence = partnerID.flatMap { presences[$0] }
            let decoration = partner?.decoration
            return .channel(SidebarChannel(
                id: channelID,
                name: name,
                kind: channel.kind,
                isUnread: state.unread,
                mentionCount: state.mentions,
                isMuted: state.muted,
                voiceMembers: [],
                avatarURL: avatarURL,
                // A group with no icon gets its own initials rather than the
                // channel glyph: the name IS the identity there, and a row of
                // identical glyphs is a list nobody can scan.
                monogram: partner?.monogram ?? Self.monogram(of: name),
                // A group has several people and no single presence; a dot on
                // one of them would be a fact about somebody the row does not
                // name.
                status: partnerID.map { presenceStatus(of: $0) },
                statusClient: partnerID.map { presenceClient(of: $0) } ?? .desktop,
                isTyping: partnerID.map { isTypingInDirectMessage(channelID, partner: $0) } ?? false,
                activityLine: partnerID.flatMap { partnerID in
                    let voice = voicePlace(of: partnerID)
                    return Self.activityLine(
                        presence: presence,
                        isBot: partner?.isBot ?? false,
                        voice: voice.place,
                        isStreaming: voice.isStreaming
                    )
                },
                tag: decoration?.primaryGuildTag,
                tagBadgeURL: decoration.flatMap { decoration in
                    guard let guildID = decoration.primaryGuildID,
                          let hash = decoration.primaryGuildBadgeHash
                    else { return nil }
                    return CDN.guildTagBadge(guildID: guildID, hash: hash)
                },
                nameplateURL: decoration?.nameplate?.artworkURL,
                nameplateAnimatedURL: decoration?.nameplate?.animatedArtworkURL,
                nameplatePalette: decoration?.nameplate?.palette ?? .none,
                nameStyle: decoration?.displayNameStyle,
                nameColorValue: nil,
                isPinned: pinnedChannelIDs.contains(channelID),
                // Only while it is still the newest: a message that has since
                // been followed by one this client has not seen is not a
                // preview of anything.
                preview: latestDirectMessages[channelID]
                    .flatMap { $0.id == channel.lastMessageID ? $0 : nil }
                    .flatMap { message in
                        directMessagePreviewLine(for: message, in: channelID).map {
                            SidebarChannel.Preview(
                                text: $0,
                                sentAt: message.sentAt,
                                isVoiceNote: message.content.isEmpty && VoiceNoteWords.isVoiceNote(message)
                            )
                        }
                    }
            ))
        }

        func isUnread(_ channelID: ChannelID) -> Bool {
            channelIndex[channelID].map { unreadState(of: $0).unread } ?? false
        }

        // Before the pins and the folders take any out: the search's list.
        let everyConversation = channelIDs

        // **The pinned ones above the list, as faces** — Messages' pins
        // (REDESIGN.md R9) — and out of the list and the folders below them,
        // where they would be the same conversation twice.
        if !pinnedChannelIDs.isEmpty {
            let pinned = channelIDs.filter { pinnedChannelIDs.contains($0) }
            let tiles = pinned.compactMap { channelID -> SidebarChannel? in
                if case .channel(let channel) = channelRow(channelID) { return channel }
                return nil
            }
            if !tiles.isEmpty { rows.append(.pinnedGrid(tiles)) }
            channelIDs.removeAll { pinnedChannelIDs.contains($0) }
        }

        // **The reader's folders, as categories** (REDESIGN.md R9): each opens
        // and closes as a server's category does, its conversations in the
        // list's own order inside it. The rest follow under a heading of their
        // own — without one they would read as the last folder's.
        let folders = DirectMessageFolders.shared.folders
        if folders.isEmpty {
            rows.append(contentsOf: channelIDs.compactMap(channelRow))
        } else {
            var filed = Set<UInt64>()
            for folder in folders {
                let members = Set(folder.channelIDs)
                filed.formUnion(members)
                let inside = channelIDs.filter { members.contains($0.rawValue) }
                rows.append(.category(SidebarCategory(
                    id: DirectMessageFolders.categoryID(for: folder.id),
                    name: folder.name,
                    isExpanded: !folder.isCollapsed,
                    hasUnread: inside.contains(where: isUnread)
                )))
                if !folder.isCollapsed { rows.append(contentsOf: inside.compactMap(channelRow)) }
            }
            let unfiled = channelIDs.filter { !filed.contains($0.rawValue) }
            let unfiledID = DirectMessageFolders.unfiledCategoryID
            let isOpen = !collapsedCategoryIDs.contains(unfiledID)
            rows.append(.category(SidebarCategory(
                id: unfiledID,
                name: "Direct Messages",
                isExpanded: isOpen,
                hasUnread: unfiled.contains(where: isUnread)
            )))
            if isOpen { rows.append(contentsOf: unfiled.compactMap(channelRow)) }
        }

        return SidebarPresentation(
            // "Messages", as Messages heads its own list — the panel's header row
            // is narrow beside its toggle and create menu (REDESIGN.md R9).
            header: SidebarHeader(guildID: nil, name: "Messages", bannerURL: nil),
            rows: rows,
            conversations: everyConversation.compactMap { channelID in
                if case .channel(let channel) = channelRow(channelID) { return channel }
                return nil
            }
        )
    }

    /// A message as one line under its conversation's name — Messages' preview:
    /// the words with their markup read out, or what was sent when there are
    /// none, and "You: " before the reader's own.
    /// `previewLine`, once per message. The list is rebuilt for everything a
    /// row draws, and almost none of that is this.
    private func directMessagePreviewLine(for message: Message, in channelID: ChannelID) -> String? {
        let key = DirectMessagePreviewKey(
            messageID: message.id,
            editedAt: message.editedAt,
            identityRevision: identityRevision,
            structureRevision: channelIndex.structureRevision
        )
        if let known = directMessagePreviewLines[channelID], known.key == key { return known.line }
        let line = previewLine(for: message)
        directMessagePreviewLines[channelID] = (key, line)
        return line
    }

    func previewLine(for message: Message) -> String? {
        var text = message.content
        if !text.isEmpty {
            text = Self.readablePreview(text) { [users, channelIndex] id, kind in
                switch kind {
                case .user: users[UserID(rawValue: id)].map { "@" + $0.preferredName }
                case .channel: channelIndex[ChannelID(rawValue: id)].map { "#" + $0.name }
                }
            }
        }
        if text.isEmpty {
            if VoiceNoteWords.isVoiceNote(message) {
                text = VoiceNoteWords.preview
            } else if let attachment = message.attachments.first {
                let type = attachment.contentType ?? ""
                text = type.hasPrefix("image/") ? "Picture" : type.hasPrefix("video/") ? "Video" : attachment.filename
            } else if !message.stickers.isEmpty {
                text = "Sticker"
            } else if let poll = message.poll {
                text = "Poll: " + poll.question
            } else if let embed = message.embeds.first {
                text = embed.title ?? embed.url ?? "Link"
            } else if let interaction = message.interaction {
                // An app's answer with nothing but controls in it: say what
                // was asked of it, as its header in the transcript does.
                let invoker = interaction.userID == currentUserID
                    ? "You" : users[interaction.userID]?.preferredName ?? "Someone"
                return "\(invoker) used /\(interaction.name)"
            }
        }
        // Nothing a line can say: the row keeps what the person is doing.
        guard !text.isEmpty else { return nil }
        return message.authorID == currentUserID ? "You: " + text : text
    }

    private nonisolated enum PreviewReference { case user, channel }

    /// Discord's markup as a person would say it: mentions by name, custom
    /// emoji by their word, spoilers hidden, emphasis dropped, one line.
    private nonisolated static func readablePreview(
        _ text: String,
        name: (UInt64, PreviewReference) -> String?
    ) -> String {
        var out = text
        out = out.replacingOccurrences(of: #"\|\|[^|]*\|\|"#, with: "▒▒▒", options: .regularExpression)
        out = out.replacingOccurrences(of: #"<a?:([A-Za-z0-9_~]+):\d+>"#, with: ":$1:", options: .regularExpression)
        for (pattern, kind) in [(#"<@!?(\d+)>"#, PreviewReference.user), (#"<#(\d+)>"#, .channel)] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let source = out
            let range = NSRange(source.startIndex..., in: source)
            var rebuilt = ""
            var cursor = source.startIndex
            for match in regex.matches(in: source, range: range) {
                guard let whole = Range(match.range, in: source),
                      let digits = Range(match.range(at: 1), in: source),
                      let id = UInt64(source[digits])
                else { continue }
                rebuilt += source[cursor..<whole.lowerBound]
                rebuilt += name(id, kind) ?? (kind == .user ? "@someone" : "#channel")
                cursor = whole.upperBound
            }
            rebuilt += source[cursor...]
            out = rebuilt
        }
        out = out.replacingOccurrences(of: #"<@&\d+>"#, with: "@role", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(\*\*|__|~~|`{1,3})"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }

    private func buildGuildSidebar(
        guild: Guild,
        eventsRow: SidebarEventsRow?,
        boostGoal: SidebarBoostGoal?
    ) -> SidebarPresentation {
        let channelIDs = channelIndex.channelIDs(inGuild: guild.id)
        let filtersByFollow = hidesUnfollowedChannels(inGuild: guild.id)
        var rows: [SidebarRow] = []
        rows.reserveCapacity(channelIDs.count + 3)

        // Discord's order: the Boost bar, the guide, then the events, then the
        // pages after.
        if let boostGoal { rows.append(.boostGoal(boostGoal)) }
        let surfaces = guildSurfaceRows(for: guild.id)
        for surface in surfaces where surface == .serverGuide {
            rows.append(.guildAction(surface))
        }
        if let eventsRow { rows.append(.events(eventsRow)) }
        for surface in surfaces where surface != .serverGuide {
            rows.append(.guildAction(surface))
        }

        // One pass. Categories in list order, each followed by its children —
        // which is exactly the order the flat channel list is already in,
        // because `ChannelIndex` sorts by position and a category always
        // precedes its members there. Uncategorised channels come first,
        // matching Discord.
        //
        // THE PERMISSION FILTER IS HERE, once, and it is the only place a
        // channel can enter the list. A channel the reader cannot view is not
        // dimmed or disabled — it does not exist, which is what Discord does and
        // what people expect from a private channel. Filtering later, at the row,
        // would leave the channel in the navigation model where a keyboard
        // shortcut or a restored selection could still reach it.
        var byParent: [ChannelID?: [Channel]] = [:]
        var categories: [Channel] = []
        for channelID in channelIDs {
            guard let channel = channelIndex[channelID] else { continue }
            if channel.kind == .category {
                // A category's own `viewChannel` is not the gate — its children's
                // are. A category denied to @everyone but whose child is allowed
                // to a role must still show, or the channel underneath becomes
                // unreachable.
                categories.append(channel)
            } else if channel.kind.isConversation || channel.kind == .forum || channel.kind == .media
                        // A stage is a room to go into, as a voice channel is,
                        // though `isConversation` does not count it — left out
                        // here, no stage channel was ever listed.
                        || channel.kind == .stage {
                guard permissionGate.canView(channel.id) else { continue }
                // **The opt-in filter sits beside the permission one**, in the
                // one place a channel can enter the list. Filtering later, at
                // the row, would leave it in the navigation model where a
                // keyboard shortcut could still reach a channel the reader has
                // taken out of their sidebar.
                guard isChannelInList(channel, filtered: filtersByFollow) else { continue }
                byParent[channel.parentID, default: []].append(channel)
            }
        }

        for channel in byParent[nil] ?? [] {
            rows.append(.channel(makeSidebarChannel(channel)))
            appendThreadRows(under: channel, into: &rows)
        }

        for category in categories {
            let children = byParent[category.id] ?? []
            // A category with no visible children is a heading over nothing.
            guard !children.isEmpty else { continue }
            let isExpanded = !collapsedCategoryIDs.contains(category.id)
            let hasUnread = children.contains { unreadState(of: $0).unread }
            rows.append(.category(SidebarCategory(
                id: category.id,
                name: category.name,
                isExpanded: isExpanded,
                hasUnread: hasUnread
            )))
            guard isExpanded else { continue }
            for channel in children {
                rows.append(.channel(makeSidebarChannel(channel)))
                appendThreadRows(under: channel, into: &rows)
            }
        }

        return SidebarPresentation(
            header: SidebarHeader(
                guildID: guild.id,
                name: guild.name,
                bannerURL: guild.bannerHash.flatMap {
                    CDN.guildBanner(
                        guildID: guild.id,
                        hash: $0,
                        width: Proportions.channelColumnMax
                    )
                },
                mark: guild.mark,
                canCreateChannels: permissionGate.permissions(inGuild: guild.id).contains(.manageChannels)
            ),
            rows: rows
        )
    }

    /// The followed threads under one channel, as rows beneath it.
    ///
    /// **Followed only, and that is the whole rule.** Opening a forum loads its
    /// entire board into the index, so nesting every known thread would put
    /// thirty-six rows under one channel the moment the reader looked at it.
    /// What Discord nests — and what the reader has actually asked to keep an
    /// eye on — is the set they follow. See `AppModel.threadMemberships`.
    ///
    /// A collapsed category never reaches here, because its children are not
    /// emitted at all.
    private func appendThreadRows(under channel: Channel, into rows: inout [SidebarRow]) {
        // Cheap guard first: most channels have no threads, and this is the one
        // place the whole tree is walked.
        let threadIDs = channelIndex.threadIDs(inParent: channel.id)
        guard !threadIDs.isEmpty else { return }

        var followed: [Channel] = []
        for threadID in threadIDs {
            guard threadMemberships[threadID] != nil,
                  let thread = channelIndex[threadID],
                  permissionGate.canView(threadID)
            else { continue }
            followed.append(thread)
        }
        guard !followed.isEmpty else { return }

        for (offset, thread) in followed.enumerated() {
            let state = unreadState(of: thread)
            rows.append(.thread(SidebarThread(
                id: thread.id,
                name: thread.name,
                isUnread: state.unread,
                mentionCount: state.mentions,
                isMuted: state.muted || (threadMemberships[thread.id]?.isMutedNow() ?? false),
                isLast: offset == followed.count - 1
            )))
        }
    }

    private func makeSidebarChannel(_ channel: Channel) -> SidebarChannel {
        let state = unreadState(of: channel)
        // **Only for a voice channel**, and the guard is not decoration: the
        // lookup is a filter over every voice state in the account, and running
        // it for each of a server's five hundred text channels is five hundred
        // passes for five hundred empty arrays.
        guard channel.kind == .voice || channel.kind == .stage else {
            return SidebarChannel(
                id: channel.id,
                name: channel.name,
                kind: channel.kind,
                isUnread: state.unread,
                mentionCount: state.mentions,
                isMuted: state.muted,
                voiceMembers: []
            )
        }
        let info = voiceChannelInfo[channel.id]
        return SidebarChannel(
            id: channel.id,
            name: channel.name,
            kind: channel.kind,
            isUnread: state.unread,
            mentionCount: state.mentions,
            isMuted: state.muted,
            voiceMembers: voiceChips(in: channel.id, guildID: channel.guildID, onStageOnly: channel.kind == .stage),
            voiceStatus: info?.status.map(VoiceChannelStatus.runs) ?? [],
            // Nil and zero both mean "no limit" on the wire, and the row draws
            // no counter for either — see `SidebarChannel.voiceLimit`.
            voiceLimit: channel.userLimit ?? 0,
            voiceStartedAt: info?.sessionStartedAt
        )
    }

    /// Internal rather than private: the Channels & Roles page reads it too,
    /// and a second copy of "is this channel unread" is a second place for the
    /// mute rule to be forgotten.
    func unreadState(of channel: Channel) -> (unread: Bool, mentions: Int, muted: Bool) {
        Self.unreadState(of: channel, in: readStates)
    }

    static func unreadState(
        of channel: Channel,
        in readStates: [ChannelID: ReadState]
    ) -> (unread: Bool, mentions: Int, muted: Bool) {
        guard let state = readStates[channel.id] else {
            return (channel.lastMessageID != nil, 0, false)
        }
        return (
            state.isUnread(newest: channel.lastMessageID),
            state.mentionCount,
            state.isMuted
        )
    }

    /// Every mention the rail is currently showing, for the Dock icon.
    ///
    /// Summed over `railItems` rather than walked over every channel again: that
    /// projection is memoized and already did the walk, so this is an add per
    /// server. Zero when the reader has turned counts off, which is what makes
    /// the Dock agree with the rail instead of contradicting it.
    var totalMentionCount: Int {
        railItems.reduce(0) { running, item in
            switch item {
            case .guild(let guild): running + guild.mentionCount
            case .folder(let folder): running + folder.guilds.reduce(0) { $0 + $1.mentionCount }
            }
        }
    }

    func guildBadge(for guildID: GuildID) -> (mentions: Int, unread: Bool, muted: Bool) {
        GuildBadgeWalk(model: self).badge(for: guildID)
    }

    // MARK: Naming and assets

    /// What to call a channel in the chrome.
    ///
    /// A DM has no name of its own — Discord sends an empty string — so it is
    /// named for whoever is in it.
    func displayName(of channel: Channel) -> String {
        guard channel.kind.isPrivate else { return channel.name }
        if !channel.name.isEmpty { return channel.name }
        let names = channel.recipientIDs.compactMap { users[$0]?.preferredName }
        return names.isEmpty ? "Direct Message" : names.joined(separator: ", ")
    }

    /// Initials for something with a name and no picture.
    static func monogram(of name: String) -> String {
        let letters = name.split(separator: " ").compactMap(\.first).prefix(2)
        return letters.isEmpty ? "#" : String(letters).uppercased()
    }

    func avatarURL(for user: User, side: CGFloat) -> URL? {
        guard let hash = user.avatarHash else {
            return CDN.defaultAvatar(index: user.defaultAvatarIndex)
        }
        return CDN.avatar(userID: user.id, hash: hash, side: side)
    }

    /// Faces for the people this account knows, in the order given — a
    /// person the store has never heard of has no face to draw and is left
    /// out, as Discord leaves them out (`getUser(e) ?? null`, filtered).
    func stackedFaces(of userIDs: [UserID], inGuild guildID: GuildID?) -> [StackedFace] {
        var faces: [StackedFace] = []
        faces.reserveCapacity(userIDs.count)
        for userID in userIDs {
            guard let user = users[userID] else { continue }
            faces.append(StackedFace(
                id: userID,
                url: avatarURL(forUserID: userID, inGuild: guildID, side: Metrics.avatarInline),
                monogram: user.monogram
            ))
        }
        return faces
    }

    /// The avatar to draw for a person in a guild, honouring a per-guild
    /// override.
    /// Somebody's status, with Discord's rule for an absent presence — see
    /// `PresenceStatus.resolved(_:flags:)`. Every surface that draws a status
    /// for a person it holds no presence for goes through this or that.
    func presenceStatus(of userID: UserID) -> PresenceStatus {
        PresenceStatus.resolved(presences[userID]?.status, flags: users[userID]?.flags ?? [])
    }

    /// What somebody's online mark is drawn as: a dot, a phone or a headset.
    func presenceClient(of userID: UserID) -> PresenceClient {
        presences[userID]?.client ?? .desktop
    }

    func avatarURL(forUserID userID: UserID, inGuild guildID: GuildID?, side: CGFloat) -> URL? {
        if let guildID, let member = members[guildID]?[userID], let hash = member.avatarHash {
            return CDN.guildMemberAvatar(
                guildID: guildID,
                userID: userID,
                hash: hash,
                side: side
            )
        }
        guard let user = users[userID] else { return nil }
        return avatarURL(for: user, side: side)
    }

    // MARK: Navigation

    /// A channel that is gone — deleted, left, or a request declined. Its
    /// draft goes with it, and so does anything showing it.
    func forgetChannel(_ channelID: ChannelID) {
        channelIndex.remove(channelID)
        drafts.forget(channelID)
        if selectedChannelID == channelID { selectedChannelID = nil }
        if previewedChannelID == channelID { previewedChannelID = nil }
        sidebarRevision &+= 1
    }

    func selectGuild(_ guildID: GuildID?) {
        // Picking a server is leaving discovery, as it is in Discord — the grid
        // is a page of its own, not something a server is shown inside.
        if discovery != nil { closeDiscovery() }
        // Discord opens the folder that holds the destination (`rc`), so an
        // application's page never sits beside a closed folder.
        if let guildID, guilds[guildID] == nil, ownJoinRequests[guildID] != nil {
            isPendingApplicationsOpen = true
        }
        guard selectedGuildID != guildID else { return }
        selectedGuildID = guildID
        // A guide belongs to the server it describes, so it does not survive
        // the trip to another one — and neither does anything it opened. The
        // requests page belongs to the home, and goes the same way.
        openGuildSurface = nil
        isMessageRequestsOpen = false
        isFriendsOpen = false
        previewedChannelID = nil
        // Return to where the reader was, not to the top of the list.
        if let guildID {
            selectedChannelID = lastChannelByGuild[guildID]
                ?? firstReadableChannel(inGuild: guildID)
        } else {
            selectedChannelID = channelIndex.privateChannelIDs().first
        }
        // A panel still showing another server's hits after the rail moved is a
        // list about somewhere else. See `searchScopeDidChange`.
        searchScopeDidChange()
    }

    func selectChannel(_ channelID: ChannelID) {
        guard canOpen(channelID) else { return }
        // **A server's channel is opened in that server.** The Servers page can
        // list a server that is not the selected one — it keeps the last
        // server's channels after the reader goes Home — and a channel opened
        // from there used to leave the selection behind: the rail lit Home
        // while the transcript showed the server, and everything that reads the
        // selected server (its pages, its roster) answered for the wrong one.
        // Every other way in selects the server first; this is the same rule
        // for the one that did not. Not the whole of `selectGuild`, which would
        // pick the server's last channel over the one just clicked.
        if let channelGuild = channelIndex.guildID(of: channelID), channelGuild != selectedGuildID {
            if discovery != nil { closeDiscovery() }
            selectedGuildID = channelGuild
        }
        // **Leaving the page is what picking a channel means**, and it has to
        // happen even when that channel is already the selected one — otherwise
        // clicking the row you came from leaves the page up and does nothing.
        openGuildSurface = nil
        isMessageRequestsOpen = false
        isFriendsOpen = false
        previewedChannelID = nil
        // A flyout describes the channel it was opened on. Carrying it across
        // is a card that names one channel while the transcript shows another.
        openTopicChannelID = nil
        guard selectedChannelID != channelID else { return }
        selectedChannelID = channelID
        let guildID = channelIndex.guildID(of: channelID)
        if let guildID { lastChannelByGuild[guildID] = channelID }
        AppSettings.shared.rememberConversation(
            guildID: guildID?.rawValue, channelID: channelID.rawValue, account: currentUserID?.description
        )
        // **A no-op inside a server, and the close at Home.** A guild search is
        // scoped to the guild, so clicking a result and landing in another
        // channel changes nothing here — which is what keeps the results up.
        // At Home the conversation IS the scope, so opening a different direct
        // message leaves that search behind. See `searchScopeDidChange`.
        searchScopeDidChange()
    }

    private func firstReadableChannel(inGuild guildID: GuildID) -> ChannelID? {
        let filtersByFollow = hidesUnfollowedChannels(inGuild: guildID)
        return channelIndex.channelIDs(inGuild: guildID).first {
            guard let channel = channelIndex[$0], channel.kind.isConversation,
                  permissionGate.canView($0)
            else { return false }
            // Landing on a channel the reader took out of their own list is the
            // list disagreeing with itself on the first frame after a click.
            return isChannelInList(channel, filtered: filtersByFollow)
        }
    }

    /// The selected channel, when it is one the follow filter would otherwise
    /// remove. Nil in every other case, which is nearly always — see the note on
    /// `SidebarMemoKey.hiddenSelection`.
    private var hiddenSelectedChannelID: ChannelID? {
        guard let selectedChannelID, let channel = channelIndex[selectedChannelID],
              let guildID = channel.guildID,
              hidesUnfollowedChannels(inGuild: guildID),
              !isChannelFollowed(channel)
        else { return nil }
        return selectedChannelID
    }

    /// Whether a channel may be navigated to at all.
    ///
    /// Checked on every selection, not only on the ones the list offers: a
    /// restored selection from a previous launch, a jump from a message link and
    /// a keyboard shortcut all reach `selectChannel` without passing the list.
    func canOpen(_ channelID: ChannelID) -> Bool {
        permissionGate.canView(channelID)
    }

    func toggleFolder(_ folderID: UInt64) {
        if expandedFolderIDs.contains(folderID) {
            expandedFolderIDs.remove(folderID)
        } else {
            expandedFolderIDs.insert(folderID)
        }
    }

    func toggleCategory(_ categoryID: ChannelID) {
        // A conversation folder keeps its own state, on this Mac.
        if let folderID = DirectMessageFolders.folderID(from: categoryID), folderID != 0 {
            DirectMessageFolders.shared.toggle(folderID)
            return
        }
        if collapsedCategoryIDs.contains(categoryID) {
            collapsedCategoryIDs.remove(categoryID)
        } else {
            collapsedCategoryIDs.insert(categoryID)
        }
    }
}

/// One server's rail tile, from tables read once for the whole rail.
///
/// **Reading an observed property inside the loop was a fifth of the app's
/// main thread on a real account.** A rail is every channel in every server,
/// and each lookup through the store goes through observation tracking; a
/// walk of five thousand channels registered tens of thousands of accesses
/// for one answer. The tables are copy-on-write, so holding them here is a
/// retain, and the loop below touches no observed property at all.
@MainActor
struct GuildBadgeWalk {
    private let model: AppModel
    private let channelIndex: ChannelIndex
    private let readStates: [ChannelID: ReadState]
    private let followedChannelIDs: Set<ChannelID>
    private let guildOnboardings: [GuildID: GuildOnboarding]
    private let countsBadges: Bool

    init(model: AppModel) {
        self.model = model
        channelIndex = model.channelIndex
        readStates = model.readStates
        followedChannelIDs = model.followedChannelIDs
        guildOnboardings = model.guildOnboardings
        countsBadges = AppSettings.shared.showsUnreadCounts
        model.permissionGate.beginWalk()
    }

    func badge(for guildID: GuildID) -> (mentions: Int, unread: Bool, muted: Bool) {
        let filtersByFollow = AppModel.hidesUnfollowedChannels(
            inGuild: guildID,
            onboardings: guildOnboardings,
            followed: followedChannelIDs,
            index: channelIndex
        )
        // Read only where it can matter, so a rail with no follow filter on it
        // is not re-evaluated by every click in the channel list.
        let selectedChannelID = filtersByFollow ? model.selectedChannelID : nil
        let gate = model.permissionGate
        var mentions = 0
        var unread = false
        for channelID in channelIndex.channelIDs(inGuild: guildID) {
            guard let channel = channelIndex[channelID], channel.kind.isConversation else {
                continue
            }
            // A channel the reader cannot see must not contribute a badge. A
            // rail tile marked unread for a channel that does not appear in the
            // list is a dot nobody can ever clear — and a channel the reader has
            // opted OUT of is exactly as absent from that list, so it is held to
            // the same rule.
            guard gate.canViewDuringWalk(channelID) else { continue }
            guard AppModel.isChannelInList(
                channel, filtered: filtersByFollow,
                followed: followedChannelIDs, selected: selectedChannelID
            ) else { continue }
            let state = AppModel.unreadState(of: channel, in: readStates)
            guard !state.muted else { continue }
            mentions += state.mentions
            unread = unread || state.unread
        }
        // The dot survives; only the COUNT is suppressed. A reader who turned
        // counts off still wants to know a server has something new — what they
        // turned off is the number, which on a busy account is a wall of digits.
        return (countsBadges ? mentions : 0, unread, false)
    }
}
