import Foundation
import Observation
import WingcordCore
import WingcordVoice

/// The user's own preferences.
///
/// **Not `@AppStorage`.** `@AppStorage` inside an `@Observable` class does not
/// trigger view updates — even marked `@ObservationIgnored` — because the two
/// mechanisms track changes in different, unconnected ways. The result is a
/// setting that persists correctly and updates nothing until something else
/// happens to invalidate the view, which reads as a toggle that does not work.
///
/// So: plain stored properties, observed the normal way, persisted in `didSet`.
///
/// **Nothing here assigns to its own property inside its own `didSet`.** The
/// `@Observable` macro rewrites stored properties into computed ones over
/// backing storage, so `x = clamp(x)` in `x`'s `didSet` re-enters the setter and
/// recurses until the stack guard page — an `EXC_BAD_ACCESS` that never appears
/// at launch, because `init` does not run `didSet`, and that kills the process
/// on the first assignment instead. Where a value needs clamping, it is a
/// computed facade over a private stored property.
///
/// **`didSet` RUNS DURING `init`, and reaching for another singleton from one
/// deadlocks the process.** The same macro rewrite is why: an assignment in
/// `init` goes through the generated setter, so every `didSet` here fires while
/// `AppSettings.shared`'s one-time initialisation is still in flight. A `didSet`
/// that then touches `PresentationRevision.shared` — whose own `init` reads
/// `AppSettings.shared` back — waits on a `dispatch_once` token this very frame
/// is holding, and the app hangs at launch with `EXC_BREAKPOINT` inside
/// `_dispatch_once_wait`.
///
/// It is invisible until a stored value differs from its declared default,
/// because the `guard newValue != oldValue` in each setter returns first. A
/// reader who had once moved the text slider crashed on every subsequent launch;
/// a reader who never touched it never saw it.
///
/// `isLoaded` is the guard. Nothing that escapes this type may happen until the
/// initialiser has returned.
@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    /// False until `init` has finished. See the note above.
    ///
    /// `@ObservationIgnored` because nothing observes it and a tracked read
    /// inside every setter would register dependencies on it across the app.
    @ObservationIgnored private var isLoaded = false

    // MARK: Appearance

    /// Extra scale applied on top of the system text size.
    ///
    /// A computed facade over private storage, because it is clamped — see the
    /// note above for why clamping in `didSet` is a crash rather than a clamp.
    var textScale: Double {
        get { storedTextScale }
        set { storedTextScale = min(1.6, max(0.8, newValue)) }
    }

    private var storedTextScale: Double = 1.0 {
        didSet {
            guard storedTextScale != oldValue else { return }
            defaults.set(storedTextScale, forKey: Key.textScale)
            // The drawn surfaces laid their rows out against the previous size,
            // and nothing about the messages changed — so this counter is the
            // only thing that can tell them to re-measure.
            notifyPresentation()
        }
    }

    /// How much of its saturation colour that came from a PERSON keeps.
    ///
    /// A role's colour, a profile's theme, a name tinted by seniority. The app's
    /// own chrome is achromatic by design and is deliberately out of scope —
    /// this turns down the part of the window nobody can art-direct.
    ///
    /// **An accessibility setting, not a taste one.** Saturated colour is
    /// fatiguing or painful for readers with visual stress, migraine sensitivity
    /// or some low-vision conditions, and a client cannot stop anyone choosing
    /// neon magenta for a role. Discord ships the same multiplier; macOS has no
    /// system signal for it, which is why this is a preference here rather than
    /// something resolved from the system like Reduce Motion.
    ///
    /// 1 is off and is the default, and `UserColor` returns its input untouched
    /// there — so the overwhelmingly common case costs no arithmetic at all.
    var userColorSaturation: Double {
        get { storedUserColorSaturation }
        set { storedUserColorSaturation = min(1, max(0, newValue)) }
    }

    private var storedUserColorSaturation: Double = 1 {
        didSet {
            guard storedUserColorSaturation != oldValue else { return }
            defaults.set(storedUserColorSaturation, forKey: Key.userColorSaturation)
            // The transcript's author names are drawn, and their colours are
            // baked into a laid-out row — so the canvas has to be told to
            // re-measure. The roster reaches its own memo through
            // `RosterMemoKey`, which carries this value for the same reason.
            notifyPresentation()
        }
    }

    /// The skin tone the emoji picker applies to every emoji that takes one.
    ///
    /// Stored as the modifier's index rather than the glyph: the table is
    /// generated and the enum is the thing both ends agree on, so a defaults
    /// entry written by an older build cannot decode into a tone that no longer
    /// exists — it falls back to the default.
    var skinTone: UnicodeEmoji.SkinTone = .default {
        didSet { defaults.set(skinTone.rawValue, forKey: Key.skinTone) }
    }

    /// Compact mode: tighter runs.
    ///
    /// Density, not size — the reader chose a text size and this must not quietly
    /// override it. Halves the gap above a run and drops the padding below one,
    /// which on a busy channel is about a screen and a half of recovered height.
    var isCompactMode = false {
        didSet {
            guard isCompactMode != oldValue else { return }
            defaults.set(isCompactMode, forKey: Key.compactMode)
            notifyPresentation()
        }
    }

    /// Whether the member list is shown by default in a new guild.
    var showsMemberListByDefault = true {
        didSet { defaults.set(showsMemberListByDefault, forKey: Key.showsMemberList) }
    }

    /// The shortcut that brings Wingcord forward from anywhere on the machine.
    ///
    /// Optional, and nil is a real value: a global shortcut is registered with
    /// the whole system, so a reader who does not want one must be able to give
    /// the combination back to the other applications on the machine. `⌫` in the
    /// recorder is how they do it.
    ///
    /// **The registration does not happen here during `init`.** Reaching for
    /// another singleton from a `didSet` is the deadlock written up at the top of
    /// this file — `isLoaded` is the guard, and `GlobalHotkey` is installed by
    /// the app root once the store has finished loading.
    var globalHotkey: Hotkey? = .default {
        didSet {
            guard globalHotkey != oldValue else { return }
            defaults.set(globalHotkey?.storageValue ?? Self.noHotkey, forKey: Key.globalHotkey)
            guard isLoaded else { return }
            GlobalHotkey.shared.register(globalHotkey)
        }
    }

    /// What a *deliberately cleared* hotkey looks like in defaults.
    ///
    /// A sentinel rather than removing the key, because absence already means
    /// something else here: it means this install has never been asked, and that
    /// one gets the default binding.
    private static let noHotkey = -1

    // MARK: Startup

    /// Where the window opens.
    ///
    /// Stored as the case name rather than an ordinal, so reordering the enum
    /// cannot silently change what an existing preference means.
    var launchDestination: LaunchDestination = .lastChannel {
        didSet { defaults.set(launchDestination.rawValue, forKey: Key.launchDestination) }
    }

    /// The conversation the window was showing when it last closed.
    ///
    /// Written on every selection and read once, at bootstrap, by
    /// `restoreNavigation()`. Two scalars rather than a codable pair: they are
    /// snowflakes, they are written on a navigation, and a JSON round trip per
    /// click to store sixteen bytes would be the expensive way to do it.
    private(set) var lastGuildID: UInt64?
    private(set) var lastChannelID: UInt64?

    /// Records where the reader is. Cheap enough to call on every navigation:
    /// it writes only when the pair actually moved.
    func rememberConversation(guildID: UInt64?, channelID: UInt64?) {
        guard guildID != lastGuildID || channelID != lastChannelID else { return }
        lastGuildID = guildID
        lastChannelID = channelID
        defaults.set(guildID.map(NSNumber.init(value:)), forKey: Key.lastGuild)
        defaults.set(channelID.map(NSNumber.init(value:)), forKey: Key.lastChannel)
    }

    // MARK: Notifications

    /// Whether the rail and the Dock carry unread counts.
    ///
    /// The DOT survives either way — a reader who turned counts off still wants
    /// to know a server has something new. What they turned off is the number.
    var showsUnreadCounts = true {
        didSet {
            guard showsUnreadCounts != oldValue else { return }
            defaults.set(showsUnreadCounts, forKey: Key.showsUnreadCounts)
        }
    }

    /// Whether the app posts system notifications at all.
    ///
    /// **The reader's own switch, on top of macOS's.** They are two different
    /// questions and both have to be yes: System Settings decides whether this
    /// app may ever interrupt, and this decides whether it wants to. A client
    /// with only the first makes somebody go to System Settings to quieten one
    /// app, and one with only the second lies about what it can do.
    var postsNotifications = true {
        didSet {
            guard postsNotifications != oldValue else { return }
            defaults.set(postsNotifications, forKey: Key.postsNotifications)
        }
    }

    /// Whether those notifications make a sound.
    ///
    /// Its own switch rather than a mode, because the two are genuinely
    /// independent: somebody working beside other people wants the banner and
    /// not the noise, and that is the commonest reason anybody touches this at
    /// all.
    var playsNotificationSound = true {
        didSet {
            guard playsNotificationSound != oldValue else { return }
            defaults.set(playsNotificationSound, forKey: Key.notificationSound)
        }
    }

    /// Whether a message that merely arrives is worth a banner, or only one
    /// addressed to the reader is.
    ///
    /// **A floor under the server's own settings, never a ceiling.** With this
    /// on, a channel the reader has explicitly set to All Messages still only
    /// notifies on a mention — which is the point: it is the one control that
    /// works without going server by server. Off, every per-server choice they
    /// have made on Discord is honoured exactly.
    var notifiesOnlyForMentions = false {
        didSet {
            guard notifiesOnlyForMentions != oldValue else { return }
            defaults.set(notifiesOnlyForMentions, forKey: Key.mentionsOnly)
        }
    }

    // MARK: Chat

    /// 24-hour timestamps regardless of locale.
    ///
    /// Defaulted FROM the locale on first run rather than to `false`, so the
    /// control starts where the reader's region already puts it and only means
    /// something once they move it.
    var uses24HourTime = false {
        didSet {
            guard uses24HourTime != oldValue else { return }
            defaults.set(uses24HourTime, forKey: Key.use24Hour)
            notifyPresentation()
        }
    }

    /// Whether link previews unfurl.
    ///
    /// Off means an embed is never *measured*, not merely never drawn — see
    /// `TimelineSettings`. A card laid out and then hidden costs its framesetting
    /// for nothing.
    var showsEmbeds = true {
        didSet {
            guard showsEmbeds != oldValue else { return }
            defaults.set(showsEmbeds, forKey: Key.showsEmbeds)
            notifyPresentation()
        }
    }

    /// Whether animated emoji, avatars and stickers play.
    ///
    /// Off is a real battery setting, not a preference: an animated decode loop
    /// per visible emoji on a busy channel is continuous work on a laptop that
    /// may be on battery.
    var playsAnimatedContent = true {
        didSet { defaults.set(playsAnimatedContent, forKey: Key.playsAnimated) }
    }

    /// Whether media loads at all on a metered connection.
    var loadsImagesAutomatically = true {
        didSet { defaults.set(loadsImagesAutomatically, forKey: Key.loadsImages) }
    }

    /// The identity bar's silhouette. See `ChromeShape`.
    ///
    /// **Its own preference, separate from the composer's.** The two bars are
    /// the same kind of object but they are not the same object: one is a fixed
    /// 46-point capsule at the foot of a column, the other grows with what is
    /// typed into it, and a pill reads differently on each. One setting for both
    /// forced a choice nobody made.
    var nowBarShape: ChromeShape = .boxy {
        didSet { defaults.set(nowBarShape.rawValue, forKey: Key.nowBarShape) }
    }

    /// The composer's silhouette.
    var composerShape: ChromeShape = .boxy {
        didSet { defaults.set(composerShape.rawValue, forKey: Key.composerShape) }
    }

    /// Whether the now bar wears the reader's own nameplate.
    ///
    /// A preference rather than always-on: a nameplate is artwork behind the
    /// one control that is always on screen, and somebody who bought a loud one
    /// may still want a quiet sidebar.
    var showsNameplateInNowBar = true {
        didSet { defaults.set(showsNameplateInNowBar, forKey: Key.nowBarNameplate) }
    }

    // MARK: Media

    /// The viewer's playback volume, shared by every clip.
    ///
    /// A computed facade over private storage, because it is clamped — see the
    /// note at the top for why clamping in `didSet` is a crash rather than a
    /// clamp.
    var mediaVolume: Double {
        get { storedMediaVolume }
        set { storedMediaVolume = min(1, max(0, newValue)) }
    }

    private var storedMediaVolume: Double = 1 {
        didSet {
            guard storedMediaVolume != oldValue else { return }
            defaults.set(storedMediaVolume, forKey: Key.mediaVolume)
        }
    }

    /// Whether the viewer starts a clip silent. Kept apart from a zero volume:
    /// unmuting has to restore the level that was set, and a mute written as
    /// `volume = 0` has thrown that away.
    var mutesMedia = false {
        didSet { defaults.set(mutesMedia, forKey: Key.mutesMedia) }
    }

    /// Whether a video repeats when it reaches the end.
    var loopsVideo = false {
        didSet { defaults.set(loopsVideo, forKey: Key.loopsVideo) }
    }

    // MARK: Voice and video
    //
    // Devices are stored by their **manufacturer id**, never by the numeric
    // `AudioDeviceID`. The number is assigned at enumeration time and changes
    // when a device is unplugged, when the machine reboots, and when an
    // aggregate device is rebuilt — so a preference stored as a number points
    // at a different microphone by the following Tuesday.
    //
    // Nil in all three cases means "whatever the system is using", which is
    // what somebody who has never opened this pane wants and what a reader whose
    // headset has gone away must fall back to.

    var voiceInputDeviceID: String? {
        didSet {
            guard voiceInputDeviceID != oldValue else { return }
            defaults.set(voiceInputDeviceID, forKey: Key.voiceInput)
        }
    }

    var voiceOutputDeviceID: String? {
        didSet {
            guard voiceOutputDeviceID != oldValue else { return }
            defaults.set(voiceOutputDeviceID, forKey: Key.voiceOutput)
        }
    }

    var cameraDeviceID: String? {
        didSet {
            guard cameraDeviceID != oldValue else { return }
            defaults.set(cameraDeviceID, forKey: Key.camera)
        }
    }

    /// 0…2, applied to the captured signal before it is encoded. Above 1 is
    /// real gain rather than a label: a quiet lavalier needs it, and the voice
    /// processor's own AGC cannot lift a signal that never reaches it.
    var voiceInputVolume: Double {
        get { storedVoiceInputVolume }
        set { storedVoiceInputVolume = min(2, max(0, newValue)) }
    }

    private var storedVoiceInputVolume: Double = 1 {
        didSet {
            guard storedVoiceInputVolume != oldValue else { return }
            defaults.set(storedVoiceInputVolume, forKey: Key.voiceInputVolume)
        }
    }

    var voiceOutputVolume: Double {
        get { storedVoiceOutputVolume }
        set { storedVoiceOutputVolume = min(2, max(0, newValue)) }
    }

    private var storedVoiceOutputVolume: Double = 1 {
        didSet {
            guard storedVoiceOutputVolume != oldValue else { return }
            defaults.set(storedVoiceOutputVolume, forKey: Key.voiceOutputVolume)
        }
    }

    /// How the microphone is gated.
    var inputMode: VoiceInputMode = .voiceActivity {
        didSet {
            guard inputMode != oldValue else { return }
            defaults.set(inputMode.rawValue, forKey: Key.inputMode)
        }
    }

    /// Where voice activity opens the gate, 0…1.
    ///
    /// **Not "sensitivity", which is the same number said backwards.** The meter
    /// beside it draws the level and the threshold on one scale, so the control
    /// reads as a line the level has to cross rather than as an abstract
    /// percentage.
    var voiceActivityThreshold: Double {
        get { storedVoiceThreshold }
        set { storedVoiceThreshold = min(0.5, max(0, newValue)) }
    }

    private var storedVoiceThreshold: Double = 0.03 {
        didSet {
            guard storedVoiceThreshold != oldValue else { return }
            defaults.set(storedVoiceThreshold, forKey: Key.voiceThreshold)
        }
    }

    /// The key held to talk. Nil means push-to-talk has never been bound, and
    /// the mode falls back to voice activity rather than to a microphone that
    /// can never open.
    var pushToTalkKey: Hotkey? {
        didSet {
            guard pushToTalkKey != oldValue else { return }
            defaults.set(pushToTalkKey?.storageValue ?? Self.noHotkey, forKey: Key.pushToTalk)
        }
    }

    /// What the camera sends. 720p at 30 is the shape a channel's bitrate
    /// actually supports; the pane offers 480 and 1080 either side of it.
    var videoQuality: VideoQuality = .high {
        didSet {
            guard videoQuality != oldValue else { return }
            defaults.set(videoQuality.rawValue, forKey: Key.videoQuality)
        }
    }

    var videoWidth: Int { videoQuality.width }
    var videoHeight: Int { videoQuality.height }
    var videoFramerate: Int { videoQuality.framerate }

    /// Whether a call makes a sound when something happens in it.
    ///
    /// **One switch, not fourteen.** Discord offers a row per sound and it is a
    /// pane of toggles nobody reads; the honest question is "do you want the
    /// app to make noises", and somebody who wants only *some* of them wants
    /// something this app cannot spell in a settings window either way.
    var playsCallSounds = true {
        didSet {
            guard playsCallSounds != oldValue else { return }
            defaults.set(playsCallSounds, forKey: Key.callSounds)
        }
    }

    /// Whether a screen share carries the shared application's sound.
    var sharesSystemAudio = true {
        didSet {
            guard sharesSystemAudio != oldValue else { return }
            defaults.set(sharesSystemAudio, forKey: Key.sharesAudio)
        }
    }

    /// The input mode as the engine wants it, with the threshold folded in.
    ///
    /// One place, because the two halves have to agree: a push-to-talk mode with
    /// no key bound is a microphone that can never open, and resolving that here
    /// means no caller has to remember it.
    var resolvedInputMode: VoiceEngine.InputMode {
        switch inputMode {
        case .voiceActivity: .voiceActivity(threshold: Float(voiceActivityThreshold))
        case .pushToTalk:
            pushToTalkKey == nil
                ? .voiceActivity(threshold: Float(voiceActivityThreshold))
                : .pushToTalk
        }
    }

    // MARK: Advanced

    /// Whether ids are offered on the surfaces that have one.
    ///
    /// **A toggle, not a build flag.** Copying a snowflake is what anybody
    /// writing a bot or filing a bug needs and what nobody else ever wants, so
    /// the items are absent rather than disabled — a menu whose last third is
    /// greyed out for every reader who is not a developer is a menu a third
    /// longer for no one's benefit.
    var developerMode = false {
        didSet { defaults.set(developerMode, forKey: Key.developerMode) }
    }

    // MARK: Diagnostics

    /// Shows the performance inspector overlay.
    var showsPerformanceInspector = false {
        didSet { defaults.set(showsPerformanceInspector, forKey: Key.showsInspector) }
    }

    /// Tells the drawn surfaces to re-measure — unless the initialiser is still
    /// running, in which case there is nothing laid out yet to invalidate and
    /// the call would deadlock. See the note at the top.
    private func notifyPresentation() {
        guard isLoaded else { return }
        PresentationRevision.shared.settingsDidChange()
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Read through `object(forKey:)` rather than `bool(forKey:)`: the
        // typed accessors return `false` for a key that was never written, which
        // is indistinguishable from a deliberate `false` and silently overrides
        // every default that should be `true`.
        storedTextScale = defaults.object(forKey: Key.textScale) as? Double ?? 1.0
        storedUserColorSaturation =
            defaults.object(forKey: Key.userColorSaturation) as? Double ?? 1
        isCompactMode = defaults.object(forKey: Key.compactMode) as? Bool ?? false
        showsMemberListByDefault = defaults.object(forKey: Key.showsMemberList) as? Bool ?? true
        globalHotkey = (defaults.object(forKey: Key.globalHotkey) as? Int)
            .map { $0 == Self.noHotkey ? nil : Hotkey(storageValue: $0) } ?? Hotkey.default
        uses24HourTime = defaults.object(forKey: Key.use24Hour) as? Bool
            ?? Locale.current.usesTwentyFourHourClock
        showsEmbeds = defaults.object(forKey: Key.showsEmbeds) as? Bool ?? true
        playsAnimatedContent = defaults.object(forKey: Key.playsAnimated) as? Bool ?? true
        loadsImagesAutomatically = defaults.object(forKey: Key.loadsImages) as? Bool ?? true
        nowBarShape = (defaults.object(forKey: Key.nowBarShape) as? String)
            .flatMap(ChromeShape.init(rawValue:)) ?? .boxy
        composerShape = (defaults.object(forKey: Key.composerShape) as? String)
            .flatMap(ChromeShape.init(rawValue:)) ?? .boxy
        showsNameplateInNowBar = defaults.object(forKey: Key.nowBarNameplate) as? Bool ?? true
        showsPerformanceInspector = defaults.object(forKey: Key.showsInspector) as? Bool ?? false
        developerMode = defaults.object(forKey: Key.developerMode) as? Bool ?? false
        storedMediaVolume = defaults.object(forKey: Key.mediaVolume) as? Double ?? 1
        voiceInputDeviceID = defaults.object(forKey: Key.voiceInput) as? String
        voiceOutputDeviceID = defaults.object(forKey: Key.voiceOutput) as? String
        cameraDeviceID = defaults.object(forKey: Key.camera) as? String
        storedVoiceInputVolume = defaults.object(forKey: Key.voiceInputVolume) as? Double ?? 1
        storedVoiceOutputVolume = defaults.object(forKey: Key.voiceOutputVolume) as? Double ?? 1
        storedVoiceThreshold = defaults.object(forKey: Key.voiceThreshold) as? Double ?? 0.03
        inputMode = (defaults.object(forKey: Key.inputMode) as? String)
            .flatMap(VoiceInputMode.init(rawValue:)) ?? .voiceActivity
        pushToTalkKey = (defaults.object(forKey: Key.pushToTalk) as? Int)
            .flatMap { $0 == Self.noHotkey ? nil : Hotkey(storageValue: $0) }
        videoQuality = (defaults.object(forKey: Key.videoQuality) as? String)
            .flatMap(VideoQuality.init(rawValue:)) ?? .high
        sharesSystemAudio = defaults.object(forKey: Key.sharesAudio) as? Bool ?? true
        playsCallSounds = defaults.object(forKey: Key.callSounds) as? Bool ?? true
        mutesMedia = defaults.object(forKey: Key.mutesMedia) as? Bool ?? false
        loopsVideo = defaults.object(forKey: Key.loopsVideo) as? Bool ?? false
        lastGuildID = (defaults.object(forKey: Key.lastGuild) as? NSNumber)?.uint64Value
        lastChannelID = (defaults.object(forKey: Key.lastChannel) as? NSNumber)?.uint64Value
        showsUnreadCounts = defaults.object(forKey: Key.showsUnreadCounts) as? Bool ?? true
        postsNotifications = defaults.object(forKey: Key.postsNotifications) as? Bool ?? true
        playsNotificationSound = defaults.object(forKey: Key.notificationSound) as? Bool ?? true
        notifiesOnlyForMentions = defaults.object(forKey: Key.mentionsOnly) as? Bool ?? false
        skinTone = (defaults.object(forKey: Key.skinTone) as? Int)
            .flatMap(UnicodeEmoji.SkinTone.init(rawValue:)) ?? .default
        launchDestination = (defaults.object(forKey: Key.launchDestination) as? String)
            .flatMap(LaunchDestination.init(rawValue:)) ?? .lastChannel
        // Last, and after every assignment above: from here on a setter may talk
        // to the rest of the app.
        isLoaded = true
    }

    /// How the microphone is gated.
    enum VoiceInputMode: String, CaseIterable, Hashable, Sendable {
        case voiceActivity
        case pushToTalk
    }

    /// What the camera sends.
    ///
    /// Three rungs rather than a free resolution: the encoder's dimensions are
    /// fixed at session creation, so every distinct pair is a session that has
    /// to be rebuilt, and a slider over them would rebuild it per pixel.
    enum VideoQuality: String, CaseIterable, Hashable, Sendable {
        case standard
        case high
        case full

        var width: Int {
            switch self {
            case .standard: 854
            case .high: 1_280
            case .full: 1_920
            }
        }

        var height: Int {
            switch self {
            case .standard: 480
            case .high: 720
            case .full: 1_080
            }
        }

        /// **1080 drops to 15.** A channel's video budget is a few megabits;
        /// spending it on twice the pixels at thirty frames leaves neither
        /// sharp, and the reference clients make exactly the same trade.
        var framerate: Int {
            switch self {
            case .standard, .high: 30
            case .full: 15
            }
        }

        /// What the encoder is given and what op 12 announces.
        ///
        /// **It was never set, and the engine's 2 Mbit default stood for every
        /// quality.** 480p at two megabits is twice what it needs and 1080p is
        /// half, so one setting was overspending and another was starving —
        /// neither visibly, because a bitrate is not something a reader can see
        /// being wrong.
        var bitrate: Int {
            switch self {
            case .standard: 1_000_000
            case .high: 2_500_000
            case .full: 4_000_000
            }
        }

        var label: String {
            switch self {
            case .standard: "480p"
            case .high: "720p"
            case .full: "1080p"
            }
        }
    }

    /// Where a cold launch lands.
    ///
    /// Two cases, not three. A third — "ask" — would need a chooser at launch
    /// that this app does not have, and a preference whose behaviour is missing
    /// is worse than a preference that is not offered.
    enum LaunchDestination: String, CaseIterable, Hashable, Sendable {
        /// Back where you were, if it is still there and still readable.
        case lastChannel
        /// The direct-message list.
        case home
    }

    private enum Key {
        static let textScale = "appearance.textScale"
        static let userColorSaturation = "accessibility.userColorSaturation"
        static let compactMode = "appearance.compactMode"
        static let showsMemberList = "appearance.showsMemberList"
        static let globalHotkey = "shortcuts.globalHotkey"
        static let use24Hour = "chat.use24HourTime"
        static let showsEmbeds = "chat.showsEmbeds"
        static let playsAnimated = "chat.playsAnimatedContent"
        static let loadsImages = "chat.loadsImagesAutomatically"
        static let nowBarShape = "appearance.nowBarShape"
        static let composerShape = "appearance.composerShape"
        static let nowBarNameplate = "appearance.nowBarNameplate"
        static let showsInspector = "diagnostics.showsPerformanceInspector"
        static let developerMode = "advanced.developerMode"
        static let launchDestination = "startup.launchDestination"
        static let lastGuild = "startup.lastGuildID"
        static let lastChannel = "startup.lastChannelID"
        static let showsUnreadCounts = "notifications.showsUnreadCounts"
        static let postsNotifications = "notifications.posts"
        static let notificationSound = "notifications.sound"
        static let mentionsOnly = "notifications.mentionsOnly"
        static let skinTone = "expressions.skinTone"
        static let mediaVolume = "media.volume"
        static let mutesMedia = "media.muted"
        static let loopsVideo = "media.loopsVideo"
        static let voiceInput = "voice.inputDevice"
        static let voiceOutput = "voice.outputDevice"
        static let camera = "voice.cameraDevice"
        static let voiceInputVolume = "voice.inputVolume"
        static let voiceOutputVolume = "voice.outputVolume"
        static let inputMode = "voice.inputMode"
        static let voiceThreshold = "voice.activityThreshold"
        static let pushToTalk = "voice.pushToTalkKey"
        static let videoQuality = "voice.videoQuality"
        static let sharesAudio = "voice.sharesSystemAudio"
        static let callSounds = "voice.playsCallSounds"
    }
}

extension Locale {
    /// Whether this locale writes the time as `13:30` rather than `1:30 pm`.
    ///
    /// Read once, to seed `uses24HourTime` on first launch. `hourCycle` is the
    /// locale's own answer; the two twelve-hour cycles differ only in whether
    /// midnight is 0 or 12, which is not a distinction this app makes.
    var usesTwentyFourHourClock: Bool {
        switch hourCycle {
        case .zeroToEleven, .oneToTwelve: false
        default: true
        }
    }
}
