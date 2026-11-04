import Foundation
import WingcordCore

/// Turns a list and what's known about the people on it into the column.
///
/// **Pure, so it can be tested without a model.** `AppModel` reads the store and
/// hands this the groups, the rows and the entries; everything about which section
/// somebody is in happens here.
///
/// **Discord's rules, on a list Discord didn't build them for.** Its friends
/// sidebar knows every friend. A server's list is the server's: it arrives in
/// pages, and only three of them can be held at a time (`MemberList.maximumPages`).
/// So the sections the client adds sit *on top of* the server's groups instead of
/// replacing them, and somebody lifted into one is taken out of their group rather
/// than drawn twice.
///
/// **Who gets lifted is who the client hears about live:** the pages always
/// subscribed (every row of a list that fits, and the first page of one that
/// doesn't), everybody in a room, and friends. That set doesn't change as the reader
/// scrolls, so Active Now doesn't flicker with it, and nothing in it goes stale the
/// way a row from a page dropped from the subscription would.
nonisolated struct RosterBuilder: Sendable {

    /// One of the list's own groups.
    struct Group: Sendable {
        var key: MemberSectionKey
        var title: String?
        var colorValue: UInt32?
        var glyph: RosterGlyph = .none
        /// Its heading's row in the list.
        var heading: Int
        var count: Int
    }

    /// See `Roster.identity`.
    var identity: String
    var groups: [Group]
    /// The members the list has sent, by their row in it.
    var rows: [Int: UserID]
    /// Everybody this build can draw.
    var entries: [UserID: MemberEntry]
    /// Anybody else known to be doing something: in a room, or a friend.
    var candidates: [UserID] = []
    /// Already resolved against what this list can do — see
    /// `MemberListOrganization.resolved(hasRoles:isWhole:)`.
    var organization: MemberListOrganization
    /// The sections folded away, by `MemberSectionKey.storageKey`.
    var collapsed: Set<String> = []
    /// Whether every row of the list is held: what makes a count a count.
    var isWhole: Bool
    /// The rooms people are in, for gathering them: empty when the reader has
    /// turned that off.
    var rooms: [ChannelID: Room] = [:]

    /// A room, as far as a section needs to know.
    struct Room: Sendable {
        var name: String
        var isStage: Bool
        /// Everybody in it.
        var occupants: Int
        var isReaderIn: Bool
        var canJoin: Bool
    }

    func build() -> Roster {
        var roster = Roster(identity: identity, sections: [], members: [:], rowCount: 0)
        switch organization {
        case .roles:
            appendGroups(moving: [], to: &roster)
        case .activeNow:
            let active = Self.sorted(considered.filter(\.isActiveNow))
            appendSection(
                key: .activeNow, title: "Active Now", countText: liftedCount(active.count),
                glyph: .activeNow, people: active, to: &roster
            )
            appendGroups(moving: Set(active.map(\.userID)), to: &roster)
        case .game:
            let players = considered.filter { $0.isActiveNow && $0.liveGame != nil }
            let games = Dictionary(grouping: players) { $0.liveGame?.key ?? "" }
            let ordered = games.values
                .map { Self.sorted($0) }
                .sorted { lhs, rhs in
                    MemberListOrder.sortKey(lhs.first?.liveGame?.name ?? "")
                        < MemberListOrder.sortKey(rhs.first?.liveGame?.name ?? "")
                }
            for people in ordered {
                guard let game = people.first?.liveGame else { continue }
                appendSection(
                    key: .game(game.key), title: game.name, countText: liftedCount(people.count),
                    glyph: .game(people.lazy.compactMap(\.liveGame?.artURL).first),
                    // Its heading names the game and shows its picture, so a row
                    // says what they're doing in it instead — Discord's `tk`
                    // returning null under `ik.GAME`.
                    people: people.map { entry in
                        var entry = entry
                        entry.line = entry.gameSectionLine
                        entry.voiceGroupLine = entry.gameVoiceGroupLine
                        entry.art = nil
                        return entry
                    },
                    to: &roster
                )
            }
            appendGroups(moving: Set(players.map(\.userID)), to: &roster)
        case .alphabetical:
            let everyone = rows.values.compactMap { entries[$0] }
            let letters = Dictionary(grouping: everyone) { MemberListOrder.letter(of: $0.name) }
            for letter in MemberListOrder.lettersInOrder(letters.keys) {
                appendSection(
                    key: .letter(letter), title: nil, countText: nil, glyph: .letter(letter),
                    people: Self.sorted(letters[letter] ?? []), to: &roster
                )
            }
        }
        return roster
    }

    /// The people who may be lifted out of their group.
    private var considered: [MemberEntry] {
        var seen = Set(candidates)
        for (row, userID) in rows where isWhole || row < MemberList.pageSize {
            seen.insert(userID)
        }
        return seen.compactMap { entries[$0] }
    }

    /// A count over something the client put together: exact over a list it holds
    /// whole, and **a floor over one it doesn't**, which is what the plus says.
    private func liftedCount(_ count: Int) -> String {
        isWhole ? count.formatted() : "\(count.formatted())+"
    }

    /// By name, Discord's collator's order, on a precomputed key.
    private static func sorted(_ people: [MemberEntry]) -> [MemberEntry] {
        people
            .map { (key: MemberListOrder.sortKey($0.name), entry: $0) }
            .sorted { lhs, rhs in
                if lhs.key != rhs.key { return lhs.key < rhs.key }
                return lhs.entry.userID < rhs.entry.userID
            }
            .map(\.entry)
    }

    private func isCollapsed(_ key: MemberSectionKey) -> Bool {
        collapsed.contains(key.storageKey)
    }

    /// A section the client put together. **One with nobody in it isn't there**,
    /// as an empty one of Discord's isn't.
    private func appendSection(
        key: MemberSectionKey,
        title: String?,
        countText: String?,
        glyph: RosterGlyph,
        people: [MemberEntry],
        to roster: inout Roster
    ) {
        guard !people.isEmpty else { return }
        let folded = isCollapsed(key)

        // **Two or more in one room gather under it, ahead of everyone else**;
        // somebody alone in one is an ordinary row — Discord's `j` (`546359`).
        var inRoom: [ChannelID: [MemberEntry]] = [:]
        if !folded, !rooms.isEmpty, organization != .alphabetical {
            for entry in people {
                if let room = entry.voiceChannelID, rooms[room] != nil { inRoom[room, default: []].append(entry) }
            }
            inRoom = inRoom.filter { $0.value.count > 1 }
        }
        let gathered = Set(inRoom.values.flatMap { $0.map(\.userID) })
        let rest = people.filter { !gathered.contains($0.userID) }

        let heading = roster.rowCount
        roster.sections.append(RosterSection(
            key: key, title: title, countText: countText, glyph: glyph,
            index: heading,
            count: folded || !inRoom.isEmpty ? 0 : people.count,
            isCollapsed: folded
        ))
        roster.rowCount = heading + 1
        guard !folded else { return }

        if inRoom.isEmpty {
            appendRows(people, after: heading, to: &roster)
            return
        }
        // Discord orders its groups by the channel's id.
        for (channelID, occupants) in inRoom.sorted(by: { $0.key < $1.key }) {
            guard let room = rooms[channelID] else { continue }
            let isReaderDrawn = occupants.contains(where: \.isReader)
            let extra = room.occupants - occupants.count - (room.isReaderIn && !isReaderDrawn ? 1 : 0)
            let index = roster.rowCount
            roster.sections.append(RosterSection(
                key: .voice(String(channelID.rawValue)),
                title: room.name,
                index: index,
                count: occupants.count,
                canCollapse: false,
                kind: .voiceGroup(RosterVoiceGroup(
                    channelID: channelID,
                    isStage: room.isStage,
                    extraCount: max(0, extra),
                    isReaderIn: room.isReaderIn,
                    canJoin: room.canJoin
                ))
            ))
            let rows = occupants.map { entry in
                var entry = entry
                entry.line = entry.voiceGroupLine
                // The room's heading is what says Join, not each row.
                entry.joinableVoiceChannelID = nil
                return entry
            }
            appendRows(rows, after: index, to: &roster)
        }
        guard !rest.isEmpty else { return }
        let index = roster.rowCount
        roster.sections.append(RosterSection(
            key: .continuation(key.storageKey),
            index: index,
            count: rest.count,
            canCollapse: false,
            kind: .continuation
        ))
        appendRows(rest, after: index, to: &roster)
    }

    /// Rows after a heading at `heading`, which is the last row so far.
    private func appendRows(_ people: [MemberEntry], after heading: Int, to roster: inout Roster) {
        for (offset, entry) in people.enumerated() {
            roster.members[heading + 1 + offset] = entry
        }
        roster.rowCount = heading + 1 + people.count
    }

    /// The list's own groups, without the people `moved` took out of them.
    private func appendGroups(moving moved: Set<UserID>, to roster: inout Roster) {
        let heldRows = rows.keys.sorted()
        var cursor = 0
        for group in groups {
            var kept: [(row: Int, entry: MemberEntry?)] = []
            var hidden: [Int] = []
            // Both are in ascending order, so this is one walk across them.
            while cursor < heldRows.count, heldRows[cursor] <= group.heading + group.count {
                let row = heldRows[cursor]
                cursor += 1
                guard row > group.heading, let userID = rows[row] else { continue }
                if moved.contains(userID) {
                    hidden.append(row)
                } else {
                    kept.append((row, entries[userID]))
                }
            }
            let remaining = group.count - hidden.count
            // A group left with nobody in it loses its heading. The placeholder
            // heading a list starts with has nobody by definition, and stays.
            guard remaining > 0 || group.key == .unknown else { continue }

            let folded = group.key != .unknown && isCollapsed(group.key)
            let heading = roster.rowCount
            roster.sections.append(RosterSection(
                key: group.key,
                title: group.title,
                // Discord's `t6`: Offline names itself and no count. So does a
                // heading that doesn't know its own name yet.
                countText: group.key == .offline || group.key == .unknown ? nil : remaining.formatted(),
                colorValue: group.colorValue,
                glyph: group.glyph,
                index: heading,
                count: folded ? 0 : remaining,
                isCollapsed: folded,
                canCollapse: group.key != .unknown,
                span: RosterServerSpan(heading: group.heading, hidden: hidden)
            ))
            if !folded {
                var hiddenBefore = 0
                for (row, entry) in kept {
                    while hiddenBefore < hidden.count, hidden[hiddenBefore] < row { hiddenBefore += 1 }
                    if let entry {
                        roster.members[heading + (row - group.heading) - hiddenBefore] = entry
                    }
                }
            }
            roster.rowCount = heading + 1 + (folded ? 0 : remaining)
        }
    }
}
