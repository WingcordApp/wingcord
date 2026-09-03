import Foundation
import WingcordCore
import WingcordNet

// MARK: - The slash command list
//
// What the `/` flyout draws, and nothing else. The store holds the indexes; the
// session controller fills them. Both directions of that are `INVARIANTS.md`'s
// rule, not a preference.
//
// **The index is fetched once and filtered here.** The capture is unambiguous:
// typing `/` fired one request and running two commands over the next minute
// fired none. So every keystroke below is a pass over an array already in
// memory — 186 leaves on the captured account — and never a request.

/// One command, as a row.
///
/// A plain value with no store reference, for the reason every other
/// presentation type here has none: `.equatable()` is worth nothing on a type
/// that closes over the store.
struct CommandRow: Hashable, Sendable, Identifiable {
    /// **Scoped to the section, not to the command.** A command in Frequently
    /// Used is drawn again under its own application, so the leaf id appears
    /// twice in one list — and two rows sharing an id is a `scrollTo` that lands
    /// on whichever `ForEach` kept.
    var id: String
    var command: SlashCommand
    var applicationName: String
    var iconURL: URL?
    var monogram: String
    /// What the row says about the command's parameters — `question` for a
    /// required one, `+2 optional` for the rest. Empty when it takes none.
    var hint: String
}

/// A titled group of rows.
struct CommandSection: Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var iconURL: URL?
    /// The account's own most-used commands. Drawn under a clock rather than an
    /// application icon, because it is the one section that is not one
    /// application's.
    var isFrequent: Bool
    var rows: [CommandRow]
}

extension AppModel {

    /// The sections the `/` flyout draws for one channel.
    ///
    /// Memoized on the revision, the channel and the query together. A keystroke
    /// moves the query and nothing else, so a miss costs one filter over the
    /// leaves rather than a rebuild of the index.
    func commandSections(in channelID: ChannelID, matching query: String) -> [CommandSection] {
        let key = CommandMemoKey(
            revision: commandRevision,
            channelID: channelID,
            query: query.trimmingCharacters(in: .whitespaces).lowercased()
        )
        // Every observable input is read before the early return: a memo that
        // answers from its cache without touching them registers no dependency
        // and is never invalidated again. `INVARIANTS.md` §2.
        let indexes = commandIndexes
        let frecency = commandFrecency
        let uses = commandUses

        if let commandSectionsCache, commandSectionsCache.key == key {
            return commandSectionsCache.value
        }
        let sections = buildCommandSections(
            in: channelID,
            indexes: indexes,
            frecency: frecency,
            uses: uses,
            query: key.query
        )
        commandSectionsCache = (key, sections)
        return sections
    }

    /// The one flat list the keyboard walks. Sections are for reading; a
    /// selection index is for moving, and deriving it here keeps the two from
    /// disagreeing about what row 4 is.
    func commandRows(in channelID: ChannelID, matching query: String) -> [CommandRow] {
        commandSections(in: channelID, matching: query).flatMap(\.rows)
    }

    /// Which indexes answer for a channel.
    ///
    /// **Two scopes in a server, one in a direct message.** A guild's index
    /// carries the bots installed to that server; the account's carries the apps
    /// installed to the reader, which work everywhere — and neither is a subset
    /// of the other. The capture proves the DM case: one request, to the account
    /// route, at the moment `/` was typed.
    func commandScopes(for channelID: ChannelID) -> [DiscordREST.CommandScope] {
        guard let guildID = channelIndex[channelID]?.guildID else { return [.account] }
        return [.guild(guildID), .account]
    }

    // MARK: Building

    private func buildCommandSections(
        in channelID: ChannelID,
        indexes: [DiscordREST.CommandScope: CommandIndex],
        frecency: [String],
        uses: [String: Date],
        query: String
    ) -> [CommandSection] {
        var applications: [ApplicationID: CommandApplication] = [:]
        var leaves: [SlashCommand] = []
        var seen = Set<String>()

        for scope in commandScopes(for: channelID) {
            guard let index = indexes[scope] else { continue }
            for application in index.applications { applications[application.id] = application }
            for leaf in index.slashCommands where seen.insert(leaf.id).inserted {
                // A user-installed app appears in the account index *and* in the
                // server's when it is installed both ways. The first scope wins,
                // which is the guild's — the same command, but the record the
                // server actually registered.
                leaves.append(leaf)
            }
        }
        guard !leaves.isEmpty else { return [] }

        let matches = CommandSearch.matches(query, in: leaves, applications: applications)
        guard !matches.isEmpty else { return [] }

        var sections: [CommandSection] = []
        let byID = Dictionary(matches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // **Frequently Used leads, and it is the account's own table.**
        // `application_command_frecency` — field 7 of the second settings
        // protobuf — keyed by command id. This session's own uses are layered
        // over it in memory, because the table is read and never written: see
        // `DiscordREST.commandFrecency`.
        let frequent = Self.frequentIDs(server: frecency, session: uses)
            .compactMap { byID[$0] }
            .prefix(Self.frequentRowsShown)
        if !frequent.isEmpty {
            sections.append(CommandSection(
                id: "frequent",
                title: "Frequently Used",
                iconURL: nil,
                isFrequent: true,
                rows: frequent.map { row(for: $0, in: "frequent", applications: applications) }
            ))
        }

        // Then one section per application, in the order their best-ranked
        // command falls — so the bot whose commands the reader is most likely
        // to want is nearest the composer rather than wherever the index
        // happened to list it.
        var grouped: [ApplicationID: [SlashCommand]] = [:]
        for leaf in matches { grouped[leaf.applicationID, default: []].append(leaf) }

        let order = grouped.keys.sorted { lhs, rhs in
            let left = grouped[lhs]?.first.flatMap(\.popularityRank) ?? .max
            let right = grouped[rhs]?.first.flatMap(\.popularityRank) ?? .max
            if left != right { return left < right }
            // A stable tiebreak, so two bots with unranked commands do not swap
            // places between keystrokes.
            return (applications[lhs]?.name ?? "") < (applications[rhs]?.name ?? "")
        }

        for id in order {
            guard let leaves = grouped[id], !leaves.isEmpty else { continue }
            let application = applications[id]
            sections.append(CommandSection(
                id: id.description,
                title: application?.name ?? id.description,
                iconURL: application?.iconHash.flatMap {
                    CDN.applicationIcon(id: id, hash: $0, side: Metrics.commandRowIcon)
                },
                isFrequent: false,
                rows: leaves.map { row(for: $0, in: id.description, applications: applications) }
            ))
        }
        return sections
    }

    private func row(
        for leaf: SlashCommand,
        in section: String,
        applications: [ApplicationID: CommandApplication]
    ) -> CommandRow {
        let application = applications[leaf.applicationID]
        let name = application?.name ?? leaf.applicationID.description
        return CommandRow(
            id: section + "/" + leaf.id,
            command: leaf,
            applicationName: name,
            iconURL: application?.iconHash.flatMap {
                CDN.applicationIcon(id: leaf.applicationID, hash: $0, side: Metrics.commandRowIcon)
            },
            monogram: String(name.prefix(1)).uppercased(),
            hint: Self.hint(for: leaf)
        )
    }

    /// The parameter summary beside a command's name.
    ///
    /// Required options are named, because they are what the reader is about to
    /// be asked for; optional ones are counted, because naming eight of them
    /// fills the row with words nobody reads. Discord's own list says
    /// `+1 optional` for exactly this reason and it is the right call.
    static func hint(for leaf: SlashCommand) -> String {
        let offered = leaf.offeredParameters
        let required = offered.filter(\.isRequired).map(\.name)
        let optional = offered.count - required.count
        var parts = required
        if optional > 0 { parts.append("+\(optional) optional") }
        return parts.joined(separator: "  ")
    }

    /// The account's table, with this session's own uses moved to the front.
    ///
    /// A command run a moment ago belongs at the top of Frequently Used, and the
    /// server's table will not say so until Discord's own client writes it —
    /// which this client deliberately does not do.
    private static func frequentIDs(server: [String], session: [String: Date]) -> [String] {
        let recent = session.sorted { $0.value > $1.value }.map(\.key)
        var seen = Set<String>()
        return (recent + server).filter { seen.insert($0).inserted }
    }

    /// How many rows Frequently Used offers. Past a handful it stops being a
    /// shortcut and becomes a second copy of the list below it.
    private static let frequentRowsShown = 5
}

/// What the `/` list is memoized on.
struct CommandMemoKey: Hashable, Sendable {
    var revision: UInt64
    var channelID: ChannelID
    var query: String
}

// MARK: - Reading the draft

/// The `/command` being typed at the head of the composer.
///
/// **A command opens on the first character and nowhere else.** `/` mid-sentence
/// is a date, a path or a fraction; only a draft that *starts* with one is a
/// command, which is the rule every client that has this feature follows and the
/// one the reader already expects.
nonisolated enum CommandQuery {

    /// What is being searched for, or nil when the draft is not a command.
    ///
    /// The whole remainder, spaces included — a leaf is named `base64 decode`
    /// and a query that stopped at the first space could never reach it.
    static func query(in text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        // A second line means the reader is writing a message that happens to
        // open with a slash, not naming a command.
        guard !text.contains(where: \.isNewline) else { return nil }
        return String(text.dropFirst())
    }
}

/// Ranking the list.
///
/// One pass over the leaves, scoring each, then a sort — rather than four passes
/// collecting tiers. On the captured account that is 186 comparisons per
/// keystroke against an array already in memory.
nonisolated enum CommandSearch {

    /// Best first. An unmatched leaf is dropped rather than ranked last.
    static func matches(
        _ query: String,
        in leaves: [SlashCommand],
        applications: [ApplicationID: CommandApplication]
    ) -> [SlashCommand] {
        let needle = query
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !needle.isEmpty else { return leaves.sorted(by: byPopularity) }

        var scored: [(leaf: SlashCommand, score: Int)] = []
        scored.reserveCapacity(leaves.count)
        for leaf in leaves {
            let application = applications[leaf.applicationID]?.name
            if let score = score(leaf, application: application, needle: needle) {
                scored.append((leaf, score))
            }
        }
        return scored
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return byPopularity($0.leaf, $1.leaf)
            }
            .map(\.leaf)
    }

    /// Higher is better. Nil means no match at all.
    ///
    /// **The application's own name is searchable.** Four bots in the captured
    /// account register a `/help`, and typing `esm` to reach esmBot's is the
    /// gesture that replaces the app rail Discord draws beside its list — a rail
    /// is a pointer affordance on a surface that is otherwise entirely
    /// keyboard-driven.
    private static func score(
        _ leaf: SlashCommand,
        application: String?,
        needle: String
    ) -> Int? {
        let name = leaf.name.lowercased()
        if name == needle { return 100 }
        if name.hasPrefix(needle) { return 80 }
        // A subcommand's own name, so `decode` reaches `base64 decode`.
        if let last = leaf.path.last?.lowercased(), last.hasPrefix(needle) { return 70 }
        if name.contains(needle) { return 60 }
        if let application, application.lowercased().contains(needle) { return 40 }
        if leaf.summary.lowercased().contains(needle) { return 20 }
        return nil
    }

    /// Discord's own ordering, smaller being more popular. A command with no
    /// rank sorts last rather than first — absence is "nobody has run this",
    /// not "rank zero".
    private static func byPopularity(_ lhs: SlashCommand, _ rhs: SlashCommand) -> Bool {
        let left = lhs.popularityRank ?? .max
        let right = rhs.popularityRank ?? .max
        if left != right { return left < right }
        return lhs.name < rhs.name
    }
}
