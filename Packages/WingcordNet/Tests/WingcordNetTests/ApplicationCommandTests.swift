import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The command index, and the interaction that runs one.
///
/// Every payload below is captured — `Slash commands.har`, 2026-09-03 — and
/// trimmed only of commands nothing here asserts about. The two interaction
/// bodies are the reference client's own, byte for byte: an interaction is
/// `204` with no body, so a client that sends a subtly wrong shape gets no
/// error at all and simply never hears back. These are the only oracle there is.
@Suite("Application commands")
struct ApplicationCommandTests {

    /// Six of the captured 183, chosen for what each proves:
    ///
    /// - `8ball` — an option with no `required` key at all, which the capture
    ///   nevertheless sends a value for.
    /// - `base64` — subcommands, so a leaf is not a command.
    /// - `wordle` — no options and a `global_popularity_rank` of 1.
    /// - `play` — `type: 4` with `handler: 1`, the entry point that broke a
    ///   handler-based filter.
    /// - `Make it a Quote` — `type: 3`, which must never reach the `/` list.
    /// - `emote` — carries `description_default` beside `description`.
    private let index = """
    {"applications":[
      {"id":"429305856241172480","name":"esmBot","description":"…",
       "icon":"6dd01dd087bdf4e6b9ed40debf290366","bot_id":"429305856241172480",
       "flags":"565248"},
      {"id":"1211781489931452447","name":"Wordle","description":"…",
       "icon":"6f38b1ceb2c4dc37955195938b54cb45","bot_id":"1211781489931452447",
       "flags":"28114944"},
      {"id":"949479338275913799","name":"Make it a Quote","description":"…",
       "icon":"3a521f17415177f7fc458d91b28ac400","bot_id":"949479338275913799",
       "flags":"28114944"}],
     "application_commands":[
      {"id":"991195178020896838","type":1,"application_id":"429305856241172480",
       "version":"1500984029405778108","name":"8ball",
       "description":"Asks the magic 8-ball a question",
       "options":[{"type":3,"name":"question",
                   "description":"A question you want to ask the ball"}],
       "dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],
       "global_popularity_rank":9},
      {"id":"991195178100592671","type":1,"application_id":"429305856241172480",
       "version":"1484223048012923033","name":"base64",
       "description":"Encodes/decodes a Base64 string",
       "options":[
         {"type":1,"name":"decode","description":"Decodes a Base64 string",
          "options":[{"type":3,"name":"text","description":"The text to decode","required":true}]},
         {"type":1,"name":"encode","description":"Encodes a Base64 string",
          "options":[{"type":3,"name":"text","description":"The text to encode","required":true}]}],
       "dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],
       "global_popularity_rank":42},
      {"id":"991195178101762361","type":1,"application_id":"429305856241172480",
       "version":"1484223048014566534","name":"emote",
       "description":"Gets a raw emoji image","description_default":"Gets a raw emote image",
       "options":[{"type":3,"name":"emoji","description":"The emoji you want to get","required":true}],
       "dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],
       "global_popularity_rank":18},
      {"id":"1331353749247234139","type":1,"application_id":"1211781489931452447",
       "version":"1354514123479711747","name":"wordle",
       "description":"Play the official Wordle from New York Times Games",
       "dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],
       "global_popularity_rank":1},
      {"id":"1310778771156913000","type":4,"application_id":"1211781489931452447",
       "version":"1331353749247589708","name":"play","description":"Play today's Wordle",
       "dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],"handler":1},
      {"id":"951070658839625567","type":3,"application_id":"949479338275913799",
       "version":"1274761331969771065","name":"Make it a Quote",
       "dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1]}],
     "version":"1544744582213013756"}
    """

    private func decoded() throws -> CommandIndex {
        try JSONDecoder().decode(CommandIndexDTO.self, from: Data(index.utf8)).domain
    }

    // MARK: The index

    @Test("Applications and commands both decode")
    func decodesIndex() throws {
        let index = try decoded()
        #expect(index.applications.count == 3)
        #expect(index.commands.count == 6)
        #expect(index.version == "1544744582213013756")
        #expect(index.applications.first { $0.name == "esmBot" }?.iconHash
            == "6dd01dd087bdf4e6b9ed40debf290366")
    }

    /// A command with subcommands has no parameters of its own, and a picker
    /// that offers it offers something that cannot be run.
    @Test("Subcommands flatten into leaves")
    func flattensSubcommands() throws {
        let leaves = try decoded().slashCommands
        // Four chat-input commands, but `base64` contributes two leaves.
        #expect(leaves.count == 5)

        let names = Set(leaves.map(\.name))
        #expect(names.contains("base64 decode"))
        #expect(names.contains("base64 encode"))
        #expect(!names.contains("base64"))

        let decode = try #require(leaves.first { $0.name == "base64 decode" })
        #expect(decode.path == ["decode"])
        #expect(decode.parameters.map(\.name) == ["text"])
        #expect(decode.parameters[0].isRequired)
        // The *leaf's* description, not the parent's — drawing "Encodes/decodes"
        // on both rows makes them indistinguishable.
        #expect(decode.summary == "Decodes a Base64 string")
    }

    /// A leaf id must be unique, or the picker's selection lands on whichever
    /// row `ForEach` happened to keep.
    @Test("Leaf ids are unique across a command's subcommands")
    func leafIDsAreUnique() throws {
        let leaves = try decoded().slashCommands
        #expect(Set(leaves.map(\.id)).count == leaves.count)
    }

    /// `type: 2` and `type: 3` are the context menus on a person and on a
    /// message. They are a different surface, and a `/` list carrying them
    /// offers a gesture that does not exist here.
    @Test("Only chat-input commands reach the slash list")
    func excludesContextMenus() throws {
        let leaves = try decoded().slashCommands
        #expect(!leaves.contains { $0.name == "Make it a Quote" })
        #expect(!leaves.contains { $0.name == "play" })
        #expect(leaves.allSatisfy { $0.command.kind == .chatInput })
    }

    /// The entry point Wordle launches from is `handler: 1`, and gating on `2`
    /// reported "Wordle has nothing to launch."
    @Test("An entry point is found by type alone, not by handler")
    func entryPointIgnoresHandler() throws {
        let index = try decoded()
        let entry = try #require(index.entryPoint(for: ApplicationID(rawValue: 1_211_781_489_931_452_447)))
        #expect(entry.name == "play")
        #expect(entry.id == "1310778771156913000")
    }

    /// Absent means false. Two thirds of the captured options omit `required`
    /// entirely, and reading absence as "unknown" would make every one of them
    /// block a Send.
    @Test("An absent required flag is false, and the option is still sendable")
    func absentRequiredIsFalse() throws {
        let ball = try #require(try decoded().slashCommands.first { $0.name == "8ball" })
        #expect(ball.parameters.count == 1)
        #expect(!ball.parameters[0].isRequired)
        #expect(PendingCommand(command: ball).isComplete)
    }

    // MARK: The interaction

    /// The captured `/8ball` body, verbatim.
    ///
    /// Compared as a decoded object rather than as a string: `JSONEncoder` has
    /// no stable key order, and asserting on bytes would be asserting on a
    /// property Foundation does not promise.
    @Test("A command with an option encodes exactly as the capture")
    func encodesCapturedInvocation() throws {
        let ball = try #require(try decoded().slashCommands.first { $0.name == "8ball" })
        var pending = PendingCommand(command: ball)
        pending.commit(.string("am i good enough"), for: ball.parameters[0])

        let sent = try object(
            CommandInvocation(
                command: ball,
                arguments: pending.arguments,
                guildID: nil,
                channelID: ChannelID(rawValue: 1_424_759_145_021_837_325),
                sessionID: "8205651d4d5729d2361d20300f8ba9fb",
                nonce: "1544985658253115392"
            )
        )
        #expect(NSDictionary(dictionary: sent).isEqual(to: try object(Self.capturedEightBall)))
    }

    /// The captured `/wordle` body — no options at all, and `options: []`
    /// present rather than omitted.
    @Test("A command with no options encodes exactly as the capture")
    func encodesCapturedInvocationWithoutOptions() throws {
        let wordle = try #require(try decoded().slashCommands.first { $0.name == "wordle" })
        let sent = try object(
            CommandInvocation(
                command: wordle,
                arguments: [],
                guildID: nil,
                channelID: ChannelID(rawValue: 1_424_759_145_021_837_325),
                sessionID: "8205651d4d5729d2361d20300f8ba9fb",
                nonce: "1544985781452406784"
            )
        )
        #expect(NSDictionary(dictionary: sent).isEqual(to: try object(Self.capturedWordle)))
    }

    /// A guild channel names its guild; a direct message does not carry the key
    /// at all. Both captures are from a direct message, so the presence of the
    /// key is what is asserted here rather than a captured value.
    @Test("guild_id is omitted in a DM and present in a guild")
    func guildIDIsConditional() throws {
        let wordle = try #require(try decoded().slashCommands.first { $0.name == "wordle" })
        func encoded(guild: GuildID?) throws -> [String: Any] {
            try object(
                CommandInvocation(
                    command: wordle, arguments: [], guildID: guild,
                    channelID: ChannelID(rawValue: 1), sessionID: "s", nonce: "n"
                )
            )
        }
        #expect(try encoded(guild: nil)["guild_id"] == nil)
        #expect(try encoded(guild: GuildID(rawValue: 42))["guild_id"] as? String == "42")
    }

    /// The subcommand path is the first level of `options`, not a flattened
    /// list — the application dispatches on that nesting, and a flat body
    /// reaches no handler at all.
    @Test("A subcommand nests its arguments one level down")
    func nestsSubcommandArguments() throws {
        let decode = try #require(try decoded().slashCommands.first { $0.name == "base64 decode" })
        var pending = PendingCommand(command: decode)
        pending.commit(.string("aGk="), for: decode.parameters[0])

        let body = try object(
            CommandInvocation(
                command: decode, arguments: pending.arguments, guildID: nil,
                channelID: ChannelID(rawValue: 1), sessionID: "s", nonce: "n"
            )
        )
        let data = try #require(body["data"] as? [String: Any])
        // The name one level up is still the *command's*, not the leaf's.
        #expect(data["name"] as? String == "base64")

        let options = try #require(data["options"] as? [[String: Any]])
        #expect(options.count == 1)
        #expect(options[0]["type"] as? Int == 1)
        #expect(options[0]["name"] as? String == "decode")
        #expect(options[0]["value"] == nil)

        let inner = try #require(options[0]["options"] as? [[String: Any]])
        #expect(inner[0]["name"] as? String == "text")
        #expect(inner[0]["value"] as? String == "aGk=")
    }

    /// An `integer` option's value must not be stringified: `"3"` where the
    /// application declared an integer is a type error at the far end.
    @Test("A value keeps the JSON type its option declared")
    func valuesKeepTheirType() throws {
        let ball = try #require(try decoded().slashCommands.first { $0.name == "8ball" })
        func value(_ value: CommandValue, kind: CommandOptionKind) throws -> Any? {
            let body = try object(
                CommandInvocation(
                    command: ball,
                    arguments: [CommandArgument(name: "x", kind: kind, value: value)],
                    guildID: nil, channelID: ChannelID(rawValue: 1), sessionID: "s", nonce: "n"
                )
            )
            let data = try #require(body["data"] as? [String: Any])
            return (data["options"] as? [[String: Any]])?.first?["value"]
        }
        #expect(try value(.integer(3), kind: .integer) as? Int == 3)
        #expect(try value(.boolean(true), kind: .boolean) as? Bool == true)
        #expect(try value(.number(1.5), kind: .number) as? Double == 1.5)
        // A snowflake goes out as a string, like every other id on this wire.
        #expect(try value(.reference(id: "42", label: "alex"), kind: .user) as? String == "42")
    }

    /// `name_localized` and `description_localized` are **not in the index**.
    /// The reference client synthesises them by repeating `name` and
    /// `description`, on the command and on every option — see both captures.
    @Test("Localized names are synthesised from the plain ones")
    func synthesisesLocalizedNames() throws {
        let ball = try #require(try decoded().slashCommands.first { $0.name == "8ball" })
        let body = try object(
            CommandInvocation(
                command: ball, arguments: [], guildID: nil,
                channelID: ChannelID(rawValue: 1), sessionID: "s", nonce: "n"
            )
        )
        let data = try #require(body["data"] as? [String: Any])
        let echo = try #require(data["application_command"] as? [String: Any])
        #expect(echo["name_localized"] as? String == "8ball")
        #expect(echo["description_localized"] as? String == "Asks the magic 8-ball a question")

        let options = try #require(echo["options"] as? [[String: Any]])
        #expect(options[0]["name_localized"] as? String == "question")
        // …and `required` is written only where the index wrote it.
        #expect(options[0]["required"] == nil)
    }

    // MARK: Filling one in

    /// Tab walks the required options first, in declaration order.
    @Test("Focus moves to the next option that still needs one")
    func focusWalksRequiredFirst() {
        let command = SlashCommand(
            command: ApplicationCommand(
                id: "1", kind: .chatInput, applicationID: ApplicationID(rawValue: 1),
                version: "1", name: "t"
            ),
            parameters: [
                CommandOption(kind: .string, name: "optional"),
                CommandOption(kind: .string, name: "required", isRequired: true),
                CommandOption(kind: .string, name: "second-optional"),
            ]
        )
        var pending = PendingCommand(command: command)
        #expect(pending.focused == "optional")
        #expect(!pending.isComplete)

        pending.commit(.string("a"), for: command.parameters[0])
        #expect(pending.focused == "required")
        #expect(!pending.isComplete)

        pending.commit(.string("b"), for: command.parameters[1])
        #expect(pending.focused == "second-optional")
        #expect(pending.isComplete)
    }

    /// Filling the same option twice replaces it. Appending would send it twice
    /// and is what makes an editable chip corrupt the body.
    @Test("Refilling an option replaces rather than appends")
    func refillReplaces() {
        let option = CommandOption(kind: .string, name: "q")
        let command = SlashCommand(
            command: ApplicationCommand(
                id: "1", kind: .chatInput, applicationID: ApplicationID(rawValue: 1),
                version: "1", name: "t"
            ),
            parameters: [option]
        )
        var pending = PendingCommand(command: command)
        pending.commit(.string("one"), for: option)
        pending.commit(.string("two"), for: option)
        #expect(pending.arguments.count == 1)
        #expect(pending.arguments[0].value == .string("two"))

        pending.clear("q")
        #expect(pending.arguments.isEmpty)
        #expect(pending.focused == "q")
    }

    /// Not one of the captured index's 83 attachment options is required, so
    /// dropping them costs no command its usability — but the guard is what
    /// keeps that a measured fact rather than a lucky one.
    @Test("An attachment option is not offered, and blocks Send only if required")
    func attachmentOptionsAreNotOffered() {
        func command(required: Bool) -> SlashCommand {
            SlashCommand(
                command: ApplicationCommand(
                    id: "1", kind: .chatInput, applicationID: ApplicationID(rawValue: 1),
                    version: "1", name: "t"
                ),
                parameters: [
                    CommandOption(kind: .string, name: "text"),
                    CommandOption(kind: .attachment, name: "file", isRequired: required),
                ]
            )
        }
        #expect(command(required: false).offeredParameters.map(\.name) == ["text"])
        #expect(!command(required: false).needsUnsupportedOption)
        #expect(PendingCommand(command: command(required: false)).isComplete)

        #expect(command(required: true).needsUnsupportedOption)
        #expect(!PendingCommand(command: command(required: true)).isComplete)
    }

    // MARK: Helpers

    private func object(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// `POST /interactions` for `/8ball question: am i good enough`, verbatim.
    private static let capturedEightBall = """
    {"type":2,"application_id":"429305856241172480","channel_id":"1424759145021837325",\
    "session_id":"8205651d4d5729d2361d20300f8ba9fb","data":{"version":"1500984029405778108",\
    "id":"991195178020896838","name":"8ball","type":1,"options":[{"type":3,"name":"question",\
    "value":"am i good enough"}],"application_command":{"id":"991195178020896838","type":1,\
    "application_id":"429305856241172480","version":"1500984029405778108","name":"8ball",\
    "description":"Asks the magic 8-ball a question","options":[{"type":3,"name":"question",\
    "description":"A question you want to ask the ball",\
    "description_localized":"A question you want to ask the ball","name_localized":"question"}],\
    "dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],"global_popularity_rank":9,\
    "description_localized":"Asks the magic 8-ball a question","name_localized":"8ball"},\
    "attachments":[]},"nonce":"1544985658253115392","analytics_location":"slash_ui"}
    """

    /// `POST /interactions` for `/wordle`, verbatim.
    private static let capturedWordle = """
    {"type":2,"application_id":"1211781489931452447","channel_id":"1424759145021837325",\
    "session_id":"8205651d4d5729d2361d20300f8ba9fb","data":{"version":"1354514123479711747",\
    "id":"1331353749247234139","name":"wordle","type":1,"options":[],\
    "application_command":{"id":"1331353749247234139","type":1,\
    "application_id":"1211781489931452447","version":"1354514123479711747","name":"wordle",\
    "description":"Play the official Wordle from New York Times Games","dm_permission":true,\
    "contexts":[0,1,2],"integration_types":[0,1],"global_popularity_rank":1,"options":[],\
    "description_localized":"Play the official Wordle from New York Times Games",\
    "name_localized":"wordle"},"attachments":[]},"nonce":"1544985781452406784",\
    "analytics_location":"slash_ui"}
    """
}

// MARK: - Pressing a button

/// `POST /interactions` with `type: 3`.
///
/// Captured five times in `slash help.har` (2026-09-03) — the Prev/Next pager on
/// Make it a Quote's `/help`, pressed through five pages — and every body is
/// byte-identical apart from its nonce. An interaction answers `204` with no
/// body, so this is the only oracle there is.
@Suite("Message components")
struct MessageComponentInteractionTests {

    /// The capture, verbatim. Note what is **not** in it: no echo of the message
    /// or the component the way a slash command echoes its whole
    /// `application_command`, and no `analytics_location`.
    private static let captured = """
    {"type":3,"nonce":"1545051958417555456","guild_id":null,\
    "channel_id":"1424759145021837325","message_flags":32832,\
    "message_id":"1545051922780243178","application_id":"949479338275913799",\
    "session_id":"02c2aa24cecc74764fe1aa84fd6b07f2",\
    "data":{"component_type":2,"custom_id":"help_page__next,987654321987654321"}}
    """

    /// The message the pager sat on: ephemeral, Components V2, from the bot.
    private func message(flags: MessageFlags = [.ephemeral, .isComponentsV2]) -> Message {
        Message(
            id: MessageID(rawValue: 1_545_051_922_780_243_178),
            channelID: ChannelID(rawValue: 1_424_759_145_021_837_325),
            authorID: UserID(rawValue: 949_479_338_275_913_799),
            flags: flags
        )
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        )
    }

    @Test("A button press encodes exactly as the capture")
    func encodesCapturedPress() throws {
        let sent = try object(
            ComponentInteraction(
                customID: "help_page__next,987654321987654321",
                componentType: ComponentInteraction.buttonComponentType,
                message: message(),
                applicationID: ApplicationID(rawValue: 949_479_338_275_913_799),
                guildID: nil,
                sessionID: "02c2aa24cecc74764fe1aa84fd6b07f2",
                nonce: "1545051958417555456"
            )
        )
        let captured = try #require(
            try JSONSerialization.jsonObject(
                with: Data(Self.captured.utf8)
            ) as? [String: Any]
        )
        #expect(NSDictionary(dictionary: sent).isEqual(to: captured))
    }

    /// **`guild_id` is sent as an explicit `null`**, where a command invocation
    /// omits the key entirely. Two code paths in Discord's own client, and this
    /// reproduces both rather than unifying them.
    @Test("guild_id is null rather than absent outside a guild")
    func sendsNullGuildID() throws {
        let sent = try object(
            ComponentInteraction(
                customID: "x", componentType: 2, message: message(),
                applicationID: ApplicationID(rawValue: 1), guildID: nil,
                sessionID: "s", nonce: "n"
            )
        )
        #expect(sent.keys.contains("guild_id"))
        #expect(sent["guild_id"] is NSNull)

        let inGuild = try object(
            ComponentInteraction(
                customID: "x", componentType: 2, message: message(),
                applicationID: ApplicationID(rawValue: 1), guildID: GuildID(rawValue: 42),
                sessionID: "s", nonce: "n"
            )
        )
        #expect(inGuild["guild_id"] as? String == "42")
    }

    /// `32832` is `EPHEMERAL` (1 << 6) plus `IS_COMPONENTS_V2` (1 << 15), echoed
    /// back from the message being acted on.
    @Test("message_flags is the message's own flag set")
    func echoesMessageFlags() throws {
        let sent = try object(
            ComponentInteraction(
                customID: "x", componentType: 2, message: message(),
                applicationID: ApplicationID(rawValue: 1), guildID: nil,
                sessionID: "s", nonce: "n"
            )
        )
        #expect(sent["message_flags"] as? Int == 32832)

        let plain = try object(
            ComponentInteraction(
                customID: "x", componentType: 2, message: message(flags: []),
                applicationID: ApplicationID(rawValue: 1), guildID: nil,
                sessionID: "s", nonce: "n"
            )
        )
        #expect(plain["message_flags"] as? Int == 0)
    }

    // MARK: What is pressable

    private func button(_ json: String) throws -> MessageComponent {
        let dto = try JSONDecoder().decode([ComponentDTO].self, from: Data(json.utf8))
        return try #require(ComponentDTO.rows(dto).first?.components.first)
    }

    @Test("A button with a custom_id is live; one without is not")
    func customIDMakesButtonLive() throws {
        let live = try button("""
        [{"type":1,"components":[{"type":2,"style":2,"label":"Next","custom_id":"n"}]}]
        """)
        #expect(live.customID == "n")
        #expect(live.isActionable)
        #expect(live.destination == nil)

        // Discord requires a custom_id on every non-link button, so this is a
        // malformed bot. Drawn dimmed rather than dropped.
        let malformed = try button("""
        [{"type":1,"components":[{"type":2,"style":2,"label":"Next"}]}]
        """)
        #expect(malformed.kind == .inert)
        #expect(!malformed.isActionable)
    }

    /// Discord marked the control unavailable and this client does not get to
    /// disagree — the same rule a disabled link button already took.
    @Test("A disabled button is not pressable even with a custom_id")
    func disabledIsNotPressable() throws {
        let disabled = try button("""
        [{"type":1,"components":[
          {"type":2,"style":2,"label":"Prev","custom_id":"p","disabled":true}]}]
        """)
        #expect(disabled.customID == nil)
        #expect(!disabled.isActionable)
    }

    /// A select with nothing to choose, or one of the pickers, has nothing
    /// this client can answer. `INVARIANTS.md` §5.5.
    @Test("A select with no options, or a picker, is not pressable")
    func emptyMenusStayInert() throws {
        let menu = try button("""
        [{"type":1,"components":[
          {"type":3,"custom_id":"m","placeholder":"Choose a role"}]}]
        """)
        #expect(menu.isSelectMenu)
        #expect(!menu.isActionable)
        #expect(menu.customID == nil)
        let picker = try button("""
        [{"type":1,"components":[{"type":6,"custom_id":"r","placeholder":"Roles"}]}]
        """)
        #expect(picker.select == nil)
        #expect(picker.label == "Roles")
    }

    /// Sapphire's rules menu: a string select with options, one of them
    /// already chosen — which is what its closed face says.
    @Test("A string select with options is live, and shows what is chosen")
    func stringSelect() throws {
        let menu = try button("""
        [{"type":1,"components":[{"type":3,"custom_id":"rules","placeholder":"Additional Information & Rules",
          "min_values":1,"max_values":1,"options":[
            {"label":"Moderation System","value":"mod","emoji":{"name":"🛡️"}},
            {"label":"Light Offenses","value":"light","description":"1-5 damage"},
            {"label":"VC Rules","value":"vc","default":true}]}]}]
        """)
        let select = try #require(menu.select)
        #expect(select.options.map(\.value) == ["mod", "light", "vc"])
        #expect(select.options[1].description == "1-5 damage")
        #expect(select.isSingle)
        #expect(menu.label == "VC Rules")
        #expect(menu.isActionable)
    }

    /// **What a pick sends is Discord's own**: the select's state spread into
    /// `data` beside the button's two keys — and a button still sends exactly
    /// the captured two.
    @Test("A pick sends its type and values; a press sends neither")
    func selectInteractionBody() throws {
        let message = Message(
            id: MessageID(rawValue: 1),
            channelID: ChannelID(rawValue: 2),
            authorID: UserID(rawValue: 3),
            content: ""
        )
        func data(_ values: [String]?) throws -> [String: Any] {
            let interaction = ComponentInteraction(
                customID: "rules", componentType: values == nil ? 2 : 3, values: values,
                message: message, applicationID: ApplicationID(rawValue: 4),
                guildID: nil, sessionID: "s", nonce: "n"
            )
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(interaction))
            return try #require((object as? [String: Any])?["data"] as? [String: Any])
        }
        let pick = try data(["light"])
        #expect(pick["component_type"] as? Int == 3)
        #expect(pick["type"] as? Int == 3)
        #expect(pick["values"] as? [String] == ["light"])
        let press = try data(nil)
        #expect(Set(press.keys) == ["component_type", "custom_id"])
    }

    /// **The pager lives inside a container, not at the top level.** A search
    /// that only walked action rows would find no button on the one message
    /// shape this feature exists for.
    @Test("A pressed button is found inside a Components V2 tree")
    func findsButtonsNestedInContainers() {
        let button = MessageComponent(
            id: "next", label: "Next", kind: .action(customID: "help_page__next")
        )
        let message = Message(
            id: MessageID(rawValue: 1),
            channelID: ChannelID(rawValue: 1),
            authorID: UserID(rawValue: 1),
            payload: MessagePayload(displayComponents: [
                .container(accent: nil, children: [
                    .text("Page 1 / 6"),
                    .row(ActionRow(components: [button])),
                ]),
            ])
        )
        #expect(message.pressableComponent(customID: "help_page__next") == button)
        #expect(message.pressableComponent(customID: "nothing") == nil)
    }

    /// `application_id` where Discord sent it, the author otherwise — and the
    /// capture's two values agree, which is what makes the fallback safe.
    @Test("The application is named from the message, falling back to its author")
    func namesTheApplication() {
        let bot = UserID(rawValue: 949_479_338_275_913_799)
        let fromAuthor = Message(
            id: MessageID(rawValue: 1), channelID: ChannelID(rawValue: 1), authorID: bot
        )
        #expect(fromAuthor.componentApplicationID.rawValue == bot.rawValue)

        let explicit = Message(
            id: MessageID(rawValue: 1), channelID: ChannelID(rawValue: 1), authorID: bot,
            payload: MessagePayload(applicationID: ApplicationID(rawValue: 12))
        )
        #expect(explicit.componentApplicationID == ApplicationID(rawValue: 12))
    }
}

// MARK: - An application's own page

/// "Use this app" — the command list on an app's page in the flyout.
///
/// Captured in `OwO app commands full.har` and `dank memer.har` (2026-09-03):
/// the app-scoped index, 7,700 bytes for OwO and 33 KB for Dank Memer, plus the
/// interactions both pages posted.
@Suite("Application pages")
struct ApplicationPageTests {

    /// Dank Memer's own index, trimmed. Its four rows are the four the
    /// screenshot shows, and between them they settle the Send/chevron rule.
    private let index = #"""
    {"applications":[{"id":"270904126974590976","name":"Dank Memer","icon":"a38cf47e5d952bc82bedb9c328725278","bot_id":"270904126974590976","flags":"27705344"}],
     "application_commands":[
      {"id":"1","type":1,"application_id":"270904126974590976","version":"1","name":"dig","description":"Dig in the dirt for bugs and other fun items.","dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],"global_popularity_rank":1},
      {"id":"2","type":1,"application_id":"270904126974590976","version":"1","name":"hunt","description":"Grab a rifle from the shop and go hunting for fun items!","dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],"global_popularity_rank":2},
      {"id":"3","type":1,"application_id":"270904126974590976","version":"1","name":"work","description":"Get a job.","options":[
        {"type":1,"name":"apply","description":"Apply for a job.","options":[{"type":3,"name":"job","description":"The job you want to apply for.","required":true,"autocomplete":true}]},
        {"type":1,"name":"list","description":"List of available jobs."}],
       "dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],"global_popularity_rank":3},
      {"id":"4","type":4,"application_id":"270904126974590976","version":"1488890513720606841","name":"GRIND XP","description":"Grind Dank Memer XP","dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1],"handler":2}],
     "version":"1"}
    """#

    private func decoded() throws -> CommandIndex {
        try CommandIndex.decode(Data(index.utf8))
    }

    /// **The trailing control is decided by whether the leaf takes anything**,
    /// and nothing else — not the type, not the depth, not the popularity. Both
    /// captures agree on every row.
    @Test("A leaf with no options sends; one with options does not")
    func sendVersusChevron() throws {
        let byName = Dictionary(
            try decoded().slashCommands.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Screenshot: dig → Send, hunt → Send, work list → Send.
        #expect(try #require(byName["dig"]).offeredParameters.isEmpty)
        #expect(try #require(byName["hunt"]).offeredParameters.isEmpty)
        #expect(try #require(byName["work list"]).offeredParameters.isEmpty)
        // Screenshot: work apply → chevron.
        #expect(try #require(byName["work apply"]).offeredParameters.map(\.name) == ["job"])
    }

    /// **"GRIND XP" is the entry point's own `name`.** Discord draws the
    /// command's name as the button's words — the interaction it posts carries
    /// `"name": "GRIND XP"` at both levels — and there is no separate label
    /// field anywhere in the payload.
    @Test("The launch button's words are the entry point's name")
    func entryPointNamesTheButton() throws {
        let entry = try #require(try decoded().entryPoint)
        #expect(entry.name == "GRIND XP")
        #expect(entry.version == "1488890513720606841")
        // …and it is not a chat-input command, so it never reaches the list.
        #expect(!(try decoded().slashCommands.contains { $0.name == "GRIND XP" }))
    }

    /// **The label raises the first character and nothing else.** A command name
    /// is lowercase on the wire — Watch Together's entry point is literally
    /// `launch` — and `.capitalized` would do it by word, turning `GRIND XP`
    /// into `Grind Xp`.
    @Test("The launch label capitalises one character")
    func launchLabelRaisesOnlyTheFirstCharacter() {
        func label(_ name: String) -> String {
            name.isEmpty ? "Launch" : name.prefix(1).uppercased() + name.dropFirst()
        }
        #expect(label("launch") == "Launch")
        #expect(label("GRIND XP") == "GRIND XP")
        #expect(label("play") == "Play")
        #expect(label("") == "Launch")
    }

    /// **"Launch in DM" is gated on `contexts` carrying `1` (`BOT_DM`).** Dank
    /// Memer's entry point lists `[0, 1, 2]` and its page draws the button; an
    /// app that lists servers only has nowhere to put it.
    @Test("A DM launch is offered only where the app says it runs in one")
    func directMessageContextGatesTheSecondButton() throws {
        #expect(try #require(try decoded().entryPoint).contexts.contains(1))

        let guildOnly = try CommandIndex.decode(Data(#"""
        {"application_commands":[{"id":"4","type":4,"application_id":"1","version":"1",
          "name":"Play","dm_permission":false,"contexts":[0],"integration_types":[0],"handler":2}]}
        """#.utf8))
        #expect(!(try #require(guildOnly.entryPoint).contexts.contains(1)))
    }

    /// **The same command carries a different `analytics_location` depending on
    /// where it was run from**, and both are captured: `slash_ui` from the
    /// composer, `app_launcher` plus a `source` from an app's page.
    @Test("The invocation names where it came from")
    func originChangesTheAnalyticsFields() throws {
        let leaf = try #require(try decoded().slashCommands.first { $0.name == "dig" })
        func body(_ origin: CommandInvocation.Origin) throws -> [String: Any] {
            let data = try JSONEncoder().encode(
                CommandInvocation(
                    command: leaf, arguments: [], guildID: nil,
                    channelID: ChannelID(rawValue: 1), sessionID: "s", nonce: "n", origin: origin
                )
            )
            return try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
        }
        let composer = try body(.slashUI)
        #expect(composer["analytics_location"] as? String == "slash_ui")
        #expect(composer["source"] == nil)

        let page = try body(.applicationPage)
        #expect(page["analytics_location"] as? String == "app_launcher")
        #expect(page["source"] as? String == "TEXT")
    }

    /// The `gen eject` body from `OwO app commands full.har`: a subcommand leaf
    /// carrying a `USER` option, sent from an app's page. It is the one capture
    /// that exercises the nesting and a snowflake value together.
    @Test("A subcommand with a user option encodes as the capture sent it")
    func encodesCapturedPageInvocation() throws {
        let owo = try CommandIndex.decode(Data(#"""
        {"application_commands":[{"id":"1302736538901508599","type":1,
          "application_id":"408785106945610143","version":"1302736538899835921","name":"gen",
          "description":"Generate some images","options":[
            {"type":1,"name":"eject","description":"Eject the user into space",
             "options":[{"type":6,"name":"user","description":"The user to use","required":true}]}],
          "dm_permission":true,"contexts":[0,1,2],"integration_types":[0,1]}]}
        """#.utf8))
        let eject = try #require(owo.slashCommands.first { $0.name == "gen eject" })
        var pending = PendingCommand(command: eject)
        pending.commit(
            .reference(id: "1328958085359467218", label: "alex"),
            for: eject.parameters[0]
        )

        let data = try JSONEncoder().encode(
            CommandInvocation(
                command: eject, arguments: pending.arguments, guildID: nil,
                channelID: ChannelID(rawValue: 1_424_759_145_021_837_325),
                sessionID: "a85da82f4c7267ca4316bbafe1c081bb",
                nonce: "1545114623106088960", origin: .applicationPage
            )
        )
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(body["data"] as? [String: Any])
        #expect(payload["name"] as? String == "gen")

        let options = try #require(payload["options"] as? [[String: Any]])
        #expect(options.count == 1)
        #expect(options[0]["type"] as? Int == 1)
        #expect(options[0]["name"] as? String == "eject")

        let inner = try #require(options[0]["options"] as? [[String: Any]])
        #expect(inner[0]["type"] as? Int == 6)
        #expect(inner[0]["name"] as? String == "user")
        // A snowflake goes out as a string, and the label never leaves the app.
        #expect(inner[0]["value"] as? String == "1328958085359467218")
    }
}
