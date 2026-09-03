import Foundation
import WingcordCore

// MARK: - Answering an option
//
// What the flyout over the composer offers while one option is being filled.
//
// **The list is offered only where there is something to pick.** An option with
// choices, a boolean, and the three whose value is a snowflake are closed sets:
// typing into them cannot produce a valid value, so the list is the whole
// interface. A string or a number is typed, and a list under it would be a
// control that does nothing.
//
// That distinction is also the keyboard's contract, and it is why it can be
// stated in one line: **a list means Return picks, no list means Return
// commits.** Anything looser puts two meanings on one key.

/// What the flyout says and offers for the option currently being answered.
struct CommandOptionPrompt: Equatable {
    var title: String
    var subtitle: String?
    var rows: [CommandOptionRow]
    /// Whether the option refuses anything not on the list. Return commits the
    /// typed text only when this is false.
    var isClosedSet: Bool
}

extension AppModel {

    /// What to show above the composer for a command being filled in.
    ///
    /// Nil once every option is answered — there is nothing left to ask, and a
    /// panel saying so would be a panel in the way of the Return that sends.
    func commandPrompt(for pending: PendingCommand, in channelID: ChannelID) -> CommandOptionPrompt? {
        guard let option = pending.focusedOption else { return nil }
        let typed = pending.text.trimmingCharacters(in: .whitespaces)

        return CommandOptionPrompt(
            title: option.name.uppercased() + (option.isRequired ? "  ·  REQUIRED" : ""),
            // **The description belongs here, not in a placeholder.** A
            // placeholder vanishes the moment anybody types, which is exactly
            // when they still want to know what was being asked for.
            subtitle: option.summary.isEmpty ? nil : option.summary,
            rows: rows(for: option, matching: typed, in: channelID),
            isClosedSet: Self.isClosedSet(option)
        )
    }

    /// An option whose value must come off a list.
    ///
    /// A reference is a snowflake and a name is not one; a boolean is two
    /// values; a declared choice list is the application saying it will reject
    /// anything else.
    static func isClosedSet(_ option: CommandOption) -> Bool {
        !option.choices.isEmpty || option.kind == .boolean || option.kind.isReference
    }

    private func rows(
        for option: CommandOption,
        matching typed: String,
        in channelID: ChannelID
    ) -> [CommandOptionRow] {
        if !option.choices.isEmpty {
            return Self.choiceRows(option.choices, matching: typed)
        }
        switch option.kind {
        case .boolean:
            return Self.booleanRows(matching: typed)
        case .user:
            return userRows(matching: typed, in: channelID)
        case .channel:
            return channelRows(matching: typed, in: channelID)
        case .role:
            return roleRows(matching: typed, in: channelID)
        case .mentionable:
            // Roles after people: a mentionable option is very nearly always
            // asking about a person, and a roster of forty roles above the one
            // name being typed is a list nobody reads.
            return userRows(matching: typed, in: channelID)
                + roleRows(matching: typed, in: channelID)
        default:
            // Typed. `.attachment` never reaches here — `offeredParameters`
            // drops it before a command can focus one.
            return []
        }
    }

    // MARK: The closed sets

    private static func choiceRows(
        _ choices: [CommandChoice],
        matching typed: String
    ) -> [CommandOptionRow] {
        matching(choices, typed: typed, name: \.name).map { choice in
            CommandOptionRow(
                id: choice.name,
                title: choice.name,
                // The value only where it differs from the label. `futura` /
                // `futura` is noise; `Very high` / `4` is worth seeing.
                detail: choice.value.display == choice.name ? nil : choice.value.display,
                symbolName: nil,
                action: .fill(choice.value)
            )
        }
    }

    private static func booleanRows(matching typed: String) -> [CommandOptionRow] {
        [(true, "True", "checkmark.circle"), (false, "False", "circle")]
            .filter { typed.isEmpty || $0.1.lowercased().hasPrefix(typed.lowercased()) }
            .map { value, title, symbol in
                CommandOptionRow(
                    id: title,
                    title: title,
                    detail: nil,
                    symbolName: symbol,
                    action: .fill(.boolean(value))
                )
            }
    }

    // MARK: References

    /// The people this option could mean.
    ///
    /// **Whoever this client already knows, and it says so by offering nothing
    /// more.** A direct message has its recipients; a server has whichever
    /// members the roster has loaded, which is a window rather than the whole
    /// membership — `INVARIANTS.md` on the windowed roster. Fetching the rest to
    /// fill a picker would be a member search per keystroke for an option six
    /// commands in the captured index declare.
    private func userRows(matching typed: String, in channelID: ChannelID) -> [CommandOptionRow] {
        var ids: [UserID] = []
        if let channel = channelIndex[channelID] {
            ids = channel.recipientIDs
            if let guildID = channel.guildID {
                ids += (members[guildID]?.keys).map(Array.init) ?? []
            }
        }
        if let currentUserID { ids.append(currentUserID) }

        var seen = Set<UserID>()
        let people = ids
            .filter { seen.insert($0).inserted }
            .compactMap { users[$0] }

        return Self.matching(people, typed: typed, name: \.preferredName)
            .prefix(Self.referenceRowsShown)
            .map { user in
                CommandOptionRow(
                    id: user.id.description,
                    title: user.preferredName,
                    detail: user.preferredName == user.username ? nil : user.username,
                    symbolName: "person.crop.circle",
                    action: .fill(.reference(id: user.id.description, label: user.preferredName))
                )
            }
    }

    private func channelRows(matching typed: String, in channelID: ChannelID) -> [CommandOptionRow] {
        guard let guildID = channelIndex[channelID]?.guildID else { return [] }
        let channels = channelIndex.channelIDs(inGuild: guildID)
            .compactMap { channelIndex[$0] }
            // A category is not a destination, and a channel the reader cannot
            // see is one they must not be able to name. The gate is checked
            // where the action happens, not only where it is drawn —
            // `INVARIANTS.md` §5.5.
            .filter { $0.kind != .category && permissionGate.canView($0.id) }

        return Self.matching(channels, typed: typed, name: { self.displayName(of: $0) })
            .prefix(Self.referenceRowsShown)
            .map { channel in
                CommandOptionRow(
                    id: channel.id.description,
                    title: displayName(of: channel),
                    detail: nil,
                    symbolName: "number",
                    action: .fill(
                        .reference(id: channel.id.description, label: displayName(of: channel))
                    )
                )
            }
    }

    private func roleRows(matching typed: String, in channelID: ChannelID) -> [CommandOptionRow] {
        guard let guildID = channelIndex[channelID]?.guildID,
              let table = roles[guildID]
        else { return [] }

        return Self.matching(Array(table.values), typed: typed, name: \.name)
            .prefix(Self.referenceRowsShown)
            .map { role in
                CommandOptionRow(
                    id: role.id.description,
                    title: role.name,
                    detail: nil,
                    symbolName: "at",
                    action: .fill(.reference(id: role.id.description, label: role.name))
                )
            }
    }

    // MARK: Shared

    /// Prefix first, then anything containing it. One pass, then a stable sort
    /// by the tier — the same shape `CommandSearch` uses, for the same reason:
    /// a prefix match is what somebody typing a name means.
    private static func matching<T>(
        _ items: [T],
        typed: String,
        name: (T) -> String
    ) -> [T] {
        let needle = typed.lowercased()
        guard !needle.isEmpty else { return items }
        var prefixed: [T] = []
        var contained: [T] = []
        for item in items {
            let candidate = name(item).lowercased()
            if candidate.hasPrefix(needle) {
                prefixed.append(item)
            } else if candidate.contains(needle) {
                contained.append(item)
            }
        }
        return prefixed + contained
    }

    /// How many people, channels or roles the picker offers before it asks the
    /// reader to type more. A list longer than a screenful is one nobody scans.
    private static let referenceRowsShown = 12
}
