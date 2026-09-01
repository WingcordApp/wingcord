import Foundation
import WingcordCore

// MARK: - The voice payloads
//
// Everything the main gateway and the REST API say about calls. Each of these
// is a captured shape rather than a documented one: none of the private-call
// routes and none of the soundboard routes are in Discord's published
// documentation.

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
            isSuppressed: suppress ?? false
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
