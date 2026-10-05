import Foundation

/// A channel's Overview page, as the editor holds it and the route takes it.
///
/// **Seeded from the channel, never from defaults.** The page sends every field
/// it owns on every save (`HANDOFF.md` §SM.14), so a draft that started from
/// "no topic, slowmode off, 64 kbps" wrote all of that back the first time
/// somebody renamed a channel — a rename cleared the topic, lifted the slowmode
/// and dropped the age gate. Discord's own store seeds its draft from the
/// channel record and edits it in place; so does this.
///
/// **`flags` is carried whole.** Content Visibility owns exactly one bit of it,
/// `IS_SPOILER_CHANNEL`, and Discord's client toggles that bit inside the
/// channel's existing flags (`tO.lA(flags, IS_SPOILER_CHANNEL, value)`). Sending
/// the spoiler bit or zero, which this client did, cleared a forum's "require a
/// tag", a channel's summaries switch and every bit this client cannot draw —
/// `INVARIANTS.md` §1.
public struct ChannelOverview: Hashable, Sendable, Identifiable {
    public var id: ChannelID
    public var name: String
    public var kind: ChannelKind
    public var topic: String
    public var visibility: ChannelVisibility
    public var bitrate: Int
    public var userLimit: Int
    public var slowmodeSeconds: Int
    public var autoArchiveMinutes: Int?
    /// The channel's own flags, spoiler bit included. See `wireFlags`.
    public var flags: Int
    /// Nil is Discord's "Automatic".
    public var rtcRegion: String?
    /// 1 automatic, 2 720p. Nil where the channel never carried one.
    public var videoQualityMode: Int?

    /// Discord's default for a fresh voice channel, used only where the channel
    /// object carries no bitrate at all.
    public static let defaultBitrate = 64_000

    public init(_ channel: Channel) {
        id = channel.id
        name = channel.name
        kind = channel.kind
        topic = channel.topic ?? ""
        visibility = ChannelVisibility(isAgeRestricted: channel.isNSFW, flags: channel.flags.rawValue)
        bitrate = channel.bitrate ?? Self.defaultBitrate
        userLimit = channel.userLimit ?? 0
        slowmodeSeconds = channel.rateLimitPerUser
        autoArchiveMinutes = channel.defaultAutoArchiveDuration
        flags = channel.flags.rawValue
        rtcRegion = channel.rtcRegion
        videoQualityMode = channel.videoQualityMode
    }

    /// The flags to send: the channel's own, with the spoiler bit set from the
    /// visibility and nothing else touched.
    public var wireFlags: Int {
        visibility.isSpoiler
            ? flags | ChannelVisibility.spoilerFlag
            : flags & ~ChannelVisibility.spoilerFlag
    }

    /// Whether the page shows the voice controls — bitrate, user limit, region
    /// and camera quality — and sends the two keys only voice channels own.
    public var isVoice: Bool { kind == .voice || kind == .stage }

    /// Whether the page shows a topic, the visibility choice and slowmode.
    public var isTextLike: Bool {
        kind == .text || kind == .announcement || kind == .forum || kind == .media
    }
}

/// A voice channel's camera quality, as Discord's Overview names it.
public enum VideoQualityMode {
    public static let automatic = 1
    public static let full = 2

    public static func title(_ value: Int) -> String {
        switch value {
        case full: "720p"
        default: "Auto"
        }
    }
}

/// One voice region a channel may be pinned to — `GET /guilds/{id}/regions`.
public struct VoiceRegion: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Discord's pick for this reader. Shown first, as its own control does.
    public var isOptimal: Bool
    /// Still answered by the route and no longer offered by Discord's picker.
    public var isDeprecated: Bool

    public init(id: String, name: String, isOptimal: Bool = false, isDeprecated: Bool = false) {
        self.id = id
        self.name = name
        self.isOptimal = isOptimal
        self.isDeprecated = isDeprecated
    }
}
