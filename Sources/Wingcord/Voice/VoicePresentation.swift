import Foundation
import WingcordCore

// MARK: - What the call surfaces are handed
//
// Plain `Equatable` values with no store reference, no closures and no
// `AnyView` — the same contract every other presentation in this app has, and
// for the same reason: a tile grid that re-lays out fifty times a second
// because somebody is speaking is a tile grid nobody can read.
//
// **The speaking flag is deliberately NOT the audio level.** The level moves at
// the frame rate; whether somebody is talking moves a few times a sentence. A
// presentation carrying the level would invalidate every tile on every packet,
// which is the one thing this shape exists to prevent — the ring's *thickness*
// is animated inside the tile from a value it reads for itself.

/// One person in a call.
struct VoiceParticipant: Hashable, Sendable, Identifiable {
    var id: UserID
    var displayName: String
    var avatarURL: URL?
    var monogram: String
    /// Their role colour, where a server gave them one.
    var nameColor: UInt32?
    var isSpeaking: Bool
    var isSelfMuted: Bool
    var isServerMuted: Bool
    var isDeafened: Bool
    var isCameraOn: Bool
    var isStreaming: Bool
    var isSelf: Bool
    /// Nil until they have actually sent a frame. A tile that reserves a video
    /// slot on the *flag* shows a black rectangle for as long as the camera
    /// takes to produce its first keyframe, which is up to two seconds.
    var hasLiveVideo: Bool
    /// Whether the reader has this person's share open.
    ///
    /// **Watching is a media session, not a view state** — a second socket, a
    /// second MLS group and a decode — so it is a fact about the call rather
    /// than about the tile drawing it.
    var isWatched: Bool

    /// Whether anything is stopping them being heard.
    var isSilenced: Bool { isSelfMuted || isServerMuted }
    /// Whether there is a share here the reader could open.
    ///
    /// Our own share is excluded: the self tile already draws it from the
    /// capture, and asking the server to forward us our own screen would be a
    /// second encode of a picture already on this machine.
    ///
    /// **And it cannot be lifted for a diagnostic either.** Watching our own
    /// stream would need a second voice websocket on the same `session_id`, and
    /// Discord closes one of the pair with `4006 Session is no longer valid` —
    /// measured, taking the published share down with it.
    var canWatch: Bool { isStreaming && !isSelf }
    /// Whether the tile draws a picture rather than a face.
    var showsVideo: Bool { hasLiveVideo && (isCameraOn || isStreaming) }
    /// Whether anything about them is worth a glyph beside their name.
    ///
    /// Read by the overlay's roster, which draws its marks *inside* the name
    /// capsule — so a person with marks and no name still needs the capsule.
    var hasMarks: Bool { isCameraOn || isStreaming || isSilenced || isDeafened }
}

/// The whole call, as one value.
struct VoicePresentation: Hashable, Sendable {
    enum Placement: Hashable, Sendable {
        /// A guild's voice channel, filling the detail column.
        case channel(ChannelID)
        /// A direct message, floating over its transcript.
        case direct(ChannelID)
    }

    var placement: Placement
    var channelName: String
    var guildName: String?
    var participants: [VoiceParticipant]
    /// Who, if anybody, is filling the stage — a screen share, or the person a
    /// reader pinned. Nil means the even grid.
    var spotlightUserID: UserID?
    var isMuted: Bool
    var isDeafened: Bool
    var isCameraOn: Bool
    var isScreenSharing: Bool
    var quality: VoiceQuality
    /// People being rung who have not answered. Direct calls only.
    var ringingUserIDs: [UserID]

    var channelID: ChannelID {
        switch placement {
        case .channel(let id), .direct(let id): id
        }
    }

    var isDirect: Bool {
        if case .direct = placement { return true }
        return false
    }
}

/// The connection, in the two numbers that mean something to a reader.
///
/// **Not a bar of five bars.** A call's quality is loss and jitter, and the only
/// honest summary is which of those is hurting — a signal-strength metaphor
/// borrowed from a phone says nothing about a path that is fast and lossy.
struct VoiceQuality: Hashable, Sendable {
    var lossPercent: Int
    var jitterMilliseconds: Double
    var isConnected: Bool
    var encryption: Encryption = .transportOnly

    /// Who, besides the people in the call, could hear it.
    ///
    /// **This is a claim about the world, so it is drawn from what actually
    /// happened rather than from the fact that a call connected.** DAVE only
    /// protects a session once the MLS group exists; until then the call is
    /// negotiated but not yet private, and saying otherwise would be the one
    /// failure the protocol is there to prevent.
    enum Encryption: Hashable, Sendable {
        /// Encrypted to Discord's servers and no further. Today that is a stage
        /// channel and nothing else.
        case transportOnly
        /// End-to-end encryption is being set up. No media is sent yet.
        case establishing
        /// End to end. The code is the group's epoch authenticator, for reading
        /// out to somebody on the other end to confirm nobody is in between.
        case endToEnd(verificationCode: String)
    }

    enum Grade: Hashable, Sendable {
        case connecting
        case good
        case fair
        case poor
    }

    var grade: Grade {
        guard isConnected else { return .connecting }
        // Two per cent of loss and thirty milliseconds of jitter are both
        // inaudible with Opus's FEC in the path. Past five and sixty the
        // concealer is doing the talking.
        if lossPercent >= 5 || jitterMilliseconds >= 60 { return .poor }
        if lossPercent >= 2 || jitterMilliseconds >= 30 { return .fair }
        return .good
    }

    var label: String {
        switch grade {
        case .connecting: "Connecting"
        case .good: "Voice Connected"
        case .fair: "Connection unstable"
        case .poor: "Poor connection"
        }
    }

    static let idle = VoiceQuality(lossPercent: 0, jitterMilliseconds: 0, isConnected: false)
}

/// The soundboard's contents, grouped the way the picker draws them.
struct SoundboardPresentation: Hashable, Sendable {
    struct Section: Hashable, Sendable, Identifiable {
        var id: String
        var title: String
        var iconURL: URL?
        var monogram: String
        /// Whether the whole section is behind the Nitro gate. Dimmed rather
        /// than hidden — §5.5: a gate is a statement, and hiding a section
        /// makes a server's sounds look like they do not exist.
        var isLocked: Bool
        var sounds: [Entry]
    }

    struct Entry: Hashable, Sendable, Identifiable {
        var id: String
        var name: String
        var emoji: String?
        var emojiURL: URL?
        var isLocked: Bool
    }

    var sections: [Section]
    /// Whether the account may press another server's sounds — the refusal's
    /// wording depends on it.
    var playsEverywhere: Bool

    static let empty = SoundboardPresentation(sections: [], playsEverywhere: false)
}
