import Foundation
import WingcordCore

struct RosterMemoKey: Hashable, Sendable {
    var guildID: GuildID?
    var channelID: ChannelID?
    var memberRevision: UInt64
    var presenceRevision: UInt64
    var roleRevision: UInt64
}

extension AppModel {

    /// The member list for the selected channel.
    ///
    /// Memoized because a presence flush is the app's most frequent event: on a
    /// large server it arrives several times a second, and it moves nobody
    /// across the online line the overwhelming majority of the time. A memo whose
    /// key does not change means the roster's whole array is handed back by
    /// pointer, and `Array ==` short-circuits on buffer identity — so the canvas
    /// compares one pointer instead of rebuilding forty rows.
    var rosterSections: [MemberSection] {
        let key = RosterMemoKey(
            guildID: selectedGuildID,
            channelID: selectedChannelID,
            memberRevision: memberRevision,
            presenceRevision: presenceRevision,
            roleRevision: roleRevision
        )
        // Read the observable inputs before the early return, so a cache hit
        // still registers the dependency the reader needs.
        let memberTable = members
        let presenceTable = presences

        if let rosterCache, rosterCache.key == key { return rosterCache.value }

        let value = buildRoster(members: memberTable, presences: presenceTable)
        rosterCache = (key, value)
        return value
    }

    private func buildRoster(
        members memberTable: [GuildID: [UserID: Member]],
        presences presenceTable: [UserID: Presence]
    ) -> [MemberSection] {
        guard let guildID = selectedGuildID,
              let guildMembers = memberTable[guildID]
        else { return [] }

        let guildRoles = roles[guildID] ?? [:]
        let channel = selectedChannelID.flatMap { channelIndex[$0] }

        // Grouped by hoist role, plus the two synthetic groups. A dictionary of
        // arrays rather than repeated filtering: filtering per section is a full
        // pass over the roster per section, and a guild with twenty hoisted
        // roles is twenty passes.
        var hoisted: [RoleID: [MemberEntry]] = [:]
        var online: [MemberEntry] = []
        var offline: [MemberEntry] = []

        for (userID, member) in guildMembers {
            guard let user = users[userID] else { continue }

            // A member who cannot see the channel does not appear in its member
            // list. This is the same gate the channel list uses, applied from
            // the other side — and leaving it out is how a private channel's
            // roster lists the whole server.
            if let channel, !canSee(channel: channel, member: member, userID: userID, guildID: guildID) {
                continue
            }

            let presence = presenceTable[userID]
            let status = presence?.status ?? .offline
            let entry = MemberEntry(
                userID: userID,
                name: member.resolvedName(user: user),
                colorValue: RoleResolver.nameColorValue(of: member.roleIDs, in: guildRoles),
                avatarURL: avatarURL(forUserID: userID, inGuild: guildID, side: Metrics.avatarRow),
                monogram: user.monogram,
                decorationURL: user.decoration?.avatarDecorationHash
                    .flatMap { CDN.avatarDecoration(hash: $0) },
                status: status,
                isOnMobile: presence?.isOnMobile ?? false,
                subtitle: presence?.primaryActivity?.rowSubtitle
                    ?? presence?.customStatus?.rowSubtitle,
                isBot: user.isBot,
                tag: user.decoration?.primaryGuildTag,
                // Reserved. See `MemberEntry.nameplateURL`.
                nameplateURL: nil
            )

            if status == .offline {
                offline.append(entry)
            } else if let role = RoleResolver.hoistRole(of: member.roleIDs, in: guildRoles) {
                hoisted[role.id, default: []].append(entry)
            } else {
                online.append(entry)
            }
        }

        // Decorate-sort-undecorate on a precomputed lowercased key.
        //
        // **Never sort with `localizedCaseInsensitiveCompare` in a comparator.**
        // It is an ICU call per comparison, and a roster of five hundred is
        // ~4,500 comparisons — measured at roughly a third of a second of main
        // thread on the app this replaces, on every roster rebuild.
        struct SortKey {
            var key: String
            var entry: MemberEntry
        }

        func sorted(_ entries: [MemberEntry]) -> [MemberEntry] {
            var decorated: [SortKey] = []
            decorated.reserveCapacity(entries.count)
            for entry in entries {
                decorated.append(SortKey(key: entry.name.localizedLowercase, entry: entry))
            }
            decorated.sort { lhs, rhs in
                if lhs.key != rhs.key { return lhs.key < rhs.key }
                return lhs.entry.userID < rhs.entry.userID
            }
            return decorated.map(\.entry)
        }

        var sections: [MemberSection] = []
        for role in guildRoles.values.filter({ hoisted[$0.id] != nil })
            .sorted(by: Role.seniorityOrder)
        {
            let entries = sorted(hoisted[role.id] ?? [])
            sections.append(MemberSection(
                roleID: role.id,
                title: role.name,
                count: entries.count,
                colorValue: role.displayColorValue,
                members: entries
            ))
        }

        let onlineEntries = sorted(online)
        if !onlineEntries.isEmpty {
            sections.append(MemberSection(
                roleID: nil,
                title: "Online",
                count: onlineEntries.count,
                colorValue: nil,
                members: onlineEntries
            ))
        }

        let offlineEntries = sorted(offline)
        if !offlineEntries.isEmpty {
            sections.append(MemberSection(
                roleID: nil,
                title: "Offline",
                count: offlineEntries.count,
                colorValue: nil,
                members: offlineEntries
            ))
        }

        return sections
    }

    /// Whether one member may see a channel.
    ///
    /// Resolved through the same `PermissionResolver` the reader's own gate uses,
    /// so the two can never disagree about what an overwrite means. It is not
    /// routed through `PermissionGate`, which caches answers for *the reader*
    /// specifically.
    private func canSee(
        channel: Channel,
        member: Member,
        userID: UserID,
        guildID: GuildID
    ) -> Bool {
        guard let guild = guilds[guildID] else { return false }
        // A DM has no roster to filter.
        guard channel.guildID != nil else { return true }
        return PermissionResolver.permissions(
            forMember: member.roleIDs,
            userID: userID,
            guildID: guildID,
            guildOwnerID: guild.ownerID,
            roles: roles[guildID] ?? [:],
            channel: channel
        )
        .contains(.viewChannel)
    }
}

private extension Activity {
    /// A custom status becomes a subtitle only when it has text; an emoji-only
    /// status is drawn beside the name instead, not on a line of its own.
    var rowSubtitle_customOnly: String? {
        kind == .custom ? state : nil
    }
}

private extension Optional where Wrapped == Activity {
    var rowSubtitle: String? {
        self?.rowSubtitle_customOnly
    }
}
