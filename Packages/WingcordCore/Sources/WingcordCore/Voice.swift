import Foundation

// MARK: - Who is in a call
//
// A voice state is the one row Discord keeps per person per connection: which
// channel they are in, and every switch they or a moderator has set on them.
// It arrives on READY for every guild, on `VOICE_STATE_UPDATE` when anything
// moves, and inside a DM call's `CALL_CREATE`.

/// One person's presence in a voice channel.
public struct VoiceState: Hashable, Sendable, Identifiable {
    public var userID: UserID
    /// Nil means they **left**. Discord does not send a departure event: a
    /// state with a null channel is the departure, and a client that treats a
    /// missing channel as "unknown" leaves everybody in the room for ever.
    public var channelID: ChannelID?
    public var guildID: GuildID?
    /// The voice session, which is what the media handshake identifies with.
    /// Ours is the one thing this client cannot invent — it comes back on our
    /// own state and nowhere else.
    public var sessionID: String

    /// Silenced by a moderator. Distinct from `isSelfMuted` in every way that
    /// matters: the reader cannot undo it, and the UI has to say which it is
    /// rather than showing one crossed-out microphone for both.
    public var isServerMuted: Bool
    public var isServerDeafened: Bool
    public var isSelfMuted: Bool
    public var isSelfDeafened: Bool
    public var isStreaming: Bool
    public var isCameraOn: Bool
    /// A stage channel's audience. Not a mute — they are simply not a speaker.
    public var isSuppressed: Bool

    public var id: UserID { userID }

    public init(
        userID: UserID,
        channelID: ChannelID? = nil,
        guildID: GuildID? = nil,
        sessionID: String = "",
        isServerMuted: Bool = false,
        isServerDeafened: Bool = false,
        isSelfMuted: Bool = false,
        isSelfDeafened: Bool = false,
        isStreaming: Bool = false,
        isCameraOn: Bool = false,
        isSuppressed: Bool = false
    ) {
        self.userID = userID
        self.channelID = channelID
        self.guildID = guildID
        self.sessionID = sessionID
        self.isServerMuted = isServerMuted
        self.isServerDeafened = isServerDeafened
        self.isSelfMuted = isSelfMuted
        self.isSelfDeafened = isSelfDeafened
        self.isStreaming = isStreaming
        self.isCameraOn = isCameraOn
        self.isSuppressed = isSuppressed
    }

    /// Whether anything is stopping this person being heard, for any reason.
    public var isSilenced: Bool { isServerMuted || isSelfMuted || isSuppressed }
}

/// Where the media session lives.
///
/// The main gateway answers a voice-state change with this, and the two halves
/// arrive as **separate events in either order** — the endpoint on
/// `VOICE_SERVER_UPDATE`, the session id on our own `VOICE_STATE_UPDATE`. A
/// client that assumes an order connects with half a credential once in every
/// few joins, which presents as a call that silently never comes up.
public struct VoiceServer: Hashable, Sendable {
    /// `guild_id` for a server channel; the DM channel's id for a private call.
    public var serverID: String
    public var token: String
    /// `us-east1234.discord.media:443`, port included and not to be trusted —
    /// see `VoiceGateway`.
    public var endpoint: String

    public init(serverID: String, token: String, endpoint: String) {
        self.serverID = serverID
        self.token = token
        self.endpoint = endpoint
    }
}

/// Where a **Go Live stream's own media session** lives.
///
/// **A stream is not the call, and this is not `VoiceServer`.** Turning a
/// camera on is a switch on the call's existing session; a screen share is a
/// second media session with its own RTC server, its own endpoint, its own
/// token and its own MLS group. This is the credential for that second session.
///
/// It arrives in **two halves in either order**, exactly as a call's does:
/// `STREAM_CREATE` carries the key and the `rtc_server_id`,
/// `STREAM_SERVER_UPDATE` carries the endpoint and the token. Neither half
/// alone can open anything.
public struct GoLiveServer: Hashable, Sendable {
    /// The server's own key for this stream — `guild:<guild>:<channel>:<user>`
    /// or `call:<channel>:<user>`. Echoed back verbatim to end the stream; it
    /// is never rebuilt from its parts.
    public var streamKey: String
    /// What the stream session's IDENTIFY sends as `server_id`: the guild, or
    /// the DM channel for a private call — the same choice a call makes.
    public var serverID: String
    public var token: String
    public var endpoint: String

    public init(streamKey: String, serverID: String, token: String, endpoint: String) {
        self.streamKey = streamKey
        self.serverID = serverID
        self.token = token
        self.endpoint = endpoint
    }
}

/// What `STREAM_CREATE` said about a stream's media session.
///
/// Separate from `GoLiveServer` because the two arrive in **either order** and
/// neither half is usable alone — the same split a call's credential has.
public struct GoLiveSession: Hashable, Sendable {
    public var streamKey: String
    /// The RTC server the stream was allocated on.
    public var rtcServerID: UInt64
    /// The stream's own RTC channel: **the media session**, which is what its
    /// MLS group is keyed on and what it identifies against. Sent as its own
    /// field, so it is read rather than derived from `rtcServerID`.
    public var rtcChannelID: UInt64

    public init(streamKey: String, rtcServerID: UInt64, rtcChannelID: UInt64) {
        self.streamKey = streamKey
        self.rtcServerID = rtcServerID
        self.rtcChannelID = rtcChannelID
    }
}

/// A Go Live stream's key, which is an address rather than an opaque token.
///
/// **Built by a viewer, echoed by an owner.** Nothing dispatches a stream event
/// to somebody who is not already watching, so a viewer has to construct the
/// key of the stream it wants before it can ask for it. An owner never builds
/// one: `STREAM_CREATE` hands it the server's own string, and that is what goes
/// back in opcode 19.
///
/// Both grammars are captured — `call:1424759145021837325:987654321987654321`
/// and `guild:<guild>:<channel>:<user>` — and this is the only place either is
/// assembled, so a change to them is a change to one function.
public enum GoLiveKey {
    /// - Parameter guildID: nil for a direct-message call, which is the shorter
    ///   of the two grammars and drops the guild field entirely rather than
    ///   sending an empty one.
    public static func make(
        guildID: GuildID?, channelID: ChannelID, userID: UserID
    ) -> String {
        if let guildID {
            "guild:\(guildID.rawValue):\(channelID.rawValue):\(userID.rawValue)"
        } else {
            "call:\(channelID.rawValue):\(userID.rawValue)"
        }
    }
}

// MARK: - The soundboard

/// One sound anybody in a channel can press.
public struct SoundboardSound: Hashable, Sendable, Identifiable {
    /// **A string, not a snowflake.** Discord's own default sounds are numbered
    /// `"1"` through `"7"` — they predate the id scheme — and a client that
    /// parses this as a `UInt64` and formats it back gets the guild ones right
    /// and the default ones right by accident. Kept as it arrives.
    public var id: String
    public var name: String
    /// 0…1, the volume the uploader chose. Multiplied by the reader's own.
    public var volume: Double
    /// A custom emoji, if the sound has one.
    public var emojiID: UInt64?
    /// A Unicode emoji, if it has one of those instead. Both are optional and
    /// a sound may have neither, which is why the picker draws a waveform in
    /// that case rather than a blank square.
    public var emojiName: String?
    /// Nil for Discord's own six, which belong to no server.
    public var guildID: GuildID?
    /// Whether the *server* has it available. A boosted server that lost its
    /// boosts keeps the sounds and cannot play them.
    public var isAvailable: Bool

    public init(
        id: String,
        name: String,
        volume: Double = 1,
        emojiID: UInt64? = nil,
        emojiName: String? = nil,
        guildID: GuildID? = nil,
        isAvailable: Bool = true
    ) {
        self.id = id
        self.name = name
        self.volume = volume
        self.emojiID = emojiID
        self.emojiName = emojiName
        self.guildID = guildID
        self.isAvailable = isAvailable
    }

    /// Whether this is one of Discord's own six.
    ///
    /// **The gate is on the sound, not on the picker.** Every account may play
    /// the default set; a server's own sounds are a Nitro perk *unless you are
    /// in that server* — the same shape as the emoji gate, which is why the two
    /// are written the same way and neither hides anything.
    public var isDefault: Bool { guildID == nil }
}

/// Whether a reader may press a given sound.
///
/// A pure function over the three facts that decide it, so it can be checked
/// against a table without a store in the picture — the same treatment
/// `MessageActionPolicy` gets, and for the same reason: a gate written at each
/// call site is a gate that drifts.
public enum SoundboardGate {
    public static func canPlay(
        _ sound: SoundboardSound,
        hasNitro: Bool,
        inGuild guildID: GuildID?
    ) -> Bool {
        guard sound.isAvailable else { return false }
        // Discord's own six are free to everybody, everywhere.
        if sound.isDefault { return true }
        // A server's own sounds are free **in that server**.
        if let owner = sound.guildID, owner == guildID { return true }
        // Anywhere else, they are the subscription's.
        return hasNitro
    }

    /// Why a sound cannot be played, in words the picker can show.
    public static func refusal(
        _ sound: SoundboardSound,
        hasNitro: Bool,
        inGuild guildID: GuildID?
    ) -> String? {
        guard !canPlay(sound, hasNitro: hasNitro, inGuild: guildID) else { return nil }
        guard sound.isAvailable else {
            return "This server has lost the boosts that unlocked this sound."
        }
        return "Nitro is needed to use another server's sounds."
    }
}

/// Somebody pressed a sound, or sent a reaction into the channel.
///
/// One event for both because Discord sends one: `VOICE_CHANNEL_EFFECT_SEND`
/// carries an emoji, an animation, a sound id, or some combination.
public struct VoiceChannelEffect: Hashable, Sendable {
    public var userID: UserID
    public var channelID: ChannelID
    public var guildID: GuildID?
    public var soundID: String?
    public var soundVolume: Double
    public var emojiName: String?
    public var emojiID: UInt64?

    public init(
        userID: UserID,
        channelID: ChannelID,
        guildID: GuildID? = nil,
        soundID: String? = nil,
        soundVolume: Double = 1,
        emojiName: String? = nil,
        emojiID: UInt64? = nil
    ) {
        self.userID = userID
        self.channelID = channelID
        self.guildID = guildID
        self.soundID = soundID
        self.soundVolume = soundVolume
        self.emojiName = emojiName
        self.emojiID = emojiID
    }
}

/// A direct-message call.
///
/// Separate from a guild's voice channel in exactly two ways, and both matter to
/// the UI: it **rings**, and the ringing list is who has not answered yet; and
/// it has no `guild_id`, so the media handshake identifies with the channel's
/// own id in the slot a guild id would occupy.
public struct DirectCall: Hashable, Sendable {
    public var channelID: ChannelID
    /// Who is being rung and has not yet joined or declined.
    public var ringingUserIDs: [UserID]
    public var region: String?

    public init(channelID: ChannelID, ringingUserIDs: [UserID] = [], region: String? = nil) {
        self.channelID = channelID
        self.ringingUserIDs = ringingUserIDs
        self.region = region
    }
}
