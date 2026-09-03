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
    /// The dispatch's `t`, kept so a trace line can name what arrived.
    ///
    /// **A log of `op=0 seq=205 bytes=692` says nothing.** Four hundred of
    /// those lines cannot answer "did `STREAM_CREATE` ever arrive", which is
    /// the one question a Go Live session needs them for. The string is already
    /// decoded to pick the payload case; storing it costs a retain.
    var name: String?
    var payload: Payload

    enum Payload: Sendable {
        case hello(Hello)
        case heartbeatAck
        case reconnect
        case invalidSession(resumable: Bool)
        case ready(ReadyPayload)
        case resumed
        case messageCreate(MessageDTO)
        /// The server acknowledging an interaction this client sent.
        ///
        /// **`id` is the interaction's own snowflake, and for an activity
        /// launch that IS the instance.** `POST /interactions` answers `204`
        /// with no body, so this dispatch is the only thing that names it —
        /// and unlike the invitation message it arrives for *every* entry
        /// point, including the `handler: 1` kind that posts no message at all.
        /// `nonce` echoes what the launch sent, which is how a client tells its
        /// own interaction from anybody else's.
        case interactionSuccess(InteractionAckPayload)
        /// The application refused, or never answered inside Discord's window.
        /// The same `{id, nonce}` shape as the success — the *name* is the whole
        /// difference, which is why one payload type serves both.
        case interactionFailure(InteractionAckPayload)
        case messageUpdate(MessageDTO)
        case messageDelete(MessageDeletePayload)
        case messageReactionAdd(ReactionEventPayload)
        case messageReactionRemove(ReactionEventPayload)
        case guildCreate(GuildDTO)
        case guildDelete(GuildDeletePayload)
        case guildUpdate(GuildDTO)
        /// A server's emoji or sticker set changed. Discord dispatches these
        /// rather than a whole GUILD_UPDATE, so without them the picker's
        /// catalog is only as fresh as the last reconnect.
        case guildEmojisUpdate(GuildEmojisPayload)
        case guildStickersUpdate(GuildStickersPayload)
        case channelCreate(ChannelDTO)
        case channelUpdate(ChannelDTO)
        case channelDelete(ChannelDTO)
        case presenceUpdate(PresenceDTO)
        case typingStart(TypingPayload)
        case guildMembersChunk(MembersChunkPayload)
        case guildMemberListUpdate(MemberListUpdatePayload)
        case messageAck(MessageAckPayload)
        case userUpdate(UserDTO)
        case relationshipAdd(RelationshipDTO)
        case relationshipRemove(RelationshipDTO)
        /// Somebody joined, left or changed a switch in a voice channel. **A
        /// null `channel_id` is the leave** — Discord sends no departure event.
        case voiceStateUpdate(VoiceStateDTO)
        /// Where our own media session lives. Arrives beside our own
        /// `VOICE_STATE_UPDATE` and in **either order** relative to it.
        case voiceServerUpdate(VoiceServerUpdateDTO)
        /// A soundboard press, or a reaction thrown into a voice channel.
        case voiceChannelEffect(VoiceChannelEffectDTO)
        /// A direct-message call started, changed who it is ringing, or ended.
        case callCreate(CallDTO)
        case callUpdate(CallDTO)
        case callDelete(CallDeleteDTO)
        /// A server's soundboard set changed. The whole set, not a delta.
        case guildSoundboardSounds(GuildSoundboardPayload)
        /// Somebody's screen share started, changed who is watching it, or
        /// ended. The **only** signal for "somebody is watching me".
        case streamUpsert(StreamEventDTO)
        case streamDelete(StreamEventDTO)
        /// Where **a Go Live stream's own media session** lives. A stream is a
        /// separate session from the call carrying it, with its own endpoint
        /// and token, and this is the only frame that names them.
        case streamServerUpdate(StreamServerUpdateDTO)
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
        self.name = name

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
        case "INTERACTION_SUCCESS":
            payload = .interactionSuccess(try decode(InteractionAckPayload.self))
        case "INTERACTION_FAILURE":
            payload = .interactionFailure(try decode(InteractionAckPayload.self))
        case "MESSAGE_UPDATE": payload = .messageUpdate(try decode(MessageDTO.self))
        case "MESSAGE_DELETE": payload = .messageDelete(try decode(MessageDeletePayload.self))
        case "MESSAGE_REACTION_ADD":
            payload = .messageReactionAdd(try decode(ReactionEventPayload.self))
        case "MESSAGE_REACTION_REMOVE":
            payload = .messageReactionRemove(try decode(ReactionEventPayload.self))
        case "GUILD_CREATE": payload = .guildCreate(try decode(GuildDTO.self))
        case "GUILD_UPDATE": payload = .guildUpdate(try decode(GuildDTO.self))
        case "GUILD_EMOJIS_UPDATE":
            payload = .guildEmojisUpdate(try decode(GuildEmojisPayload.self))
        case "GUILD_STICKERS_UPDATE":
            payload = .guildStickersUpdate(try decode(GuildStickersPayload.self))
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
        // A friend request sent, accepted, declined or withdrawn — and a block
        // put on or taken off. All four arrive as these two events, which is
        // why the client does not have to re-fetch anything after acting.
        case "RELATIONSHIP_ADD": payload = .relationshipAdd(try decode(RelationshipDTO.self))
        case "RELATIONSHIP_REMOVE":
            payload = .relationshipRemove(try decode(RelationshipDTO.self))
        case "VOICE_STATE_UPDATE": payload = .voiceStateUpdate(try decode(VoiceStateDTO.self))
        case "VOICE_SERVER_UPDATE":
            payload = .voiceServerUpdate(try decode(VoiceServerUpdateDTO.self))
        case "VOICE_CHANNEL_EFFECT_SEND":
            payload = .voiceChannelEffect(try decode(VoiceChannelEffectDTO.self))
        case "CALL_CREATE": payload = .callCreate(try decode(CallDTO.self))
        case "CALL_UPDATE": payload = .callUpdate(try decode(CallDTO.self))
        case "CALL_DELETE": payload = .callDelete(try decode(CallDeleteDTO.self))
        case "GUILD_SOUNDBOARD_SOUNDS_UPDATE", "SOUNDBOARD_SOUNDS":
            payload = .guildSoundboardSounds(try decode(GuildSoundboardPayload.self))
        case "STREAM_CREATE", "STREAM_UPDATE":
            payload = .streamUpsert(try decode(StreamEventDTO.self))
        case "STREAM_DELETE":
            payload = .streamDelete(try decode(StreamEventDTO.self))
        case "STREAM_SERVER_UPDATE":
            payload = .streamServerUpdate(try decode(StreamServerUpdateDTO.self))
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
    /// Base64 `PreloadedUserSettings`. **This is where the folders live now** —
    /// `user_settings` is absent from a modern READY. See `UserSettingsProto`.
    var user_settings_proto: String?
    var user_guild_settings: GuildSettingsEnvelope?
    var users: [UserDTO]?
    var relationships: [RelationshipDTO]?
    /// `{ "<user id>": "note" }`. Keyed by string because JSON objects are, and
    /// parsed to snowflakes on the way into the snapshot.
    var notes: [String: String]?

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
        /// The opt-in bit lives here — see `ChannelSettingsFlags`.
        var flags: Int?
    }
}

struct RelationshipDTO: Decodable, Sendable {
    var id: UserID
    /// 2 is BLOCKED. Ignoring is not a type — see `is_ignored`.
    var type: Int?
    /// Orthogonal to `type`: a friend can be ignored, and a block does not
    /// imply one.
    var is_ignored: Bool?
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

/// `GUILD_EMOJIS_UPDATE` — the server's whole emoji set, not a delta.
public struct GuildEmojisPayload: Decodable, Sendable {
    public var guild_id: GuildID
    var emojis: [EmojiDTO]?

    /// The usable custom emoji, in the order the server lists them.
    public var catalog: [EmojiRef] { emojis?.compactMap(\.catalogEntry) ?? [] }
}

/// `GUILD_STICKERS_UPDATE` — likewise the whole set.
public struct GuildStickersPayload: Decodable, Sendable {
    public var guild_id: GuildID
    var stickers: [StickerDTO]?

    public var catalog: [StickerRef] { stickers?.compactMap(\.catalogEntry) ?? [] }
}

/// `GUILD_SOUNDBOARD_SOUNDS_UPDATE`, and the `SOUNDBOARD_SOUNDS` reply to the
/// op-31 request. The same shape answers both.
public struct GuildSoundboardPayload: Decodable, Sendable {
    public var guild_id: GuildID?
    var soundboard_sounds: [SoundboardSoundDTO]?

    public var catalog: [SoundboardSound] {
        (soundboard_sounds ?? []).map(\.domain)
    }
}


/// `INTERACTION_SUCCESS`. Captured as 98 bytes on the wire —
/// `{"nonce":"…","id":"…"}` and nothing else.
public struct InteractionAckPayload: Decodable, Sendable {
    public var id: String?
    public var nonce: String?
}
