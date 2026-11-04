import Foundation

/// What a "used" line's chip is, and so what pressing it does — Discord's own
/// split (`es` in module `217424`).
public enum CommandHeaderChip: Hashable, Sendable {
    /// A slash command: the apps glyph, and a press opens the command as it was
    /// run.
    case command
    /// An app's entry point: the apps glyph, and a press opens the app launcher
    /// at the app.
    case activity
    /// A context-menu command: its name, and nothing to press.
    case label
    /// An activity something other than an entry point started: "started an
    /// activity", whose last word opens the launcher.
    case startedActivity

    /// Whether it is drawn on a plate, with the glyph at its head.
    public var hasPlate: Bool { self == .command || self == .activity }

    /// Whether a press does anything.
    public var isPressable: Bool { self != .label }

    /// The words on the chip.
    ///
    /// An entry point's name is a word for machines — `launch`, `play_game` —
    /// so it is written as Discord writes it (`kF` in `735991`): a capital and
    /// spaces.
    public func title(of interaction: MessageInteraction) -> String {
        switch self {
        case .command, .label:
            interaction.name
        case .activity:
            interaction.name.prefix(1).uppercased()
                + interaction.name.dropFirst().replacingOccurrences(of: "_", with: " ")
        case .startedActivity:
            "activity"
        }
    }
}

extension Message {
    /// Nil where there is no "used" line at all.
    public var commandHeaderChip: CommandHeaderChip? {
        guard let interaction else { return nil }
        let isEntryPoint = interaction.commandType == MessageInteraction.primaryEntryPoint
        if activityInvite != nil, !isEntryPoint { return .startedActivity }
        if kind == .chatInputCommand { return .command }
        return isEntryPoint ? .activity : .label
    }
}

extension MessageInteraction {
    /// `command_type` 4: an app's entry point, which launches its activity.
    public static let primaryEntryPoint = 4
}

/// What somebody actually ran: `GET /channels/{c}/messages/{m}/interaction-data`,
/// which is what Discord's popout over a "used" line's chip draws (`Y` in
/// `217424`).
///
/// **The message itself does not say.** `interaction_metadata` names the
/// command and nothing else; the options it was given exist only behind this
/// route, so they are asked for when the chip is pressed.
public struct InvokedCommand: Hashable, Sendable {
    /// The command's own name, without its subcommands — they are in `options`,
    /// where the wire has them.
    public var name: String
    public var options: [InvokedOption]

    public init(name: String, options: [InvokedOption] = []) {
        self.name = name
        self.options = options
    }

    /// One piece of the line the popout draws, in reading order:
    /// `/base64 decode text: aGk=`.
    public enum Piece: Hashable, Sendable {
        /// The command, and a subcommand after it.
        case command(String)
        /// An option's name.
        case label(String)
        /// What an option was given.
        case value(InvokedOption.Value)
    }

    public var pieces: [Piece] {
        [.command("/" + name)] + options.flatMap(\.pieces)
    }
}

/// One option as it was filled in, or a subcommand and the options under it.
public struct InvokedOption: Hashable, Sendable {
    public enum Value: Hashable, Sendable {
        /// What was typed, or the label of the choice picked.
        case text(String)
        case user(UserID)
        case channel(ChannelID)
        case role(RoleID)
        /// A snowflake that may be a role or a person.
        case mentionable(UInt64)
        /// Discord writes "[attachment]" and shows no name: the option holds an
        /// id, and the file is on the message.
        case attachment
    }

    /// The name as declared, localized where the command says so.
    public var name: String
    /// Nil for a subcommand, and for an option that arrived with no value.
    public var value: Value?
    /// Whether this is a subcommand or a group, which has options, not a value.
    public var isBranch: Bool
    public var options: [InvokedOption]

    public init(name: String, value: Value? = nil, isBranch: Bool = false, options: [InvokedOption] = []) {
        self.name = name
        self.value = value
        self.isBranch = isBranch
        self.options = options
    }

    var pieces: [InvokedCommand.Piece] {
        if isBranch { return [.command(" " + name)] + options.flatMap(\.pieces) }
        return [.label(" \(name): ")] + (value.map { [.value($0)] } ?? [])
    }
}
