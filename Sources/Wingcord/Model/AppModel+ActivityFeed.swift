import AppKit
import Foundation
import SwiftUI
import WingcordCore

// MARK: - The member list's Activity section
//
// Discord's content feed at the head of a server's member list (`946228`):
// what the people the reader talks to did, ranked by the server, shown to the
// channel's audience only. The rules are `ActivityCardRules`; this file is the
// store's half — what is held, and the cards it comes to for one channel.

/// The reader's feed, and the asking for it.
struct ActivityFeedState {
    var inbox: ActivityInbox?
    var isLoading = false
    /// Failed fetches in a row — Discord retries four times, a minute and then
    /// doubling.
    var failures = 0
}

/// One card's popout, open beside it.
struct ActivityCardRequest: Equatable {
    var entryID: String
    var anchor: CGRect
    /// Opened by resting the pointer on the card, Discord's way: it closes
    /// when the pointer leaves card and popout, and has no click-catcher, so
    /// the list keeps tracking the pointer. A click, a focused or half-typed
    /// reply, or the emoji picker pins it (docs/ACTIVITY-CARDS.md decision 7).
    var opensOnHover = false
}

/// What the section's memo is keyed on.
struct ActivityBlockKey: Equatable {
    var channelID: ChannelID?
    var feed: [String]
    var hidden: Bool
    var expanded: Bool
    var impressions: Int
    var memberRevision: UInt64
    var presenceRevision: UInt64
    var roleRevision: UInt64
    var structureRevision: UInt64
    var identityRevision: UInt64
    var gamesCount: Int
    var applicationsCount: Int
}

extension AppModel {

    /// The section for the channel on screen, or nil where Discord draws none:
    /// outside a server, in a server the section is not offered in, beside a
    /// forum, or with nothing to show.
    var memberActivityBlock: MemberActivityBlock? {
        let settings = AppSettings.shared
        let key = ActivityBlockKey(
            channelID: selectedChannelID,
            feed: activityFeed.inbox?.entries.map(\.id) ?? [],
            hidden: settings.hidesActivityCards,
            expanded: activityExpanded,
            impressions: settings.activityImpressions.sightings.count,
            memberRevision: memberRevision,
            presenceRevision: presenceRevision,
            roleRevision: roleRevision,
            structureRevision: channelIndex.structureRevision,
            identityRevision: identityRevision,
            gamesCount: games.count,
            applicationsCount: activityDirectory.apps.count
        )
        if let activityBlockCache, activityBlockCache.key == key { return activityBlockCache.value }
        let value = buildActivityBlock(now: .now)
        activityBlockCache = (key, value)
        return value
    }

    /// The entries one channel's section may show, in the server's order.
    func activityEntries(for channelID: ChannelID, now: Date) -> [ActivityFeedEntry] {
        guard let inbox = activityFeed.inbox,
              var channel = channelIndex[channelID],
              let guildID = channel.guildID,
              let guild = guilds[guildID],
              ActivityCardRules.isOffered(
                  features: guild.features, memberCount: guild.memberCount, isForum: channel.kind == .forum
              )
        else { return [] }
        // A thread's audience is its parent's.
        if channel.kind.isThread, let parent = channel.parentID.flatMap({ channelIndex[$0] }) { channel = parent }
        let guildMembers = members[guildID] ?? [:]
        let roleTable = roles[guildID] ?? [:]
        let audience = channel
        let canSee: (UserID) -> Bool = { userID in
            guard let member = guildMembers[userID] else { return false }
            return PermissionResolver.permissions(
                forMember: member.roleIDs, userID: userID, guildID: guildID,
                guildOwnerID: guild.ownerID, roles: roleTable, channel: audience
            ).contains(.viewChannel)
        }
        // Somebody whose conversation the reader muted, or blocked, or
        // ignores — Discord's `808323` and its renderable check.
        var quiet = blockedUserIDs.union(ignoredUserIDs)
        for channelID in channelIndex.privateChannelIDs() {
            guard let conversation = channelIndex[channelID], conversation.kind == .directMessage,
                  notificationPreferences.mutedChannelIDs.contains(channelID)
            else { continue }
            quiet.formUnion(conversation.recipientIDs)
        }
        let authors = Set(inbox.entries.map(\.activity.authorID))
        let offline = Set(authors.filter { (presences[$0]?.status ?? .offline) == .offline })
        return ActivityCardRules.cards(
            from: inbox.entries,
            canSee: canSee,
            mutedOrBlocked: quiet,
            offline: offline,
            capped: AppSettings.shared.activityImpressions.capped(at: now),
            now: now
        )
        // Discord draws a top artist or top game only over a week, and a
        // listening session only while the presence still plays it.
        .filter { ActivityCardRules.isDrawable($0.activity, isStillListening: matchingPresence(for: $0) != nil) }
    }

    private func buildActivityBlock(now: Date) -> MemberActivityBlock? {
        guard let channelID = selectedChannelID else { return nil }
        let entries = activityEntries(for: channelID, now: now)
        guard !entries.isEmpty, let guildID = channelIndex.guildID(of: channelID) else { return nil }
        let hidden = AppSettings.shared.hidesActivityCards
        let shown = hidden ? [] : activityExpanded ? entries : Array(entries.prefix(ActivityCardRules.collapsedCount))
        return MemberActivityBlock(
            count: entries.count,
            isExpanded: activityExpanded,
            isHidden: hidden,
            cards: shown.map { activityCard(for: $0, inGuild: guildID, now: now) }
        )
    }

    /// One card, as Discord's (`322789`, `868065`, `506326`) words it —
    /// docs/ACTIVITY-CARDS.md decisions 5 and 6.
    func activityCard(for entry: ActivityFeedEntry, inGuild guildID: GuildID, now: Date) -> MemberActivityCard {
        let activity = entry.activity
        let author = activity.authorID
        let faces = entry.participants.prefix(3).map { userID in
            MemberActivityCard.Face(
                url: avatarURL(forUserID: userID, inGuild: guildID, side: MemberActivityGeometry.face),
                monogram: users[userID]?.monogram ?? "?"
            )
        }
        let nameColor = members[guildID]?[author].flatMap { member in
            roles[guildID].flatMap { RoleResolver.nameColorValue(of: member.roleIDs, in: $0) }
        }.flatMap(roleColor)
        let context = activityMarkerContext(for: entry, inGuild: guildID, now: now)
        return MemberActivityCard(
            id: entry.id,
            authorID: author,
            faces: Array(faces),
            extraPeople: max(0, entry.participants.count - 3),
            name: voiceName(of: author, inGuild: guildID),
            nameColor: nameColor,
            nameFont: users[author].flatMap { cosmetics(of: $0)?.displayNameStyle?.font }.flatMap { $0 == .default ? nil : $0 },
            title: cardTitle(for: activity),
            markers: ActivityMarkers.markers(for: activity, at: .card, context: context),
            artURL: activityArtURL(for: entry, side: MemberActivityGeometry.art, prefersCover: false),
            artSymbol: activity.subject.symbolName,
            liveSince: activity.isOngoing(at: now)
                ? matchingPresence(for: entry)?.startedAt ?? activity.startedAt ?? entry.snowflakeDate
                : nil,
            occurredAt: entry.snowflakeDate
        )
    }

    /// The card's title — Discord's: a top artist is titled with the artist,
    /// a listening session with its artists (`363670`), the rest with their
    /// subject.
    func cardTitle(for activity: RecentActivity) -> String {
        switch activity.subject {
        case .listening(let track, let artist, _): artist ?? track
        case .listeningSession(let track, let artists, _): artists.isEmpty ? track : artists.joined(separator: ", ")
        default: activity.subject.title
        }
    }

    /// What the markers need beyond the entry: the author's live presence,
    /// voice channel and stream (`202195`, `299846`).
    func activityMarkerContext(for entry: ActivityFeedEntry, inGuild guildID: GuildID?, now: Date) -> ActivityMarkers.Context {
        let activity = entry.activity
        let presence = activity.isLive ? matchingPresence(for: entry) : nil
        var voiceName: String?
        var isStreaming = false
        if activity.isLive, let state = voiceStates[activity.authorID], let channelID = state.channelID,
           permissionGate.canView(channelID), let channel = channelIndex[channelID]
        {
            voiceName = channel.name
            isStreaming = state.isStreaming
        }
        return ActivityMarkers.Context(
            party: presence.flatMap { ActivityCardRules.partyText(state: $0.state, size: $0.partySize) },
            voiceChannelName: voiceName,
            isStreaming: isStreaming,
            entryDate: entry.snowflakeDate,
            now: now
        )
    }

    /// The author's presence this entry is the record of, while it is live —
    /// Discord's `getMatchingActivity`: the same game or activity; for music,
    /// their Spotify.
    func matchingPresence(for entry: ActivityFeedEntry) -> Activity? {
        let activities = presences[entry.activity.authorID]?.activities?.list ?? []
        switch entry.activity.subject {
        case .listening, .listeningSession:
            return activities.first { $0.kind == .listening }
        default:
            return activities.first { entry.activity.records($0) }
        }
    }

    /// The picture a card or popout draws (`325158`'s `nO`): the live
    /// presence's own picture first; music and shows their artwork; a game's
    /// **cover** (portrait box art) in the popout, its square mark on the card;
    /// the application's icon last.
    func activityArtURL(for entry: ActivityFeedEntry, side: CGFloat, prefersCover: Bool) -> URL? {
        let activity = entry.activity
        if activity.isLive, let live = matchingPresence(for: entry)?.largeImageURL { return live }
        switch activity.subject {
        case .listening(_, _, let artwork), .listeningSession(_, _, let artwork):
            return artwork
        case .watched(_, _, let applicationID):
            if let url = Activity.assetURL(activity.details.mediaImage, application: applicationID, side: side) {
                return url
            }
            return applicationIconURL(applicationID, side: side)
        case .game(_, let applicationID), .activity(_, let applicationID), .topGame(_, let applicationID):
            if let game = applicationID.flatMap({ games[$0] }) {
                if prefersCover, gameArtIsCover(game, kind: .cover) {
                    return gameArtURL(game, kind: .cover, side: side * 2)
                }
                if let mark = gameArtURL(game, kind: .mark, side: side) { return mark }
            }
            return applicationIconURL(applicationID, side: side)
        }
    }

    /// Whether the popout's picture is a portrait cover — drawn at its own
    /// shape rather than squared (Discord's `aspectRatio: "none"`).
    func activityArtIsCover(for entry: ActivityFeedEntry) -> Bool {
        if entry.activity.isLive, matchingPresence(for: entry)?.largeImageURL != nil { return false }
        switch entry.activity.subject {
        case .game(_, let applicationID?):
            return games[applicationID].map { gameArtIsCover($0, kind: .cover) } ?? false
        default:
            return false
        }
    }

    // MARK: Acting on the section

    /// The heading clicked: a hidden section comes back; a long one folds or
    /// unfolds — Discord's `x` in `946228`.
    func toggleActivitySection() {
        let settings = AppSettings.shared
        if settings.hidesActivityCards {
            settings.hidesActivityCards = false
        } else {
            activityExpanded.toggle()
        }
    }

    func setActivityCardsHidden(_ hidden: Bool) {
        AppSettings.shared.hidesActivityCards = hidden
        if !hidden { sessionController.loadActivityFeedIfDue() }
    }

    /// A click on a card: its popout, pinned until a click elsewhere or
    /// Escape. A click on the card already open by hover only pins it.
    func openActivityCard(_ entryID: String, anchor: CGRect) {
        activityHoverTask?.cancel()
        activityCardRequest = ActivityCardRequest(entryID: entryID, anchor: anchor)
    }

    /// The pointer rested on a card for 100 ms: its popout — unless another
    /// one is pinned (a reply being written is not taken away by a pass over
    /// the list).
    func hoverActivityCard(_ entryID: String, anchor: CGRect) {
        activityHoverTask?.cancel()
        if let open = activityCardRequest {
            guard open.opensOnHover, open.entryID != entryID else { return }
        }
        activityCardRequest = ActivityCardRequest(entryID: entryID, anchor: anchor, opensOnHover: true)
    }

    /// The pointer left the cards or the popout: a hover-opened popout closes
    /// a moment later, unless by then the pointer is on it (or back on a card).
    ///
    /// **150 ms, a little over the 100 it takes to open** (Discord uses 100
    /// for both): a pointer going from the popout back onto its card reopens
    /// it at 100, which cancels this before it fires — at equal delays the two
    /// raced and the popout blinked shut and open.
    func endActivityCardHover() {
        activityHoverTask?.cancel()
        guard activityCardRequest?.opensOnHover == true else { return }
        activityHoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled,
                  self.activityCardRequest?.opensOnHover == true,
                  !self.isActivityPopoutHovered
            else { return }
            self.activityCardRequest = nil
        }
    }

    /// The popout under the pointer, or not.
    func setActivityPopoutHovered(_ hovered: Bool) {
        isActivityPopoutHovered = hovered
        if hovered { activityHoverTask?.cancel() } else { endActivityCardHover() }
    }

    /// The reader started using the popout — a focused or typed reply, the
    /// emoji picker: it stays until they are done with it.
    func pinActivityCard() {
        activityHoverTask?.cancel()
        guard activityCardRequest?.opensOnHover == true else { return }
        activityCardRequest?.opensOnHover = false
    }

    /// Whether the popout up now was opened by hover — the member list keeps
    /// tracking the pointer under it.
    var isActivityPopoutHoverOpened: Bool {
        activityCardRequest?.opensOnHover == true
    }

    /// The entry a popout is about, wherever the feed holds it.
    func activityEntry(_ id: String) -> ActivityFeedEntry? {
        activityFeed.inbox?.entries.first { $0.id == id }
    }

    /// Records that these cards were shown — after three days they retire.
    func noteActivityCardsShown(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        AppSettings.shared.activityImpressions.record(ids, at: .now)
    }
}
