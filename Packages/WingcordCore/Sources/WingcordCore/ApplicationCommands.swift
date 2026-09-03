import Foundation

// MARK: - Application commands
//
// A slash command is an *interaction*, not a message. Typing `/8ball` and
// pressing Return does not send text: it posts an interaction naming a command
// the application registered, and the application answers with a message of its
// own. Nothing the reader types is ever written into the channel.
//
// **Every shape here is a capture.** `Slash commands.har` (2026-09-03) carries
// the whole index for the account — twelve applications, 183 commands, 621
// options — and two complete `POST /interactions` bodies, one with an option
// value and one without. `ApplicationCommandTests` replays them.
//
// The one thing the capture disagrees with the index about is worth stating
// here because it is the sort of field a client invents by accident:
// `name_localized` and `description_localized` are **not in the index**. The
// reference client synthesises them when it echoes the command back inside the
// interaction, by repeating `name` and `description`. See `CommandInvocation`.

/// What kind of surface a command is invoked from.
///
/// Only `chatInput` reaches the composer. `user` and `message` are the context
/// menus on a person and on a message — a different surface with a different
/// gesture — and `primaryEntryPoint` is the activity launch `ActivityEntryPoint`
/// already models. Keeping all four means the index can be decoded once and
/// filtered by the surface that wants it, rather than each surface re-reading
/// the wire.
public enum CommandKind: Int, Hashable, Sendable {
    case chatInput = 1
    case user = 2
    case message = 3
    case primaryEntryPoint = 4
}

/// An option's type, which decides both what may be typed and what the wire
/// carries.
///
/// `subCommand` and `subCommandGroup` are not parameters at all — they are
/// branches, and a command that has them has no parameters of its own. That
/// distinction is the whole reason `SlashCommand` exists: what a person invokes
/// is a *leaf*, and the leaf is what carries the parameter list.
public enum CommandOptionKind: Int, Hashable, Sendable {
    case subCommand = 1
    case subCommandGroup = 2
    case string = 3
    case integer = 4
    case boolean = 5
    case user = 6
    case channel = 7
    case role = 8
    case mentionable = 9
    case number = 10
    case attachment = 11

    /// Whether this option branches rather than carries a value.
    public var isBranch: Bool { self == .subCommand || self == .subCommandGroup }

    /// Whether the value is a snowflake naming something in the channel — a
    /// person, a channel, a role — rather than something typed.
    public var isReference: Bool {
        switch self {
        case .user, .channel, .role, .mentionable: true
        default: false
        }
    }
}

/// One of a fixed set of values an option accepts.
///
/// **The value is not always a string.** `choices` on an `integer` option
/// carries integers, and a client that stringifies them sends `"3"` where the
/// application expects `3`. `CommandValue` keeps the distinction all the way to
/// the encoder.
public struct CommandChoice: Hashable, Sendable, Identifiable {
    public var name: String
    public var value: CommandValue

    public var id: String { name }

    public init(name: String, value: CommandValue) {
        self.name = name
        self.value = value
    }
}

/// A parameter, or a branch to more of them.
public struct CommandOption: Hashable, Sendable, Identifiable {
    public var kind: CommandOptionKind
    public var name: String
    public var summary: String
    /// **Absent means false.** Two thirds of the captured options omit the key
    /// entirely, and the `8ball` capture proves an *optional* option is still
    /// sent when it was filled in.
    public var isRequired: Bool
    /// Whether the application answers suggestions as this is typed. 142 of the
    /// captured account's 621 options do.
    public var autocompletes: Bool
    public var choices: [CommandChoice]
    /// Branches, for `subCommand` and `subCommandGroup`. Empty otherwise.
    public var options: [CommandOption]
    public var minValue: Double?
    public var maxValue: Double?
    public var minLength: Int?
    public var maxLength: Int?

    public var id: String { name }

    /// Turns typed text into the value this option declared, or nil when it will
    /// not convert.
    ///
    /// **The bounds are enforced here rather than at the far end.** `abc` in an
    /// integer option, or `101` where the application declared a maximum of 100,
    /// is a body it rejects — so Return does nothing and the reader keeps their
    /// caret, instead of watching a command vanish and no answer arrive.
    ///
    /// Nil is also the right answer for a closed set: nothing typed can name a
    /// snowflake. Callers check `CommandOption` kinds for that before reaching
    /// here, and this stays a pure conversion.
    public func value(from typed: String) -> CommandValue? {
        switch kind {
        case .integer:
            guard let value = Int(typed), isInRange(Double(value)) else { return nil }
            return .integer(value)
        case .number:
            guard let value = Double(typed), isInRange(value) else { return nil }
            return .number(value)
        case .string:
            if let maximum = maxLength, typed.count > maximum { return nil }
            if let minimum = minLength, typed.count < minimum { return nil }
            return .string(typed)
        default:
            return .string(typed)
        }
    }

    private func isInRange(_ value: Double) -> Bool {
        if let minimum = minValue, value < minimum { return false }
        if let maximum = maxValue, value > maximum { return false }
        return true
    }

    public init(
        kind: CommandOptionKind,
        name: String,
        summary: String = "",
        isRequired: Bool = false,
        autocompletes: Bool = false,
        choices: [CommandChoice] = [],
        options: [CommandOption] = [],
        minValue: Double? = nil,
        maxValue: Double? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil
    ) {
        self.kind = kind
        self.name = name
        self.summary = summary
        self.isRequired = isRequired
        self.autocompletes = autocompletes
        self.choices = choices
        self.options = options
        self.minValue = minValue
        self.maxValue = maxValue
        self.minLength = minLength
        self.maxLength = maxLength
    }
}

/// A command exactly as the index answered it.
///
/// The wire's own record, kept whole rather than narrowed, because the
/// interaction **echoes it back**: `data.application_command` repeats id,
/// version, contexts, handler and the option tree beside the `id`/`version`
/// pair one level up. Narrowing here would mean rebuilding a shape at send time
/// out of fields that had been thrown away.
public struct ApplicationCommand: Hashable, Sendable, Identifiable {
    /// A string, not a `Snowflake`. Discord's own built-in commands are keyed
    /// with **negative** ids — the captured frecency table has an entry for
    /// `-6` — so a client that insists on `UInt64` cannot even read the account
    /// back. Nothing here does arithmetic on it.
    public var id: String
    public var kind: CommandKind
    public var applicationID: ApplicationID
    public var version: String
    public var name: String
    public var summary: String
    public var options: [CommandOption]
    public var contexts: [Int]
    public var integrationTypes: [Int]
    public var dmPermission: Bool
    /// Discord's own popularity ordering, smaller being more popular. Absent on
    /// 17 of the captured 183 — a command nobody has run has no rank rather
    /// than a large one, so absence sorts last rather than first.
    public var popularityRank: Int?
    /// `primaryEntryPoint` only. See `ActivityEntryPoint`.
    public var handler: Int?

    public init(
        id: String,
        kind: CommandKind,
        applicationID: ApplicationID,
        version: String,
        name: String,
        summary: String = "",
        options: [CommandOption] = [],
        contexts: [Int] = [],
        integrationTypes: [Int] = [],
        dmPermission: Bool = true,
        popularityRank: Int? = nil,
        handler: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.applicationID = applicationID
        self.version = version
        self.name = name
        self.summary = summary
        self.options = options
        self.contexts = contexts
        self.integrationTypes = integrationTypes
        self.dmPermission = dmPermission
        self.popularityRank = popularityRank
        self.handler = handler
    }
}

/// The application a command belongs to, as the index names it.
///
/// The index carries these *beside* the commands rather than inside them, which
/// is what makes one 119 KB response enough to draw a grouped list: twelve
/// applications named once, not 183 times.
public struct CommandApplication: Hashable, Sendable, Identifiable {
    public var id: ApplicationID
    public var name: String
    public var iconHash: String?
    public var botID: UserID?

    public init(id: ApplicationID, name: String, iconHash: String? = nil, botID: UserID? = nil) {
        self.id = id
        self.name = name
        self.iconHash = iconHash
        self.botID = botID
    }
}

/// One `application-command-index` response.
public struct CommandIndex: Hashable, Sendable {
    public var applications: [CommandApplication]
    public var commands: [ApplicationCommand]
    /// Bumped by Discord when anything in the index changes. The reference
    /// client sends it back to ask "has this moved?", and it is what makes one
    /// fetch per session correct rather than optimistic.
    public var version: String

    public init(
        applications: [CommandApplication] = [],
        commands: [ApplicationCommand] = [],
        version: String = ""
    ) {
        self.applications = applications
        self.commands = commands
        self.version = version
    }

    public var isEmpty: Bool { commands.isEmpty && applications.isEmpty }
}

// MARK: - What a person actually invokes

/// A chat-input command flattened to a **leaf**: the command, the subcommand
/// path taken through it, and the parameters that path exposes.
///
/// **The list a person reads is a list of leaves, not of commands.** esmBot's
/// `base64` has no parameters at all — it has `encode` and `decode`, and each of
/// those has a `text`. A picker that offers `base64` offers something that
/// cannot be run; Discord's own list draws `gen eject` and `gen emergency` as
/// two rows for exactly this reason. The captured index flattens 166 chat-input
/// commands into 186 leaves.
///
/// The path is at most two deep — group, then subcommand — because that is the
/// deepest the wire allows, and `path` being an array rather than two optionals
/// is what lets the encoder nest it by folding rather than by branching.
public struct SlashCommand: Hashable, Sendable, Identifiable {
    public var command: ApplicationCommand
    /// The names walked to reach this leaf. Empty for a command with no
    /// subcommands.
    public var path: [String]
    /// The leaf's own parameters, in the order the application declared them —
    /// which is the order they must be *offered* in, because a bot's required
    /// options come first by convention and the reader fills them in that order.
    public var parameters: [CommandOption]

    /// Unique across the whole index. The command id alone is not: two leaves of
    /// `base64` share it.
    public var id: String {
        path.isEmpty ? command.id : command.id + " " + path.joined(separator: " ")
    }

    /// `base64 decode`, or `8ball`. What the row draws after its slash.
    public var name: String {
        ([command.name] + path).joined(separator: " ")
    }

    /// The leaf's description where it has one, the command's otherwise.
    public var summary: String

    public var applicationID: ApplicationID { command.applicationID }
    public var popularityRank: Int? { command.popularityRank }

    public init(
        command: ApplicationCommand,
        path: [String] = [],
        parameters: [CommandOption] = [],
        summary: String = ""
    ) {
        self.command = command
        self.path = path
        self.parameters = parameters
        self.summary = summary
    }

    /// The parameters this client can actually fill.
    ///
    /// **Attachment options are not offered**, because sending one needs the
    /// multipart upload this client does not have — and an option that looks
    /// fillable and silently sends nothing is the inert control `INVARIANTS.md`
    /// §5.5 forbids. Not one of the 83 attachment options in the captured index
    /// is required, so dropping them costs no command its usability; the guard
    /// below is what keeps that a *measured* fact rather than a lucky one.
    public var offeredParameters: [CommandOption] {
        parameters.filter { $0.kind != .attachment }
    }

    /// Whether an option this client cannot fill is required.
    ///
    /// Zero commands in the captured index answer true. It is checked anyway:
    /// the alternative is a Send control that posts an interaction the
    /// application rejects, which reads as the client being broken.
    public var needsUnsupportedOption: Bool {
        parameters.contains { $0.kind == .attachment && $0.isRequired }
    }
}

extension CommandIndex {

    /// Every chat-input leaf, flattened.
    ///
    /// One pass, and the recursion is bounded by the wire's own two-level
    /// limit — so this is O(options), not O(options²), and it is memoized by the
    /// caller rather than recomputed per keystroke.
    public var slashCommands: [SlashCommand] {
        var result: [SlashCommand] = []
        result.reserveCapacity(commands.count)
        for command in commands where command.kind == .chatInput {
            Self.appendLeaves(of: command, options: command.options, path: [], into: &result)
        }
        return result
    }

    private static func appendLeaves(
        of command: ApplicationCommand,
        options: [CommandOption],
        path: [String],
        into result: inout [SlashCommand]
    ) {
        let branches = options.filter(\.kind.isBranch)
        guard !branches.isEmpty else {
            result.append(
                SlashCommand(
                    command: command,
                    path: path,
                    parameters: options,
                    // A leaf's own description where the path took one, and the
                    // command's where it did not. `base64 decode` says "Decodes
                    // a Base64 string"; drawing the parent's "Encodes/decodes"
                    // on both rows makes them indistinguishable.
                    summary: command.summary
                )
            )
            return
        }
        for branch in branches {
            var nested: [SlashCommand] = []
            appendLeaves(of: command, options: branch.options, path: path + [branch.name], into: &nested)
            for var leaf in nested {
                // Written after the recursion so the deepest description wins:
                // a group's own line is a heading, and the subcommand under it
                // is what the row is about.
                if leaf.path.count == path.count + 1 { leaf.summary = branch.summary }
                result.append(leaf)
            }
        }
    }
}

// MARK: - A value on its way to the wire

/// What an option was filled with.
///
/// A closed set rather than `Any`, so the encoder cannot be handed something it
/// has no rule for — and so an `integer` option carries an `Int` all the way
/// down rather than being stringified at the view and re-parsed at the socket.
public enum CommandValue: Hashable, Sendable, Encodable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    /// A user, channel, role or mentionable. The wire carries the snowflake as
    /// a string; `label` is what the composer draws and never leaves the app.
    case reference(id: String, label: String)

    /// Encodes as the scalar the option's type calls for — never as an object,
    /// and never coerced to a string. An `integer` choice sent back as `"3"` is
    /// a type error at the application.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        // A snowflake goes out as a string, like every other id on this wire.
        case .reference(let id, _): try container.encode(id)
        }
    }

    /// What the field shows once the option is filled.
    public var display: String {
        switch self {
        case .string(let text): text
        case .integer(let value): String(value)
        case .number(let value): Self.numberFormat.string(from: value as NSNumber) ?? String(value)
        case .boolean(let value): value ? "True" : "False"
        case .reference(_, let label): label
        }
    }

    /// Trailing zeros are noise on a value somebody typed as `1.5`.
    private static let numberFormat: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 6
        formatter.usesGroupingSeparator = false
        return formatter
    }()
}

/// An option name paired with what it was filled with.
///
/// An ordered array rather than a dictionary: the wire's `options` array is
/// ordered, the application reads it positionally in more than one library, and
/// a dictionary would make the send order depend on hashing.
public struct CommandArgument: Hashable, Sendable, Identifiable {
    public var name: String
    public var kind: CommandOptionKind
    public var value: CommandValue

    public var id: String { name }

    public init(name: String, kind: CommandOptionKind, value: CommandValue) {
        self.name = name
        self.kind = kind
        self.value = value
    }
}

/// A command the reader has chosen but not yet sent.
///
/// **This lives beside the draft, never inside it.** Discord's own composer
/// draws a command as chips over a text field, and the state underneath is a
/// token stream rather than a string — a client that keeps `/8ball question:…`
/// as text has to re-parse the reader's own punctuation to know what they meant,
/// and gets it wrong the first time somebody's question contains a colon.
///
/// Holding it beside `draft` also means abandoning a command with Escape gives
/// back exactly what was typed before it started.
public struct PendingCommand: Hashable, Sendable {
    public var command: SlashCommand
    /// Filled options, in the order they were filled.
    public var arguments: [CommandArgument]
    /// The option being typed into, by name. Nil once every option the reader
    /// wants is filled and the bar is waiting on Return.
    public var focused: String?
    /// What has been typed into the focused option so far.
    public var text: String

    public init(
        command: SlashCommand,
        arguments: [CommandArgument] = [],
        focused: String? = nil,
        text: String = ""
    ) {
        self.command = command
        self.arguments = arguments
        self.focused = focused ?? command.offeredParameters.first?.name
        self.text = text
    }

    public var focusedOption: CommandOption? {
        guard let focused else { return nil }
        return command.parameters.first { $0.name == focused }
    }

    public func argument(named name: String) -> CommandArgument? {
        arguments.first { $0.name == name }
    }

    /// Options with nothing in them yet, in declaration order.
    public var unfilledParameters: [CommandOption] {
        let filled = Set(arguments.map(\.name))
        return command.offeredParameters.filter { !filled.contains($0.name) }
    }

    /// Whether every required option has a value.
    ///
    /// The focused option's *typed text* does not count: it becomes a value when
    /// it is committed, and treating a half-typed word as filled is how Return
    /// sends a command with an empty required argument.
    public var isComplete: Bool {
        guard !command.needsUnsupportedOption else { return false }
        let filled = Set(arguments.map(\.name))
        return command.offeredParameters
            .filter(\.isRequired)
            .allSatisfy { filled.contains($0.name) }
    }

    /// Puts `value` in, replacing whatever was there, and moves to the next
    /// option that still needs one.
    ///
    /// **Replacing rather than appending** is what makes going back to an option
    /// already filled work: the chips are editable, and a second write to the
    /// same name must not send it twice.
    public mutating func commit(_ value: CommandValue, for option: CommandOption) {
        let argument = CommandArgument(name: option.name, kind: option.kind, value: value)
        if let index = arguments.firstIndex(where: { $0.name == option.name }) {
            arguments[index] = argument
        } else {
            arguments.append(argument)
        }
        text = ""
        focused = nextFocus(after: option.name)
    }

    /// Takes an option back out and puts the caret in it.
    public mutating func clear(_ name: String) {
        arguments.removeAll { $0.name == name }
        focused = name
        text = ""
    }

    /// The option to move to after `name`.
    ///
    /// Required options first, in declaration order, then the optional ones —
    /// so Tab walks the command the way its author wrote it and never stops on
    /// something already answered.
    private func nextFocus(after name: String) -> String? {
        let filled = Set(arguments.map(\.name))
        let remaining = command.offeredParameters.filter { !filled.contains($0.name) }
        if let required = remaining.first(where: \.isRequired) { return required.name }
        // Past the required ones, keep going forward from where we were rather
        // than jumping back to the first optional the reader already skipped.
        let order = command.offeredParameters.map(\.name)
        if let position = order.firstIndex(of: name) {
            for candidate in order[order.index(after: position)...] where !filled.contains(candidate) {
                return candidate
            }
        }
        return remaining.first?.name
    }
}
