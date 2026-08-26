import Foundation
import WingcordCore

/// One decoded gateway frame.
///
/// **The whole envelope decodes in a single pass**, and that matters more than
/// it looks: READY is the largest JSON this app ever parses, and a shape that
/// reads the event name, then re-serialises `d` to decode it into the right
/// type, parses the payload twice. Reading `t` and `d` out of the *same* keyed
/// container — which `JSONDecoder` permits in any order — costs one parse.
///
/// An unrecognised event decodes as `.unhandled` **without touching `d`**, so
/// the dozens of events this client does not care about cost a string compare
/// rather than an object graph.
struct GatewayFrame: Decodable, Sendable {
    var opcode: Int
    var sequence: Int?
    var payload: Payload

    enum Payload: Sendable {
        case hello(Hello)
        case heartbeatAck
        case reconnect
        case invalidSession(resumable: Bool)
        case ready(ReadyPayload)
        case resumed
        case messageCreate(MessageDTO)
        case messageUpdate(MessageDTO)
        case messageDelete(MessageDeletePayload)
        case messageReactionAdd(ReactionEventPayload)
        case messageReactionRemove(ReactionEventPayload)
        case guildCreate(GuildDTO)
        case guildDelete(GuildDeletePayload)
        case guildUpdate(GuildDTO)
        case channelCreate(ChannelDTO)
        case channelUpdate(ChannelDTO)
        case channelDelete(ChannelDTO)
        case presenceUpdate(PresenceDTO)
        case typingStart(TypingPayload)
        case guildMembersChunk(MembersChunkPayload)
        case guildMemberListUpdate(MemberListUpdatePayload)
        case messageAck(MessageAckPayload)
        case userUpdate(UserDTO)
        /// Anything this client does not act on. `d` is never decoded.
        case unhandled(name: String?)
    }

    struct Hello: Decodable, Sendable {
        var heartbeat_interval: Double
    }

    private enum CodingKeys: String, CodingKey {
        case op, s, t, d
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        opcode = try container.decode(Int.self, forKey: .op)
        sequence = try container.decodeIfPresent(Int.self, forKey: .s)
        let name = try container.decodeIfPresent(String.self, forKey: .t)

        switch opcode {
        case 10:
            payload = .hello(try container.decode(Hello.self, forKey: .d))
            return
        case 11:
            payload = .heartbeatAck
            return
        case 7:
            payload = .reconnect
            return
        case 9:
            // `d` is a bare boolean: whether the session may be resumed.
            payload = .invalidSession(
                resumable: (try? container.decode(Bool.self, forKey: .d)) ?? false
            )
            return
        case 0:
            break
        default:
            payload = .unhandled(name: name)
            return
        }

        // A dispatch. Decode `d` only for the events this client acts on.
        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try container.decode(T.self, forKey: .d)
        }

        switch name {
        case "READY": payload = .ready(try decode(ReadyPayload.self))
        case "RESUMED": payload = .resumed
        case "MESSAGE_CREATE": payload = .messageCreate(try decode(MessageDTO.self))
        case "MESSAGE_UPDATE": payload = .messageUpdate(try decode(MessageDTO.self))
        case "MESSAGE_DELETE": payload = .messageDelete(try decode(MessageDeletePayload.self))
        case "MESSAGE_REACTION_ADD":
            payload = .messageReactionAdd(try decode(ReactionEventPayload.self))
        case "MESSAGE_REACTION_REMOVE":
            payload = .messageReactionRemove(try decode(ReactionEventPayload.self))
        case "GUILD_CREATE": payload = .guildCreate(try decode(GuildDTO.self))
        case "GUILD_UPDATE": payload = .guildUpdate(try decode(GuildDTO.self))
        case "GUILD_DELETE": payload = .guildDelete(try decode(GuildDeletePayload.self))
        case "CHANNEL_CREATE": payload = .channelCreate(try decode(ChannelDTO.self))
        case "CHANNEL_UPDATE": payload = .channelUpdate(try decode(ChannelDTO.self))
        case "CHANNEL_DELETE": payload = .channelDelete(try decode(ChannelDTO.self))
        case "PRESENCE_UPDATE": payload = .presenceUpdate(try decode(PresenceDTO.self))
        case "TYPING_START": payload = .typingStart(try decode(TypingPayload.self))
        case "GUILD_MEMBERS_CHUNK":
            payload = .guildMembersChunk(try decode(MembersChunkPayload.self))
        case "GUILD_MEMBER_LIST_UPDATE":
            payload = .guildMemberListUpdate(try decode(MemberListUpdatePayload.self))
        case "MESSAGE_ACK": payload = .messageAck(try decode(MessageAckPayload.self))
        case "USER_UPDATE": payload = .userUpdate(try decode(UserDTO.self))
        default: payload = .unhandled(name: name)
        }
    }
}

/// The bootstrap payload.
struct ReadyPayload: Decodable, Sendable {
    var v: Int?
    var user: UserDTO
    var session_id: String
    var resume_gateway_url: String?
    var guilds: [GuildDTO]?
    var private_channels: [ChannelDTO]?
    var read_state: ReadStateEnvelope?
    var user_settings: ClientSettingsDTO?
    var user_guild_settings: GuildSettingsEnvelope?
    var users: [UserDTO]?
    var relationships: [RelationshipDTO]?

    /// Discord wrapped several READY arrays in `{ entries, partial, version }`
    /// envelopes and left others bare, in the same payload. Both shapes decode.
    struct ReadStateEnvelope: Decodable, Sendable {
        var entries: [ReadStateDTO]?

        init(from decoder: any Decoder) throws {
            if let list = try? [ReadStateDTO](from: decoder) {
                entries = list
                return
            }
            let container = try decoder.container(keyedBy: Keys.self)
            entries = try container.decodeIfPresent([ReadStateDTO].self, forKey: .entries)
        }

        private enum Keys: String, CodingKey { case entries }
    }

    struct GuildSettingsEnvelope: Decodable, Sendable {
        var entries: [GuildSettingsDTO]?

        init(from decoder: any Decoder) throws {
            if let list = try? [GuildSettingsDTO](from: decoder) {
                entries = list
                return
            }
            let container = try decoder.container(keyedBy: Keys.self)
            entries = try container.decodeIfPresent([GuildSettingsDTO].self, forKey: .entries)
        }

        private enum Keys: String, CodingKey { case entries }
    }
}

struct GuildSettingsDTO: Decodable, Sendable {
    var guild_id: GuildID?
    var muted: Bool?
    var channel_overrides: [ChannelOverride]?

    struct ChannelOverride: Decodable, Sendable {
        var channel_id: ChannelID?
        var muted: Bool?
        var message_notifications: Int?
    }
}

struct RelationshipDTO: Decodable, Sendable {
    var id: UserID
    var type: Int?
    var user: UserDTO?
}

struct MessageDeletePayload: Decodable, Sendable {
    var id: MessageID
    var channel_id: ChannelID
    var guild_id: GuildID?
}

struct ReactionEventPayload: Decodable, Sendable {
    var user_id: UserID
    var channel_id: ChannelID
    var message_id: MessageID
    var guild_id: GuildID?
    var emoji: EmojiDTO
}

struct GuildDeletePayload: Decodable, Sendable {
    var id: GuildID
    /// True when the guild has gone *unavailable* rather than been left. A
    /// client that treats the two the same removes a server from the rail during
    /// an outage and puts it back when the outage ends, which reads as the
    /// account being kicked and re-invited.
    var unavailable: Bool?
}

struct TypingPayload: Decodable, Sendable {
    var channel_id: ChannelID
    var user_id: UserID
    var guild_id: GuildID?
    var timestamp: Double?
    var member: MemberDTO?
}

struct MembersChunkPayload: Decodable, Sendable {
    var guild_id: GuildID
    var members: [MemberDTO]?
    var presences: [PresenceDTO]?
    var chunk_index: Int?
    var chunk_count: Int?
}

/// The lazy member-list subscription's reply.
///
/// This is how a large guild's roster is actually populated: Discord will not
/// send members for a large guild up front, and the documented
/// `REQUEST_GUILD_MEMBERS` route answers with members but **no presences** for
/// them. The undocumented op-14 subscription answers with both, in the exact
/// ranges the client asked for.
struct MemberListUpdatePayload: Decodable, Sendable {
    var guild_id: GuildID
    var id: String?
    var member_count: Int?
    var online_count: Int?
    var ops: [Operation]?

    struct Operation: Decodable, Sendable {
        var op: String
        var range: [Int]?
        var index: Int?
        var items: [Item]?
        var item: Item?
    }

    /// A roster entry is either a group heading or a member, distinguished by
    /// which key is present.
    struct Item: Decodable, Sendable {
        var group: Group?
        var member: MemberEntry?

        struct Group: Decodable, Sendable {
            var id: String?
            var count: Int?
        }

        struct MemberEntry: Decodable, Sendable {
            var user: UserDTO?
            var nick: String?
            var avatar: String?
            var roles: [RoleID]?
            var joined_at: Date?
            var premium_since: Date?
            var presence: PresenceDTO?
        }
    }
}

struct MessageAckPayload: Decodable, Sendable {
    var channel_id: ChannelID
    var message_id: MessageID?
    var mention_count: Int?
}
