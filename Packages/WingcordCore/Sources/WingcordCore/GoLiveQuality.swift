import Foundation

// MARK: - Go Live's choices, and who may make them
//
// Discord's own table (its module 753070), read by every surface that offers
// a stream's quality: the Go Live sheet before a share, and the share's own
// flyout while it runs. One copy, so the two cannot disagree about what is
// locked.

/// Discord's Resolution choices for a stream.
public enum StreamResolution: Int, CaseIterable, Sendable, Codable {
    case p480 = 480
    case p720 = 720
    case p1080 = 1_080
    case p1440 = 1_440
    /// The source's own size.
    case source = 0

    /// Discord's label: `{resolution}p`, or "Source".
    public var label: String {
        self == .source ? "Source" : "\(rawValue)p"
    }

    /// The box a share at this resolution is fitted inside.
    ///
    /// Discord's own, from its `setGoLiveSource`: four by three at 480 and
    /// below, sixteen by nine above. **Source is capped at 3840×2160**, which
    /// is Discord's own promise for it ("Up to 4K source resolution") and the
    /// largest picture an H.264 decoder at the level every client uses is
    /// required to take.
    public var box: (width: Int, height: Int) {
        switch self {
        case .p480: (640, 480)
        case .p720: (1_280, 720)
        case .p1080: (1_920, 1_080)
        case .p1440: (2_560, 1_440)
        case .source: (3_840, 2_160)
        }
    }
}

/// Discord's Frame Rate choices for a stream.
public enum StreamFrameRate: Int, CaseIterable, Sendable, Codable {
    case fps15 = 15
    case fps30 = 30
    case fps60 = 60

    /// Discord's label: `{value} FPS`.
    public var label: String { "\(rawValue) FPS" }
}

/// What the reader last chose for Go Live.
///
/// Discord's `ApplicationStreamingSettingsStore`: 720p at 30 frames a second
/// with the sound shared, until the reader chooses otherwise, and kept from
/// one stream to the next.
public struct GoLiveSettings: Codable, Equatable, Sendable {
    public var resolution: StreamResolution
    public var frameRate: StreamFrameRate
    public var sharesAudio: Bool

    public init(
        resolution: StreamResolution = .p720,
        frameRate: StreamFrameRate = .fps30,
        sharesAudio: Bool = true
    ) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.sharesAudio = sharesAudio
    }
}

/// Who may stream at what — Discord's `canStreamWithSettings` (its module
/// 327649) over its table.
///
/// **Two ways in, and either is enough.** The account's own subscription —
/// Source needs Nitro; 1080p, 1440p and 60 frames a second need Nitro or
/// Nitro Classic — or the server's boosts: level 2 opens 1080p and 1440p at
/// any rate, level 1 opens 60 frames a second at 720p and below. A direct
/// message has no server, and its boost level is zero.
public struct GoLiveGate: Sendable, Equatable {
    public var premiumTier: PremiumTier
    /// The server's boost level, 0–3.
    public var guildBoostTier: Int
    /// Fake Nitro's stream quality, which lifts every limit — as the plugin's
    /// `canStreamQuality` patch does. The server enforces none of them.
    public var isUnlocked: Bool

    public init(premiumTier: PremiumTier, guildBoostTier: Int, isUnlocked: Bool = false) {
        self.premiumTier = premiumTier
        self.guildBoostTier = guildBoostTier
        self.isUnlocked = isUnlocked
    }

    public func allows(_ resolution: StreamResolution, _ frameRate: StreamFrameRate) -> Bool {
        guard !isUnlocked else { return true }
        return switch resolution {
        case .source:
            premiumTier.grants(.streamHighQuality)
        case .p1080, .p1440:
            guildBoostTier >= 2 || premiumTier.grants(.streamMidQuality)
        case .p480, .p720:
            frameRate != .fps60 || guildBoostTier >= 1 || premiumTier.grants(.streamMidQuality)
        }
    }

    /// The settings, or Discord's default where they ask for more than this
    /// account and server allow — a subscription that lapsed, a server that
    /// lost its boosts.
    public func admit(_ settings: GoLiveSettings) -> GoLiveSettings {
        guard !allows(settings.resolution, settings.frameRate) else { return settings }
        var admitted = settings
        admitted.resolution = .p720
        admitted.frameRate = .fps30
        return admitted
    }
}
