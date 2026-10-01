import Foundation
import WingcordCore

// MARK: - Pressing a button on somebody's message
//
// The same route a slash command uses, with `type: 3`. Captured five times in
// `slash help.har` (2026-09-03) — the Prev/Next pager on Make it a Quote's
// `/help`, pressed through five pages — and every body is byte-identical apart
// from its nonce.
//
// **The message is NOT echoed back.** A slash command repeats its whole
// `application_command` record inside the interaction; a component press sends
// `{component_type, custom_id}` and nothing else. 311 bytes against the slash
// command's 662. Predicting a sibling echo here and sending one would be sending
// a shape nobody else sends.

extension DiscordREST {

    /// Presses a component. Answers `204` with an empty body.
    ///
    /// What the application does with it arrives over the socket — almost always
    /// as a `MESSAGE_UPDATE` editing the message the button is attached to, which
    /// is how a pager redraws in place. `INTERACTION_SUCCESS` says it was taken.
    public func pressComponent(_ interaction: ComponentInteraction) async throws {
        _ = try await requestData(
            method: "POST",
            path: "/interactions",
            route: "interactions",
            body: interaction
        )
    }
}

/// `POST /interactions`, `type: 3`.
///
/// Three things here differ from the command invocation beside it, and all three
/// are the capture's, not a preference:
///
///  - **`guild_id` is sent as an explicit `null`** in a direct message. The
///    command invocation omits the key entirely. Two code paths in Discord's own
///    client, and this reproduces both rather than unifying them.
///  - **There is no `analytics_location`.** A command carries `slash_ui`; a
///    press carries nothing.
///  - **`message_flags` is echoed back** from the message being acted on. The
///    capture sends `32832` — `EPHEMERAL` (1 << 6) plus `IS_COMPONENTS_V2`
///    (1 << 15) — which is exactly the flag set on the message the pager was
///    attached to.
public struct ComponentInteraction: Encodable, Sendable {
    var type = 3
    var nonce: String
    /// Explicitly null outside a guild. See the type note.
    var guild_id: String?
    var channel_id: String
    var message_flags: Int
    var message_id: String
    var application_id: String
    var session_id: String
    var data: Payload

    public init(
        customID: String,
        componentType: Int,
        values: [String]? = nil,
        message: Message,
        applicationID: ApplicationID,
        guildID: GuildID?,
        sessionID: String,
        nonce: String
    ) {
        self.nonce = nonce
        guild_id = guildID?.description
        channel_id = message.channelID.description
        message_flags = Int(message.flags.rawValue)
        message_id = message.id.description
        application_id = applicationID.description
        session_id = sessionID
        data = Payload(
            component_type: componentType,
            custom_id: customID,
            type: values == nil ? nil : componentType,
            values: values
        )
    }

    struct Payload: Encodable {
        /// `2` for a button, `3` for a string select.
        var component_type: Int
        /// The application's own opaque string, echoed verbatim.
        var custom_id: String
        /// A select's own state, spread into `data` beside the two above:
        /// its type again and the values chosen. **Read out of Discord's
        /// interaction builder**, which returns a string select's state
        /// object as it is — `{type, values}` — for the spread. Absent for a
        /// button, and the encoder leaves both out then, so a press is still
        /// byte for byte the captured one.
        var type: Int?
        var values: [String]?
    }

    enum CodingKeys: String, CodingKey {
        case type, nonce, guild_id, channel_id, message_flags, message_id
        case application_id, session_id, data
    }

    /// Hand-written for one key. Swift's synthesised encoder omits a nil
    /// optional; the capture **sends `"guild_id": null`**, and matching the wire
    /// is worth six lines.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(nonce, forKey: .nonce)
        try container.encode(guild_id, forKey: .guild_id)
        try container.encode(channel_id, forKey: .channel_id)
        try container.encode(message_flags, forKey: .message_flags)
        try container.encode(message_id, forKey: .message_id)
        try container.encode(application_id, forKey: .application_id)
        try container.encode(session_id, forKey: .session_id)
        try container.encode(data, forKey: .data)
    }

    /// A button. The only component type this client presses.
    public static let buttonComponentType = 2
}
