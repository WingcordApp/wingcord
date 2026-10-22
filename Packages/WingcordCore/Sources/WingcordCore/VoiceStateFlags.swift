import Foundation

/// What a client says about clips — sent in its own voice state (op 4's
/// `flags`) and handed by the voice server to everybody else in the call
/// (voice op 18). Discord's `Ajs` in web build 641803.
///
/// **This is the whole consent model for voices in clips.** A client keeps
/// somebody else's voice only when that person's flags carry
/// `allowsVoiceRecording`; and when somebody in the call has `clipsEnabled`,
/// everybody whose own setting allows recording is told so once
/// (docs/CLIPS-PRESENCE.md, Phase 3).
public struct VoiceStateFlags: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// `CLIPS_ENABLED`: this client keeps clips.
    public static let clipsEnabled = VoiceStateFlags(rawValue: 1)
    /// `ALLOW_VOICE_RECORDING`: others may keep this person's voice.
    public static let allowsVoiceRecording = VoiceStateFlags(rawValue: 2)
    /// `ALLOW_ANY_VIEWER_CLIPS`: anybody watching this person's stream may
    /// clip it.
    public static let allowsAnyViewerClips = VoiceStateFlags(rawValue: 4)

    /// Discord's `computeVoiceFlags()`: the account's allow setting, and
    /// whether clips are on here.
    public static func announced(allowsVoiceRecording: Bool, clipsEnabled: Bool) -> VoiceStateFlags {
        var flags: VoiceStateFlags = []
        if allowsVoiceRecording { flags.insert(.allowsVoiceRecording) }
        if clipsEnabled { flags.insert(.clipsEnabled) }
        return flags
    }
}
