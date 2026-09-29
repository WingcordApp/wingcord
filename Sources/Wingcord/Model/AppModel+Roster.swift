import Foundation
import WingcordCore

/// One of a server's member lists — see `MemberList`.
struct MemberListKey: Hashable, Sendable {
    var guildID: GuildID
    var listID: String
}

struct RosterMemoKey: Hashable, Sendable {
    var guildID: GuildID?
    var channelID: ChannelID?
    /// Any list changed. Coarse on purpose: a list update is a handful of rows,
    /// and the build it costs is the few hundred members around the viewport.
    var memberListRevision: UInt64
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
    /// The ground a role colour is checked against — see
    /// `AppModel.roleColor(_:)`. In the key for `colorSaturation`'s reason: a
    /// theme change moves which names need lifting, and nothing else would
    /// tell this memo so.
    var inkCeiling: UInt32
    /// Who is typing in the channel on screen — the dots a row draws. The set,
    /// not a revision: somebody typing in another channel moves nothing here,
    /// and a roster of five hundred is not rebuilt for it.
    var typers: Set<UserID>
    /// Who is talking where, for the "In voice" a row's line can say — the
    /// facts, for `typers`' reason. See `RosterVoiceFacts`.
    var voice: RosterVoiceFacts
}

/// The voice facts the member list's lines draw, for the conversation on screen.
///
/// **The facts, not a revision.** `voiceRevision` moves whenever anybody in any
/// server joins, leaves or mutes, and a roster of five hundred is not rebuilt
/// for a call in another server. Resolved on every read — one pass over the
/// voice table, with visibility a cached lookup — and compared as two small
/// tables, which costs far less than the rebuild it spares.
struct RosterVoiceFacts: Hashable, Sendable {
    /// Where each person is talking, where the reader can see the room.
    var places: [UserID: ActivityStatusLine.VoicePlace] = [:]
    /// Who among them is sharing a screen.
    var sharing: Set<UserID> = []
}

extension AppModel {

    /// Names in order, sorted once on a precomputed key.
    ///
    /// **Never sort with `localizedCaseInsensitiveCompare` in a comparator.** It
    /// is an ICU call per comparison, and a roster of five hundred is ~4,500
    /// comparisons — measured at roughly a third of a second of main thread on
    /// the app this replaces, on every roster rebuild. Decorate, sort, undecorate.
    ///
    /// A server sorts its own lists; this orders the one roster the client
    /// builds itself, a group conversation's.
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

    /// The list a channel shows, and the channel whose subscription feeds it.
    ///
    /// **A thread shows its parent's list**, the way Discord's client treats an
    /// announcement thread; its own member list is a different feature this
    /// column does not draw. Nil outside a server.
    func memberListTarget(for channelID: ChannelID) -> (key: MemberListKey, channelID: ChannelID)? {
        guard var channel = channelIndex[channelID], let guildID = channel.guildID else { return nil }
        if channel.kind.isThread, let parent = channel.parentID.flatMap({ channelIndex[$0] }) {
            channel = parent
        }
        let everyone = roles[guildID]?[RoleID(rawValue: guildID.rawValue)]?.permissions ?? []
        let listID = MemberList.id(for: channel, everyonePermissions: everyone)
        return (MemberListKey(guildID: guildID, listID: listID), channel.id)
    }

    /// The member list for the selected channel.
    ///
    /// Memoized because a presence flush is the app's most frequent event: on a
    /// large server it arrives several times a second, and it moves nobody
    /// across the online line the overwhelming majority of the time. A memo
    /// whose key does not change hands the same roster back, and the canvas
    /// compares it and stops.
    var roster: Roster {
        let key = RosterMemoKey(
            guildID: selectedGuildID,
            channelID: selectedChannelID,
            memberListRevision: memberListRevision,
            memberRevision: memberRevision,
            presenceRevision: presenceRevision,
            roleRevision: roleRevision,
            structureRevision: channelIndex.structureRevision,
            colorSaturation: userColorSaturation,
            inkCeiling: ThemeStore.shared.ground.inkCeiling,
            typers: selectedChannelID.map { Set(typers(in: $0).keys) } ?? [],
            voice: rosterVoiceFacts()
        )
        // Read the observable inputs before the early return, so a cache hit
        // still registers the dependency the reader needs.
        let memberTable = members
        let presenceTable = presences

        if let rosterCache, rosterCache.key == key { return rosterCache.value }

        let value = buildRoster(members: memberTable, presences: presenceTable, voice: key.voice)
        rosterCache = (key, value)
        return value
    }

    private func buildRoster(
        members memberTable: [GuildID: [UserID: Member]],
        presences presenceTable: [UserID: Presence],
        voice: RosterVoiceFacts
    ) -> Roster {
        // A group conversation has a roster of its own — its recipients — and
        // no guild behind it, so it never reaches the list below.
        if let channelID = selectedChannelID,
           let channel = channelIndex[channelID],
           channel.kind == .groupDirectMessage
        {
            return buildGroupRoster(channel, presences: presenceTable, voice: voice)
        }
        guard let channelID = selectedChannelID,
              let target = memberListTarget(for: channelID)
        else { return .empty }

        let guildID = target.key.guildID
        let guildRoles = roles[guildID] ?? [:]
        let list = memberLists[target.key] ?? MemberList()
        let guildMembers = memberTable[guildID] ?? [:]
        let people = RosterPeople(
            saturation: userColorSaturation,
            // **Read once, for the channel on screen.** Typing is per
            // conversation, and the roster is drawn beside one.
            typing: typers(in: channelID),
            voice: voice
        )

        let sections = zip(list.groups, list.headingIndexes).map { group, index in
            let title: String?
            var colorValue: UInt32?
            var iconURL: URL?
            switch group.id {
            case .role(let roleID):
                // A role nobody here knows is a heading with no name, which is
                // how Discord draws it too.
                let role = guildRoles[roleID]
                title = role?.name ?? ""
                colorValue = roleColor(role?.displayColorValue)
                iconURL = role?.iconHash.flatMap {
                    CDN.roleIcon(roleID: roleID, hash: $0, side: MemberRowGeometry.sectionIconSide)
                }
            case .online: title = "Online"
            case .offline: title = "Offline"
            case .unknown: title = nil
            }
            return RosterSection(
                label: title.map { "\($0) — \(group.count.formatted())" },
                colorValue: colorValue,
                iconURL: iconURL,
                index: index,
                count: group.count
            )
        }

        // Only the rows the server has sent — a few hundred, whatever the
        // list's length. Somebody whose records are missing stays a placeholder.
        var entries: [Int: MemberEntry] = [:]
        entries.reserveCapacity(list.rows.count)
        for (index, row) in list.rows {
            guard case .member(let userID) = row,
                  let member = guildMembers[userID],
                  let user = users[userID]
            else { continue }
            entries[index] = memberEntry(
                user, member: member, guildID: guildID, roles: guildRoles,
                presence: presenceTable[userID], people: people
            )
        }

        return Roster(
            identity: "\(guildID):\(target.key.listID)",
            sections: sections,
            members: entries,
            rowCount: list.rowCount
        )
    }

    /// One server member's row.
    private func memberEntry(
        _ user: User,
        member: Member,
        guildID: GuildID,
        roles guildRoles: [RoleID: Role],
        presence: Presence?,
        people: RosterPeople
    ) -> MemberEntry {
        let userID = user.id
        // One role answers for both, so a gradient can never be drawn over a
        // different role's colour — see `RoleResolver.nameColorRole`.
        let coloured = RoleResolver.nameColorRole(of: member.roleIDs, in: guildRoles)
        let cosmetics = cosmetics(of: user)
        return MemberEntry(
            userID: userID,
            name: member.resolvedName(user: user),
            colorValue: roleColor(coloured?.displayColorValue),
            gradient: AppSettings.shared.roleColorPlacement.tintsNames
                ? coloured?.colors
                    .flatMap { RoleColors.wrappedStops($0) }?
                    .map { UserColor.desaturated($0, by: people.saturation) }
                : nil,
            avatarURL: avatarURL(forUserID: userID, inGuild: guildID, side: Metrics.avatarRow),
            monogram: user.monogram,
            decorationURL: cosmetics?.avatarDecorationHash.flatMap { CDN.avatarDecoration(hash: $0) },
            displayNameFont: cosmetics?.displayNameStyle?.font,
            status: presence?.status ?? .offline,
            isOnMobile: presence?.isOnMobile ?? false,
            activityLine: Self.activityLine(
                presence: presence,
                isBot: user.isBot,
                voice: people.voice.places[userID],
                isStreaming: people.voice.sharing.contains(userID)
            ),
            isBot: user.isBot,
            tag: cosmetics?.primaryGuildTag,
            tagBadgeURL: cosmetics.flatMap { decoration in
                guard let guildID = decoration.primaryGuildID,
                      let hash = decoration.primaryGuildBadgeHash
                else { return nil }
                return CDN.guildTagBadge(guildID: guildID, hash: hash)
            },
            nameplateURL: cosmetics?.nameplate?.artworkURL,
            nameplateAnimatedURL: cosmetics?.nameplate?.animatedArtworkURL,
            nameplatePalette: cosmetics?.nameplate?.palette ?? .none,
            isTyping: people.typing[userID] != nil
        )
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
        presences presenceTable: [UserID: Presence],
        voice: RosterVoiceFacts
    ) -> Roster {
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
                decorationURL: cosmetics(of: user)?.avatarDecorationHash
                    .flatMap { CDN.avatarDecoration(hash: $0) },
                displayNameFont: cosmetics(of: user)?.displayNameStyle?.font,
                status: status,
                isOnMobile: presence?.isOnMobile ?? false,
                activityLine: Self.activityLine(
                    presence: presence,
                    isBot: user.isBot,
                    voice: voice.places[userID],
                    isStreaming: voice.sharing.contains(userID)
                ),
                isBot: user.isBot,
                tag: cosmetics(of: user)?.primaryGuildTag,
                tagBadgeURL: cosmetics(of: user).flatMap { decoration in
                    guard let guildID = decoration.primaryGuildID,
                          let hash = decoration.primaryGuildBadgeHash
                    else { return nil }
                    return CDN.guildTagBadge(guildID: guildID, hash: hash)
                },
                nameplateURL: cosmetics(of: user)?.nameplate?.artworkURL,
                nameplateAnimatedURL: cosmetics(of: user)?.nameplate?.animatedArtworkURL,
                nameplatePalette: cosmetics(of: user)?.nameplate?.palette ?? .none,
                isOwner: userID == channel.ownerID
            )
            if status == .offline { offline.append(entry) } else { online.append(entry) }
        }

        var roster = Roster(identity: "group:\(channel.id)", sections: [], members: [:], rowCount: 0)
        for (title, people) in [("Online", online), ("Offline", offline)] where !people.isEmpty {
            let heading = roster.rowCount
            roster.sections.append(RosterSection(
                label: "\(title) — \(people.count.formatted())",
                index: heading,
                count: people.count
            ))
            for (offset, entry) in Self.sortedByName(people).enumerated() {
                roster.members[heading + 1 + offset] = entry
            }
            roster.rowCount = heading + 1 + people.count
        }
        return roster
    }
}

/// What one roster build reads once and hands to every row.
///
/// **Read once per build, never per row.** `userColorSaturation` is an
/// observable property, so a read inside the loop is a tracked access per
/// member, for a value that cannot change while the roster is being built.
private struct RosterPeople {
    var saturation: Double
    /// Who is typing in the channel on screen.
    var typing: [UserID: Date]
    var voice: RosterVoiceFacts
}

extension AppModel {

    /// Who is talking where, for the roster on screen — see `RosterVoiceFacts`.
    ///
    /// A server's list counts the rooms in that server the reader can see —
    /// Discord's own gate on the voice channel it names (module `714114`); a
    /// group's counts its own call.
    fileprivate func rosterVoiceFacts() -> RosterVoiceFacts {
        var facts = RosterVoiceFacts()
        let group = selectedChannelID
            .flatMap { channelIndex[$0] }
            .flatMap { $0.kind == .groupDirectMessage ? $0 : nil }
        guard group != nil || selectedGuildID != nil else { return facts }
        for state in voiceStates.values {
            guard let channelID = state.channelID else { continue }
            let place: ActivityStatusLine.VoicePlace
            if let group {
                guard channelID == group.id else { continue }
                place = .call
            } else {
                guard state.guildID == selectedGuildID,
                      let kind = channelIndex[channelID]?.kind,
                      permissionGate.canView(channelID)
                else { continue }
                place = kind == .stage ? .stage : .voiceChannel
            }
            facts.places[state.userID] = place
            if state.isStreaming { facts.sharing.insert(state.userID) }
        }
        return facts
    }
}
