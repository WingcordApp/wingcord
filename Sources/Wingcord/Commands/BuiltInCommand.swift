import Foundation

/// A command Wingcord answers itself: typed like a slash command, listed in
/// the `/` flyout under Wingcord, and **never sent to Discord**.
///
/// `/bug` was the first (docs/BUG-REPORTING.md D21), `/idea` the second
/// (D24). Whatever follows the name opens the sheet with those words already
/// in its first field.
nonisolated enum BuiltInCommand: String, CaseIterable, Hashable, Sendable {
    case bug
    case idea

    var name: String { rawValue }

    var summary: String {
        switch self {
        case .bug: "Report a bug in Wingcord. Nothing is sent to Discord."
        case .idea: "Suggest a feature for Wingcord. Nothing is sent to Discord."
        }
    }

    var symbolName: String {
        switch self {
        case .bug: "ladybug"
        case .idea: "lightbulb"
        }
    }

    /// What the `/` flyout lists for a query: every built-in for a bare `/`,
    /// the ones whose name starts with what is typed, and the one named
    /// exactly with words after it — `/bug it froze` is still `/bug`.
    static func matching(_ query: String) -> [BuiltInCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return allCases }
        let word = trimmed.prefix { !$0.isWhitespace }
        let hasMore = word.count < trimmed.count
        return allCases.filter { command in
            hasMore ? command.name == word : command.name.hasPrefix(word)
        }
    }

    /// The built-in a whole draft runs, and the words after its name — or nil
    /// when the draft is a message.
    static func invocation(in draft: String) -> (command: BuiltInCommand, argument: String)? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let word = body.prefix { !$0.isWhitespace }
        guard let command = BuiltInCommand(rawValue: word.lowercased()) else { return nil }
        let argument = body.dropFirst(word.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (command, argument)
    }

    /// The flyout's Wingcord section for a query, or nil when nothing matches.
    static func section(matching query: String) -> CommandSection? {
        let commands = matching(query)
        guard !commands.isEmpty else { return nil }
        return CommandSection(
            id: "wingcord",
            title: "Wingcord",
            iconURL: nil,
            isFrequent: false,
            isBuiltIn: true,
            rows: commands.map { command in
                CommandRow(
                    id: "wingcord/" + command.name,
                    target: .builtIn(command),
                    applicationName: "Wingcord",
                    iconURL: nil,
                    monogram: "W",
                    symbolName: command.symbolName,
                    hint: ""
                )
            }
        )
    }
}
