import AppKit
import SwiftUI
import WingcordCore

// MARK: - Who and what a composer can name
//
// The store side of the `@` and `#` completions. The scan is pure and lives in
// `MentionAutocomplete`; this answers the question it asks.

extension AppModel {

    /// What to offer for a completion in progress.
    ///
    /// Nil rather than empty when there is no trigger, because "not
    /// completing" and "completing and nothing matches" are different states
    /// and the list draws them differently.
    func mentionCandidates(
        for trigger: MentionAutocomplete.Trigger,
        in channelID: ChannelID
    ) -> [MentionCandidate] {
        switch trigger.kind {
        case .member: memberCandidates(matching: trigger.query, in: channelID)
        case .channel: channelCandidates(matching: trigger.query, in: channelID)
        case .time: timeCandidates(for: trigger.query)
        case .game: gameCandidates(for: trigger.query)
        }
    }

    // MARK: People

    /// Discord's `queryMentionResults`, in its order: people, then the
    /// mentions that are not a person, then roles — ten rows in all.
    ///
    /// **Roles fill whatever room the people leave**, and `@everyone` and
    /// `@here` come only while there is still room, which is how a large
    /// server's bare `@` is all people and a small one's is everything.
    private func memberCandidates(
        matching query: String,
        in channelID: ChannelID
    ) -> [MentionCandidate] {
        let channel = channelIndex[channelID]
        let guildID = channel?.guildID
        let limit = MentionAutocomplete.limit
        // **One permission answers three questions**: whether `@everyone` and
        // `@here` are offered, and whether a role nobody marked mentionable is.
        // Offering one the server refuses is an inert control — §5.5 — and the
        // bit is what decides whether the ping lands.
        let canMentionEveryone = guildID != nil
            && permissionGate.permissions(in: channelID).contains(.mentionEveryone)

        var people = personCandidates(matching: query, in: channel, guildID: guildID, limit: limit)

        var roleRows: [MentionCandidate] = []
        if let guildID, people.count < limit {
            roleRows = roleCandidates(
                matching: query, in: guildID, includesUnmentionable: canMentionEveryone,
                limit: limit - people.count
            )
        }

        var globals: [MentionCandidate] = []
        if guildID != nil, canMentionEveryone {
            let words = [
                ("everyone", "Notify everyone who has permission to view this channel."),
                ("here", "Notify everyone online who has permission to view this channel."),
            ]
            for (word, detail) in words
            where people.count + roleRows.count + globals.count < limit
                && MentionAutocomplete.looselyMatches(query, word)
            {
                globals.append(MentionCandidate(
                    id: "special-\(word)",
                    art: .symbol("at"),
                    title: "@\(word)",
                    subtitle: detail,
                    // **The literal word, not a snowflake.** Discord has no id
                    // for these — the message carries the text and the server
                    // reads it — which is exactly why the token rides on the
                    // candidate rather than being rebuilt from an id.
                    token: "@\(word)",
                    group: .global
                ))
            }
        }

        // `@game` and `@time`, Discord's other two (`966382`) — offered in a
        // conversation as well. Each joins while there is room, or when nothing
        // has been typed, or when the query is the whole word; a full list
        // makes room by giving up its last role, else its last person
        // (`queryMentionResults`' `N`). So a bare `@` in a busy server is
        // eight people, then these two.
        let inputs = [
            ("game", "gamecontroller.fill", "Mention a game"),
            ("time", "clock", "Refer to a time dynamically in the viewer's time zone"),
        ]
        for (word, symbol, detail) in inputs {
            let count = people.count + roleRows.count + globals.count
            let fits = (count < limit || query.isEmpty) && MentionAutocomplete.looselyMatches(query, word)
            guard fits || query == word else { continue }
            if count >= limit {
                if !roleRows.isEmpty { roleRows.removeLast() } else if !people.isEmpty { people.removeLast() }
            }
            globals.append(MentionCandidate(
                id: "special-\(word)",
                art: .symbol(symbol),
                title: "@\(word)",
                subtitle: detail,
                // The word and a space, which opens its input — see
                // `MentionAutocomplete.inputWords`.
                token: "@\(word)",
                group: .global,
                opensInput: true
            ))
        }
        return people + globals + roleRows
    }

    // MARK: Times

    /// `@time`'s list — Discord's, from `TimestampSuggestions`. Nothing until
    /// two characters are in (`matches: n.length > 1`): before that the hint
    /// is all that shows.
    private func timeCandidates(for query: String) -> [MentionCandidate] {
        guard query.count > 1 else { return [] }
        var section = 0
        var rows: [MentionCandidate] = []
        for row in TimestampSuggestions.rows(for: query) {
            switch row {
            case .divider:
                section += 1
            case .option(let date, let style, let label):
                let token = TimestampStyle.token(for: date, style: style)
                rows.append(MentionCandidate(
                    id: "time-\(section)-\(token)",
                    art: .symbol("clock"),
                    title: style.format(date),
                    subtitle: label,
                    token: token,
                    group: .section(section)
                ))
            }
        }
        return rows
    }

    // MARK: Games

    /// `@game`'s list: the answer for what was typed, or for the longest start
    /// of it already answered while the rest is on its way — Discord's
    /// `getClosestResults`. The search itself runs from the composer.
    private func gameCandidates(for query: String) -> [MentionCandidate] {
        guard let key = GameMentionSearch.normalized(query),
              let games = gameSearch.closestResults(for: key)
        else { return [] }
        return games.map { found in
            let game = gameSearch.byID[found.id] ?? found
            return MentionCandidate(
                id: "game-\(game.id.rawValue)",
                art: .picture(game.iconURL),
                title: game.name,
                subtitle: nil,
                token: "<@$\(game.id.rawValue)>",
                group: .section(0)
            )
        }
    }

    /// The people a channel is about, alphabetical.
    ///
    /// A guild channel draws from its roster; a direct message from its
    /// recipients, which is a handful and never needs a fetch. Alphabetical is
    /// the only order that does not move under the reader: a roster sorted by
    /// presence reshuffles while they are choosing.
    private func personCandidates(
        matching query: String,
        in channel: Channel?,
        guildID: GuildID?,
        limit: Int
    ) -> [MentionCandidate] {
        let userIDs: [UserID] = if let guildID {
            Array((members[guildID] ?? [:]).keys)
        } else {
            channel?.recipientIDs ?? []
        }

        var matches: [(MentionCandidate, String)] = []
        for userID in userIDs {
            guard let user = users[userID] else { continue }
            let member = guildID.flatMap { members[$0]?[userID] }
            let name = member?.resolvedName(user: user) ?? user.preferredName
            let handle = user.handle
            // Prefix on either the displayed name or the handle: people
            // reach for whichever they remember, and Discord matches both.
            guard query.isEmpty
                || name.lowercased().hasPrefix(query)
                || handle.lowercased().hasPrefix(query)
            else { continue }
            matches.append((
                MentionCandidate(
                    id: "user-\(userID.rawValue)",
                    art: .avatar(avatarURL(for: user, side: Metrics.avatarRow), monogram: user.monogram),
                    title: name,
                    subtitle: handle.isEmpty ? nil : handle,
                    // `<@id>`, which is what the parser reads back — see
                    // `InlineScanner`. A bare `@name` is text.
                    token: "<@\(userID.rawValue)>",
                    nameColor: member.flatMap { member in
                        guildID.flatMap { roles[$0] }.flatMap {
                            RoleResolver.nameColorValue(of: member.roleIDs, in: $0)
                        }
                    }
                ),
                name.lowercased()
            ))
        }
        return matches.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0)
    }

    /// The roles that can be named here: the mentionable ones, or every role
    /// for somebody with "Mention @everyone, @here, and All Roles" — never the
    /// server's own `@everyone` role, which is the literal word above.
    ///
    /// A name that starts with what was typed ranks ahead of one that merely
    /// contains it, then the roster's own order, highest role first. Two roles
    /// with one name are two rows, because they are two roles.
    private func roleCandidates(
        matching query: String,
        in guildID: GuildID,
        includesUnmentionable: Bool,
        limit: Int
    ) -> [MentionCandidate] {
        var matches: [(role: Role, isPrefix: Bool)] = []
        for role in (roles[guildID] ?? [:]).values
        where role.id.rawValue != guildID.rawValue && (role.isMentionable || includesUnmentionable) {
            let name = role.name.lowercased()
            guard MentionAutocomplete.looselyMatches(query, name) else { continue }
            matches.append((role, name.hasPrefix(query)))
        }
        matches.sort {
            if $0.isPrefix != $1.isPrefix { return $0.isPrefix }
            if $0.role.position != $1.role.position { return $0.role.position > $1.role.position }
            return $0.role.id < $1.role.id
        }
        return matches.prefix(limit).map { match in
            MentionCandidate(
                id: "role-\(match.role.id.rawValue)",
                art: .symbol("at"),
                title: "@\(match.role.name)",
                subtitle: "Notify users with this role who have permission to view this channel.",
                token: "<@&\(match.role.id.rawValue)>",
                nameColor: roleColor(match.role.displayColorValue),
                group: .role
            )
        }
    }

    // MARK: Channels

    private func channelCandidates(
        matching query: String,
        in channelID: ChannelID
    ) -> [MentionCandidate] {
        // **A direct message can still name a channel** — the link resolves
        // for anybody who can see it — but there is no list to draw from, so
        // the completion is offered only where the reader is in a server.
        guard let guildID = channelIndex[channelID]?.guildID else { return [] }

        var results: [(MentionCandidate, Int)] = []
        for (position, id) in channelIndex.channelIDs(inGuild: guildID).enumerated() {
            guard let channel = channelIndex[id], channel.kind != .category else { continue }
            // **The permission gate, once, here.** A channel the reader cannot
            // see is a channel they cannot link: the mention would render as a
            // dead `#unknown` for them and expose a name to everybody else.
            guard permissionGate.canView(id) else { continue }
            guard query.isEmpty || channel.name.lowercased().hasPrefix(query) else { continue }
            results.append((
                MentionCandidate(
                    id: "channel-\(id.rawValue)",
                    art: .symbol(channel.kind.symbolName),
                    title: channel.name,
                    // The category above it, which is how a reader tells two
                    // `#general`s apart.
                    subtitle: channel.parentID.flatMap { channelIndex[$0]?.name },
                    token: "<#\(id.rawValue)>"
                ),
                position
            ))
        }
        // The server's own order, which is the one the sidebar shows and
        // therefore the one the reader is holding in their head.
        return results
            .sorted { $0.1 < $1.1 }
            .prefix(MentionAutocomplete.limit)
            .map(\.0)
    }
}

// MARK: - The composer's chips

extension AppModel {

    /// How the composer draws a mention token it holds — the transcript's chip
    /// in the composer's own type: a person, role or channel by name on the
    /// mention plate, a game by name, a moment as the style writes it on the
    /// timestamp plate. Nil leaves the token as text: one this account cannot
    /// name.
    func composerChip(for mention: EditorMention, in channelID: ChannelID) -> EditorChip? {
        let ink = ThemeInk.current
        let accent = NSColor(cgColor: ink.accent) ?? .controlAccentColor
        let plate = NSColor(cgColor: ink.mentionFill) ?? accent.withAlphaComponent(0.24)
        let guildID = channelIndex.guildID(of: channelID)
        switch mention {
        case .user(let userID):
            guard users[userID] != nil else { return nil }
            return EditorChip(label: "@" + voiceName(of: userID, inGuild: guildID), ink: accent, fill: plate)
        case .role(let roleID):
            guard let role = guildID.flatMap({ roles[$0]?[roleID] }) else { return nil }
            // A role's own colour, at Discord's 10% for the plate.
            guard let color = roleColor(role.displayColorValue) else {
                return EditorChip(label: "@" + role.name, ink: accent, fill: plate)
            }
            let tint = NSColor(Color(hex: color))
            return EditorChip(label: "@" + role.name, ink: tint, fill: tint.withAlphaComponent(0.1))
        case .channel(let id):
            guard let channel = channelIndex[id] else { return nil }
            return EditorChip(label: "#" + displayName(of: channel), ink: accent, fill: plate)
        case .game(let gameID):
            return EditorChip(label: gameMentionNames[gameID] ?? "unknown-game", ink: accent, fill: plate)
        case .timestamp(let date, let style):
            return EditorChip(
                label: style.format(date),
                ink: .composerSolid,
                fill: NSColor(cgColor: ink.timestampFill) ?? .quaternaryLabelColor
            )
        }
    }

    /// Moves whenever a chip's words or colours may have — see
    /// `MarkdownEditor.chipRevision`.
    var composerChipRevision: UInt64 {
        identityRevision &* 1_000_003
            &+ memberRevision &* 8_191
            &+ roleRevision &* 131
            &+ channelIndex.structureRevision &* 31
            &+ gameMentionRevision &* 7
            &+ PresentationRevision.shared.value
    }
}
