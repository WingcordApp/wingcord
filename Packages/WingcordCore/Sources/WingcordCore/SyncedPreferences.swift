import Foundation

/// The synced preferences the app honours, each kept where Discord
/// keeps it — so a choice made here is the choice every other client of the
/// account sees, and one made there arrives here.
public struct SyncedPreferences: Hashable, Sendable {
    /// "Open threads in split view" — `text_and_images.use_thread_sidebar`.
    /// On unless switched off, which is Discord's own default.
    public var opensThreadsInSplitView: Bool
    /// "Don't show this again" on an ignored person's profile —
    /// `safety_settings.ignore_profile_speedbump_disabled`.
    public var skipsIgnoredProfileWarning: Bool
    /// Soundboard Volume — `voice_and_video.soundboard_settings.volume`, the
    /// loudness sounds play at here, as a percentage of the uploader's own:
    /// Discord's `getSetting()?.volume ?? 100`.
    public var soundboardVolume: Float
    /// "Always preview video" — `voice_and_video.always_preview_video`: the
    /// camera's preview opens every time the camera is turned on. Discord's
    /// `?.value ?? false`.
    public var alwaysPreviewsVideo: Bool
    /// The account's theme — what "Sync theme across my devices" keeps in
    /// step. Nil until the account's settings have said.
    public var accountTheme: AccountTheme?
    /// "Allow my voice to be recorded in Clips" — `clips.allow_voice_recording`.
    /// What other people's clients read before keeping this account's voice
    /// in their clips (it travels as the voice state's `ALLOW_VOICE_RECORDING`
    /// flag). Discord's `?.value ?? true`: on until switched off.
    public var allowsVoiceRecordingInClips: Bool

    public init(
        opensThreadsInSplitView: Bool = true,
        skipsIgnoredProfileWarning: Bool = false,
        soundboardVolume: Float = 100,
        alwaysPreviewsVideo: Bool = false,
        accountTheme: AccountTheme? = nil,
        allowsVoiceRecordingInClips: Bool = true
    ) {
        self.opensThreadsInSplitView = opensThreadsInSplitView
        self.skipsIgnoredProfileWarning = skipsIgnoredProfileWarning
        self.soundboardVolume = soundboardVolume
        self.alwaysPreviewsVideo = alwaysPreviewsVideo
        self.accountTheme = accountTheme
        self.allowsVoiceRecordingInClips = allowsVoiceRecordingInClips
    }

    /// What one settings blob says about them. **Nil where the blob does not
    /// carry the message the preference lives in** — a live update is partial,
    /// and reading an absent message as its default would undo the reader's
    /// choice every time anything else in their settings changed.
    public struct Delta: Hashable, Sendable {
        public var opensThreadsInSplitView: Bool?
        public var skipsIgnoredProfileWarning: Bool?
        public var soundboardVolume: Float?
        public var alwaysPreviewsVideo: Bool?
        public var accountTheme: AccountTheme?
        public var allowsVoiceRecordingInClips: Bool?

        public init(
            opensThreadsInSplitView: Bool? = nil,
            skipsIgnoredProfileWarning: Bool? = nil,
            soundboardVolume: Float? = nil,
            alwaysPreviewsVideo: Bool? = nil,
            accountTheme: AccountTheme? = nil,
            allowsVoiceRecordingInClips: Bool? = nil
        ) {
            self.opensThreadsInSplitView = opensThreadsInSplitView
            self.skipsIgnoredProfileWarning = skipsIgnoredProfileWarning
            self.soundboardVolume = soundboardVolume
            self.alwaysPreviewsVideo = alwaysPreviewsVideo
            self.accountTheme = accountTheme
            self.allowsVoiceRecordingInClips = allowsVoiceRecordingInClips
        }
    }

    public mutating func apply(_ delta: Delta) {
        if let value = delta.opensThreadsInSplitView { opensThreadsInSplitView = value }
        if let value = delta.skipsIgnoredProfileWarning { skipsIgnoredProfileWarning = value }
        if let value = delta.soundboardVolume { soundboardVolume = value }
        if let value = delta.alwaysPreviewsVideo { alwaysPreviewsVideo = value }
        if let value = delta.accountTheme { accountTheme = value }
        if let value = delta.allowsVoiceRecordingInClips { allowsVoiceRecordingInClips = value }
    }
}

/// The theme an account holds — Discord's `AppearanceSettings.theme` and the
/// gradient preset in its `client_theme_settings`, read out of Discord's
/// compiled descriptors (DESIGN-NOTES §15).
public struct AccountTheme: Hashable, Sendable {
    /// Discord's `Theme`, as its writer maps its four rooms onto it: Ash is
    /// `DARK` (1), Light `LIGHT` (2), Dark `DARKER` (3), Onyx `MIDNIGHT` (4);
    /// 0 is a theme never set.
    public var base: Int
    /// `background_gradient_preset_id`, nil for a plain theme. Mint Apple is
    /// 0, written as an empty wrapper.
    public var gradientPresetID: Int?
    /// Whether a Nitro custom theme (`custom_user_theme_settings`) is set,
    /// which no theme here stands for.
    public var hasCustomTheme: Bool

    public static let ash = 1
    public static let light = 2
    public static let dark = 3
    public static let onyx = 4

    public init(base: Int, gradientPresetID: Int? = nil, hasCustomTheme: Bool = false) {
        self.base = base
        self.gradientPresetID = gradientPresetID
        self.hasCustomTheme = hasCustomTheme
    }
}
