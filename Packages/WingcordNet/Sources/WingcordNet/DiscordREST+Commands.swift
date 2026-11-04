import Foundation
import WingcordCore

// MARK: - Slash commands
//
// Two routes and one shape. The index says what may be run; `POST /interactions`
// runs it. Both are captured in `Slash commands.har` (2026-09-03) — the index
// with 183 commands across twelve applications, and two complete interaction
// bodies, one carrying an option value and one carrying none.
//
// **The index is fetched once and filtered locally.** The capture is
// unambiguous about this: typing `/` fired exactly one request, and running two
// different commands over the next sixty seconds fired none. There is no search
// route, and a client that sends one per keystroke is inventing traffic.

extension DiscordREST {

    /// Where a command list is being asked for.
    ///
    /// Three routes answer the same shape and the channel decides which. A
    /// guild's index carries the bots installed *to that server*; the account's
    /// carries the apps installed to the reader, which are the ones that work
    /// anywhere. Both are needed in a guild, because a user-installed app is in
    /// neither the other's list — Wordle's entry point is in the account index
    /// and not in the app-scoped one, which is the same asymmetry
    /// `activityEntryPoint` already has to walk.
    ///
    /// **The guild route is documented, not captured.** The capture was taken
    /// in a direct message, where the reference client asks for the account's
    /// index and nothing else — one request, at the moment `/` was typed.
    /// `/guilds/{id}/application-command-index` is what `docs.discord.food`
    /// names for a server and it answers the same shape; a guild capture would
    /// promote it. The account route is the one this client can prove.
    public enum CommandScope: Hashable, Sendable {
        case account
        case guild(GuildID)
        /// One application's own commands. The 622-byte route the activity
        /// launcher already leans on.
        case application(ApplicationID)

        var path: String {
            switch self {
            case .account: "/users/@me/application-command-index"
            case .guild(let id): "/guilds/\(id.rawValue)/application-command-index"
            case .application(let id): "/applications/\(id.rawValue)/application-command-index"
            }
        }

        var route: String {
            switch self {
            case .account: "users/@me/application-command-index"
            case .guild: "guilds/:id/application-command-index"
            case .application: "applications/:id/application-command-index"
            }
        }
    }

    /// Everything the reader may run in one scope.
    ///
    /// **A 404 is an empty index, not a failure.** A server with no bots
    /// answers one, and treating it as an error would put "commands could not
    /// be loaded" over a channel where the true answer is "there are none".
    public func commandIndex(_ scope: CommandScope) async throws -> CommandIndex {
        do {
            return try await get(scope.path, route: scope.route, as: CommandIndexDTO.self).domain
        } catch Failure.api(let status, _, _) where status == 404 {
            return CommandIndex()
        }
    }

    /// Runs a command.
    ///
    /// Answers `204` with an empty body, exactly as the activity launch does —
    /// what the command produced arrives over the socket as the application's
    /// own message, and `INTERACTION_SUCCESS` / `INTERACTION_FAILURE` say
    /// whether it is coming.
    ///
    /// `sessionID` is the gateway's and is not optional: an interaction names
    /// the session that will receive its response.
    public func sendCommand(_ invocation: CommandInvocation) async throws {
        _ = try await requestData(
            method: "POST",
            path: "/interactions",
            route: "interactions",
            body: invocation
        )
    }
}

extension CommandIndex {

    /// Decodes an `application-command-index` payload.
    ///
    /// Public so `--demo` can build its fixtures out of the capture's own bytes
    /// rather than by hand — which means the demo exercises this decoder rather
    /// than an object graph somebody typed to match it.
    public static func decode(_ data: Data) throws -> CommandIndex {
        try JSONDecoder().decode(CommandIndexDTO.self, from: data).domain
    }

    /// The first thing here that can open an activity.
    ///
    /// **`kind == .primaryEntryPoint` alone. The handler is not a filter.**
    ///
    /// `handler` says *who answers* the interaction — `2` is Discord opening
    /// the activity itself, `1` is the application answering and opening it in
    /// its response — not whether there is anything to launch. Of the seven
    /// type-4 entry points in the captured account index, six are `2` and one is
    /// `1`: Wordle's, whose `play` is exactly as launchable as Watch Together's.
    /// Filtering on `2` reported "Wordle has nothing to launch."
    public var entryPoint: ActivityEntryPoint? {
        commands.lazy.compactMap(\.activityEntryPoint).first
    }

    public func entryPoint(for id: ApplicationID) -> ActivityEntryPoint? {
        commands.lazy
            .filter { $0.applicationID == id }
            .compactMap(\.activityEntryPoint)
            .first
    }
}

extension ApplicationCommand {
    public var activityEntryPoint: ActivityEntryPoint? {
        guard kind == .primaryEntryPoint else { return nil }
        return ActivityEntryPoint(
            id: id,
            applicationID: applicationID,
            version: version,
            name: name,
            contexts: contexts,
            integrationTypes: integrationTypes,
            // Carried so the launch can echo the index rather than invent a
            // record — see `ActivityEntryPoint` and `LaunchInteraction`.
            summary: summary,
            dmPermission: dmPermission,
            handler: handler
        )
    }
}

// MARK: - The index, on the wire

/// `GET /{scope}/application-command-index`.
///
/// Decoded leniently throughout — every field optional, every unknown dropped.
/// One command with a type this client has no case for must cost that row and
/// nothing else: the alternative is a `/` that opens onto nothing because a bot
/// somewhere registered something new.
struct CommandIndexDTO: Decodable, Sendable {
    var applications: [ApplicationDTO]?
    var application_commands: [CommandDTO]?
    var version: String?

    struct ApplicationDTO: Decodable, Sendable {
        var id: ApplicationID?
        var name: String?
        var icon: String?
        var bot_id: UserID?

        var domain: CommandApplication? {
            guard let id else { return nil }
            return CommandApplication(
                id: id,
                // An application with no name is drawn under its id rather than
                // dropped: its commands are still runnable, and a section with
                // no heading is better than commands that vanish.
                name: name ?? id.description,
                iconHash: icon,
                botID: bot_id
            )
        }
    }

    struct CommandDTO: Decodable, Sendable {
        var id: String?
        var type: Int?
        var application_id: ApplicationID?
        var version: String?
        var name: String?
        var description: String?
        var options: [OptionDTO]?
        var dm_permission: Bool?
        var contexts: [Int]?
        var integration_types: [Int]?
        var global_popularity_rank: Int?
        var handler: Int?

        var domain: ApplicationCommand? {
            guard let id, let application_id, let version, let name,
                  // **Absent `type` means CHAT_INPUT.** The wire's own default,
                  // and the index does omit it — a command dropped for having no
                  // type is a command that was perfectly ordinary.
                  let kind = CommandKind(rawValue: type ?? 1)
            else { return nil }
            return ApplicationCommand(
                id: id,
                kind: kind,
                applicationID: application_id,
                version: version,
                name: name,
                summary: description ?? "",
                options: (options ?? []).compactMap(\.domain),
                contexts: contexts ?? [],
                integrationTypes: integration_types ?? [],
                dmPermission: dm_permission ?? true,
                popularityRank: global_popularity_rank,
                handler: handler
            )
        }
    }

    struct OptionDTO: Decodable, Sendable {
        var type: Int?
        var name: String?
        var description: String?
        var required: Bool?
        var autocomplete: Bool?
        var choices: [ChoiceDTO]?
        var options: [OptionDTO]?
        var min_value: JSONNumber?
        var max_value: JSONNumber?
        var min_length: Int?
        var max_length: Int?

        var domain: CommandOption? {
            guard let name, let type, let kind = CommandOptionKind(rawValue: type) else { return nil }
            return CommandOption(
                kind: kind,
                name: name,
                summary: description ?? "",
                isRequired: required ?? false,
                autocompletes: autocomplete ?? false,
                choices: (choices ?? []).compactMap(\.domain),
                options: (options ?? []).compactMap(\.domain),
                minValue: min_value?.double,
                maxValue: max_value?.double,
                minLength: min_length,
                maxLength: max_length
            )
        }
    }

    struct ChoiceDTO: Decodable, Sendable {
        var name: String?
        var value: JSONValue?

        var domain: CommandChoice? {
            guard let name, let value = value?.commandValue else { return nil }
            return CommandChoice(name: name, value: value)
        }
    }

    var domain: CommandIndex {
        CommandIndex(
            applications: (applications ?? []).compactMap(\.domain),
            commands: (application_commands ?? []).compactMap(\.domain),
            version: version ?? ""
        )
    }
}

/// A bound that is written as an integer on an `integer` option and as a
/// fraction on a `number` one.
///
/// Both land in one `Double` because that is all a bound is ever compared
/// against, and a decoder that insisted on the matching type would throw away
/// the whole option over a `1` where it expected `1.0`.
struct JSONNumber: Decodable, Sendable {
    var double: Double

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            double = value
        } else if let value = try? container.decode(Int.self) {
            double = Double(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a number")
        }
    }
}

/// A choice's value, which is a string on a `string` option and a number on the
/// other two kinds that may carry choices.
///
/// **Not stringified on the way in.** An `integer` choice sent back as `"3"` is
/// a type error at the application, and the round trip through this type is the
/// only place the distinction can be preserved — the index does not repeat the
/// option's type inside its own choices.
enum JSONValue: Decodable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a scalar")
        }
    }

    var commandValue: CommandValue {
        switch self {
        case .string(let value): .string(value)
        case .integer(let value): .integer(value)
        case .number(let value): .number(value)
        }
    }
}

// MARK: - Running one

/// `POST /interactions`, `type: 2`.
///
/// **The command is echoed back inside the interaction, not merely named.**
/// `data.application_command` repeats the whole record the index answered with
/// — id, version, contexts, integration types, the option *tree* — beside the
/// `id`/`version` pair one level up. Both captured bodies are shaped that way,
/// and this encoder reproduces them field for field.
///
/// Two fields in that echo are **not** in the index and are synthesised by the
/// client: `name_localized` and `description_localized`. The reference client
/// writes them by repeating `name` and `description`, on the command and on
/// every option; a client that omits them sends a shape nobody else sends.
public struct CommandInvocation: Encodable, Sendable {
    var type = 2
    var application_id: String
    /// Absent in both captures, because both were sent from a direct message.
    /// A guild channel names its guild; the field is optional on the route and
    /// omitted rather than sent empty.
    var guild_id: String?
    var channel_id: String
    var session_id: String
    var data: Payload
    var nonce: String
    /// Discord's own analytics vocabulary, and it is **not one value**. A
    /// command typed after a slash carries `slash_ui`; the same command sent
    /// from an app's own page carries `app_launcher` and a `source` beside it.
    /// Both are captured — `Slash commands.har` and `OwO app commands full.har`
    /// — and a client that sent one everywhere would be sending a shape nobody
    /// else sends from half its surfaces.
    var analytics_location: String
    var source: String?

    /// Where the reader ran it from.
    public enum Origin: Sendable {
        /// Typed into the composer after a slash.
        case slashUI
        /// Sent from an application's own page in the apps flyout.
        case applicationPage

        var location: String {
            switch self {
            case .slashUI: "slash_ui"
            case .applicationPage: "app_launcher"
            }
        }

        /// Only the app launcher sends one, and `TEXT` is the value both of its
        /// captured invocations carry.
        var source: String? {
            switch self {
            case .slashUI: nil
            case .applicationPage: "TEXT"
            }
        }
    }

    public init(
        command: SlashCommand,
        arguments: [CommandArgument],
        guildID: GuildID?,
        channelID: ChannelID,
        sessionID: String,
        nonce: String,
        origin: Origin = .slashUI
    ) {
        application_id = command.applicationID.description
        guild_id = guildID?.description
        channel_id = channelID.description
        session_id = sessionID
        self.nonce = nonce
        analytics_location = origin.location
        source = origin.source
        data = Payload(command: command, arguments: arguments)
    }

    struct Payload: Encodable {
        var version: String
        var id: String
        var name: String
        var type = 1
        var options: [OptionPayload]
        var application_command: CommandPayload
        var attachments: [String] = []

        init(command: SlashCommand, arguments: [CommandArgument]) {
            version = command.command.version
            id = command.command.id
            name = command.command.name
            // **The subcommand path is the first level of `options`.** A leaf
            // reached through `base64 → decode` sends
            // `[{type: 1, name: "decode", options: [ … ]}]`, not a flat list
            // with the branch's name lost — the application dispatches on that
            // nesting and a flattened body reaches no handler at all.
            options = OptionPayload.nest(
                path: command.path,
                leaves: arguments.map(OptionPayload.init)
            )
            application_command = CommandPayload(command.command)
        }
    }

    /// One filled option, or one step of the subcommand path.
    struct OptionPayload: Encodable {
        var type: Int
        var name: String
        var value: CommandValue?
        var options: [OptionPayload]?

        init(_ argument: CommandArgument) {
            type = argument.kind.rawValue
            name = argument.name
            value = argument.value
        }

        private init(branch name: String, options: [OptionPayload]) {
            // Always `1`. A group is `2` on the *declaration* and the invocation
            // nests it identically, so the distinction costs nothing here — but
            // a two-deep path writes its outer step as a group, which is what
            // the fold below reproduces by walking the path in reverse.
            type = CommandOptionKind.subCommand.rawValue
            self.name = name
            self.options = options
        }

        static func nest(path: [String], leaves: [OptionPayload]) -> [OptionPayload] {
            guard !path.isEmpty else { return leaves }
            var payload = leaves
            for (index, name) in zip(path.indices, path).reversed() {
                var branch = OptionPayload(branch: name, options: payload)
                // The outer step of a two-deep path is the group.
                if index < path.count - 1 { branch.type = CommandOptionKind.subCommandGroup.rawValue }
                payload = [branch]
            }
            return payload
        }

        enum CodingKeys: String, CodingKey { case type, name, value, options }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(name, forKey: .name)
            if let value { try container.encode(value, forKey: .value) }
            if let options { try container.encode(options, forKey: .options) }
        }
    }

    /// The index's own record, sent back verbatim.
    struct CommandPayload: Encodable {
        var id: String
        var type: Int
        var application_id: String
        var version: String
        var name: String
        var description: String
        var options: [DeclaredOption]
        var dm_permission: Bool
        var contexts: [Int]
        var integration_types: [Int]
        var global_popularity_rank: Int?
        var handler: Int?
        var description_localized: String
        var name_localized: String

        init(_ command: ApplicationCommand) {
            id = command.id
            type = command.kind.rawValue
            application_id = command.applicationID.description
            version = command.version
            name = command.name
            description = command.summary
            options = command.options.map(DeclaredOption.init)
            dm_permission = command.dmPermission
            contexts = command.contexts
            integration_types = command.integrationTypes
            global_popularity_rank = command.popularityRank
            handler = command.handler
            description_localized = command.summary
            name_localized = command.name
        }
    }

    /// An option as *declared*, inside the echo. Distinct from `OptionPayload`,
    /// which is an option as *filled* — the two share a name on the wire and
    /// nothing else: this one carries the description and no value, that one
    /// carries a value and no description.
    struct DeclaredOption: Encodable {
        var type: Int
        var name: String
        var description: String
        var required: Bool?
        var autocomplete: Bool?
        var options: [DeclaredOption]?
        var description_localized: String
        var name_localized: String

        init(_ option: CommandOption) {
            type = option.kind.rawValue
            name = option.name
            description = option.summary
            // Written only where the index wrote them. The `8ball` capture omits
            // `required` on an option that is not required, and echoing a
            // `false` the index never sent is the sort of drift that makes a
            // client identifiable.
            required = option.isRequired ? true : nil
            autocomplete = option.autocompletes ? true : nil
            options = option.options.isEmpty ? nil : option.options.map(DeclaredOption.init)
            description_localized = option.summary
            name_localized = option.name
        }

        enum CodingKeys: String, CodingKey {
            case type, name, description, required, autocomplete, options
            case description_localized, name_localized
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(description, forKey: .description)
            try container.encodeIfPresent(required, forKey: .required)
            try container.encodeIfPresent(autocomplete, forKey: .autocomplete)
            try container.encodeIfPresent(options, forKey: .options)
            try container.encode(description_localized, forKey: .description_localized)
            try container.encode(name_localized, forKey: .name_localized)
        }
    }
}

// MARK: - Running a context command

/// `POST /interactions`, `type: 2`, with a **target** instead of options.
///
/// The same interaction the `/` picker sends, and the differences are exactly
/// three:
///
///  - **`data.type` is the command's own kind** — 2 for a person, 3 for a
///    message — where a chat-input command sends 1.
///  - **`data.target_id` says what it runs on**, and it is the whole of the
///    payload: a context command has no options, so nothing else distinguishes
///    running it on this message from running it on another.
///  - **`data.options` is empty and stays present.** Discord forbids options
///    on types 2 and 3, and the reference client still sends the key.
///
/// The `application_command` echo is the same record the index answered with,
/// verbatim, exactly as the chat-input invocation sends it.
///
/// **`analytics_location` here is NOT captured.** The two locations this
/// client knows — `slash_ui` and `app_launcher` — are both from HARs; nothing
/// has watched Discord invoke a command from a right-click. It is an analytics
/// field, so a wrong value fails *silently* rather than refusing the command,
/// which is the whole reason it is called out here: the tell would be a
/// command that runs perfectly and is attributed to the wrong surface.
public struct ContextCommandInvocation: Encodable, Sendable {
    var type = 2
    var application_id: String
    var guild_id: String?
    var channel_id: String
    var session_id: String
    var data: Payload
    var nonce: String
    var analytics_location: String

    public init(
        command: ApplicationCommand,
        targetID: String,
        guildID: GuildID?,
        channelID: ChannelID,
        sessionID: String,
        nonce: String
    ) {
        application_id = command.applicationID.description
        guild_id = guildID?.description
        channel_id = channelID.description
        session_id = sessionID
        self.nonce = nonce
        analytics_location = command.kind == .user
            ? "user_context_menu"
            : "message_context_menu"
        data = Payload(command: command, targetID: targetID)
    }

    struct Payload: Encodable {
        var version: String
        var id: String
        var name: String
        var type: Int
        var target_id: String
        var options: [String] = []
        var application_command: CommandInvocation.CommandPayload
        var attachments: [String] = []

        init(command: ApplicationCommand, targetID: String) {
            version = command.version
            id = command.id
            name = command.name
            type = command.kind.rawValue
            target_id = targetID
            application_command = CommandInvocation.CommandPayload(command)
        }
    }
}

extension DiscordREST {

    /// Runs a context command on a message or on a person.
    ///
    /// **204 means nothing here**, exactly as it does for a chat-input
    /// command: the route accepts the interaction and the *socket* is the only
    /// thing that says whether the application answered. See §S.8.
    public func runContextCommand(_ invocation: ContextCommandInvocation) async throws {
        _ = try await requestData(
            method: "POST",
            path: "/interactions",
            route: "interactions",
            body: invocation
        )
    }
}

// MARK: - What was run

extension DiscordREST {
    /// The command a message answers, with what it was given — see
    /// `InvokedCommand`. Nil for an answer that names no command.
    public func invokedCommand(channelID: ChannelID, messageID: MessageID) async throws -> InvokedCommand? {
        try await get(
            "/channels/\(channelID.rawValue)/messages/\(messageID.rawValue)/interaction-data",
            route: "channels/{id}/messages/{id}/interaction-data",
            as: InteractionDataDTO.self
        ).domain
    }
}

extension InvokedCommand {
    /// Decodes an `interaction-data` payload. Public so `--demo` can build its
    /// fixtures out of the wire's own shape, as it does the command index.
    public static func decode(_ data: Data) throws -> InvokedCommand? {
        try JSONDecoder().decode(InteractionDataDTO.self, from: data).domain
    }
}

/// `{ id, type, name, application_command, options? }`.
///
/// **The declaration travels beside the answer** because the answer alone is not
/// what gets drawn: a choice's value is `"r"` and its label is "Reversed", and
/// only `application_command` knows that. Discord reads the same two side by
/// side (`Y` in `217424`).
struct InteractionDataDTO: Decodable, Sendable {
    var name: String?
    var application_command: CommandSpec?
    var options: [Option]?

    struct CommandSpec: Decodable, Sendable {
        var name: String?
        var name_localized: String?
        var options: [OptionSpec]?
    }

    struct OptionSpec: Decodable, Sendable {
        var name: String?
        var name_localized: String?
        var options: [OptionSpec]?
        var choices: [ChoiceSpec]?
    }

    struct ChoiceSpec: Decodable, Sendable {
        var name: String?
        var name_localized: String?
        var value: Scalar?
    }

    struct Option: Decodable, Sendable {
        var type: Int?
        var name: String?
        var value: Scalar?
        var options: [Option]?
    }

    /// An option's value as text, as `toString()` writes it. **Booleans too** —
    /// the command index's `JSONValue` has no case for one, because no choice
    /// can be a boolean, and a value here very often is.
    struct Scalar: Decodable, Sendable {
        var text: String

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                text = value
            } else if let value = try? container.decode(Bool.self) {
                text = value ? "true" : "false"
            } else if let value = try? container.decode(Int.self) {
                text = String(value)
            } else if let value = try? container.decode(Double.self) {
                text = String(value)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a scalar")
            }
        }
    }

    var domain: InvokedCommand? {
        // `name` carries the subcommands — "base64 decode" — and `options` has
        // them again, so the bare name is the declaration's, or the first word.
        guard let name = application_command?.name_localized
            ?? application_command?.name
            ?? name?.split(separator: " ").first.map(String.init)
        else { return nil }
        return InvokedCommand(
            name: name,
            options: Self.options(options ?? [], specs: application_command?.options ?? [])
        )
    }

    private static func options(_ options: [Option], specs: [OptionSpec]) -> [InvokedOption] {
        options.compactMap { option in
            guard let name = option.name else { return nil }
            let spec = specs.first { $0.name == name }
            let shown = spec?.name_localized ?? spec?.name ?? name
            // SUB_COMMAND and SUB_COMMAND_GROUP.
            if option.type == 1 || option.type == 2 {
                return InvokedOption(
                    name: shown,
                    isBranch: true,
                    options: Self.options(option.options ?? [], specs: spec?.options ?? [])
                )
            }
            return InvokedOption(name: shown, value: value(of: option, spec: spec))
        }
    }

    private static func value(of option: Option, spec: OptionSpec?) -> InvokedOption.Value? {
        guard let text = option.value?.text else { return nil }
        // USER, CHANNEL, ROLE, MENTIONABLE and ATTACHMENT hold ids. An id that
        // will not parse is shown as it came, as Discord shows one it cannot
        // resolve.
        switch option.type {
        case 6: if let id = UInt64(text) { return .user(UserID(rawValue: id)) }
        case 7: if let id = UInt64(text) { return .channel(ChannelID(rawValue: id)) }
        case 8: if let id = UInt64(text) { return .role(RoleID(rawValue: id)) }
        case 9: if let id = UInt64(text) { return .mentionable(id) }
        case 11: return .attachment
        default:
            if let choice = spec?.choices?.first(where: { $0.value?.text == text }),
               let label = choice.name_localized ?? choice.name
            {
                return .text(label)
            }
        }
        return .text(text)
    }
}
