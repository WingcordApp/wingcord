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

    /// One card, as Discord's (`322789`, `868065`, `506326`) words it.
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

        var badges: [MemberActivityCard.Badge] = []
        var art: URL?
        switch activity.subject {
        case .game(_, let applicationID), .activity(_, let applicationID):
            badges.append(.clock(symbol: activity.subject.symbolName))
            if ActivityCardRules.isNewRelease(applicationID, now: now) {
                badges.append(.label(symbol: "sparkles", text: "New Release", isPositive: false))
            }
            if case .game = activity.subject {
                for trait in activity.traits {
                    switch trait {
                    case .newPlayer:
                        badges.append(.label(symbol: "person.fill.badge.plus", text: "New Player", isPositive: true))
                    case .streak(let days)
                        where ActivityCardRules.showsStreak(days: days, entryDate: entry.snowflakeDate, now: now):
                        badges.append(.label(symbol: "bolt.fill", text: "\(days)x Streak", isPositive: false))
                    default:
                        break
                    }
                }
            }
            if activity.traits.contains(.trending) {
                badges.append(.label(symbol: "flame.fill", text: "Trending", isPositive: false))
            }
            if case .game = activity.subject,
               activity.traits.contains(where: { if case .returning = $0 { true } else { false } })
            {
                badges.append(.label(symbol: "arrow.clockwise", text: "Returning", isPositive: false))
            }
            if activity.traits.contains(.marathon), let duration = activity.duration {
                let hours = Int((duration / 3600).rounded())
                if hours > 0 { badges.append(.label(symbol: "clock.fill", text: "\(hours)h Marathon", isPositive: false)) }
            }
            art = applicationID.flatMap { id in games[id].flatMap { gameArtURL($0, kind: .mark, side: MemberActivityGeometry.art) } }
                ?? applicationIconURL(applicationID, side: MemberActivityGeometry.art)
        case .listening(_, _, let artworkURL):
            for case .weeklyCount(let count) in activity.traits {
                badges.append(.label(symbol: "trophy.fill", text: "\(count.formatted()) tracks this week", isPositive: false))
            }
            art = artworkURL
        }

        return MemberActivityCard(
            id: entry.id,
            authorID: author,
            faces: Array(faces),
            name: voiceName(of: author, inGuild: guildID),
            nameColor: nameColor,
            title: activity.subject.title,
            badges: badges,
            artURL: art,
            artSymbol: activity.subject.symbolName,
            liveSince: activity.isOngoing(at: now) ? activity.startedAt ?? entry.snowflakeDate : nil,
            occurredAt: entry.snowflakeDate
        )
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

    func openActivityCard(_ entryID: String, anchor: CGRect) {
        activityCardRequest = ActivityCardRequest(entryID: entryID, anchor: anchor)
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
