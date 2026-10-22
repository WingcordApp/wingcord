import Foundation
import WingcordCore

/// `SyncedPreferences` on the wire: three fields of `PreloadedUserSettings`,
/// read out of Discord's compiled descriptors (`VoiceAndVideoSettings`,
/// `TextAndImagesSettings`, `SafetySettings`) rather than recalled.
public enum SyncedPreferencesProto {
    enum Top {
        static let voiceAndVideo = 5
        static let textAndImages = 6
        static let appearance = 13
        static let clips = 19
        static let safetySettings = 21
    }
    /// `ClipsSettings { BoolValue allow_voice_recording = 1 }` (web build
    /// 641803's descriptor `discord_protos.discord_users.v1.ClipsSettings`).
    static let allowVoiceRecording = 1
    /// `AppearanceSettings`: `Theme theme = 1`, `ClientThemeSettings
    /// client_theme_settings = 3`; and in that, `UInt32Value
    /// background_gradient_preset_id = 2` and `custom_user_theme_settings = 4`.
    enum Appearance {
        static let theme = 1
        static let clientThemeSettings = 3
        static let gradientPreset = 2
        static let customTheme = 4
    }
    /// `soundboard_settings`, a `SoundboardSettings { float volume = 1 }`.
    static let soundboardSettings = 9
    /// `always_preview_video`, a `BoolValue` — Discord reads it
    /// `?.value ?? false`, so absent and present-but-empty are both off.
    static let alwaysPreviewVideo = 5
    /// `use_thread_sidebar`, a `BoolValue` — Discord reads it `?.value ?? true`,
    /// so an absent wrapper is on and a present empty one is off.
    static let useThreadSidebar = 3
    /// `ignore_profile_speedbump_disabled`, a **bare** bool, absent when false.
    static let ignoreProfileSpeedbumpDisabled = 2

    public enum Change: Sendable {
        case opensThreadsInSplitView(Bool)
        case skipsIgnoredProfileWarning(Bool)
        /// Soundboard Volume, a percentage of the uploader's own.
        case soundboardVolume(Float)
        /// "Always preview video".
        case alwaysPreviewsVideo(Bool)
        /// The theme, as Discord's own picker writes it: the base, and the
        /// client theme settings whole — the preset, or an empty message for
        /// a plain theme, which also clears a custom one.
        case accountTheme(base: Int, gradientPresetID: Int?)
        /// "Allow my voice to be recorded in Clips".
        case allowsVoiceRecordingInClips(Bool)
    }

    /// What a blob says, each preference nil where its message is absent — see
    /// `SyncedPreferences.Delta`.
    public static func decode(_ data: Data) -> SyncedPreferences.Delta {
        var delta = SyncedPreferences.Delta()
        var reader = ProtobufReader(data)
        while let field = reader.next() {
            switch field.number {
            case Top.textAndImages where field.wireType == 2:
                var opens = true
                var inner = reader.reader(for: field)
                while let entry = inner.next() {
                    guard entry.number == useThreadSidebar, entry.wireType == 2 else { continue }
                    var wrapper = inner.reader(for: entry)
                    var value = false
                    while let bit = wrapper.next() {
                        guard bit.number == 1, bit.wireType == 0 else { continue }
                        value = bit.value != 0
                    }
                    opens = value
                }
                delta.opensThreadsInSplitView = opens
            case Top.voiceAndVideo where field.wireType == 2:
                // Discord's `getSetting()?.volume ?? 100`: a present
                // `voice_and_video` with no soundboard settings is the default.
                var volume: Float = 100
                var previews = false
                var inner = reader.reader(for: field)
                while let entry = inner.next() {
                    switch entry.number {
                    case soundboardSettings where entry.wireType == 2:
                        var settings = inner.reader(for: entry)
                        volume = 0
                        while let value = settings.next() {
                            guard value.number == 1, value.wireType == 5 else { continue }
                            volume = Float(bitPattern: UInt32(truncatingIfNeeded: value.value))
                        }
                    case alwaysPreviewVideo where entry.wireType == 2:
                        var wrapper = inner.reader(for: entry)
                        while let bit = wrapper.next() {
                            guard bit.number == 1, bit.wireType == 0 else { continue }
                            previews = bit.value != 0
                        }
                    default:
                        continue
                    }
                }
                delta.soundboardVolume = volume
                delta.alwaysPreviewsVideo = previews
            case Top.appearance where field.wireType == 2:
                delta.accountTheme = decodeAccountTheme(reader.reader(for: field))
            case Top.clips where field.wireType == 2:
                // `clips.allowVoiceRecording?.value ?? true`: no wrapper is
                // on, a wrapper is its value — and an empty one is off.
                var allows = true
                var inner = reader.reader(for: field)
                while let entry = inner.next() {
                    guard entry.number == allowVoiceRecording, entry.wireType == 2 else { continue }
                    var wrapper = inner.reader(for: entry)
                    var value = false
                    while let bit = wrapper.next() {
                        guard bit.number == 1, bit.wireType == 0 else { continue }
                        value = bit.value != 0
                    }
                    allows = value
                }
                delta.allowsVoiceRecordingInClips = allows
            case Top.safetySettings where field.wireType == 2:
                var skips = false
                var inner = reader.reader(for: field)
                while let entry = inner.next() {
                    guard entry.number == ignoreProfileSpeedbumpDisabled, entry.wireType == 0 else { continue }
                    skips = entry.value != 0
                }
                delta.skipsIgnoredProfileWarning = skips
            default:
                break
            }
        }
        return delta
    }

    private static func decodeAccountTheme(_ source: ProtobufReader) -> AccountTheme {
        var appearance = source
        var theme = AccountTheme(base: 0)
        while let entry = appearance.next() {
            switch entry.number {
            case Appearance.theme where entry.wireType == 0:
                theme.base = Int(entry.value)
            case Appearance.clientThemeSettings where entry.wireType == 2:
                var settings = appearance.reader(for: entry)
                while let setting = settings.next() {
                    switch setting.number {
                    case Appearance.gradientPreset where setting.wireType == 2:
                        // An empty wrapper is 0 — Mint Apple.
                        var wrapper = settings.reader(for: setting)
                        var id = 0
                        while let value = wrapper.next() {
                            if value.number == 1, value.wireType == 0 { id = Int(value.value) }
                        }
                        theme.gradientPresetID = id
                    case Appearance.customTheme where setting.wireType == 2:
                        theme.hasCustomTheme = true
                    default:
                        continue
                    }
                }
            default:
                continue
            }
        }
        return theme
    }

    /// The body of `PATCH /users/@me/settings-proto/1` for one change: the one
    /// top-level message it lives in, **every other byte of it as it came** —
    /// Discord's writer replaces a top-level field whole, and `text_and_images`
    /// alone holds a reader's keyword filters, their collapsed emoji sections
    /// and a dozen more. See `ActivityPrivacyProto.replacing`.
    ///
    /// - Parameter blob: the whole settings blob, fetched just before.
    static func patch(applying change: Change, to blob: Data) -> String {
        let top: Int
        var replacements: [(field: Int, encoded: Data?)] = []
        switch change {
        case .accountTheme(let base, let presetID):
            top = Top.appearance
            var theme = ProtobufWriter()
            theme.varint(field: Appearance.theme, UInt64(base))
            var settings = ProtobufWriter()
            if let presetID {
                var wrapper = ProtobufWriter()
                if presetID != 0 { wrapper.varint(field: 1, UInt64(presetID)) }
                settings.message(field: Appearance.gradientPreset, wrapper.data)
            }
            var client = ProtobufWriter()
            client.message(field: Appearance.clientThemeSettings, settings.data)
            replacements = [(Appearance.theme, theme.data), (Appearance.clientThemeSettings, client.data)]
        case .opensThreadsInSplitView(let opens):
            top = Top.textAndImages
            var writer = ProtobufWriter()
            // An empty wrapper for off — proto3 writes no false — and that
            // present-but-empty wrapper is what Discord reads as off.
            writer.message(field: useThreadSidebar, ActivityPrivacyProto.boolValue(opens))
            replacements = [(useThreadSidebar, writer.data)]
        case .skipsIgnoredProfileWarning(let skips):
            top = Top.safetySettings
            var writer = ProtobufWriter()
            writer.varint(field: ignoreProfileSpeedbumpDisabled, 1)
            replacements = [(ignoreProfileSpeedbumpDisabled, skips ? writer.data : nil)]
        case .soundboardVolume(let volume):
            top = Top.voiceAndVideo
            var settings = ProtobufWriter()
            // proto3 writes no zero, so a silenced soundboard is an empty
            // message — which is what Discord's reader takes as 0, not 100.
            if volume != 0 { settings.float(field: 1, volume) }
            var writer = ProtobufWriter()
            writer.message(field: soundboardSettings, settings.data)
            replacements = [(soundboardSettings, writer.data)]
        case .allowsVoiceRecordingInClips(let allows):
            top = Top.clips
            // `BoolValue.create({value})` either way, as Discord writes it.
            var writer = ProtobufWriter()
            writer.message(field: allowVoiceRecording, ActivityPrivacyProto.boolValue(allows))
            replacements = [(allowVoiceRecording, writer.data)]
        case .alwaysPreviewsVideo(let previews):
            top = Top.voiceAndVideo
            // Discord writes `BoolValue.create({value})` either way, so off is
            // a present empty wrapper.
            var writer = ProtobufWriter()
            writer.message(field: alwaysPreviewVideo, ActivityPrivacyProto.boolValue(previews))
            replacements = [(alwaysPreviewVideo, writer.data)]
        }
        var current = Data()
        var reader = ProtobufReader(blob)
        while let entry = reader.next() {
            if entry.number == top, let data = reader.data(for: entry) { current = data }
        }
        for (field, encoded) in replacements {
            current = ActivityPrivacyProto.replacing(field: field, with: encoded, in: current)
        }
        var outer = ProtobufWriter()
        outer.message(field: top, current)
        return outer.base64
    }
}
