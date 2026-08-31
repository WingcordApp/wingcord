import Foundation
import WingcordCore
import Observation

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
        showsPerformanceInspector = defaults.object(forKey: Key.showsInspector) as? Bool ?? false
        developerMode = defaults.object(forKey: Key.developerMode) as? Bool ?? false
        storedMediaVolume = defaults.object(forKey: Key.mediaVolume) as? Double ?? 1
        mutesMedia = defaults.object(forKey: Key.mutesMedia) as? Bool ?? false
        loopsVideo = defaults.object(forKey: Key.loopsVideo) as? Bool ?? false
        lastGuildID = (defaults.object(forKey: Key.lastGuild) as? NSNumber)?.uint64Value
        lastChannelID = (defaults.object(forKey: Key.lastChannel) as? NSNumber)?.uint64Value
        showsUnreadCounts = defaults.object(forKey: Key.showsUnreadCounts) as? Bool ?? true
        skinTone = (defaults.object(forKey: Key.skinTone) as? Int)
            .flatMap(UnicodeEmoji.SkinTone.init(rawValue:)) ?? .default
        launchDestination = (defaults.object(forKey: Key.launchDestination) as? String)
            .flatMap(LaunchDestination.init(rawValue:)) ?? .lastChannel
        // Last, and after every assignment above: from here on a setter may talk
        // to the rest of the app.
        isLoaded = true
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
        static let showsInspector = "diagnostics.showsPerformanceInspector"
        static let developerMode = "advanced.developerMode"
        static let launchDestination = "startup.launchDestination"
        static let lastGuild = "startup.lastGuildID"
        static let lastChannel = "startup.lastChannelID"
        static let showsUnreadCounts = "notifications.showsUnreadCounts"
        static let skinTone = "expressions.skinTone"
        static let mediaVolume = "media.volume"
        static let mutesMedia = "media.muted"
        static let loopsVideo = "media.loopsVideo"
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
