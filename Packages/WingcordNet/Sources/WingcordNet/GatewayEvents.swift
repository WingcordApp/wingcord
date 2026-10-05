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
        /// The rest of the bootstrap. **Where the voice states are** — see
        /// `ReadySupplementalPayload` for the capability bit that put them
        /// there and for what else moved with them.
        case readySupplemental(ReadySupplementalPayload)
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
        case messageReactionRemoveAll(ReactionRemoveAllPayload)
        case messageReactionRemoveEmoji(ReactionRemoveEmojiPayload)
        case messageReactionAddMany(ReactionAddManyPayload)
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
        /// A thread was made, or one the account can already see changed.
        ///
        /// **`THREAD_CREATE` is also how a thread arrives when access is
        /// gained** — Discord re-sends it rather than a list, so it must be
        /// treated as an upsert and never as "this is new, animate it in".
        case threadCreate(ThreadCreateDTO)
        case threadUpdate(ChannelDTO)
        /// Deleting a thread sends a *partial* channel: id, guild, parent and
        /// type, and nothing else. It is decoded as its own narrow payload so a
        /// missing `name` cannot fail the frame.
        case threadDelete(ThreadDeleteDTO)
        /// The threads in one or more channels, sent when the account gains
        /// access to a channel that already had some.
        case threadListSync(ThreadListSyncDTO)
        /// **Our own** membership of one thread changed — joined, left, or the
        /// notification and mute settings moved. Nobody else's membership
        /// arrives this way.
        case threadMemberUpdate(ThreadMemberUpdateDTO)
        /// Somebody else joined or left a thread. Carries the new member count,
        /// which is the only reason this client listens to it.
        case threadMembersUpdate(ThreadMembersUpdateDTO)
        case presenceUpdate(PresenceDTO)
        case typingStart(TypingPayload)
        case guildMembersChunk(MembersChunkPayload)
        /// Somebody joined, or a member changed — roles, nickname, timeout,
        /// flags. **One case for both**: the payload is the whole member
        /// either way, and the store upserts it.
        case guildMemberUpsert(GuildMemberEventDTO)
        case guildMemberRemove(GuildMemberRemoveDTO)
        /// The outcome of a bulk ban — the POST answers before the bans are
        /// done, and this is where Discord's own client learns how it went.
        case guildBulkBanUpdate(GuildBulkBanUpdateDTO)
        /// A join request was made or changed — the reader's own, or, for a
        /// moderator, anybody's in a server they review.
        case guildJoinRequestUpsert(GuildJoinRequestEventDTO)
        case guildJoinRequestDelete(GuildJoinRequestDeleteDTO)
        case guildMemberListUpdate(MemberListUpdatePayload)
        case messageAck(MessageAckPayload)
        /// A mention was acknowledged — here, or on the reader's phone. The
        /// inbox's Mentions tab is a server-side list, so this is the only
        /// signal that a row somebody dismissed elsewhere has gone.
        case recentMentionDelete(RecentMentionDeletePayload)
        /// A message was bookmarked, or a reminder set on one. The inner
        /// payload is a whole saved message, so nothing has to be refetched.
        case savedMessageCreate(SavedMessageDTO)
        case savedMessageDelete(SavedMessageDeletePayload)
        case userUpdate(UserDTO)
        case relationshipAdd(RelationshipDTO)
        case relationshipRemove(RelationshipDTO)
        case relationshipUpdate(RelationshipDTO)
        case userGuildSettingsUpdate(GuildSettingsDTO)
        /// The account's settings blob changed — here, or in another client.
        case userSettingsProtoUpdate(SettingsProtoUpdateDTO)
        /// An application asked for a form — `InteractionModalDTO`.
        case interactionModalCreate(InteractionModalDTO)
        case stageInstanceUpsert(StageInstanceDTO)
        case stageInstanceDelete(StageInstanceDTO)
        case scheduledEventUpsert(ScheduledEventDTO)
        case scheduledEventDelete(ScheduledEventDTO)
        /// Somebody answered an event, or took the answer back — the reader's
        /// own included, from another client.
        case scheduledEventUserAdd(ScheduledEventRSVPDTO)
        case scheduledEventUserRemove(ScheduledEventRSVPDTO)
        /// A date of a series was moved, cancelled or restored.
        case scheduledEventExceptionUpsert(ScheduledEventExceptionDTO)
        case scheduledEventExceptionDelete(ScheduledEventExceptionDTO)
        /// Every date's change was dropped — the series was edited whole.
        case scheduledEventExceptionsDelete(ScheduledEventExceptionDTO)
        case activityInboxStale(ActivityInboxStaleDTO)
        /// Somebody joined, left or changed a switch in a voice channel. **A
        /// null `channel_id` is the leave** — Discord sends no departure event.
        case voiceStateUpdate(VoiceStateDTO)
        /// Where our own media session lives. Arrives beside our own
        /// `VOICE_STATE_UPDATE` and in **either order** relative to it.
        case voiceServerUpdate(VoiceServerUpdateDTO)
        /// A soundboard press, or a reaction thrown into a voice channel.
        case voiceChannelEffect(VoiceChannelEffectDTO)
        /// The room's own label changed — set by anybody sitting in it.
        case voiceChannelStatusUpdate(VoiceChannelStatusDTO)
        /// The room's current session started, or ended.
        case voiceChannelStartTimeUpdate(VoiceChannelStartTimeDTO)
        /// The answer to opcode 43: the status and session clock of every voice
        /// channel in one guild.
        case channelInfo(ChannelInfoPayload)
        /// A guild the client is not subscribed to, in one periodic delta.
        case passiveUpdate(PassiveUpdateDTO)
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
        /// Discord summed up a new stretch of a channel, or updated one.
        case conversationSummaryUpdate(SummaryUpdatePayload)
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
        case "READY_SUPPLEMENTAL":
            payload = .readySupplemental(try decode(ReadySupplementalPayload.self))
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
        case "MESSAGE_REACTION_REMOVE_ALL":
            payload = .messageReactionRemoveAll(try decode(ReactionRemoveAllPayload.self))
        case "MESSAGE_REACTION_REMOVE_EMOJI":
            payload = .messageReactionRemoveEmoji(try decode(ReactionRemoveEmojiPayload.self))
        case "MESSAGE_REACTION_ADD_MANY":
            payload = .messageReactionAddMany(try decode(ReactionAddManyPayload.self))
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
        case "THREAD_CREATE": payload = .threadCreate(try decode(ThreadCreateDTO.self))
        case "THREAD_UPDATE": payload = .threadUpdate(try decode(ChannelDTO.self))
        case "THREAD_DELETE": payload = .threadDelete(try decode(ThreadDeleteDTO.self))
        case "THREAD_LIST_SYNC": payload = .threadListSync(try decode(ThreadListSyncDTO.self))
        case "THREAD_MEMBER_UPDATE":
            payload = .threadMemberUpdate(try decode(ThreadMemberUpdateDTO.self))
        case "THREAD_MEMBERS_UPDATE":
            payload = .threadMembersUpdate(try decode(ThreadMembersUpdateDTO.self))
        case "PRESENCE_UPDATE": payload = .presenceUpdate(try decode(PresenceDTO.self))
        case "TYPING_START": payload = .typingStart(try decode(TypingPayload.self))
        case "GUILD_MEMBERS_CHUNK":
            payload = .guildMembersChunk(try decode(MembersChunkPayload.self))
        // A role given, a nickname set, a timeout, a kick — the authority for
        // what a moderation write did, and for the reader's own member record.
        case "GUILD_MEMBER_ADD", "GUILD_MEMBER_UPDATE":
            payload = .guildMemberUpsert(try decode(GuildMemberEventDTO.self))
        case "GUILD_MEMBER_REMOVE":
            payload = .guildMemberRemove(try decode(GuildMemberRemoveDTO.self))
        case "GUILD_BULK_BAN_UPDATE":
            payload = .guildBulkBanUpdate(try decode(GuildBulkBanUpdateDTO.self))
        // An application sent, reviewed, reopened or taken back. Create and
        // update are one case: the payload is the whole request either way,
        // and Discord's store files both with one function (`212455`'s `A`).
        case "GUILD_JOIN_REQUEST_CREATE", "GUILD_JOIN_REQUEST_UPDATE":
            payload = .guildJoinRequestUpsert(try decode(GuildJoinRequestEventDTO.self))
        case "GUILD_JOIN_REQUEST_DELETE":
            payload = .guildJoinRequestDelete(try decode(GuildJoinRequestDeleteDTO.self))
        case "GUILD_MEMBER_LIST_UPDATE":
            payload = .guildMemberListUpdate(try decode(MemberListUpdatePayload.self))
        case "MESSAGE_ACK": payload = .messageAck(try decode(MessageAckPayload.self))
        // The inbox's three. A bookmark put on from a phone, a reminder that
        // came due, a mention dismissed in another client — each reaches this
        // window without the flyout refetching anything.
        case "RECENT_MENTION_DELETE":
            payload = .recentMentionDelete(try decode(RecentMentionDeletePayload.self))
        case "SAVED_MESSAGE_CREATE":
            payload = .savedMessageCreate(try decode(SavedMessageDTO.self))
        case "SAVED_MESSAGE_DELETE":
            payload = .savedMessageDelete(try decode(SavedMessageDeletePayload.self))
        case "USER_UPDATE": payload = .userUpdate(try decode(UserDTO.self))
        // A friend request sent, accepted, declined or withdrawn — and a block
        // put on or taken off. All four arrive as these two events, which is
        // why the client does not have to re-fetch anything after acting.
        case "RELATIONSHIP_ADD": payload = .relationshipAdd(try decode(RelationshipDTO.self))
        case "RELATIONSHIP_REMOVE":
            payload = .relationshipRemove(try decode(RelationshipDTO.self))
        // A friend nickname set, changed or cleared. Its own event rather than
        // an `ADD` with a nickname on it, so a rename cannot be mistaken for a
        // relationship arriving.
        case "RELATIONSHIP_UPDATE":
            payload = .relationshipUpdate(try decode(RelationshipDTO.self))
        // A pin, a mute or a notification level changed — here or on the
        // reader's phone. One entry per guild, and the private-channel
        // pseudo-guild sends `guild_id: null`.
        case "USER_GUILD_SETTINGS_UPDATE":
            payload = .userGuildSettingsUpdate(try decode(GuildSettingsDTO.self))
        // Settings saved anywhere — Discord's own client rearranging the rail,
        // or the echo of a write from this one. `partial` means the blob holds
        // only the fields that changed.
        case "USER_SETTINGS_PROTO_UPDATE":
            payload = .userSettingsProtoUpdate(try decode(SettingsProtoUpdateDTO.self))
        case "INTERACTION_MODAL_CREATE":
            payload = .interactionModalCreate(try decode(InteractionModalDTO.self))
        // A stage started, was renamed, or ended. **Create and update are one
        // case**: the payload is the whole instance either way, so a client
        // that told them apart would be telling itself something it does not
        // act on.
        case "STAGE_INSTANCE_CREATE", "STAGE_INSTANCE_UPDATE":
            payload = .stageInstanceUpsert(try decode(StageInstanceDTO.self))
        case "STAGE_INSTANCE_DELETE":
            payload = .stageInstanceDelete(try decode(StageInstanceDTO.self))
        // The payload is the whole event either way — the inbox's Events group
        // only asks which exist and which is newest.
        case "GUILD_SCHEDULED_EVENT_CREATE", "GUILD_SCHEDULED_EVENT_UPDATE":
            payload = .scheduledEventUpsert(try decode(ScheduledEventDTO.self))
        case "GUILD_SCHEDULED_EVENT_DELETE":
            payload = .scheduledEventDelete(try decode(ScheduledEventDTO.self))
        // Discord's store reads these five (`698441`); their payloads are not
        // captured here, so each is decoded leniently and a missing id drops
        // the event rather than the socket.
        case "GUILD_SCHEDULED_EVENT_USER_ADD":
            payload = .scheduledEventUserAdd(try decode(ScheduledEventRSVPDTO.self))
        case "GUILD_SCHEDULED_EVENT_USER_REMOVE":
            payload = .scheduledEventUserRemove(try decode(ScheduledEventRSVPDTO.self))
        case "GUILD_SCHEDULED_EVENT_EXCEPTION_CREATE", "GUILD_SCHEDULED_EVENT_EXCEPTION_UPDATE":
            payload = .scheduledEventExceptionUpsert(try decode(ScheduledEventExceptionDTO.self))
        case "GUILD_SCHEDULED_EVENT_EXCEPTION_DELETE":
            payload = .scheduledEventExceptionDelete(try decode(ScheduledEventExceptionDTO.self))
        case "GUILD_SCHEDULED_EVENT_EXCEPTIONS_DELETE":
            payload = .scheduledEventExceptionsDelete(try decode(ScheduledEventExceptionDTO.self))
        case "CONTENT_INVENTORY_INBOX_STALE":
            payload = .activityInboxStale(try decode(ActivityInboxStaleDTO.self))
        case "VOICE_STATE_UPDATE": payload = .voiceStateUpdate(try decode(VoiceStateDTO.self))
        case "VOICE_SERVER_UPDATE":
            payload = .voiceServerUpdate(try decode(VoiceServerUpdateDTO.self))
        case "VOICE_CHANNEL_EFFECT_SEND":
            payload = .voiceChannelEffect(try decode(VoiceChannelEffectDTO.self))
        case "VOICE_CHANNEL_STATUS_UPDATE":
            payload = .voiceChannelStatusUpdate(try decode(VoiceChannelStatusDTO.self))
        case "VOICE_CHANNEL_START_TIME_UPDATE":
            payload = .voiceChannelStartTimeUpdate(try decode(VoiceChannelStartTimeDTO.self))
        case "CHANNEL_INFO": payload = .channelInfo(try decode(ChannelInfoPayload.self))
        case "PASSIVE_UPDATE_V2": payload = .passiveUpdate(try decode(PassiveUpdateDTO.self))
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
        case "CONVERSATION_SUMMARY_UPDATE":
            payload = .conversationSummaryUpdate(try decode(SummaryUpdatePayload.self))
        default: payload = .unhandled(name: name)
        }
    }
}

struct NotificationSettingsDTO: Decodable, Sendable {
    var flags: Int?
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
    /// The account's own notification settings: `flags` carries
    /// `USE_NEW_NOTIFICATIONS` (16), which decides how a channel's unread
    /// setting resolves — see `NotificationPreferences.usesNewNotifications`.
    var notification_settings: NotificationSettingsDTO?
    var users: [UserDTO]?
    var relationships: [RelationshipDTO]?
    /// `{ "<user id>": "note" }`. Keyed by string because JSON objects are, and
    /// parsed to snowflakes on the way into the snapshot.
    var notes: [String: String]?
    /// The reader's own applications to servers, each with how it stands —
    /// Discord's `CONNECTION_OPEN` reads `e.guild_join_requests ?? []`.
    var guild_join_requests: JoinRequestList?

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

    /// **Never the reason READY fails.** Nothing here has been captured off a
    /// real READY, so an element that cannot be read is dropped and a shape
    /// that is not a list reads as none — the bootstrap carries every other
    /// table in the app, and losing it over an applicant's list would be
    /// losing the session over a folder.
    struct JoinRequestList: Decodable, Sendable {
        var requests: [OwnJoinRequestDTO]

        init(from decoder: any Decoder) throws {
            requests = (try? LossyList<OwnJoinRequestDTO>(from: decoder))?.elements ?? []
        }
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

/// `USER_SETTINGS_PROTO_UPDATE`: `{ settings: { type, proto }, partial }`, the
/// shape Discord's own dispatcher unpacks (`e.settings.type`,
/// `e.settings.proto`, `e.partial`). Type 1 is `PreloadedUserSettings`.
struct SettingsProtoUpdateDTO: Decodable, Sendable {
    struct Settings: Decodable, Sendable {
        var type: Int
        var proto: String
    }
    var settings: Settings
    var partial: Bool?
}

struct GuildSettingsDTO: Decodable, Sendable {
    var guild_id: GuildID?
    var muted: Bool?
    /// The reader's own level for this whole server. `3` means they have not set
    /// one and the server's own default stands — see `MessageNotificationLevel`.
    var message_notifications: Int?
    /// Whether `@everyone` and `@here` are turned off here. Per-server, and
    /// orthogonal to the level: somebody can want every message *and* not want
    /// `@everyone`.
    var suppress_everyone: Bool?
    var suppress_roles: Bool?
    var channel_overrides: [ChannelOverride]?
    /// `OPT_IN_CHANNELS_ON` and the unread bits — see `GuildUserSettingsFlags`.
    /// **A different table from the override's `flags` below**, at overlapping
    /// numbers: `16384` is opt-in here and "new forum threads on" there.
    var flags: Int?
    /// Present and non-null only while a mute is running.
    var mute_config: MuteConfig?
    var hide_muted_channels: Bool?
    var mobile_push: Bool?
    var mute_scheduled_events: Bool?
    /// Discord's `Highlight Level`: 0 default, 1 suppressed, 2 on.
    var notify_highlights: Int?

    struct ChannelOverride: Decodable, Sendable {
        var channel_id: ChannelID?
        var muted: Bool?
        var message_notifications: Int?
        /// The opt-in bit lives here — see `ChannelSettingsFlags`.
        var flags: Int?
        var mute_config: MuteConfig?
    }

    /// A running mute, on a guild or on one of its channels.
    ///
    /// **`end_time` is an ISO-8601 string with fractional seconds**, which the
    /// shared decoder does not parse — captured as
    /// `"2026-09-22T04:22:36.924Z"`. It is read as a string and converted here
    /// rather than typed as a `Date`, so one unexpected format costs the mute's
    /// expiry and not the whole settings object.
    struct MuteConfig: Decodable, Sendable {
        var end_time: String?
        var selected_time_window: Int?
    }
}

struct RelationshipDTO: Decodable, Sendable {
    var id: UserID
    /// 2 is BLOCKED. Ignoring is not a type — see `is_ignored`.
    var type: Int?
    /// Orthogonal to `type`: a friend can be ignored, and a block does not
    /// imply one.
    var is_ignored: Bool?
    /// What the reader has decided to call this person, 1-32 characters.
    ///
    /// **Theirs alone and friends only.** It is not a nickname in a server and
    /// it is not the person's own display name — it is a private renaming that
    /// travels with the account, and Discord offers it on FRIEND relationships
    /// only. Absent on everybody else, and `null` once cleared.
    var nickname: String?
    var user: UserDTO?
    /// When the request was made.
    ///
    /// **The only ordering a friend-requests list has.** Absent on a
    /// relationship that was never a request, which is why `RelationshipFacts`
    /// holds it as an optional rather than defaulting it to the epoch.
    var since: Date?
    /// Discord's own spam flag on an incoming request. Not a guess this client
    /// makes, and not implied by `stranger_request`.
    var is_spam_request: Bool?
    /// They share no mutual friend and no small mutual server with the reader.
    /// Ordinary, and deliberately distinct from spam.
    var stranger_request: Bool?

    /// The three facts above, or nil when there is nothing remarkable to store.
    var facts: RelationshipFacts? {
        let facts = RelationshipFacts(
            since: since,
            isSpam: is_spam_request ?? false,
            isStranger: stranger_request ?? false
        )
        return facts.isNoteworthy ? facts : nil
    }
}

struct MessageDeletePayload: Decodable, Sendable {
    var id: MessageID
    var channel_id: ChannelID
    var guild_id: GuildID?
}

/// `MESSAGE_REACTION_ADD` and `MESSAGE_REACTION_REMOVE`.
///
/// `type` names the half — `0` plain, `1` super — and a super reaction's add
/// carries the server's palette for it. Read the way Discord's dispatcher reads
/// them (module `597643`): `type` is the kind and `burst_colors` the colours.
struct ReactionEventPayload: Decodable, Sendable {
    var user_id: UserID
    var channel_id: ChannelID
    var message_id: MessageID
    var guild_id: GuildID?
    var emoji: EmojiDTO
    var type: Int?
    /// The same fact as `type == 1`, sent beside it. Consulted only when
    /// `type` is missing, so a payload that carries one without the other is
    /// still read the way it plainly means.
    var burst: Bool?
    var burst_colors: [String]?

    var kind: ReactionKind {
        switch type {
        case ReactionKind.burst.rawValue: .burst
        case nil: burst == true ? .burst : .normal
        default: .normal
        }
    }
}

/// `MESSAGE_REACTION_REMOVE_ALL`: a moderator cleared every reaction.
struct ReactionRemoveAllPayload: Decodable, Sendable {
    var channel_id: ChannelID
    var message_id: MessageID
}

/// `MESSAGE_REACTION_REMOVE_EMOJI`: a moderator cleared one emoji, both halves.
struct ReactionRemoveEmojiPayload: Decodable, Sendable {
    var channel_id: ChannelID
    var message_id: MessageID
    var emoji: EmojiDTO
}

/// `MESSAGE_REACTION_ADD_MANY`: several plain reactions batched into one
/// dispatch.
///
/// **Its fields are read out of Discord's own reducer, not captured.** The
/// event arrives on a live session — it is in `session.log` — and Discord's
/// client hands `reactions` to `addReactionBatch`, which reads `users` and
/// `emoji` from each entry and adds every user as a *plain* reaction. Every
/// field is optional so a shape that turns out different costs this one event
/// rather than failing the frame.
struct ReactionAddManyPayload: Decodable, Sendable {
    var channel_id: ChannelID
    var message_id: MessageID
    var reactions: [Entry]?

    struct Entry: Decodable, Sendable {
        var users: [UserID]?
        var emoji: EmojiDTO?
    }
}

/// `CONVERSATION_SUMMARY_UPDATE`: new or changed summaries for one channel.
///
/// **Read out of Discord's own dispatcher and store, not captured.** The
/// dispatcher forwards `d` whole, and the summary store (module `822074`) reads
/// `channel_id` and `summaries` — each entry the same wire object the list
/// route answers with, mapped by the same function. Everything past the channel
/// is optional, so a different shape costs this one event rather than the frame.
struct SummaryUpdatePayload: Decodable, Sendable {
    var channel_id: ChannelID
    var summaries: [SummaryDTO]?
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

/// `GUILD_MEMBER_ADD` and `GUILD_MEMBER_UPDATE`: a member object with the
/// server's id beside its fields, at one level.
struct GuildMemberEventDTO: Decodable, Sendable {
    var guild_id: GuildID
    var member: MemberDTO

    private enum Key: String, CodingKey { case guild_id }

    init(from decoder: Decoder) throws {
        guild_id = try decoder.container(keyedBy: Key.self).decode(GuildID.self, forKey: .guild_id)
        member = try MemberDTO(from: decoder)
    }
}

/// `GUILD_MEMBER_REMOVE`: who left, or was removed, and from where.
struct GuildMemberRemoveDTO: Decodable, Sendable {
    var guild_id: GuildID
    var user: UserDTO
}

/// `{guild_id, bulk_ban: {banned_users, failed_users}}`, as Discord's own
/// socket handler reads it.
struct GuildBulkBanUpdateDTO: Decodable, Sendable {
    var guild_id: GuildID
    var bulk_ban: Outcome?

    struct Outcome: Decodable, Sendable {
        var banned_users: [UserID]?
        var failed_users: [UserID]?
    }
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
/// ranges the client asked for — see `MemberListUpdate` for what is kept.
struct MemberListUpdatePayload: Decodable, Sendable {
    var guild_id: GuildID
    var id: String?
    var groups: [Item.Group]?
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
    /// Another session's Mark Unread, rather than its reading — Discord's
    /// gateway hands it on as `manual: e.manual`.
    var manual: Bool?
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

/// `CONTENT_INVENTORY_INBOX_STALE` — the reader's activity feed has moved on.
/// Discord's own reading (`eV(["CONTENT_INVENTORY_INBOX_STALE"], …)`):
/// `refresh_after_ms` and nothing else.
struct ActivityInboxStaleDTO: Decodable, Sendable {
    var refresh_after_ms: Double?
}
