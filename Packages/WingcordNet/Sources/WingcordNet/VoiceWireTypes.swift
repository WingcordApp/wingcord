import Foundation
import WingcordCore

// MARK: - The voice payloads
//
// Everything the main gateway and the REST API say about calls. Each of these
// is a captured shape rather than a documented one: none of the private-call
// routes and none of the soundboard routes are in Discord's published
// documentation.

/// A number of seconds that may arrive as a number or a string, or as neither.
struct LooseSeconds: Decodable, Sendable {
    var value: Double?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = (try? container.decode(Double.self))
            ?? (try? container.decode(String.self)).flatMap(Double.init)
    }
}

struct VoiceStateDTO: Decodable, Sendable {
    var user_id: UserID?
    var channel_id: ChannelID?
    var guild_id: GuildID?
    var session_id: String?
    var deaf: Bool?
    var mute: Bool?
    var self_deaf: Bool?
    var self_mute: Bool?
    var self_stream: Bool?
    var self_video: Bool?
    var suppress: Bool?
    /// A raised hand on a stage, as an ISO-8601 instant. Null is a hand down —
    /// which is also how a request is withdrawn.
    var request_to_speak_timestamp: String?
    /// Seconds since the epoch, by Discord's own use of it (`1e3 * connectedAt`).
    /// **Read loosely**: a field this client only draws a clock from must not be
    /// able to fail a whole voice state.
    var connected_at: LooseSeconds?
    var member: MemberDTO?

    var domain: VoiceState? {
        guard let user_id else { return nil }
        return VoiceState(
            userID: user_id,
            // **A null channel is a departure, not an absence.** Discord sends
            // no leave event; this is it.
            channelID: channel_id,
            guildID: guild_id,
            sessionID: session_id ?? "",
            isServerMuted: mute ?? false,
            isServerDeafened: deaf ?? false,
            isSelfMuted: self_mute ?? false,
            isSelfDeafened: self_deaf ?? false,
            isStreaming: self_stream ?? false,
            isCameraOn: self_video ?? false,
            isSuppressed: suppress ?? false,
            // **Both shapes, because Discord sends both.** The same payload
            // carries fractional seconds on some fields and not on others —
            // see `DiscordREST`'s decoder, which pays for exactly this. This
            // one is decoded by hand because the DTO takes it as a `String`:
            // null is a hand *down* and a strict `Date?` would be a decode
            // failure on a value that legitimately is not a date.
            requestToSpeakAt: request_to_speak_timestamp.flatMap {
                ISO8601DateFormatter.withFraction.date(from: $0)
                    ?? ISO8601DateFormatter.plain.date(from: $0)
            },
            connectedAt: connected_at?.value.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

struct VoiceServerUpdateDTO: Decodable, Sendable {
    var token: String
    var endpoint: String?
    var guild_id: GuildID?
    /// Present instead of `guild_id` for a direct-message call.
    var channel_id: ChannelID?

    var domain: VoiceServer? {
        // An endpoint of null is Discord saying "the region is being
        // reassigned, wait for another of these". Treating it as a connect
        // target produces a socket to `wss://null`.
        guard let endpoint, !endpoint.isEmpty else { return nil }
        let serverID = guild_id.map { String($0.rawValue) }
            ?? channel_id.map { String($0.rawValue) }
        guard let serverID else { return nil }
        return VoiceServer(serverID: serverID, token: token, endpoint: endpoint)
    }
}

struct VoiceChannelEffectDTO: Decodable, Sendable {
    var user_id: UserID
    var channel_id: ChannelID
    var guild_id: GuildID?
    var sound_id: SoundIdentifier?
    var sound_volume: Double?
    var emoji: EmojiDTO?

    var domain: VoiceChannelEffect {
        VoiceChannelEffect(
            userID: user_id,
            channelID: channel_id,
            guildID: guild_id,
            soundID: sound_id?.value,
            soundVolume: sound_volume ?? 1,
            emojiName: emoji?.name,
            emojiID: emoji?.id?.rawValue
        )
    }
}

/// A sound id, which arrives as **either a string or a number**.
///
/// Discord's own six are the strings `"1"`…`"7"`; a server's are snowflakes,
/// and the soundboard routes have been observed sending those unquoted. A
/// decoder that expects one shape fails on half the catalog, and the failure is
/// silent because the whole sound is optional.
struct SoundIdentifier: Decodable, Sendable {
    var value: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = text
        } else if let number = try? container.decode(UInt64.self) {
            value = String(number)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "a sound id that is neither a string nor a number"
            )
        }
    }
}

struct SoundboardSoundDTO: Decodable, Sendable {
    var sound_id: SoundIdentifier
    var name: String
    var volume: Double?
    var emoji_id: EmojiIdentifier?
    var emoji_name: String?
    var guild_id: GuildID?
    var available: Bool?
    var user_id: UserID?
    /// The uploader, as a whole object.
    ///
    /// **Two shapes for one fact.** The gateway's `SOUNDBOARD_SOUNDS` carries
    /// `user_id`; the REST list and the create response carry a whole `user`.
    /// Both are decoded and `uploaderID` is the one place they are reconciled,
    /// so the management page does not care which route it was handed.
    var user: UserDTO?

    /// Who uploaded it, from whichever of the two shapes arrived.
    var uploaderID: UserID? { user?.id ?? user_id }

    var domain: SoundboardSound {
        SoundboardSound(
            id: sound_id.value,
            name: name,
            volume: volume ?? 1,
            emojiID: emoji_id?.value,
            emojiName: emoji_name,
            guildID: guild_id,
            isAvailable: available ?? true
        )
    }
}

/// Same two-shape problem as a sound id, on the emoji.
struct EmojiIdentifier: Decodable, Sendable {
    var value: UInt64?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let text = try? container.decode(String.self) {
            value = UInt64(text)
        } else {
            value = try? container.decode(UInt64.self)
        }
    }
}

/// `GET /guilds/{id}/soundboard-sounds` answers an envelope; the default route
/// answers a bare array. Both decode.
struct SoundboardListDTO: Decodable, Sendable {
    var items: [SoundboardSoundDTO]

    init(from decoder: any Decoder) throws {
        if let list = try? [SoundboardSoundDTO](from: decoder) {
            items = list
            return
        }
        let container = try decoder.container(keyedBy: Keys.self)
        items = try container.decodeIfPresent([SoundboardSoundDTO].self, forKey: .items) ?? []
    }

    private enum Keys: String, CodingKey { case items }
}

/// `CALL_CREATE` / `CALL_UPDATE`.
struct CallDTO: Decodable, Sendable {
    var channel_id: ChannelID
    var message_id: MessageID?
    var region: String?
    var ringing: [UserID]?
    var voice_states: [VoiceStateDTO]?

    var domain: DirectCall {
        DirectCall(
            channelID: channel_id,
            ringingUserIDs: ringing ?? [],
            region: region
        )
    }
}

struct CallDeleteDTO: Decodable, Sendable {
    var channel_id: ChannelID
}

/// `STREAM_CREATE` / `STREAM_UPDATE` / `STREAM_DELETE`.
///
/// **`viewer_ids` is the only signal a client gets for "somebody is watching
/// me".** Nothing on the voice state says it, and the media socket cannot know
/// — the server fans the stream out. So the viewer sounds are driven off the
/// delta between two of these.
///
/// **The key carries the identity.** It is
/// `guild:<guild id>:<channel id>:<user id>` for a server channel and
/// `call:<channel id>:<user id>` for a private call, so whose stream an event
/// is about is the last colon-separated field and nothing else in the payload
/// says it.
struct StreamEventDTO: Decodable, Sendable {
    var stream_key: String
    var viewer_ids: [UserID]?
    var paused: Bool?
    /// The RTC server the stream's **own media session** was allocated on.
    ///
    /// Present on `STREAM_CREATE` and the reason this event matters to the
    /// media stack rather than only to the viewer count: a Go Live stream is a
    /// second media session with its own MLS group, and that group is keyed on
    /// the media session id — **one less than this** — rather than on the
    /// channel. `rtc_channel_id`, beside this, is that id.
    ///
    /// Optional because `STREAM_UPDATE` and `STREAM_DELETE` carry no such
    /// thing, and because it is decoded from other people's stream events too,
    /// where it may not be sent at all.
    var rtc_server_id: RTCServerID?
    /// The stream's **own RTC channel** — the media session its group is keyed
    /// on, and the identifier that is not the DM channel or the guild.
    ///
    /// **Read, never derived.** The documentation says the media session id is
    /// one less than `rtc_server_id`, and in the first frame ever captured it
    /// is: `…905` beside `…906`. It is also *sent*, in this field, so nothing
    /// here computes it — §"READY describes the stream the server already made"
    /// is the same rule, and an arithmetic relationship that holds in one
    /// capture is not a contract.
    ///
    /// **It is also what the stream's IDENTIFY names as `server_id`.**
    /// Identifying with the DM channel instead was answered `4006 Session is no
    /// longer valid.` twenty milliseconds later, on a stream Discord had just
    /// created for us.
    var rtc_channel_id: RTCServerID?
    var region: String?

    /// Whose stream this is.
    var ownerID: UserID? {
        stream_key.split(separator: ":").last
            .flatMap { UInt64($0) }
            .map(UserID.init(rawValue:))
    }

    var channelID: ChannelID? {
        let parts = stream_key.split(separator: ":")
        // `guild:<guild>:<channel>:<user>` puts the channel third;
        // `call:<channel>:<user>` puts it second.
        guard parts.count >= 3 else { return nil }
        let raw = parts[0] == "guild" ? parts[2] : parts[1]
        return UInt64(raw).map(ChannelID.init(rawValue:))
    }
}

/// `STREAM_SERVER_UPDATE` — where a Go Live stream's media session lives.
///
/// **The exact counterpart of `VOICE_SERVER_UPDATE`, one session over.** A
/// stream is not carried on the call's media session: it gets its own endpoint
/// and its own token, and this is the frame that names them. The two halves
/// arrive separately again — `STREAM_CREATE` carries the key and the RTC
/// server, this carries the endpoint and the token — so the same latch the call
/// needs, the stream needs.
struct StreamServerUpdateDTO: Decodable, Sendable {
    var stream_key: String
    var token: String
    var endpoint: String?
    var guild_id: GuildID?

    /// Whose stream this is, read out of the key exactly as `StreamEventDTO`
    /// reads it — the payload does not say.
    var ownerID: UserID? {
        stream_key.split(separator: ":").last
            .flatMap { UInt64($0) }
            .map(UserID.init(rawValue:))
    }

    var domain: GoLiveServer? {
        // A null endpoint is the region being reassigned — the same thing
        // `VOICE_SERVER_UPDATE` does, and the same answer: wait for another.
        guard let endpoint, !endpoint.isEmpty else { return nil }
        // A guild stream identifies with the guild; a call stream has no
        // `guild_id` and identifies with the DM channel, which the key carries
        // as its second field.
        let serverID = guild_id.map { String($0.rawValue) }
            ?? stream_key.split(separator: ":").dropFirst().first.map(String.init)
        guard let serverID else { return nil }
        return GoLiveServer(
            streamKey: stream_key, serverID: serverID, token: token, endpoint: endpoint
        )
    }
}
