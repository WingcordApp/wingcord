import Foundation
import WingcordCore
import WingcordNet

// MARK: - What an app can do to a message, or to a person
//
// The **other half** of the command index. `slashCommands` flattens the
// chat-input ones into the leaves the `/` picker walks; these are types 2 and
// 3 — USER and MESSAGE — and they are what Discord's Apps submenu offers on a
// right-click. Both kinds have been decoded since the index was, and until now
// nothing read them: `CommandKind.user` and `.message` were parsed and then
// filtered out one line later.
//
// **A context command has no options.** Discord forbids them on types 2 and 3,
// because a right-click has nowhere to type one — so there is no leaf to
// flatten, no argument to collect and no second surface to open. One click
// runs it, which is why this submenu is a list and the `/` picker is a
// composer.

extension AppModel {

    /// The apps offering something for this subject, in this channel.
    ///
    /// Grouped by application because that is how the submenu reads and how
    /// Discord's own draws it: an app with one command is one row, an app with
    /// six is a row that opens onto six.
    func contextCommandGroups(
        _ kind: CommandKind,
        in channelID: ChannelID,
        matching query: String = ""
    ) -> [ContextCommandGroup] {
        var applications: [ApplicationID: CommandApplication] = [:]
        var byApplication: [ApplicationID: [ContextCommand]] = [:]
        var seen = Set<String>()

        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()

        for scope in commandScopes(for: channelID) {
            guard let index = commandIndexes[scope] else { continue }
            for application in index.applications { applications[application.id] = application }
            for command in index.contextCommands(kind) where seen.insert(command.id).inserted {
                // **A direct message is where `dm_permission` bites.** Half of
                // OwO's commands are `dm_permission: false`, and offering one
                // here is offering a control the API refuses — §5.5.
                if channelIndex[channelID]?.guildID == nil, !command.dmPermission { continue }
                if !needle.isEmpty, !command.name.lowercased().contains(needle) { continue }
                byApplication[command.applicationID, default: []].append(
                    ContextCommand(
                        id: command.id,
                        name: command.name,
                        applicationID: command.applicationID,
                        popularityRank: command.popularityRank,
                        lastUsed: commandUses[command.id]
                    )
                )
            }
        }

        return byApplication.compactMap { applicationID, commands -> ContextCommandGroup? in
            guard let application = applications[applicationID] else { return nil }
            return ContextCommandGroup(
                id: applicationID,
                name: application.name,
                iconURL: application.iconHash.flatMap {
                    CDN.applicationIcon(id: applicationID, hash: $0)
                },
                commands: commands.sorted(by: ContextCommand.byPopularity)
            )
        }
        // Apps in name order. **Not by command count**, which would reshuffle
        // the list whenever an app added one, and not by popularity, which is
        // a fact about commands rather than about apps.
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The handful the reader actually reaches for.
    ///
    /// **From `commandUses`, which is the frecency table this client already
    /// keeps** — the same one the `/` picker's Frequently Used section reads.
    /// A second notion of "recent" would disagree with it within a day.
    func frequentContextCommands(
        _ kind: CommandKind,
        in channelID: ChannelID,
        limit: Int = 4
    ) -> [ContextCommand] {
        contextCommandGroups(kind, in: channelID)
            .flatMap(\.commands)
            .filter { $0.lastUsed != nil }
            .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    /// Runs one, on a message or on a person.
    ///
    /// **The target is the whole of the payload.** A context command has no
    /// options, so what distinguishes "Make it a Quote on *this* message" from
    /// the same command on another is one field — `data.target_id` — and
    /// getting it wrong runs the command on the wrong thing rather than
    /// failing.
    func runContextCommand(_ command: ContextCommand, on target: AppCommandTarget) {
        guard let channelID = target.channelID,
              let index = commandIndexes.values.first(where: { index in
                  index.commands.contains { $0.id == command.id }
              }),
              let record = index.commands.first(where: { $0.id == command.id })
        else { return }
        dismissMessageSurfaces()
        dismissDirectMessageMenu()
        noteCommandUse(command.id)
        sessionController.runContextCommand(record, on: target, in: channelID)
    }

    /// Remembers that a command was run, so Frequently Used means something.
    ///
    /// Local only. The frecency table Discord keeps is written back by a
    /// protobuf `PATCH` this client has for the `/` picker; a context command
    /// has never been watched write one, so nothing is sent here rather than
    /// a shape being invented. See §S.12.
    func noteCommandUse(_ id: String) {
        commandUses[id] = .now
        commandRevision &+= 1
    }
}

/// One app's context commands.
struct ContextCommandGroup: Hashable, Sendable, Identifiable {
    var id: ApplicationID
    var name: String
    var iconURL: URL?
    var commands: [ContextCommand]
}

/// One command a right-click can run.
struct ContextCommand: Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var applicationID: ApplicationID
    /// Discord's own popularity ordering, smaller being more popular. Absent
    /// on a command nobody has run, which sorts last rather than first.
    var popularityRank: Int?
    /// When the reader last ran it, for Frequently Used.
    var lastUsed: Date?

    /// Most popular first, then by name.
    ///
    /// **Absent rank sorts last.** Seventeen of the captured index's hundred
    /// and eighty-three carry none, and reading that as rank zero would put
    /// every command nobody has ever run at the top of the list.
    static func byPopularity(_ lhs: ContextCommand, _ rhs: ContextCommand) -> Bool {
        switch (lhs.popularityRank, rhs.popularityRank) {
        case let (left?, right?) where left != right: left < right
        case (nil, .some): false
        case (.some, nil): true
        default: lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

/// What a context command is being run on.
///
/// **A case rather than two optionals**, because the two are exclusive and the
/// interaction's `data.type` is decided by which it is: 2 for a person, 3 for
/// a message. A payload carrying both would be a payload with no defined
/// meaning.
enum AppCommandTarget: Hashable, Sendable {
    case message(MessageID, in: ChannelID)
    case user(UserID, in: ChannelID)

    var channelID: ChannelID? {
        switch self {
        case .message(_, let channelID), .user(_, let channelID): channelID
        }
    }

    var targetID: String {
        switch self {
        case .message(let id, _): id.description
        case .user(let id, _): id.description
        }
    }

    /// The `CommandKind` whose commands may run on this.
    var kind: CommandKind {
        switch self {
        case .message: .message
        case .user: .user
        }
    }
}
