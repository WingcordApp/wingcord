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

    /// Whether a detected game is broadcast as a presence.
    ///
    /// Discord calls this **"Share my activity"**, and on the wire it is
    /// `status.show_current_game` — field 3 of field 11 in
    /// `PreloadedUserSettings`, walked out of a capture 2026-09-14 and written
    /// up in `docs/OVERLAY.md`.
    ///
    /// **Local-only for now, and that is a gap rather than a decision.** This
    /// client does not yet read or write that protobuf field, so the preference
    /// governs what *this* Mac publishes and does not follow the account to
    /// another client. It still reaches the app — see `publishedActivities` —
    /// so it is a setting that does something, which is the bar `INVARIANTS.md`
    /// sets.
    var sharesGameActivity = true {
        didSet {
            guard sharesGameActivity != oldValue else { return }
            defaults.set(sharesGameActivity, forKey: Key.sharesGameActivity)
        }
    }

    // MARK: The overlay, and clips
    /// Games the reader added by hand, because Discord's database does not
    /// know them.
    ///
    /// **Keyed on the executable path**, which is what the detector matches on
    /// and the only thing about a process that is stable across launches. The
    /// id is synthetic — these applications have no Discord snowflake — and is
    /// derived from the path so adding the same thing twice is one entry.
    private(set) var manualGames: [ManualGame] = []

    struct ManualGame: Hashable, Sendable, Codable, Identifiable {
        var name: String
        var path: String
        var id: UInt64
    }

    func addManualGame(name: String, path: String, id: ApplicationID) {
        manualGames.removeAll { $0.path == path }
        manualGames.append(ManualGame(name: name, path: path, id: id.rawValue))
        persistManualGames()
    }

    func removeManualGame(at path: String) {
        manualGames.removeAll { $0.path == path }
        persistManualGames()
    }

    private func persistManualGames() {
        guard let data = try? JSONEncoder().encode(manualGames) else { return }
        defaults.set(data, forKey: Key.manualGames)
    }

    //
    // Everything on this surface is **local to this Mac**. Discord keeps the
    // overlay's own settings out of the account blob too — they describe a
    // machine's windows and its keyboard, not a person — so this is the
    // reference's shape rather than a gap.

    /// Whether the overlay comes up at all when a game is detected.
    var isOverlayEnabled = true {
        didSet { defaults.set(isOverlayEnabled, forKey: Key.overlayEnabled) }
    }

    /// Whether a pinned widget can be clicked while the overlay is asleep.
    ///
    /// **Off by default, and the default is the safe one.** With it on, a
    /// widget sitting over the game swallows any click that lands on it — which
    /// is right for somebody who wants to mute without opening the overlay, and
    /// wrong for somebody whose crosshair happens to be there.
    var overlayHasClickableRegions = false {
        didSet {
            defaults.set(overlayHasClickableRegions, forKey: Key.overlayClickableRegions)
        }
    }

    /// Whether messages appear over the game.
    var overlayShowsNotifications = true {
        didSet { defaults.set(overlayShowsNotifications, forKey: Key.overlayNotifications) }
    }

    /// Which corner the toasts stack in.
    var overlayNotificationCorner: OverlayCorner = .topLeading {
        didSet {
            defaults.set(overlayNotificationCorner.rawValue, forKey: Key.overlayCorner)
        }
    }

    /// When a name is drawn beside a face in the voice widget.
    var overlayVoiceNames: OverlayNameDisplay = .whileSpeaking {
        didSet { defaults.set(overlayVoiceNames.rawValue, forKey: Key.overlayVoiceNames) }
    }

    /// How big those faces are.
    var overlayAvatarSize: OverlayAvatarSize = .small {
        didSet { defaults.set(overlayAvatarSize.rawValue, forKey: Key.overlayAvatarSize) }
    }

    /// How many people the voice widget will draw before it stops.
    ///
    /// A computed facade over private storage, because clamping in a `didSet`
    /// re-enters the setter — see the note at the top of this type.
    var overlayVoiceLimit: Int {
        get { storedOverlayVoiceLimit }
        set {
            let clamped = min(max(newValue, 1), 20)
            guard clamped != storedOverlayVoiceLimit else { return }
            storedOverlayVoiceLimit = clamped
            defaults.set(clamped, forKey: Key.overlayVoiceLimit)
        }
    }

    private var storedOverlayVoiceLimit = 8

    /// Whether the clip key does anything.
    ///
    /// **Off by default.** Clips runs a capture and an encoder for as long as a
    /// game is in front, and arming that without being asked is not a decision
    /// this client gets to make on somebody's behalf.
    var clipsEnabled = false {
        didSet { defaults.set(clipsEnabled, forKey: Key.clipsEnabled) }
    }

    var clipLength: ClipLength = .fifteenSeconds {
        didSet { defaults.set(clipLength.rawValue, forKey: Key.clipLength) }
    }

    var clipResolution: ClipResolution = .p1080 {
        didSet { defaults.set(clipResolution.rawValue, forKey: Key.clipResolution) }
    }

    var clipFrameRate: ClipFrameRate = .fps60 {
        didSet { defaults.set(clipFrameRate.rawValue, forKey: Key.clipFrameRate) }
    }

    /// Where clips are written. Nil means the default, which is resolved
    /// lazily — `~/Movies/Wingcord Clips`, matching where Discord puts its own.
    var clipsFolder: URL? {
        didSet { defaults.set(clipsFolder?.path, forKey: Key.clipsFolder) }
    }

    /// Whether the overlay says so after a clip is taken.
    var clipsShowsFeedback = true {
        didSet { defaults.set(clipsShowsFeedback, forKey: Key.clipsFeedback) }
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
    /// Every global shortcut, by what it does.
    ///
    /// **A table since the overlay arrived**, where it was one binding before.
    /// The value is a double optional on purpose: a missing key means "this
    /// install has never been asked and gets the default", and a present `nil`
    /// means "the reader deliberately cleared it". Collapsing those two is what
    /// makes a cleared binding come back on the next launch.
    ///
    /// Registration happens in `GlobalHotkeyInstaller`, never here — see the
    /// note at the top of this type about `didSet` and `init`.
    var globalHotkeys: [GlobalAction: Hotkey?] = [:] {
        didSet {
            guard globalHotkeys != oldValue else { return }
            for action in GlobalAction.allCases {
                let key = Key.hotkey(action)
                guard let binding = globalHotkeys[action] else {
                    defaults.removeObject(forKey: key)
                    continue
                }
                defaults.set(binding?.storageValue ?? Self.noHotkey, forKey: key)
            }
        }
    }

    /// The binding for one action, resolved through its default.
    func hotkey(for action: GlobalAction) -> Hotkey? {
        globalHotkeys[action] ?? action.defaultHotkey
    }

    func setHotkey(_ hotkey: Hotkey?, for action: GlobalAction) {
        globalHotkeys[action] = .some(hotkey)
    }

    /// The in-window shortcuts the reader has moved.
    ///
    /// **The same double-optional as the table above, for the same reason**: a
    /// missing key is "never asked, take the default" and a present `nil` is
    /// "deliberately cleared". A menu item whose binding was cleared keeps its
    /// row and loses its equivalent, which is what makes clearing one a way of
    /// freeing a combination rather than of hiding a command.
    var appShortcuts: [AppShortcut: Hotkey?] = [:] {
        didSet {
            guard appShortcuts != oldValue else { return }
            for action in AppShortcut.allCases {
                let key = Key.appShortcut(action)
                guard let binding = appShortcuts[action] else {
                    defaults.removeObject(forKey: key)
                    continue
                }
                defaults.set(binding?.storageValue ?? Self.noHotkey, forKey: key)
            }
        }
    }

    func shortcut(for action: AppShortcut) -> Hotkey? {
        appShortcuts[action] ?? action.defaultBinding
    }

    func setShortcut(_ hotkey: Hotkey?, for action: AppShortcut) {
        appShortcuts[action] = .some(hotkey)
    }

    /// Every action a binding would collide with, so a recorder can say so
    /// before the reader has two menu items on one combination.
    ///
    /// **A collision is a real defect and a silent one.** AppKit gives the
    /// combination to whichever item it finds first, so the other command simply
    /// stops working and nothing says why.
    func shortcutConflicts(_ hotkey: Hotkey, ignoring action: AppShortcut) -> [AppShortcut] {
        AppShortcut.allCases.filter { $0 != action && shortcut(for: $0) == hotkey }
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

    /// The silhouette of the app's two floating bars. See `ChromeShape`.
    ///
    /// **One preference for both, restored.** It was split in two for a while on
    /// the argument that a fixed 46-point capsule and a bar that grows with what
    /// is typed into it are different objects. They are not, to look at: they
    /// are the two floating plates at the foot of the window's two columns, they
    /// are seen together, and a window with two opinions about its own shape is
    /// what the split produced. A reader who genuinely wants them different is
    /// asking for something no client offers.
    var chromeShape: ChromeShape = .boxy {
        didSet { defaults.set(chromeShape.rawValue, forKey: Key.chromeShape) }
    }

    /// The order of the four controls at the composer's trailing end.
    ///
    /// A preference because the reader reaches for one of them far more than the
    /// other three and which one that is is theirs to say — Apple's
    /// *flexibility* principle, and the cheapest possible form of it: the row is
    /// four controls wide, so letting somebody drag their own to the end costs a
    /// stored permutation and nothing else. `ComposerControlOrder` normalises
    /// whatever comes back out of the defaults, so a build that adds or removes
    /// a control needs no migration here.
    var composerControls: ComposerControlOrder = .default {
        didSet { defaults.set(composerControls.storage, forKey: Key.composerControls) }
    }

    /// Extra space between message runs, in points, on top of the density the
    /// segmented control above it sets.
    ///
    /// **A slider AND a segmented control, because they answer different
    /// questions.** Compact is a *shape* — it also closes the run's bottom
    /// padding and shrinks the author gutter — and this is the air between one
    /// person's block and the next. Discord ships both for the same reason.
    var messageGroupSpacing: Double {
        get { storedGroupSpacing }
        set { storedGroupSpacing = min(24, max(0, newValue)) }
    }

    /// Clamped, so it is a computed facade over private storage — see the note
    /// at the top of this type about why clamping in `didSet` is a crash.
    private var storedGroupSpacing: Double = 0 {
        didSet {
            guard storedGroupSpacing != oldValue else { return }
            defaults.set(storedGroupSpacing, forKey: Key.groupSpacing)
            notifyPresentation()
        }
    }

    /// Whether a timestamp carries seconds.
    var showsSeconds = false {
        didSet {
            guard showsSeconds != oldValue else { return }
            defaults.set(showsSeconds, forKey: Key.showsSeconds)
            notifyPresentation()
        }
    }

    /// Whether every message shows its time, or only the one under the pointer.
    ///
    /// **Off is not "no timestamps"** — the first message of a run always
    /// carries one beside the author's name. This is the *gutter* time on a
    /// continuation row, which appears on hover, and turning it on makes the
    /// column of times permanent.
    var alwaysShowsTimestamps = false {
        didSet {
            guard alwaysShowsTimestamps != oldValue else { return }
            defaults.set(alwaysShowsTimestamps, forKey: Key.alwaysShowsTimestamps)
            notifyPresentation()
        }
    }

    /// The cosmetics this reader has asked not to see.
    ///
    /// **One stored set rather than six booleans.** It is the memo key for the
    /// filtered decorations — see `AppModel.cosmetics(of:)` — and a set compares
    /// in one word where six properties are six reads on every row.
    var suppressedCosmetics: CosmeticSuppression = [] {
        didSet {
            guard suppressedCosmetics != oldValue else { return }
            defaults.set(Int(suppressedCosmetics.rawValue), forKey: Key.suppressedCosmetics)
            notifyPresentation()
        }
    }

    /// Whether the suppression above applies to the reader's OWN cosmetics too.
    ///
    /// **Off by default, and that asymmetry is the point.** Somebody who turns
    /// nameplates off is usually saying "stop other people's decorations
    /// shouting at me", not "take the thing I bought off my own name". Discord
    /// draws the same distinction.
    var suppressesOwnCosmetics = false {
        didSet {
            guard suppressesOwnCosmetics != oldValue else { return }
            defaults.set(suppressesOwnCosmetics, forKey: Key.suppressesOwnCosmetics)
            notifyPresentation()
        }
    }

    /// Whether every link is underlined, or only the ones under the pointer.
    var underlinesLinks = false {
        didSet {
            guard underlinesLinks != oldValue else { return }
            defaults.set(underlinesLinks, forKey: Key.underlinesLinks)
            notifyPresentation()
        }
    }

    /// Where a role's colour is allowed to land.
    var roleColorPlacement: RoleColorPlacement = .inNames {
        didSet {
            guard roleColorPlacement != oldValue else { return }
            defaults.set(roleColorPlacement.rawValue, forKey: Key.roleColorPlacement)
            notifyPresentation()
        }
    }

    /// What VoiceOver is told about a message beyond its words.
    ///
    /// **A set, for the reason the cosmetics are one**, and an *opt-out* set:
    /// everything is spoken unless it is in here, so a build that adds a detail
    /// speaks it for everybody rather than silently leaving it out of a stored
    /// list nobody will go back and tick.
    var mutedSpokenDetails: SpokenDetail.Set = [] {
        didSet {
            guard mutedSpokenDetails != oldValue else { return }
            defaults.set(Int(mutedSpokenDetails.rawValue), forKey: Key.mutedSpokenDetails)
        }
    }

    /// Whether VoiceOver is interrupted when a message arrives in the channel
    /// being read.
    ///
    /// **Off by default.** An announcement per message in a busy channel makes
    /// the app unusable with a screen reader, which is the opposite of what the
    /// pane is for.
    var announcesNewMessages = false {
        didSet {
            guard announcesNewMessages != oldValue else { return }
            defaults.set(announcesNewMessages, forKey: Key.announcesNewMessages)
        }
    }

    /// Whether the now bar wears the reader's own nameplate.
    ///
    /// A preference rather than always-on: a nameplate is artwork behind the
    /// one control that is always on screen, and somebody who bought a loud one
    /// may still want a quiet sidebar.
    var showsNameplateInNowBar = true {
        didSet { defaults.set(showsNameplateInNowBar, forKey: Key.nowBarNameplate) }
    }

    /// Whether a channel's summaries bar is shown — the toolbar's Hide / Show
    /// Summaries.
    ///
    /// **One switch for every channel, kept on this Mac**, as Discord keeps
    /// it: its summary store persists `shouldShowTopicsBar` locally (module
    /// `822074`) and syncs nothing. On by default, as Discord's is.
    var showsSummaryBar = true {
        didSet {
            guard showsSummaryBar != oldValue else { return }
            defaults.set(showsSummaryBar, forKey: Key.showsSummaryBar)
        }
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
        sharesGameActivity = defaults.object(forKey: Key.sharesGameActivity) as? Bool ?? true
        isOverlayEnabled = defaults.object(forKey: Key.overlayEnabled) as? Bool ?? true
        overlayHasClickableRegions =
            defaults.object(forKey: Key.overlayClickableRegions) as? Bool ?? false
        overlayShowsNotifications =
            defaults.object(forKey: Key.overlayNotifications) as? Bool ?? true
        overlayNotificationCorner = (defaults.string(forKey: Key.overlayCorner))
            .flatMap(OverlayCorner.init(rawValue:)) ?? .topLeading
        overlayVoiceNames = (defaults.string(forKey: Key.overlayVoiceNames))
            .flatMap(OverlayNameDisplay.init(rawValue:)) ?? .whileSpeaking
        overlayAvatarSize = (defaults.string(forKey: Key.overlayAvatarSize))
            .flatMap(OverlayAvatarSize.init(rawValue:)) ?? .small
        storedOverlayVoiceLimit =
            min(max(defaults.object(forKey: Key.overlayVoiceLimit) as? Int ?? 8, 1), 20)
        clipsEnabled = defaults.object(forKey: Key.clipsEnabled) as? Bool ?? false
        clipLength = (defaults.string(forKey: Key.clipLength))
            .flatMap(ClipLength.init(rawValue:)) ?? .fifteenSeconds
        clipResolution = (defaults.string(forKey: Key.clipResolution))
            .flatMap(ClipResolution.init(rawValue:)) ?? .p1080
        clipFrameRate = (defaults.string(forKey: Key.clipFrameRate))
            .flatMap(ClipFrameRate.init(rawValue:)) ?? .fps60
        clipsFolder = (defaults.string(forKey: Key.clipsFolder)).map { URL(fileURLWithPath: $0) }
        clipsShowsFeedback = defaults.object(forKey: Key.clipsFeedback) as? Bool ?? true
        manualGames = (defaults.data(forKey: Key.manualGames))
            .flatMap { try? JSONDecoder().decode([ManualGame].self, from: $0) } ?? []
        var table: [GlobalAction: Hotkey?] = [:]
        for action in GlobalAction.allCases {
            guard let stored = defaults.object(forKey: Key.hotkey(action)) as? Int else {
                continue
            }
            table[action] = stored == Self.noHotkey ? .some(nil) : .some(Hotkey(storageValue: stored))
        }
        globalHotkeys = table

        var shortcuts: [AppShortcut: Hotkey?] = [:]
        for action in AppShortcut.allCases {
            guard let stored = defaults.object(forKey: Key.appShortcut(action)) as? Int else {
                continue
            }
            shortcuts[action] = stored == Self.noHotkey
                ? .some(nil)
                : .some(Hotkey(storageValue: stored))
        }
        appShortcuts = shortcuts
        uses24HourTime = defaults.object(forKey: Key.use24Hour) as? Bool
            ?? Locale.current.usesTwentyFourHourClock
        showsEmbeds = defaults.object(forKey: Key.showsEmbeds) as? Bool ?? true
        playsAnimatedContent = defaults.object(forKey: Key.playsAnimated) as? Bool ?? true
        loadsImagesAutomatically = defaults.object(forKey: Key.loadsImages) as? Bool ?? true
        // The composer's old key is the migration: it is the bar the reader
        // looked at while choosing, so where the two disagreed it is the answer
        // they meant. Read once, never written again.
        chromeShape = (defaults.object(forKey: Key.chromeShape) as? String)
            .flatMap(ChromeShape.init(rawValue:))
            ?? (defaults.object(forKey: Key.legacyComposerShape) as? String)
            .flatMap(ChromeShape.init(rawValue:))
            ?? .boxy
        composerControls = defaults.stringArray(forKey: Key.composerControls)
            .map(ComposerControlOrder.init(storage:)) ?? .default
        showsNameplateInNowBar = defaults.object(forKey: Key.nowBarNameplate) as? Bool ?? true
        showsSummaryBar = defaults.object(forKey: Key.showsSummaryBar) as? Bool ?? true
        suppressedCosmetics = CosmeticSuppression(
            rawValue: UInt8(truncatingIfNeeded:
                defaults.object(forKey: Key.suppressedCosmetics) as? Int ?? 0)
        )
        suppressesOwnCosmetics =
            defaults.object(forKey: Key.suppressesOwnCosmetics) as? Bool ?? false
        underlinesLinks = defaults.object(forKey: Key.underlinesLinks) as? Bool ?? false
        roleColorPlacement = (defaults.object(forKey: Key.roleColorPlacement) as? String)
            .flatMap(RoleColorPlacement.init(rawValue:)) ?? .inNames
        mutedSpokenDetails = SpokenDetail.Set(
            rawValue: UInt8(truncatingIfNeeded:
                defaults.object(forKey: Key.mutedSpokenDetails) as? Int ?? 0)
        )
        announcesNewMessages =
            defaults.object(forKey: Key.announcesNewMessages) as? Bool ?? false
        storedGroupSpacing = defaults.object(forKey: Key.groupSpacing) as? Double ?? 0
        showsSeconds = defaults.object(forKey: Key.showsSeconds) as? Bool ?? false
        alwaysShowsTimestamps = defaults.object(forKey: Key.alwaysShowsTimestamps) as? Bool
            ?? false
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
        static let sharesGameActivity = "activity.sharesGameActivity"
        static let overlayEnabled = "overlay.enabled"
        static let overlayClickableRegions = "overlay.clickableRegions"
        static let overlayNotifications = "overlay.notifications"
        static let overlayCorner = "overlay.notificationCorner"
        static let overlayVoiceNames = "overlay.voiceNames"
        static let overlayAvatarSize = "overlay.avatarSize"
        static let overlayVoiceLimit = "overlay.voiceLimit"
        static let clipsEnabled = "clips.enabled"
        static let clipLength = "clips.length"
        static let clipResolution = "clips.resolution"
        static let clipFrameRate = "clips.frameRate"
        static let clipsFolder = "clips.folder"
        static let clipsFeedback = "clips.feedback"
        static let manualGames = "activity.manualGames"
        /// Where the window's binding lived before the table. Read once, for
        /// migration, and never written again.
        static let legacyGlobalHotkey = "shortcuts.globalHotkey"
        static func hotkey(_ action: GlobalAction) -> String {
            "shortcuts.hotkey.\(action.rawValue)"
        }
        static func appShortcut(_ action: AppShortcut) -> String {
            "shortcuts.app.\(action.rawValue)"
        }
        static let use24Hour = "chat.use24HourTime"
        static let showsEmbeds = "chat.showsEmbeds"
        static let playsAnimated = "chat.playsAnimatedContent"
        static let loadsImages = "chat.loadsImagesAutomatically"
        static let chromeShape = "appearance.chromeShape"
        /// Where the composer's own shape lived before the two bars shared one.
        /// Read once, for migration, and never written again.
        static let legacyComposerShape = "appearance.composerShape"
        static let composerControls = "appearance.composerControls"
        static let nowBarNameplate = "appearance.nowBarNameplate"
        static let showsSummaryBar = "chat.showsSummaryBar"
        static let suppressedCosmetics = "accessibility.suppressedCosmetics"
        static let suppressesOwnCosmetics = "accessibility.suppressesOwnCosmetics"
        static let underlinesLinks = "accessibility.underlinesLinks"
        static let roleColorPlacement = "accessibility.roleColorPlacement"
        static let mutedSpokenDetails = "accessibility.mutedSpokenDetails"
        static let announcesNewMessages = "accessibility.announcesNewMessages"
        static let groupSpacing = "appearance.messageGroupSpacing"
        static let showsSeconds = "chat.showsSeconds"
        static let alwaysShowsTimestamps = "chat.alwaysShowsTimestamps"
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
