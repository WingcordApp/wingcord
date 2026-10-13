import Foundation
import WingcordCore

// MARK: - The quick switcher
//
// ⌘K. Everywhere the account can go, ranked against what has been typed.
//
// **Nothing here is a request except the games**, which is the whole shape of
// the feature and it is what the capture says: `quick switcher.har` has one
// route in it, `/games/autocomplete`, and everything else on the reference
// client's own list — servers, channels, voice channels, people — is answered
// out of tables it already holds. So is this.
//
// The ordering comes from Discord's own table rather than from a model invented
// here: `guild_and_channel_frecency`, field 12 of the second settings protobuf,
// which is a hundred places the account genuinely goes with a decayed score
// against each. See `DiscordREST.navigationFrecency`.

extension AppModel {

    // MARK: Opening and closing

    var isQuickSwitchShown: Bool { quickSwitch != nil }

    /// ⌘K, both ways.
    ///
    /// **Opening always starts empty.** A switcher that reopens on the last
    /// thing anybody typed is a switcher whose first keystroke has to be a
    /// delete, and the empty state — where you were, and who is waiting — is
    /// the most useful list it ever shows.
    func toggleQuickSwitch() {
        if quickSwitch != nil {
            closeQuickSwitch()
            return
        }
        quickSwitch = QuickSwitchState()
        sessionController.loadNavigationFrecency()
    }

    func closeQuickSwitch() {
        quickSwitch = nil
        sessionController.cancelGameSearch()
    }

    /// What the field publishes.
    ///
    /// The games request is raised here rather than from the view: a body that
    /// starts a fetch starts one per evaluation, and this one is debounced and
    /// deduplicated inside the controller.
    func setQuickSwitchText(_ text: String) {
        guard quickSwitch != nil, quickSwitch?.text != text else { return }
        quickSwitch?.text = text
        let query = QuickSwitchQuery.parse(text)
        // Only where a game could be offered. Under `#`, `@`, `!` or `*` the
        // list cannot contain one, so asking would be a round trip for rows
        // that are already filtered out.
        guard query.filter == nil || query.filter == .games, !query.isEmpty else {
            sessionController.cancelGameSearch()
            quickSwitch?.games = []
            quickSwitch?.gamesNeedle = ""
            quickSwitch?.isSearchingGames = false
            return
        }
        sessionController.searchGames(matching: query.needle)
    }

    /// Goes where a row points, and closes.
    ///
    /// **The panel always closes**, unlike the search results column: a switcher
    /// is one act, and a list that stays up after taking you somewhere is a list
    /// covering the thing you asked for.
    ///
    /// **And so does everything it was opened over.** ⌘K is reached from
    /// anywhere, including from on top of a profile card or a game page, and a
    /// card about somebody still floating over the channel it just sent you to
    /// is chrome describing somewhere you no longer are. `openChannelLink` has
    /// always done the same for the same reason.
    func openQuickSwitchRow(_ row: QuickSwitchRow) {
        closeQuickSwitch()
        profileRequest = nil
        gameProfileRequest = nil
        tenureBadgeRequest = nil
        expressionInfoRequest = nil
        dismissMessageSurfaces()
        switch row.target {
        case .channel(let channelID):
            // The server first, then the channel — `selectGuild` lands on
            // whatever was last read there, and the channel overrides it.
            selectGuild(channelIndex.guildID(of: channelID))
            selectChannel(channelID)
        case .guild(let guildID):
            selectGuild(guildID)
        case .person(let userID):
            // Resolves the conversation, making one where there is not one yet,
            // which is the same act the profile's Message control performs.
            messagePerson(userID)
        case .game(let gameID):
            openGameProfile(gameID)
        }
    }

    // MARK: Where you have been

    /// Records a channel as visited, most recent first.
    ///
    /// **Only the selected channel, never a previewed one.** A channel read
    /// beside a server's guide is a peek — §1's word for it — and putting it in
    /// the switcher's Previous list would fill that list with pages nobody
    /// navigated to.
    ///
    /// Bounded, and the bound is small on purpose: past a handful this stops
    /// being "where I just was" and becomes a second, worse copy of the ranked
    /// list underneath it.
    func recordChannelVisit(_ channelID: ChannelID) {
        guard channelID == selectedChannelID else { return }
        guard recentChannelIDs.first != channelID else { return }
        recentChannelIDs.removeAll { $0 == channelID }
        recentChannelIDs.insert(channelID, at: 0)
        if recentChannelIDs.count > Self.visitsRemembered {
            recentChannelIDs.removeLast(recentChannelIDs.count - Self.visitsRemembered)
        }
    }

    /// Channel › Recents: this session's visits, as the switcher names them —
    /// only this session's, so that Clear Recents visibly clears; the
    /// account's own history stays the switcher's — and the conversations
    /// with drafts waiting.
    func recentsForMenu() -> (channels: [QuickSwitchRow], drafts: [QuickSwitchRow]) {
        let channels = recentChannelIDs
            .filter { $0 != selectedChannelID }
            .compactMap(channelRow)
        return (channels, draftRows(excluding: []))
    }

    /// Channel › Recents › Clear Recents.
    func clearRecents() {
        recentChannelIDs.removeAll()
        refreshMenuContext()
    }

    // MARK: What the panel draws

    /// The sections, for whatever is in the field.
    ///
    /// **Rebuilt per keystroke and not per frame**, which is the reason the lit
    /// row lives in the panel's own state: this walks the account, and an arrow
    /// key must not.
    var quickSwitchSections: [QuickSwitchSection] {
        guard let state = quickSwitch else { return [] }
        let query = QuickSwitchQuery.parse(state.text)

        guard query.filter != nil || !query.isEmpty else { return restingSections() }

        var sections: [QuickSwitchSection] = []
        let places = query.isEmpty ? browse(query) : ranked(query)
        if let filter = query.filter {
            // The mode is stated even when it has nothing to show, because the
            // sigil changed what the field means and a blank panel with no
            // heading reads as a switcher that broke.
            if filter != .games {
                sections.append(
                    QuickSwitchSection(id: "filtered", title: filter.title, rows: places)
                )
            }
        } else if !places.isEmpty {
            // No heading: the field above already says what these answer.
            sections.append(QuickSwitchSection(id: "results", title: nil, rows: places))
        }

        let games = gameRows(query, state: state)
        if query.filter == .games || !games.isEmpty {
            sections.append(
                QuickSwitchSection(
                    id: "games",
                    title: QuickSwitchFilter.games.title,
                    rows: games
                )
            )
        }
        return sections
    }

    /// Whether a games request is still out, so the panel can say so rather than
    /// showing an empty list that is about to fill.
    var isQuickSwitchLoadingGames: Bool { quickSwitch?.isSearchingGames ?? false }

    var quickSwitchFilter: QuickSwitchFilter? {
        quickSwitch.map { QuickSwitchQuery.parse($0.text).filter } ?? nil
    }

    // MARK: The empty state

    /// Where you were, what you were writing, and who is waiting.
    ///
    /// The lists the reference client shows on an empty field, and between them
    /// they answer the reasons anybody opens a switcher without typing.
    private func restingSections() -> [QuickSwitchSection] {
        var sections: [QuickSwitchSection] = []
        let previous = previousChannelRows()
        if !previous.isEmpty {
            sections.append(
                QuickSwitchSection(id: "previous", title: "Previous channels", rows: previous)
            )
        }
        // **Each list leaves out what an earlier one already offered**, as
        // Discord's does — one place named twice is one row too many to read.
        var offered = Set(previous.map(\.target))
        if let selectedChannelID { offered.insert(.channel(selectedChannelID)) }
        let drafts = draftRows(excluding: offered)
        if !drafts.isEmpty {
            sections.append(QuickSwitchSection(id: "drafts", title: "Drafts", rows: drafts))
        }
        offered.formUnion(drafts.map(\.target))
        let mentions = mentionRows().filter { !offered.contains($0.target) }
        if !mentions.isEmpty {
            sections.append(
                QuickSwitchSection(id: "mentions", title: "Mentions", rows: mentions)
            )
        }
        return sections
    }

    /// The conversations with words waiting in their composers, the most
    /// recently written first — Discord's Drafts.
    ///
    /// **Its filter, too**: a server's channel that will not take a message has
    /// nothing to come back to. A one-to-one conversation is offered as its
    /// person, which is how this switcher names one everywhere else.
    private func draftRows(excluding offered: Set<QuickSwitchTarget>) -> [QuickSwitchRow] {
        var rows: [QuickSwitchRow] = []
        for channelID in drafts.recentlyEdited {
            guard let channel = channelIndex[channelID] else { continue }
            let row: QuickSwitchRow? = if channel.kind == .directMessage {
                channel.recipientIDs.first { $0 != currentUserID }.flatMap(personRow)
            } else if channel.guildID == nil || permissionGate.canSend(in: channelID) {
                channelRow(channelID)
            } else {
                nil
            }
            guard let row, !offered.contains(row.target) else { continue }
            rows.append(row)
        }
        return rows
    }

    /// The channels most recently read, this session first and the account's own
    /// history behind it.
    ///
    /// **The two sources are layered rather than merged.** A visit made in this
    /// window is the most certain thing there is, and Discord's table is what
    /// fills the list on the first ⌘K of a session — before which a
    /// freshly-launched client has nothing to show at all.
    ///
    /// The channel on screen is left out. A switcher's top row is where Return
    /// goes, and offering the channel somebody is already reading makes ⌘K↵ do
    /// nothing; leaving it out makes the same two keys mean "back to the last
    /// one", which is the gesture people actually want.
    private func previousChannelRows() -> [QuickSwitchRow] {
        var seen: Set<ChannelID> = []
        if let selectedChannelID { seen.insert(selectedChannelID) }
        var rows: [QuickSwitchRow] = []
        rows.reserveCapacity(Self.previousChannelsShown)

        func offer(_ channelID: ChannelID) {
            guard rows.count < Self.previousChannelsShown, seen.insert(channelID).inserted else {
                return
            }
            guard let row = channelRow(channelID) else { return }
            rows.append(row)
        }

        for channelID in recentChannelIDs { offer(channelID) }
        guard rows.count < Self.previousChannelsShown else { return rows }
        for (id, _) in placeFrecency
            .filter({ $0.value.lastUsedAt != nil })
            .sorted(by: { ($0.value.lastUsedAt ?? .distantPast) > ($1.value.lastUsedAt ?? .distantPast) })
        {
            offer(ChannelID(rawValue: id))
            if rows.count == Self.previousChannelsShown { break }
        }
        return rows
    }

    /// Every channel with something addressed to the reader in it.
    ///
    /// Walked over the read states rather than over the channels: the table has
    /// an entry per channel the account has ever opened, and the ones with a
    /// mention in them are a handful.
    private func mentionRows() -> [QuickSwitchRow] {
        var rows: [QuickSwitchRow] = []
        for (channelID, state) in readStates where state.mentionCount > 0 && !state.isMuted {
            guard let row = channelRow(channelID), row.mentionCount > 0 else { continue }
            rows.append(row)
        }
        // Newest first, which is the order somebody works through a backlog.
        rows.sort { left, right in
            let a = channelIndex[channelIDOf(left)]?.lastMessageID?.rawValue ?? 0
            let b = channelIndex[channelIDOf(right)]?.lastMessageID?.rawValue ?? 0
            return a > b
        }
        return Array(rows.prefix(Self.mentionsShown))
    }

    private func channelIDOf(_ row: QuickSwitchRow) -> ChannelID {
        guard case .channel(let channelID) = row.target else { return ChannelID(rawValue: 0) }
        return channelID
    }

    // MARK: Ranking

    /// One mode's whole list, for a sigil with nothing typed after it.
    ///
    /// Ordered by how much the account uses each, which is the only ordering
    /// that means anything with no needle to match against.
    private func browse(_ query: QuickSwitchQuery) -> [QuickSwitchRow] {
        guard let filter = query.filter, filter != .games else { return [] }
        let frecency = placeFrecency
        let candidates = quickSwitchCandidates()
            .filter { $0.kind == filter }
            .sorted { left, right in
                let a = frecency[left.frecencyID]
                let b = frecency[right.frecencyID]
                if a?.score != b?.score { return (a?.score ?? 0) > (b?.score ?? 0) }
                return left.key < right.key
            }
        return rows(for: candidates.prefix(Self.rowLimit))
    }

    /// Everything that answers what was typed, best first.
    private func ranked(_ query: QuickSwitchQuery) -> [QuickSwitchRow] {
        let frecency = placeFrecency
        var scored: [(candidate: QuickSwitchCandidate, score: Int, recency: Date)] = []
        scored.reserveCapacity(Self.rowLimit * 4)

        for candidate in quickSwitchCandidates() {
            if let filter = query.filter, candidate.kind != filter { continue }
            var best = QuickSwitchRank.match(candidate.key, query.needle)
            if let alternate = candidate.alternate,
               let second = QuickSwitchRank.match(alternate, query.needle),
               best.map({ second > $0 }) ?? true
            {
                best = second
            }
            guard let best else { continue }
            let place = frecency[candidate.frecencyID]
            scored.append((
                candidate,
                QuickSwitchRank.score(best, frecency: place?.score ?? 0),
                place?.lastUsedAt ?? .distantPast
            ))
        }

        // Sorted whole rather than kept as a bounded heap: a one-character
        // needle matches most of an account as a subsequence, and five thousand
        // comparisons is microseconds where a heap is a structure to maintain.
        scored.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.recency != right.recency { return left.recency > right.recency }
            return left.candidate.key < right.candidate.key
        }
        return rows(for: scored.prefix(Self.rowLimit).map(\.candidate))
    }

    /// The game hits, and how many of them belong in the list.
    ///
    /// **Three in a mixed list, all of them under `$`.** The route answers ten,
    /// and the reference client draws three of them under everything local —
    /// which is the right trade, because a game profile is a different kind of
    /// destination from a place in your account and it should not push
    /// somewhere you actually go off the bottom.
    private func gameRows(_ query: QuickSwitchQuery, state: QuickSwitchState) -> [QuickSwitchRow] {
        guard query.filter == nil || query.filter == .games else { return [] }
        // The answer is drawn only against the question it answers.
        guard state.gamesNeedle == query.needle else { return [] }
        let limit = query.filter == .games ? state.games.count : Self.gamesInMixedList
        return state.games.prefix(limit).map { game in
            QuickSwitchRow(
                target: .game(game.id),
                title: game.name,
                label: "Game profile",
                iconURL: game.iconURL,
                monogram: Self.monogram(of: game.name)
            )
        }
    }

    // MARK: The snapshot

    /// Everywhere the account can go, as the smallest value that can be ranked.
    ///
    /// **Memoized on the five counters that can change the set**, and rebuilt on
    /// none of the ones a message moves. It walks every channel in the account
    /// through the permission gate — the same walk the forward sheet makes, and
    /// the second most expensive snapshot in the app — so it is built once when
    /// the switcher opens and filtered per keystroke, never rebuilt per
    /// keystroke.
    ///
    /// **Frecency is deliberately not in it.** Baking the score in would mean
    /// the table landing rebuilds the whole snapshot; looked up at ranking time
    /// it re-orders an existing one, and the lookup is a hash per *matched*
    /// candidate rather than per candidate.
    func quickSwitchCandidates() -> [QuickSwitchCandidate] {
        // Every observable input read before the cache is consulted: a memo that
        // answers from its cache without touching them registers no dependency
        // and is never invalidated again. `INVARIANTS.md` §2.
        let key = QuickSwitchMemoKey(
            structureRevision: channelIndex.structureRevision,
            roleRevision: roleRevision,
            identityRevision: identityRevision,
            memberRevision: memberRevision,
            railRevision: railRevision
        )
        if let quickSwitchCache, quickSwitchCache.key == key { return quickSwitchCache.value }

        var candidates: [QuickSwitchCandidate] = []
        candidates.reserveCapacity(256)

        // The conversation each person already has, resolved once. Asked per
        // person it would be a scan of the DM list per friend.
        var conversations: [UserID: ChannelID] = [:]
        for channelID in channelIndex.privateChannelIDs() {
            guard let channel = channelIndex[channelID] else { continue }
            switch channel.kind {
            case .directMessage:
                if let other = channel.recipientIDs.first(where: { $0 != currentUserID }) {
                    conversations[other] = channelID
                }
            case .groupDirectMessage:
                // A group has a name of its own and no single person behind it,
                // so it is a channel here and not a person.
                let name = displayName(of: channel)
                candidates.append(QuickSwitchCandidate(
                    target: .channel(channelID),
                    key: QuickSwitchRank.fold(name),
                    alternate: nil,
                    kind: .textChannels,
                    frecencyID: channelID.rawValue
                ))
            default:
                continue
            }
        }

        for (guildID, guild) in guilds {
            candidates.append(QuickSwitchCandidate(
                target: .guild(guildID),
                key: QuickSwitchRank.fold(guild.name),
                alternate: nil,
                kind: .servers,
                frecencyID: guildID.rawValue
            ))
            for channelID in channelIndex.channelIDs(inGuild: guildID) {
                guard let channel = channelIndex[channelID],
                      let kind = Self.switcherKind(of: channel.kind),
                      // A channel the reader cannot open is a row that goes
                      // nowhere — §5.5, as a destination.
                      permissionGate.canView(channelID)
                else { continue }
                candidates.append(QuickSwitchCandidate(
                    target: .channel(channelID),
                    key: QuickSwitchRank.fold(channel.name),
                    alternate: nil,
                    kind: kind,
                    frecencyID: channelID.rawValue
                ))
            }
        }

        for userID in switcherPeopleIDs(conversations: conversations) {
            guard let user = users[userID] else { continue }
            candidates.append(QuickSwitchCandidate(
                target: .person(userID),
                key: QuickSwitchRank.fold(user.preferredName),
                // The handle, because it is how somebody with a display name
                // nobody can spell is actually found.
                alternate: QuickSwitchRank.fold(user.handle),
                kind: .people,
                // A person's score is their conversation's. Somebody the account
                // has never written to has none, which is a real answer.
                frecencyID: conversations[userID]?.rawValue ?? 0
            ))
        }

        quickSwitchCache = (key, candidates)
        return candidates
    }

    /// Who the switcher offers.
    ///
    /// **Bounded, and the boundary is "people you know".** Friends, everybody in
    /// an open conversation, and the rosters this session has loaded — which is
    /// what the account genuinely holds. Discord's `@` searches a directory and
    /// this does not; a header promising one would be a promise the surface
    /// cannot keep, which is why the mode is named for what it does.
    ///
    /// Blocked people are left out. Picking one opens a conversation with
    /// somebody the reader has said they do not want to hear from.
    private func switcherPeopleIDs(conversations: [UserID: ChannelID]) -> Set<UserID> {
        var ids = Set(conversations.keys)
        ids.formUnion(relationships.keys)
        for table in members.values { ids.formUnion(table.keys) }
        if let currentUserID { ids.remove(currentUserID) }
        ids.subtract(blockedUserIDs)
        return ids
    }

    /// Which sigil a channel answers to, or nil for one that is not a
    /// destination at all.
    ///
    /// A category is a heading, a directory is a listing, and a thread is
    /// reached through the channel it hangs off — none of the three is a place
    /// this switcher can send anybody, and offering one is the inert control
    /// §5.5 forbids.
    private static func switcherKind(of kind: ChannelKind) -> QuickSwitchFilter? {
        switch kind {
        case .text, .announcement, .forum, .media: .textChannels
        case .voice, .stage: .voiceChannels
        case .category, .directory, .unknown,
             .announcementThread, .publicThread, .privateThread,
             .directMessage, .groupDirectMessage: nil
        }
    }

    // MARK: Rows

    private func rows(for candidates: some Sequence<QuickSwitchCandidate>) -> [QuickSwitchRow] {
        candidates.compactMap { candidate in
            switch candidate.target {
            case .channel(let channelID): channelRow(channelID)
            case .guild(let guildID): guildRow(guildID)
            case .person(let userID): personRow(userID)
            // Games never come out of the snapshot — they arrive from the route
            // already shaped as rows.
            case .game: nil
            }
        }
    }

    /// One channel, with the two things that tell two `#general`s apart: the
    /// category above it and the server it is in.
    private func channelRow(_ channelID: ChannelID) -> QuickSwitchRow? {
        guard let channel = channelIndex[channelID], permissionGate.canView(channelID) else {
            return nil
        }
        let state = unreadState(of: channel)
        if channel.kind == .groupDirectMessage {
            return QuickSwitchRow(
                target: .channel(channelID),
                title: displayName(of: channel),
                label: "\(channel.recipientIDs.count + 1) members",
                iconURL: channel.iconHash.flatMap {
                    CDN.channelIcon(channelID: channelID, hash: $0, side: Metrics.avatarRow)
                },
                monogram: Self.monogram(of: displayName(of: channel)),
                mentionCount: state.muted ? 0 : state.mentions,
                isUnread: !state.muted && state.unread
            )
        }
        guard let guildID = channel.guildID else { return nil }
        return QuickSwitchRow(
            target: .channel(channelID),
            title: displayName(of: channel),
            label: channel.parentID.flatMap { channelIndex[$0]?.name },
            trailing: guilds[guildID]?.name,
            symbolName: channel.kind.symbolName,
            mentionCount: state.muted ? 0 : state.mentions,
            isUnread: !state.muted && state.unread
        )
    }

    private func guildRow(_ guildID: GuildID) -> QuickSwitchRow? {
        guard let guild = guilds[guildID] else { return nil }
        return QuickSwitchRow(
            target: .guild(guildID),
            title: guild.name,
            label: "Server",
            iconURL: guild.iconHash.flatMap {
                CDN.guildIcon(guildID: guildID, hash: $0, side: Metrics.avatarRow)
            },
            monogram: guild.monogram
        )
    }

    private func personRow(_ userID: UserID) -> QuickSwitchRow? {
        guard let user = users[userID] else { return nil }
        return QuickSwitchRow(
            target: .person(userID),
            title: user.preferredName,
            subtitle: user.handle,
            iconURL: avatarURL(for: user, side: Metrics.avatarRow),
            monogram: user.monogram,
            status: presenceStatus(of: userID),
            isPerson: true
        )
    }

    // MARK: Bounds

    /// How many places a ranked list offers. Past about twenty nobody is reading
    /// a switcher's list — they are typing another character, which is cheaper
    /// for them and for this.
    private static let rowLimit = 20
    /// The reference client draws three game profiles under everything local.
    private static let gamesInMixedList = 3
    /// Where you just were. Small on purpose — see `previousChannelRows`.
    private static let previousChannelsShown = 5
    private static let mentionsShown = 8
    /// How many visits the session keeps. One more than the list shows, so the
    /// channel currently open can be skipped without shortening it.
    static let visitsRemembered = 6
}
