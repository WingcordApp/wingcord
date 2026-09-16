import Foundation
import WingcordCore

struct RosterMemoKey: Hashable, Sendable {
    var guildID: GuildID?
    var channelID: ChannelID?
    var memberRevision: UInt64
    var presenceRevision: UInt64
    var roleRevision: UInt64
    /// A group conversation's roster IS its channel's recipient list, so this
    /// memo has to see a channel change. It is the revision that deliberately
    /// does **not** move on an inbound message — see `ChannelIndex` — so
    /// carrying it costs a rebuild when somebody joins the group and never
    /// otherwise.
    var structureRevision: UInt64
    /// **In the key, not merely read by the builder.** A memo whose key does not
    /// carry a setting is present, correct and never invalidated — the roster
    /// would keep serving the saturation it was built with until something else
    /// happened to move a revision.
    var colorSaturation: Double
}

extension AppModel {

    /// Names in order, sorted once on a precomputed key.
    ///
    /// **Never sort with `localizedCaseInsensitiveCompare` in a comparator.** It
    /// is an ICU call per comparison, and a roster of five hundred is ~4,500
    /// comparisons — measured at roughly a third of a second of main thread on
    /// the app this replaces, on every roster rebuild. Decorate, sort, undecorate.
    ///
    /// Shared by the guild roster and the group one: two copies of a sort is two
    /// places for a tie-break to differ, and a list that orders differently in
    /// two surfaces is a list nobody can scan.
    static func sortedByName(_ entries: [MemberEntry]) -> [MemberEntry] {
        struct SortKey {
            var key: String
            var entry: MemberEntry
        }
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
            roleRevision: roleRevision,
            structureRevision: channelIndex.structureRevision,
            colorSaturation: userColorSaturation
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

    /// **Read once per build, never per row.** `userColorSaturation` is an
    /// observable property, so a read inside the loop is a tracked access per
    /// member — five hundred of them on a large roster, for a value that cannot
    /// change while the array is being built.
    private func buildRoster(
        members memberTable: [GuildID: [UserID: Member]],
        presences presenceTable: [UserID: Presence]
    ) -> [MemberSection] {
        let saturation = userColorSaturation
        // A group conversation has a roster of its own — its recipients — and
        // no guild behind it, so it never reaches the table lookup below.
        if let channelID = selectedChannelID,
           let channel = channelIndex[channelID],
           channel.kind == .groupDirectMessage
        {
            return buildGroupRoster(channel, presences: presenceTable)
        }
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
            // One role answers for both, so a gradient can never be drawn over
            // a different role's colour — see `RoleResolver.nameColorRole`.
            let coloured = RoleResolver.nameColorRole(of: member.roleIDs, in: guildRoles)
            let entry = MemberEntry(
                userID: userID,
                name: member.resolvedName(user: user),
                colorValue: coloured?.displayColorValue
                    .map { UserColor.desaturated($0, by: saturation) },
                gradient: coloured?.colors
                    .flatMap { RoleColors.wrappedStops($0) }?
                    .map { UserColor.desaturated($0, by: saturation) },
                avatarURL: avatarURL(forUserID: userID, inGuild: guildID, side: Metrics.avatarRow),
                monogram: user.monogram,
                decorationURL: user.decoration?.avatarDecorationHash
                    .flatMap { CDN.avatarDecoration(hash: $0) },
                displayNameFont: user.decoration?.displayNameStyle?.font,
                status: status,
                isOnMobile: presence?.isOnMobile ?? false,
                subtitle: presence?.primaryActivity?.rowSubtitle
                    ?? presence?.customStatus?.rowSubtitle,
                isBot: user.isBot,
                tag: user.decoration?.primaryGuildTag,
                tagBadgeURL: user.decoration.flatMap { decoration in
                    guard let guildID = decoration.primaryGuildID,
                          let hash = decoration.primaryGuildBadgeHash
                    else { return nil }
                    return CDN.guildTagBadge(guildID: guildID, hash: hash)
                },
                nameplateURL: user.decoration?.nameplate?.artworkURL,
                nameplateAnimatedURL: user.decoration?.nameplate?.animatedArtworkURL,
                nameplatePalette: user.decoration?.nameplate?.palette ?? .none
            )

            if status == .offline {
                offline.append(entry)
            } else if let role = RoleResolver.hoistRole(of: member.roleIDs, in: guildRoles) {
                hoisted[role.id, default: []].append(entry)
            } else {
                online.append(entry)
            }
        }

        let sorted = Self.sortedByName

        var sections: [MemberSection] = []
        for role in guildRoles.values.filter({ hoisted[$0.id] != nil })
            .sorted(by: Role.seniorityOrder)
        {
            let entries = sorted(hoisted[role.id] ?? [])
            sections.append(MemberSection(
                roleID: role.id,
                title: role.name,
                count: entries.count,
                colorValue: role.displayColorValue
                    .map { UserColor.desaturated($0, by: saturation) },
                iconURL: role.iconHash.flatMap {
                    CDN.roleIcon(roleID: role.id, hash: $0, side: MemberRowGeometry.sectionIconSide)
                },
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

    /// The roster of a group conversation.
    ///
    /// **Built from the channel, not from a member table.** A group has no guild
    /// and therefore no member records, no roles and no hoisting — its people
    /// are the `recipients` array Discord already sent with the channel, plus
    /// the reader, who is in the conversation and is not in that array.
    ///
    /// Two sections, Online and Offline, because that is the only grouping a
    /// group has. The owner carries a crown wherever they land rather than being
    /// hoisted into a section of one.
    private func buildGroupRoster(
        _ channel: Channel,
        presences presenceTable: [UserID: Presence]
    ) -> [MemberSection] {
        var online: [MemberEntry] = []
        var offline: [MemberEntry] = []

        // The reader first, so a conversation whose recipients have not arrived
        // still lists somebody — and so the list matches the group's own
        // membership rather than everybody-but-you.
        var participants = channel.recipientIDs
        if let currentUserID, !participants.contains(currentUserID) {
            participants.append(currentUserID)
        }

        for userID in participants {
            guard let user = users[userID] else { continue }
            let presence = presenceTable[userID]
            let status = presence?.status ?? .offline
            let entry = MemberEntry(
                userID: userID,
                name: user.preferredName,
                // No roles in a group, so no role colour. Nil is the default
                // ink, which is what every name here should be.
                colorValue: nil,
                avatarURL: avatarURL(for: user, side: Metrics.avatarRow),
                monogram: user.monogram,
                decorationURL: user.decoration?.avatarDecorationHash
                    .flatMap { CDN.avatarDecoration(hash: $0) },
                displayNameFont: user.decoration?.displayNameStyle?.font,
                status: status,
                isOnMobile: presence?.isOnMobile ?? false,
                subtitle: presence?.primaryActivity?.rowSubtitle
                    ?? presence?.customStatus?.rowSubtitle,
                isBot: user.isBot,
                tag: user.decoration?.primaryGuildTag,
                tagBadgeURL: user.decoration.flatMap { decoration in
                    guard let guildID = decoration.primaryGuildID,
                          let hash = decoration.primaryGuildBadgeHash
                    else { return nil }
                    return CDN.guildTagBadge(guildID: guildID, hash: hash)
                },
                nameplateURL: user.decoration?.nameplate?.artworkURL,
                nameplateAnimatedURL: user.decoration?.nameplate?.animatedArtworkURL,
                nameplatePalette: user.decoration?.nameplate?.palette ?? .none,
                isOwner: userID == channel.ownerID
            )
            if status == .offline { offline.append(entry) } else { online.append(entry) }
        }

        var sections: [MemberSection] = []
        if !online.isEmpty {
            let entries = Self.sortedByName(online)
            sections.append(MemberSection(
                roleID: nil,
                title: "Online",
                count: entries.count,
                colorValue: nil,
                members: entries
            ))
        }
        if !offline.isEmpty {
            let entries = Self.sortedByName(offline)
            sections.append(MemberSection(
                roleID: nil,
                title: "Offline",
                count: entries.count,
                colorValue: nil,
                members: entries
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
