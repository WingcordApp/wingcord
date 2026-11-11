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
    /// How the reader asked for it to be arranged, and what they folded away.
    /// In the key for `colorSaturation`'s reason.
    var organization = MemberListOrganization.standard
    var collapsed: Set<String> = []
    /// The room the reader is in, which is what takes Join Voice off a row.
    var connectedVoiceChannelID: ChannelID?
    /// A row's picture falls back to the application's icon, and those arrive
    /// after the row does.
    var applicationsCount = 0
    var gamesCount = 0
    /// A friend here is somebody the client hears about.
    var friendsCount = 0
    var groupsInVoice = true
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
    /// The room each of them is in.
    var channels: [UserID: ChannelID] = [:]
    /// When they joined it, where the gateway said.
    var connectedAt: [UserID: Date] = [:]
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
            presenceRevision: rosterPresenceRevision,
            roleRevision: roleRevision,
            structureRevision: channelIndex.structureRevision,
            colorSaturation: userColorSaturation,
            inkCeiling: nameGround,
            typers: selectedChannelID.map { Set(typers(in: $0).keys) } ?? [],
            voice: rosterVoiceFacts(),
            organization: AppSettings.shared.memberListOrganization,
            collapsed: AppSettings.shared.collapsedMemberSections[memberListScope ?? ""] ?? [],
            connectedVoiceChannelID: connectedVoiceChannelID,
            applicationsCount: activityDirectory.apps.count,
            gamesCount: games.count,
            friendsCount: relationships.count,
            groupsInVoice: AppSettings.shared.groupsMembersInVoice
        )
        // Read the observable inputs before the early return, so a cache hit
        // still registers the dependency the reader needs.
        let memberTable = members
        let presenceTable = presences

        if let rosterCache, rosterCache.key == key { return rosterCache.value }

        let value = Signposts.interval("Member list build") {
            buildRoster(members: memberTable, presences: presenceTable, voice: key.voice)
        }
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
        let isWhole = MemberList.isWhole(rowCount: list.rowCount)
        let organization = AppSettings.shared.memberListOrganization
            .resolved(hasRoles: true, isWhole: isWhole)

        let groups = zip(list.groups, list.headingIndexes).map { group, index in
            var section = RosterBuilder.Group(key: .unknown, heading: index, count: group.count)
            switch group.id {
            case .role(let roleID):
                // A role nobody here knows is a heading with no name, which is
                // how Discord draws it too.
                let role = guildRoles[roleID]
                section.key = .role(roleID)
                section.title = role?.name ?? ""
                section.colorValue = roleColor(role?.displayColorValue)
                section.glyph = role.map(sectionGlyph(of:)) ?? .none
            case .online:
                section.key = .online
                section.title = "Online"
                section.glyph = .online
            case .offline:
                section.key = .offline
                section.title = "Offline"
                section.glyph = .offline
            case .unknown:
                break
            }
            return section
        }

        // Only the rows the server has sent — a few hundred, whatever the
        // list's length. Somebody whose records are missing stays a placeholder.
        var rows: [Int: UserID] = [:]
        var entries: [UserID: MemberEntry] = [:]
        rows.reserveCapacity(list.rows.count)
        entries.reserveCapacity(list.rows.count)
        for (index, row) in list.rows {
            guard case .member(let userID) = row,
                  let member = guildMembers[userID],
                  let user = users[userID]
            else { continue }
            rows[index] = userID
            entries[userID] = memberEntry(
                user, member: member, guildID: guildID, roles: guildRoles,
                presence: presenceTable[userID], people: people
            )
        }

        // Everybody else the client hears about live, for the sections at the
        // head: anyone in a room here, and friends. **Only those who may see this
        // channel**, or a private channel's list would name people who aren't on it.
        var candidates: [UserID] = []
        if organization == .activeNow || organization == .game {
            let audience = memberListAudience(of: target.channelID, listID: target.key.listID, in: guildID)
            var wanted = Array(voice.places.keys)
            for (userID, relationship) in relationships where relationship == .friend {
                if presenceTable[userID]?.activities?.list.contains(where: \.isGame) == true {
                    wanted.append(userID)
                }
            }
            for userID in wanted where entries[userID] == nil {
                guard let member = guildMembers[userID],
                      let user = users[userID],
                      // A presence nobody has heard yet might be invisible.
                      presenceTable[userID] != nil,
                      audience(userID, member)
                else { continue }
                entries[userID] = memberEntry(
                    user, member: member, guildID: guildID, roles: guildRoles,
                    presence: presenceTable[userID], people: people
                )
                candidates.append(userID)
            }
        }

        return RosterBuilder(
            identity: "\(guildID):\(target.key.listID)",
            groups: groups,
            rows: rows,
            entries: entries,
            candidates: candidates,
            organization: organization,
            collapsed: AppSettings.shared.collapsedMemberSections[memberListScope ?? ""] ?? [],
            isWhole: isWhole,
            rooms: rosterRooms(voice: voice)
        )
        .build()
    }

    /// The rooms on this list, for gathering people under: none when the reader
    /// has turned that off.
    private func rosterRooms(voice: RosterVoiceFacts) -> [ChannelID: RosterBuilder.Room] {
        guard AppSettings.shared.groupsMembersInVoice else { return [:] }
        var counts: [ChannelID: Int] = [:]
        for room in voice.channels.values { counts[room, default: 0] += 1 }
        var rooms: [ChannelID: RosterBuilder.Room] = [:]
        for (room, occupants) in counts where occupants > 1 {
            guard let channel = channelIndex[room] else { continue }
            rooms[room] = RosterBuilder.Room(
                name: displayName(of: channel),
                isStage: channel.kind == .stage,
                occupants: occupants,
                isReaderIn: connectedVoiceChannelID == room,
                canJoin: channel.kind == .groupDirectMessage || permissionGate.canJoinVoice(room)
            )
        }
        return rooms
    }

    /// What goes in front of a role's name: its uploaded icon, or its emoji.
    func sectionGlyph(of role: Role) -> RosterGlyph {
        if let override = demoRoleIcons[role.id] { return .image(override) }
        if let url = role.iconHash.flatMap({
            CDN.roleIcon(roleID: role.id, hash: $0, side: MemberSectionGeometry.glyphBox)
        }) {
            return .image(url)
        }
        return role.unicodeEmoji.map { .emoji($0) } ?? .none
    }

    /// Who can see a channel, by the rule Discord's list is built on: everybody on
    /// a list everybody shares, otherwise whoever the channel's overwrites let in.
    private func memberListAudience(
        of channelID: ChannelID,
        listID: String,
        in guildID: GuildID
    ) -> (UserID, Member) -> Bool {
        guard listID != "everyone",
              let channel = channelIndex[channelID],
              let guild = guilds[guildID]
        else { return { _, _ in true } }
        let roleTable = roles[guildID] ?? [:]
        return { userID, member in
            PermissionResolver.permissions(
                forMember: member.roleIDs, userID: userID, guildID: guildID,
                guildOwnerID: guild.ownerID, roles: roleTable, channel: channel
            ).contains(.viewChannel)
        }
    }

    /// What the list on screen can be arranged by: a group conversation has no roles,
    /// and a list the server won't send whole can't be put in an order of the client's.
    var memberListCapabilities: MemberListCapabilities {
        if let channelID = selectedChannelID, let channel = channelIndex[channelID],
           channel.kind == .groupDirectMessage
        {
            return MemberListCapabilities(hasRoles: false, isWhole: true)
        }
        guard let channelID = selectedChannelID, let target = memberListTarget(for: channelID) else {
            return MemberListCapabilities(hasRoles: false, isWhole: true)
        }
        return MemberListCapabilities(
            hasRoles: true,
            isWhole: MemberList.isWhole(rowCount: memberLists[target.key]?.rowCount ?? 1)
        )
    }

    /// Who on this list goes by a name, for its search: by nickname, display name or
    /// username, as Discord's own (`nT`, `763349`) — one section, by name.
    ///
    /// **Everybody this session knows about**, which is far more than the list's
    /// rows: the server's answer to `queryMembers` lands in these tables and this
    /// reads it, with nothing to correlate.
    func memberSearchRoster(query: String) -> Roster {
        guard let channelID = selectedChannelID else { return .empty }
        let scope = memberListScope ?? ""
        let key = MemberSearchKey(
            query: query, scope: scope, channelID: channelID,
            memberRevision: memberRevision, presenceRevision: presenceRevision,
            voice: rosterVoiceFacts()
        )
        if let memberSearchCache, memberSearchCache.key == key { return memberSearchCache.value }
        let value = buildMemberSearchRoster(query: query, channelID: channelID, voice: key.voice)
        memberSearchCache = (key, value)
        return value
    }

    private func buildMemberSearchRoster(query: String, channelID: ChannelID, voice: RosterVoiceFacts) -> Roster {
        let needle = MemberListOrder.sortKey(query)
        func matches(_ names: String?...) -> Bool {
            names.contains { name in
                name.map { MemberListOrder.sortKey($0).contains(needle) } ?? false
            }
        }
        let people = RosterPeople(saturation: userColorSaturation, typing: [:], voice: voice)
        var found: [MemberEntry] = []
        if let channel = channelIndex[channelID], channel.kind == .groupDirectMessage {
            var participants = channel.recipientIDs
            if let currentUserID, !participants.contains(currentUserID) { participants.append(currentUserID) }
            for userID in participants {
                guard let user = users[userID],
                      matches(user.username, user.displayName, friendNicknames[userID])
                else { continue }
                found.append(groupEntry(user, in: channel, presence: presences[userID], voice: voice))
            }
        } else if let target = memberListTarget(for: channelID) {
            let guildID = target.key.guildID
            let guildRoles = roles[guildID] ?? [:]
            let audience = memberListAudience(of: target.channelID, listID: target.key.listID, in: guildID)
            for (userID, member) in members[guildID] ?? [:] {
                guard let user = users[userID],
                      matches(member.nickname, user.username, user.displayName),
                      audience(userID, member)
                else { continue }
                found.append(memberEntry(
                    user, member: member, guildID: guildID, roles: guildRoles,
                    presence: presences[userID], people: people
                ))
            }
        }
        guard !found.isEmpty else {
            return Roster(identity: "search:\(memberListScope ?? "")", sections: [], members: [:], rowCount: 0)
        }
        var roster = Roster(
            identity: "search:\(memberListScope ?? "")",
            sections: [RosterSection(
                key: .results,
                title: found.count == 1 ? "1 result found" : "\(found.count.formatted()) results found",
                index: 0,
                count: found.count,
                canCollapse: false
            )],
            members: [:],
            rowCount: found.count + 1
        )
        for (offset, entry) in Self.sortedByName(found).enumerated() {
            roster.members[offset + 1] = entry
        }
        return roster
    }

    /// Where what the reader folded away is written down: one per server, and one
    /// per group conversation.
    var memberListScope: String? {
        if let channelID = selectedChannelID, let channel = channelIndex[channelID],
           channel.kind == .groupDirectMessage
        {
            return "channel:\(channelID.rawValue)"
        }
        return selectedGuildID.map { "guild:\($0.rawValue)" }
    }

    /// Folds a section of the list on screen, or brings it back. Remembered, as a
    /// channel category is.
    func toggleMemberSection(_ key: MemberSectionKey) {
        guard let scope = memberListScope else { return }
        var collapsed = AppSettings.shared.collapsedMemberSections[scope] ?? []
        if collapsed.remove(key.storageKey) == nil { collapsed.insert(key.storageKey) }
        AppSettings.shared.collapsedMemberSections[scope] = collapsed.isEmpty ? nil : collapsed
    }

    /// The holders of one role, as a one-section roster the member list's own
    /// view can draw — Discord's role popout (`593284`): its heading is the
    /// list's section header, its rows are member-list rows, sorted by the
    /// name each person shows.
    ///
    /// **The members this session knows hold it**, which is what Discord's
    /// popout lists too: the ids route asks for up to a hundred of them, and
    /// they land here as their records arrive.
    func roleRoster(for request: RoleMembersRequest) -> Roster {
        let guildID = request.guildID
        let guildRoles = roles[guildID] ?? [:]
        guard let role = guildRoles[request.roleID] else { return .empty }
        let people = RosterPeople(
            saturation: userColorSaturation,
            typing: [:],
            voice: rosterVoiceFacts()
        )
        var entries: [MemberEntry] = []
        for (userID, member) in members[guildID] ?? [:]
        where member.roleIDs.contains(role.id) {
            guard let user = users[userID] else { continue }
            entries.append(memberEntry(
                user, member: member, guildID: guildID, roles: guildRoles,
                presence: presences[userID], people: people
            ))
        }
        let sorted = Self.sortedByName(entries)
        let count = roleMemberCounts[guildID]?[role.id]
        let section = RosterSection(
            key: .role(role.id),
            title: role.name,
            countText: (count ?? sorted.count).formatted(),
            colorValue: roleColor(role.displayColorValue),
            glyph: sectionGlyph(of: role),
            index: 0,
            count: sorted.count,
            canCollapse: false
        )
        var rows: [Int: MemberEntry] = [:]
        for (offset, entry) in sorted.enumerated() { rows[offset + 1] = entry }
        return Roster(
            identity: "role:\(guildID):\(role.id)",
            sections: [section],
            members: rows,
            rowCount: sorted.count + 1
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
        var entry = MemberEntry(
            userID: userID,
            name: member.resolvedName(user: user),
            colorValue: roleColor(coloured?.displayColorValue),
            gradient: AppSettings.shared.roleColorPlacement.tintsNames
                ? coloured?.colors
                    .flatMap { RoleColors.wrappedStops($0) }?
                    .map { UserColor.desaturated($0, by: people.saturation) }
                : nil,
            avatarURL: avatarURL(forUserID: userID, inGuild: guildID, side: MemberRowGeometry.avatarSide),
            monogram: user.monogram,
            decorationURL: cosmetics?.avatarDecorationHash.flatMap { CDN.avatarDecoration(hash: $0) },
            displayNameFont: cosmetics?.displayNameStyle?.font,
            status: PresenceStatus.resolved(presence?.status, flags: user.flags),
            isOnMobile: presence?.isOnMobile ?? false,
            isOnVR: presence?.isOnVR ?? false,
            isBot: user.isBot,
            isVerifiedBot: user.flags.contains(.verifiedBot),
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
        fillActivity(of: &entry, presence: presence, voice: people.voice)
        return entry
    }

    /// What somebody is doing, for their row: the line, the picture, the game that
    /// makes them Active Now, and the room they could be joined in — Discord's `P`
    /// and `tT` (`546359`, `763349`).
    private func fillActivity(
        of entry: inout MemberEntry,
        presence: Presence?,
        voice: RosterVoiceFacts
    ) {
        let userID = entry.userID
        entry.isReader = userID == currentUserID
        let room = voice.channels[userID]
        entry.voiceChannelID = room
        if let room, room != connectedVoiceChannelID, !entry.isReader,
           channelIndex[room]?.kind == .groupDirectMessage || permissionGate.canJoinVoice(room)
        {
            entry.joinableVoiceChannelID = room
        }
        // **Nothing for somebody offline or invisible**, whatever else is true:
        // Discord's own guard (module `397244`), and what keeps a roster's offline
        // half a column of names.
        guard let presence, presence.status != .offline, presence.status != .invisible else { return }
        let activities = presence.activities?.list ?? []
        let place = voice.places[userID]
        let isSharing = voice.sharing.contains(userID)
        entry.line = MemberRowLine.resolve(
            activities: activities, voice: place, isStreaming: isSharing, isBot: entry.isBot
        )
        // An app's "Playing /help" earns no picture and no place in Active Now.
        guard !entry.isBot else { return }
        if place != nil {
            entry.voiceGroupLine = MemberRowLine.resolve(
                activities: activities, voice: place, isStreaming: isSharing,
                isInVoiceGroup: true, connectedAt: voice.connectedAt[userID]
            )
        }

        if let game = activities.first(where: \.isGame) {
            let art = memberRowArtURL(of: game)
            entry.liveGame = MemberLiveGame(
                key: game.applicationID.map { String($0.rawValue) } ?? game.name,
                name: game.name,
                applicationID: game.applicationID,
                artURL: art
            )
            entry.gameSectionLine = MemberRowLine.resolve(
                activities: activities, voice: place, isStreaming: isSharing, inGameSection: true
            )
            if place != nil {
                entry.gameVoiceGroupLine = MemberRowLine.resolve(
                    activities: activities, voice: place, isStreaming: isSharing,
                    inGameSection: true, isInVoiceGroup: true, connectedAt: voice.connectedAt[userID]
                )
            }
            // Discord's `tk`: a game with an application has a picture, even if
            // it's a placeholder for now. A bare name doesn't earn one.
            if game.applicationID != nil {
                entry.art = art.map { .image($0) } ?? .placeholder(.game)
            }
        }
        if entry.art == nil, let listening = activities.first(where: { $0.kind == .listening }) {
            entry.art = listening.largeArtworkURL(side: MemberRowGeometry.artSide)
                .map { .image($0) } ?? .placeholder(.music)
        }
    }

    /// A game's picture: what the game itself sent, then the application's icon,
    /// then its mark — Discord's `gameAssetUrl`, `tD` and `C4`.
    private func memberRowArtURL(of game: Activity) -> URL? {
        let side = MemberRowGeometry.artSide
        if let url = game.largeArtworkURL(side: side) ?? game.smallArtworkURL(side: side) { return url }
        return applicationIconURL(game.applicationID, side: side)
            ?? game.applicationID
                .flatMap { games[$0] }
                .flatMap { gameArtURL($0, kind: .mark, side: side) }
    }

    /// One group conversation's row: no roles, so no role colour.
    private func groupEntry(
        _ user: User,
        in channel: Channel,
        presence: Presence?,
        voice: RosterVoiceFacts
    ) -> MemberEntry {
        let userID = user.id
        let cosmetics = cosmetics(of: user)
        var entry = MemberEntry(
            userID: userID,
            name: user.preferredName,
            // Nil is the default ink, which is what every name here should be.
            colorValue: nil,
            avatarURL: avatarURL(for: user, side: MemberRowGeometry.avatarSide),
            monogram: user.monogram,
            decorationURL: cosmetics?.avatarDecorationHash.flatMap { CDN.avatarDecoration(hash: $0) },
            displayNameFont: cosmetics?.displayNameStyle?.font,
            status: PresenceStatus.resolved(presence?.status, flags: user.flags),
            isOnMobile: presence?.isOnMobile ?? false,
            isOnVR: presence?.isOnVR ?? false,
            isBot: user.isBot,
            isVerifiedBot: user.flags.contains(.verifiedBot),
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
            isOwner: userID == channel.ownerID
        )
        fillActivity(of: &entry, presence: presence, voice: voice)
        return entry
    }

    /// The roster of a group conversation.
    ///
    /// **Built from the channel, not from a member table.** A group has no guild
    /// and therefore no member records, no roles and no hoisting — its people
    /// are the `recipients` array Discord already sent with the channel, plus
    /// the reader, who is in the conversation and is not in that array.
    ///
    /// Online and Offline are its only groups, and the client makes them itself,
    /// so nothing here is ever partial. The owner carries a crown wherever they
    /// land rather than being hoisted into a section of one.
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
            let entry = groupEntry(user, in: channel, presence: presenceTable[userID], voice: voice)
            if entry.status == .offline { offline.append(entry) } else { online.append(entry) }
        }

        // The same builder as a server's, over a list the client makes up. **Online
        // puts listeners first** (Discord's `G`, `546359`), which it can only do
        // where the client does the ordering.
        var groups: [RosterBuilder.Group] = []
        var rows: [Int: UserID] = [:]
        var entries: [UserID: MemberEntry] = [:]
        var next = 0
        let ordered: [(MemberSectionKey, String, RosterGlyph, [MemberEntry])] = [
            (.online, "Online", .online, Self.sortedByName(online).sorted { lhs, rhs in
                (lhs.art != nil && lhs.liveGame == nil) && !(rhs.art != nil && rhs.liveGame == nil)
            }),
            (.offline, "Offline", .offline, Self.sortedByName(offline)),
        ]
        for (key, title, glyph, people) in ordered where !people.isEmpty {
            groups.append(RosterBuilder.Group(
                key: key, title: title, glyph: glyph, heading: next, count: people.count
            ))
            for (offset, entry) in people.enumerated() {
                rows[next + 1 + offset] = entry.userID
                entries[entry.userID] = entry
            }
            next += people.count + 1
        }
        return RosterBuilder(
            identity: "group:\(channel.id)",
            groups: groups,
            rows: rows,
            entries: entries,
            organization: AppSettings.shared.memberListOrganization.resolved(hasRoles: false, isWhole: true),
            collapsed: AppSettings.shared.collapsedMemberSections[memberListScope ?? ""] ?? [],
            isWhole: true,
            rooms: rosterRooms(voice: voice)
        )
        .build()
    }
}

/// What the list on screen can be arranged by.
struct MemberListCapabilities: Equatable, Sendable {
    var hasRoles: Bool
    var isWhole: Bool

    func resolved(_ organization: MemberListOrganization) -> MemberListOrganization {
        organization.resolved(hasRoles: hasRoles, isWhole: isWhole)
    }
}

/// What a search's memo answers for. See `RosterMemoKey`.
struct MemberSearchKey: Hashable, Sendable {
    var query: String
    var scope: String
    var channelID: ChannelID
    var memberRevision: UInt64
    var presenceRevision: UInt64
    var voice: RosterVoiceFacts
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
            facts.channels[state.userID] = channelID
            if let connectedAt = state.connectedAt { facts.connectedAt[state.userID] = connectedAt }
            if state.isStreaming { facts.sharing.insert(state.userID) }
        }
        return facts
    }
}
