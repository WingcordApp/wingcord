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

    /// The conversation in bubbles: the reader's messages on the trailing
    /// side in the accent, everyone else's on the leading side — the way
    /// Messages draws one. Discord has no such mode, so this is the app's own.
    ///
    /// **Layout, not paint**: every row changes shape, so it reaches the
    /// transcript through `TimelineSettings` and moves the revision.
    var usesMessageBubbles = true {
        didSet {
            guard usesMessageBubbles != oldValue else { return }
            defaults.set(usesMessageBubbles, forKey: Key.messageBubbles)
            notifyPresentation()
        }
    }

    /// Whether the reader's own bubbles wear the accent. Off by default: in the
    /// redesign both sides are frosted glass over the background, the reader's a
    /// step lighter (REDESIGN.md R6). Layout, because the words on an accent
    /// bubble are set white at layout time.
    var tintsOwnBubbles = false {
        didSet {
            guard tintsOwnBubbles != oldValue else { return }
            defaults.set(tintsOwnBubbles, forKey: Key.tintsOwnBubbles)
            notifyPresentation()
        }
    }

    /// Whether a message that says happy birthday, congratulations or happy
    /// new year celebrates on screen as it arrives (REDESIGN.md R14) — the
    /// Messages app's screen effects, drawn on this Mac only: nothing is sent,
    /// and nobody else's client shows them. Reduce Motion turns them off
    /// whatever this says.
    var playsScreenEffects = true {
        didSet { defaults.set(playsScreenEffects, forKey: Key.screenEffects) }
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

    // MARK: Focus

    /// What the status becomes while a macOS Focus asks for "Wingcord's Focus
    /// status" — the value a Focus filter set to that choice applies. Local to
    /// this Mac, as the Focus that drives it is.
    var focusStatus: PresenceStatus = .doNotDisturb {
        didSet {
            guard focusStatus != oldValue else { return }
            defaults.set(focusStatus.rawValue, forKey: Key.focusStatus)
        }
    }

    /// The custom status worn alongside it, if any.
    var focusCustomStatus: CustomStatus? {
        didSet {
            guard focusCustomStatus != oldValue else { return }
            defaults.set(try? JSONEncoder().encode(focusCustomStatus), forKey: Key.focusCustomStatus)
        }
    }

    /// Whether the end of a Focus puts back what it changed.
    var focusRestores = true {
        didSet {
            guard focusRestores != oldValue else { return }
            defaults.set(focusRestores, forKey: Key.focusRestores)
        }
    }

    // MARK: Now Playing

    /// Whether what macOS says is playing is shared — "Listening to Apple
    /// Music", "Watching YouTube" (docs/CLIPS-PRESENCE.md, D4–D7). It rides
    /// "Share my activity" as well.
    ///
    /// **Off until the reader turns it on**: an update must not start telling
    /// everyone what they watch.
    var sharesNowPlaying = false {
        didSet {
            guard sharesNowPlaying != oldValue else { return }
            defaults.set(sharesNowPlaying, forKey: Key.sharesNowPlaying)
        }
    }

    /// Each player's own switch, by `MediaPlayer.id`, where the reader set one;
    /// a player missing here takes its catalogue default.
    var nowPlayingPlayers: [String: Bool] = [:] {
        didSet {
            guard nowPlayingPlayers != oldValue else { return }
            defaults.set(nowPlayingPlayers, forKey: Key.nowPlayingPlayers)
        }
    }

    var nowPlayingShowsWhilePaused = false {
        didSet {
            guard nowPlayingShowsWhilePaused != oldValue else { return }
            defaults.set(nowPlayingShowsWhilePaused, forKey: Key.nowPlayingShowsWhilePaused)
        }
    }

    /// A YouTube video's own thumbnail as the picture, rather than YouTube's logo.
    var nowPlayingShowsThumbnails = true {
        didSet {
            guard nowPlayingShowsThumbnails != oldValue else { return }
            defaults.set(nowPlayingShowsThumbnails, forKey: Key.nowPlayingShowsThumbnails)
        }
    }

    /// Watch Video, View Channel, Listen Along.
    var nowPlayingShowsButtons = true {
        didSet {
            guard nowPlayingShowsButtons != oldValue else { return }
            defaults.set(nowPlayingShowsButtons, forKey: Key.nowPlayingShowsButtons)
        }
    }

    /// "by <artist>" rather than the bare name.
    var nowPlayingPrefixesBy = true {
        didSet {
            guard nowPlayingPrefixesBy != oldValue else { return }
            defaults.set(nowPlayingPrefixesBy, forKey: Key.nowPlayingPrefixesBy)
        }
    }

    /// Which line a member list shows.
    var nowPlayingMemberListLine: MediaPresenceLine = .automatic {
        didSet {
            guard nowPlayingMemberListLine != oldValue else { return }
            defaults.set(nowPlayingMemberListLine.rawValue, forKey: Key.nowPlayingMemberListLine)
        }
    }

    /// Words that keep a title, channel or artist off the presence.
    var nowPlayingExcludedWords: [String] = [] {
        didSet {
            guard nowPlayingExcludedWords != oldValue else { return }
            defaults.set(nowPlayingExcludedWords, forKey: Key.nowPlayingExcludedWords)
        }
    }

    /// Whether a song's cover is looked up — iTunes Search is asked for the
    /// artist and the title.
    var nowPlayingFindsCovers = true {
        didSet {
            guard nowPlayingFindsCovers != oldValue else { return }
            defaults.set(nowPlayingFindsCovers, forKey: Key.nowPlayingFindsCovers)
        }
    }

    /// Apps on the local RPC socket whose activity is never shared, by
    /// application id — with the name each went by, so the pane can list one
    /// that is not running.
    var blockedRPCApplications: [String: String] = [:] {
        didSet {
            guard blockedRPCApplications != oldValue else { return }
            defaults.set(blockedRPCApplications, forKey: Key.blockedRPCApplications)
        }
    }

    // MARK: Previews

    /// Others' custom typing indicators — their emoji and their word — drawn,
    /// as Discord's phone apps draw them and its desktop app does not yet.
    var drawsCustomTypingIndicators = true {
        didSet {
            guard drawsCustomTypingIndicators != oldValue else { return }
            defaults.set(drawsCustomTypingIndicators, forKey: Key.drawsCustomTypingIndicators)
        }
    }

    /// Servers' Server Hubs (docs/BETA2.md, phase 9): Discord's page of
    /// widgets, shown where Discord has given a server one. **On unless the
    /// reader turns it off** (Alex, 2026-11-16): Wingcord follows Discord's
    /// own per-server rollout (`AppModel.isInServerHubExperiment`) and the
    /// server's settings, so it appears exactly where Discord shows it.
    var showsServerHub = true {
        didSet {
            guard showsServerHub != oldValue else { return }
            defaults.set(showsServerHub, forKey: Key.showsServerHub)
        }
    }

    /// Which card a voice invite gets: Discord's, or its channel-row variant —
    /// as Discord's experiment puts each server, or always one of them.
    var voiceInviteCardStyle: VoiceInviteCardStyle = .asDiscordDecides {
        didSet {
            guard voiceInviteCardStyle != oldValue else { return }
            defaults.set(voiceInviteCardStyle.rawValue, forKey: Key.voiceInviteCardStyle)
        }
    }

    /// Whether one player's media is shared.
    func sharesNowPlaying(from player: MediaPlayer) -> Bool {
        nowPlayingPlayers[player.id] ?? player.isOnByDefault
    }

    /// The presence's options, as the settings stand.
    var nowPlayingOptions: MediaPresenceOptions {
        MediaPresenceOptions(
            showsWhilePaused: nowPlayingShowsWhilePaused,
            showsYouTubeThumbnails: nowPlayingShowsThumbnails,
            showsButtons: nowPlayingShowsButtons,
            prefixesBy: nowPlayingPrefixesBy,
            memberListLine: nowPlayingMemberListLine,
            excludedWords: nowPlayingExcludedWords
        )
    }

    // MARK: The Rich Presence builder

    /// The presences the reader made in the full profile's Activity tab
    /// (DESIGN-NOTES §11) — kept on this Mac, as Vencord keeps its plugin's.
    var customPresences: [CustomPresence] = [] {
        didSet {
            guard customPresences != oldValue else { return }
            defaults.set(try? JSONEncoder().encode(customPresences), forKey: Key.customPresences)
        }
    }
    /// The one that is on, if any — one at a time.
    var activeCustomPresenceID: UUID? {
        didSet {
            guard activeCustomPresenceID != oldValue else { return }
            defaults.set(activeCustomPresenceID?.uuidString, forKey: Key.activeCustomPresence)
            if let activeCustomPresenceID { lastCustomPresenceID = activeCustomPresenceID }
        }
    }
    /// The one Show Custom RPC turns back on.
    private(set) var lastCustomPresenceID: UUID? {
        didSet {
            guard lastCustomPresenceID != oldValue else { return }
            defaults.set(lastCustomPresenceID?.uuidString, forKey: Key.lastCustomPresence)
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

    var clipLength: ClipLength = .thirtySeconds {
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

    /// Discord's Auto Clips: moments kept without the key, waiting in the
    /// library to be kept or thrown away (docs/CLIPS-PRESENCE.md, Phase 7.2).
    ///
    /// **Off by default.** It listens to the call — on this Mac, through
    /// Apple's own classifier, and only to what a clip may keep — and that is
    /// not something to start on somebody's behalf.
    var autoClipsEnabled = false {
        didSet { defaults.set(autoClipsEnabled, forKey: Key.autoClips) }
    }

    /// Whether laughter and shouting count — Discord's emotion signal.
    var autoClipsHearsReactions = true {
        didSet { defaults.set(autoClipsHearsReactions, forKey: Key.autoClipsReactions) }
    }

    /// Whether the game's own events count.
    var autoClipsHearsGameEvents = true {
        didSet { defaults.set(autoClipsHearsGameEvents, forKey: Key.autoClipsGameEvents) }
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
    private var legacyLastPlace: LastPlace?
    private var lastPlaces: [String: LastPlace] = [:]

    /// Where an account was. Written by nothing else, and nothing else may read it.
    struct LastPlace: Codable, Equatable {
        var guildID: UInt64?
        var channelID: UInt64?
    }

    /// Where this account was when it last had the window.
    ///
    /// **Per account, or one opens in another's channel.** The single pair from before
    /// there could be two is what the first account after the update gets, and nobody
    /// after it: from then on, an account that's never been opened has nowhere to be.
    func lastPlace(forAccount accountID: String?) -> LastPlace? {
        if let accountID, let place = lastPlaces[accountID] { return place }
        return lastPlaces.isEmpty ? legacyLastPlace : nil
    }

    /// Records where the reader is. Cheap enough to call on every navigation:
    /// it writes only when the pair actually moved.
    func rememberConversation(guildID: UInt64?, channelID: UInt64?, account: String?) {
        guard let account else { return }
        let place = LastPlace(guildID: guildID, channelID: channelID)
        guard lastPlaces[account] != place else { return }
        lastPlaces[account] = place
        defaults.set(try? JSONEncoder().encode(lastPlaces), forKey: Key.lastPlaces)
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

    /// Whether moving pictures play right now: the reader's switch, and Low
    /// Power Mode, which is the reader asking the Mac to spend less and is
    /// honoured the same way.
    var playsAnimatedMedia: Bool { playsAnimatedContent && !isLowPowerModeOn && !isRunningHot }

    /// The Mac's Low Power Mode, kept current so anything drawn from
    /// `playsAnimatedMedia` follows it.
    private(set) var isLowPowerModeOn = ProcessInfo.processInfo.isLowPowerModeEnabled
    @ObservationIgnored private var powerStateObserver: NSObjectProtocol?

    /// Whether the Mac says it is running hot — `ProcessInfo.thermalState` at
    /// serious or critical, where the system is already slowing things down.
    /// Honoured as Low Power Mode is: moving pictures are the one cost here
    /// that nobody needs in order to read.
    private(set) var isRunningHot = AppSettings.isHot(ProcessInfo.processInfo.thermalState)
    @ObservationIgnored private var thermalStateObserver: NSObjectProtocol?

    nonisolated static func isHot(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
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

    /// What the Direct Messages tile at the top of the rail wears. See
    /// `RailHomeIcon`.
    var railHomeIcon: RailHomeIcon = .appIcon {
        didSet { defaults.set(railHomeIcon.rawValue, forKey: Key.railHomeIcon) }
    }

    // MARK: The window shell

    /// Whether the sidebar is a glass panel floating inside the window, or a
    /// column flush with its edges. See `SidebarStyle`.
    var sidebarStyle: SidebarStyle = .floating {
        didSet { defaults.set(sidebarStyle.rawValue, forKey: Key.sidebarStyle) }
    }

    /// Whether a server's banner art heads its channel list. Off, every server
    /// starts as one without art: the list at the top, the name in the header.
    var showsServerBanners = true {
        didSet { defaults.set(showsServerBanners, forKey: Key.showsServerBanners) }
    }

    /// Whether the conversation list asks Discord for each conversation's newest
    /// message, for its preview line — one request when the list first
    /// appears (`SessionController.loadDirectMessagePreviews`). Off, a row
    /// shows a preview only for conversations opened this session.
    var loadsMessagePreviews = true {
        didSet { defaults.set(loadsMessagePreviews, forKey: Key.loadsMessagePreviews) }
    }

    /// The pages the sidebar swipes between — see `SidebarPageLayout`.
    var sidebarPages: SidebarPageLayout = .twoPages {
        didSet { defaults.set(sidebarPages.rawValue, forKey: Key.sidebarPages) }
    }

    /// Whether the sidebar is out. View › Hide Sidebar, ⌃⌘S, and the header's
    /// own toggle all write this one value.
    var isSidebarShown = true {
        didSet { defaults.set(isSidebarShown, forKey: Key.sidebarShown) }
    }

    /// The sidebar's width, as the reader last dragged it.
    ///
    /// A clamped facade over private storage, for the reason `textScale` is one:
    /// clamping inside a `didSet` re-enters the setter.
    var sidebarWidth: CGFloat {
        get { storedSidebarWidth }
        set { storedSidebarWidth = ShellMetrics.clampedSidebarWidth(newValue) }
    }

    private var storedSidebarWidth: CGFloat = ShellMetrics.sidebarIdealWidth {
        didSet {
            guard storedSidebarWidth != oldValue else { return }
            defaults.set(Double(storedSidebarWidth), forKey: Key.sidebarWidth)
        }
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

    /// Whether the GIF, sticker and app controls sit in the composer beside
    /// the field — the arrangement before the redesign — rather than in `+`'s
    /// menu, with only the emoji control and the send arrow in the field, as
    /// Messages has it (REDESIGN.md R7).
    var composerControlsInline = false {
        didSet { defaults.set(composerControlsInline, forKey: Key.composerControlsInline) }
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

    /// The channel list's air between rows, in points, on either side of the
    /// system's own (Alex, 2026-11-16: "an option to adjust the spacing between
    /// channels and categories in the channel list"). Negative is denser than
    /// the system sidebar, positive roomier.
    var channelSpacing: Double {
        get { storedChannelSpacing }
        set { storedChannelSpacing = min(Self.channelSpacingRange.upperBound, max(Self.channelSpacingRange.lowerBound, newValue)) }
    }

    static let channelSpacingRange: ClosedRange<Double> = -6...12

    private var storedChannelSpacing: Double = 0 {
        didSet {
            guard storedChannelSpacing != oldValue else { return }
            defaults.set(storedChannelSpacing, forKey: Key.channelSpacing)
        }
    }

    /// The air above each category heading, in points, on top of the list's
    /// own — the other half of the same ask.
    var categorySpacing: Double {
        get { storedCategorySpacing }
        set { storedCategorySpacing = min(Self.categorySpacingRange.upperBound, max(Self.categorySpacingRange.lowerBound, newValue)) }
    }

    static let categorySpacingRange: ClosedRange<Double> = -4...24

    private var storedCategorySpacing: Double = 0 {
        didSet {
            guard storedCategorySpacing != oldValue else { return }
            defaults.set(storedCategorySpacing, forKey: Key.categorySpacing)
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

    /// View › Hide Times, from Alex's reference (DESIGN-NOTES §10): every time
    /// in the transcript drawn only under the pointer — the one beside an
    /// author's name as well as a continuation row's, which it takes back from
    /// `alwaysShowsTimestamps`.
    var hidesMessageTimes = false {
        didSet {
            guard hidesMessageTimes != oldValue else { return }
            defaults.set(hidesMessageTimes, forKey: Key.hidesMessageTimes)
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

    /// Whether a channel's summaries are shown on the toolbar's row — its Hide /
    /// Show Summaries. The name is older than their move up from a bar of their own.
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

    /// The viewer's cinema mode: light from the picture glowing around it
    /// (docs/ACTIVITIES-CALLS-PICKER.md, decision 25). On until turned off.
    var viewerCinemaMode = true {
        didSet { defaults.set(viewerCinemaMode, forKey: Key.viewerCinemaMode) }
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

    /// Discord's Input Profile — Custom until the reader picks another, as
    /// Discord's is.
    var inputProfile: InputProfile = .custom {
        didSet {
            guard inputProfile != oldValue else { return }
            defaults.set(inputProfile.rawValue, forKey: Key.inputProfile)
        }
    }

    /// Discord's Echo Cancellation, for the Custom profile: Apple's voice
    /// processor, or the 48 kHz path without it.
    var echoCancellation = true {
        didSet {
            guard echoCancellation != oldValue else { return }
            defaults.set(echoCancellation, forKey: Key.echoCancellation)
        }
    }

    /// Speech stretched by a pitch period to absorb delay changes inside a
    /// sentence (NetEQ's accelerate and expand; docs/ACTIVITIES-CALLS-PICKER.md,
    /// decision 11). **Off by default until it has been heard in real calls.**
    var adaptivePlayout = false {
        didSet {
            guard adaptivePlayout != oldValue else { return }
            defaults.set(adaptivePlayout, forKey: Key.adaptivePlayout)
        }
    }

    /// Discord's Automatic Gain Control, for the Custom profile.
    var automaticGainControl = true {
        didSet {
            guard automaticGainControl != oldValue else { return }
            defaults.set(automaticGainControl, forKey: Key.automaticGainControl)
        }
    }

    /// What the profile makes of the Custom switches — Discord's profiles are
    /// overrides, and Custom is the reader's own settings untouched.
    var resolvedProcessing: VoiceAudioEngine.Processing {
        switch inputProfile {
        case .voiceIsolation: VoiceAudioEngine.Processing(echoCancellation: true, automaticGainControl: true)
        case .studio: VoiceAudioEngine.Processing(echoCancellation: false, automaticGainControl: false)
        case .custom: VoiceAudioEngine.Processing(
            echoCancellation: echoCancellation, automaticGainControl: automaticGainControl
        )
        }
    }

    /// Discord's "Automatically determine input sensitivity" — on by default,
    /// as its desktop app has it.
    var automaticInputSensitivity = true {
        didSet {
            guard automaticInputSensitivity != oldValue else { return }
            defaults.set(automaticInputSensitivity, forKey: Key.automaticSensitivity)
        }
    }

    /// Where voice activity opens the gate when sensitivity is set by hand, in
    /// dBFS — Discord's own scale, −100…0, and its default of −60.
    var voiceActivityThreshold: Double {
        get { storedVoiceThreshold }
        set { storedVoiceThreshold = min(0, max(-100, newValue)) }
    }

    private var storedVoiceThreshold: Double = -60 {
        didSet {
            guard storedVoiceThreshold != oldValue else { return }
            defaults.set(storedVoiceThreshold, forKey: Key.voiceThresholdDecibels)
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

    /// Discord's Push to Talk (Priority): held, the microphone opens in either
    /// mode and transmits with priority — which everybody else's client honours
    /// only from somebody with the channel's Priority Speaker.
    var priorityPushToTalkKey: Hotkey? {
        didSet {
            guard priorityPushToTalkKey != oldValue else { return }
            defaults.set(priorityPushToTalkKey?.storageValue ?? Self.noHotkey, forKey: Key.priorityPushToTalk)
        }
    }

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

    /// Discord's Go Live choices — Resolution, Frame Rate and Share Audio —
    /// kept from one stream to the next, as its `ApplicationStreamingSettingsStore`
    /// keeps them. What the account may actually use is `GoLiveGate`'s call.
    var goLive = GoLiveSettings() {
        didSet {
            guard goLive != oldValue else { return }
            defaults.set(goLive.resolution.rawValue, forKey: Key.goLiveResolution)
            defaults.set(goLive.frameRate.rawValue, forKey: Key.goLiveFrameRate)
            defaults.set(goLive.sharesAudio, forKey: Key.sharesAudio)
        }
    }

    /// Discord's Stream Attenuation: "Automatically reduce stream volume when
    /// people are talking." On by default, as Discord's `sidechainCompression`.
    var streamAttenuation = true {
        didSet {
            guard streamAttenuation != oldValue else { return }
            defaults.set(streamAttenuation, forKey: Key.streamAttenuation)
        }
    }

    /// Discord's Stream Attenuation Strength, 0–100, 50 by default.
    var streamAttenuationStrength: Double = 50 {
        didSet {
            let clamped = min(100, max(0, streamAttenuationStrength))
            guard clamped == streamAttenuationStrength else {
                streamAttenuationStrength = clamped
                return
            }
            guard streamAttenuationStrength != oldValue else { return }
            defaults.set(streamAttenuationStrength, forKey: Key.streamAttenuationStrength)
        }
    }

    /// Vencord's Fake Nitro (decision 9): one switch, off by default, and under
    /// it the three things it does — send emoji and stickers this account
    /// cannot use as links to their pictures, and lift Go Live's limits. Each
    /// on by default once the switch is, as the plugin's are.
    var fakeNitro = false {
        didSet {
            guard fakeNitro != oldValue else { return }
            defaults.set(fakeNitro, forKey: Key.fakeNitro)
        }
    }
    var fakeNitroEmoji = true {
        didSet {
            guard fakeNitroEmoji != oldValue else { return }
            defaults.set(fakeNitroEmoji, forKey: Key.fakeNitroEmoji)
        }
    }
    var fakeNitroStickers = true {
        didSet {
            guard fakeNitroStickers != oldValue else { return }
            defaults.set(fakeNitroStickers, forKey: Key.fakeNitroStickers)
        }
    }
    var fakeNitroStreamQuality = true {
        didSet {
            guard fakeNitroStreamQuality != oldValue else { return }
            defaults.set(fakeNitroStreamQuality, forKey: Key.fakeNitroStreamQuality)
        }
    }

    /// The plugin's `disableEmbedPermissionCheck`: off, a send whose links a
    /// channel will not embed asks first ("Hold on!").
    var fakeNitroSkipsEmbedCheck = false {
        didSet {
            guard fakeNitroSkipsEmbedCheck != oldValue else { return }
            defaults.set(fakeNitroSkipsEmbedCheck, forKey: Key.fakeNitroSkipsEmbedCheck)
        }
    }

    /// Vencord's AnonymiseFileNames (decision 11): off, as a plugin is until
    /// it is switched on. On, each file is renamed as its send begins unless
    /// its tile says otherwise — by the plugin's settings, with its defaults.
    var anonymisesFileNames = false {
        didSet {
            guard anonymisesFileNames != oldValue else { return }
            defaults.set(anonymisesFileNames, forKey: Key.anonymisesFileNames)
        }
    }
    /// "Whether to anonymise file names by default" — for a tile nobody has
    /// toggled.
    var anonymisesByDefault = true {
        didSet {
            guard anonymisesByDefault != oldValue else { return }
            defaults.set(anonymisesByDefault, forKey: Key.anonymisesByDefault)
        }
    }
    /// "Anonymising method".
    var anonymisingMethod = FileNameAnonymiser.Method.randomCharacters {
        didSet {
            guard anonymisingMethod != oldValue else { return }
            defaults.set(anonymisingMethod.rawValue, forKey: Key.anonymisingMethod)
        }
    }
    /// "Random characters length".
    var randomisedLength = 7 {
        didSet {
            let clamped = min(Self.randomisedLengths.upperBound, max(Self.randomisedLengths.lowerBound, randomisedLength))
            guard clamped == randomisedLength else {
                randomisedLength = clamped
                return
            }
            guard randomisedLength != oldValue else { return }
            defaults.set(randomisedLength, forKey: Key.randomisedLength)
        }
    }
    /// At least one character — the plugin would send a name that is only its
    /// ending — and no more than the 255 a Mac's disks hold in one name.
    static let randomisedLengths = 1...255
    /// "Consistent filename".
    var consistentFileName = "image" {
        didSet {
            guard consistentFileName != oldValue else { return }
            defaults.set(consistentFileName, forKey: Key.consistentFileName)
        }
    }

    /// Vencord's SilentTyping (decisions 16–19): off, as a plugin is until it
    /// is switched on.
    var silentTyping = false {
        didSet {
            guard silentTyping != oldValue else { return }
            defaults.set(silentTyping, forKey: Key.silentTyping)
        }
    }
    /// "Show an icon for toggling the plugin" — the composer's struck keyboard.
    var silentTypingShowsIcon = false {
        didSet {
            guard silentTypingShowsIcon != oldValue else { return }
            defaults.set(silentTypingShowsIcon, forKey: Key.silentTypingShowsIcon)
        }
    }
    /// "Add option to toggle the functionality in the chat input context menu".
    var silentTypingInContextMenu = true {
        didSet {
            guard silentTypingInContextMenu != oldValue else { return }
            defaults.set(silentTypingInContextMenu, forKey: Key.silentTypingInContextMenu)
        }
    }
    /// "Toggle functionality" — what the icon, the menu item and the User
    /// menu flip. On by default, so switching the plugin on hides typing.
    var silentTypingIsOn = true {
        didSet {
            guard silentTypingIsOn != oldValue else { return }
            defaults.set(silentTypingIsOn, forKey: Key.silentTypingIsOn)
        }
    }

    /// Whether typing goes unreported: the plugin on, and its functionality.
    var hidesTyping: Bool { silentTyping && silentTypingIsOn }

    /// Discord's "Sync theme across my devices" (`shouldSync("appearance")`,
    /// on unless switched off): one of Discord's themes chosen here is
    /// written to the account, and one chosen in Discord is taken here.
    var syncsThemeAcrossDevices = true {
        didSet {
            guard syncsThemeAcrossDevices != oldValue else { return }
            defaults.set(syncsThemeAcrossDevices, forKey: Key.syncsThemeAcrossDevices)
        }
    }

    /// Discord's "Apply theme to other users' profiles"
    /// (`syncProfileThemeWithUserTheme`, off): a profile with colours of its
    /// own is drawn in the reader's light or dark, under Discord's heavier
    /// overlay. See `ProfileGround`.
    var appliesThemeToProfiles = false {
        didSet {
            guard appliesThemeToProfiles != oldValue else { return }
            defaults.set(appliesThemeToProfiles, forKey: Key.appliesThemeToProfiles)
        }
    }

    /// Discord's "Auto-compress Images": a picture over the upload limit is
    /// compressed to fit as it is added, without asking. Off, as Discord's
    /// desktop has no such step; Always Compress Images turns it on.
    var autoCompressesImages = false {
        didSet {
            guard autoCompressesImages != oldValue else { return }
            defaults.set(autoCompressesImages, forKey: Key.autoCompressesImages)
        }
    }

    var sendsFakeEmoji: Bool { fakeNitro && fakeNitroEmoji }
    var sendsFakeStickers: Bool { fakeNitro && fakeNitroStickers }
    var liftsStreamQuality: Bool { fakeNitro && fakeNitroStreamQuality }

    /// Discord's "Show a warning when Discord is not detecting audio from your
    /// mic" — its `silenceWarning`, on by default.
    var showsSilentMicWarning = true {
        didSet {
            guard showsSilentMicWarning != oldValue else { return }
            defaults.set(showsSilentMicWarning, forKey: Key.silenceWarning)
        }
    }

    /// Discord's "Don't show again" on the activity suggestions under a call —
    /// its `VC_TILE_ACTIVITIES_ENTRY_POINT`, dismissed for good on the device.
    var hidesActivitySuggestions = false {
        didSet {
            guard hidesActivitySuggestions != oldValue else { return }
            defaults.set(hidesActivitySuggestions, forKey: Key.activitySuggestionsDismissed)
        }
    }

    /// Discord's Mute Music in a stage's tray, kept on the device as its
    /// `StageMusicStore` keeps it.
    var mutesStageMusic = false {
        didSet {
            guard mutesStageMusic != oldValue else { return }
            defaults.set(mutesStageMusic, forKey: Key.stageMusicMuted)
        }
    }

    /// Whether "Welcome to Stages!" has been shown — Discord's once-ever
    /// `HasBeenInStageChannel`.
    var hasSeenStageWelcome = false {
        didSet {
            guard hasSeenStageWelcome != oldValue else { return }
            defaults.set(hasSeenStageWelcome, forKey: Key.stageWelcomeSeen)
        }
    }

    /// People whose video the reader turned off — Discord's Disable Video,
    /// which it keeps on the device rather than syncing.
    var disabledVideoUserIDs: Set<UInt64> = [] {
        didSet {
            guard disabledVideoUserIDs != oldValue else { return }
            defaults.set(disabledVideoUserIDs.map(String.init), forKey: Key.disabledVideo)
        }
    }

    /// The attenuation as the engine takes it: how far a stream drops, 0…1,
    /// or `nil` when it is off.
    var resolvedStreamAttenuation: Float? {
        streamAttenuation ? Float(streamAttenuationStrength / 100) : nil
    }

    /// The input mode as the engine wants it, with the threshold folded in.
    ///
    /// One place, because the two halves have to agree: a push-to-talk mode with
    /// no key bound is a microphone that can never open, and resolving that here
    /// means no caller has to remember it.
    ///
    /// **The profile overrides, as Discord's do**: Studio is voice activity at a
    /// fixed −84 dB whatever was chosen, and Voice Isolation decides the line
    /// itself.
    var resolvedInputMode: MediaSession.InputMode {
        let activity = switch inputProfile {
        case .studio: MediaSession.VoiceActivity(isAutomatic: false, threshold: -84)
        case .voiceIsolation: MediaSession.VoiceActivity(isAutomatic: true, threshold: Float(voiceActivityThreshold))
        case .custom: MediaSession.VoiceActivity(
            isAutomatic: automaticInputSensitivity, threshold: Float(voiceActivityThreshold)
        )
        }
        if inputProfile == .studio { return .voiceActivity(activity) }
        return switch inputMode {
        case .voiceActivity: .voiceActivity(activity)
        case .pushToTalk: pushToTalkKey == nil ? .voiceActivity(activity) : .pushToTalk
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

    // MARK: Activity

    /// The member list's Activity cards folded away — Discord's Hide Activity
    /// Cards, which its client keeps on the device (`435738`'s `hidden`).
    var hidesActivityCards = false {
        didSet { defaults.set(hidesActivityCards, forKey: Key.hidesActivityCards) }
    }

    /// How the member list is arranged — its head's Organize by. One choice for the
    /// whole app, as Discord keeps its friends sidebar's (`FriendRowStore`).
    var memberListOrganization = MemberListOrganization.standard {
        didSet { defaults.set(memberListOrganization.rawValue, forKey: Key.memberListOrganization) }
    }

    /// Whether people in the same voice channel gather under it — Discord's
    /// `voiceGroupingEnabled`, on by default.
    var groupsMembersInVoice = true {
        didSet { defaults.set(groupsMembersInVoice, forKey: Key.groupsMembersInVoice) }
    }

    /// The member list's sections the reader folded away, by server and by group
    /// conversation — see `AppModel.memberListScope`. Discord forgets these when
    /// the list unmounts; a section someone folds is one they don't want back.
    var collapsedMemberSections: [String: Set<String>] = [:] {
        didSet {
            guard collapsedMemberSections != oldValue else { return }
            defaults.set(
                collapsedMemberSections.mapValues { Array($0).sorted() },
                forKey: Key.collapsedMemberSections
            )
        }
    }

    /// Which Activity cards the reader has been shown, and when first — what
    /// retires a card after three days. Kept on the device, as Discord keeps it.
    var activityImpressions = ActivityImpressions() {
        didSet {
            guard activityImpressions != oldValue,
                  let data = try? JSONEncoder().encode(activityImpressions)
            else { return }
            defaults.set(data, forKey: Key.activityImpressions)
        }
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
        usesMessageBubbles = defaults.object(forKey: Key.messageBubbles) as? Bool ?? true
        tintsOwnBubbles = defaults.object(forKey: Key.tintsOwnBubbles) as? Bool ?? false
        playsScreenEffects = defaults.object(forKey: Key.screenEffects) as? Bool ?? true
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
            .flatMap(ClipLength.init(rawValue:)) ?? .thirtySeconds
        clipResolution = (defaults.string(forKey: Key.clipResolution))
            .flatMap(ClipResolution.init(rawValue:)) ?? .p1080
        clipFrameRate = (defaults.string(forKey: Key.clipFrameRate))
            .flatMap(ClipFrameRate.init(rawValue:)) ?? .fps60
        clipsFolder = (defaults.string(forKey: Key.clipsFolder)).map { URL(fileURLWithPath: $0) }
        clipsShowsFeedback = defaults.object(forKey: Key.clipsFeedback) as? Bool ?? true
        autoClipsEnabled = defaults.object(forKey: Key.autoClips) as? Bool ?? false
        autoClipsHearsReactions = defaults.object(forKey: Key.autoClipsReactions) as? Bool ?? true
        autoClipsHearsGameEvents = defaults.object(forKey: Key.autoClipsGameEvents) as? Bool ?? true
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
        railHomeIcon = (defaults.object(forKey: Key.railHomeIcon) as? String)
            .flatMap(RailHomeIcon.init(rawValue:)) ?? .appIcon
        composerControls = defaults.stringArray(forKey: Key.composerControls)
            .map(ComposerControlOrder.init(storage:)) ?? .default
        composerControlsInline = defaults.object(forKey: Key.composerControlsInline) as? Bool ?? false
        sidebarStyle = defaults.string(forKey: Key.sidebarStyle)
            .flatMap(SidebarStyle.init(rawValue:)) ?? .floating
        sidebarPages = defaults.string(forKey: Key.sidebarPages)
            .flatMap(SidebarPageLayout.init(rawValue:)) ?? .twoPages
        loadsMessagePreviews = defaults.object(forKey: Key.loadsMessagePreviews) as? Bool ?? true
        showsServerBanners = defaults.object(forKey: Key.showsServerBanners) as? Bool ?? true
        isSidebarShown = defaults.object(forKey: Key.sidebarShown) as? Bool ?? true
        storedSidebarWidth = ShellMetrics.clampedSidebarWidth(
            (defaults.object(forKey: Key.sidebarWidth) as? Double).map { CGFloat($0) }
                ?? ShellMetrics.sidebarIdealWidth
        )
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
        storedChannelSpacing = defaults.object(forKey: Key.channelSpacing) as? Double ?? 0
        storedCategorySpacing = defaults.object(forKey: Key.categorySpacing) as? Double ?? 0
        showsSeconds = defaults.object(forKey: Key.showsSeconds) as? Bool ?? false
        alwaysShowsTimestamps = defaults.object(forKey: Key.alwaysShowsTimestamps) as? Bool
            ?? false
        hidesMessageTimes = defaults.object(forKey: Key.hidesMessageTimes) as? Bool ?? false
        showsPerformanceInspector = defaults.object(forKey: Key.showsInspector) as? Bool ?? false
        developerMode = defaults.object(forKey: Key.developerMode) as? Bool ?? false
        hidesActivityCards = defaults.object(forKey: Key.hidesActivityCards) as? Bool ?? false
        memberListOrganization = (defaults.string(forKey: Key.memberListOrganization))
            .flatMap(MemberListOrganization.init(rawValue:)) ?? .standard
        groupsMembersInVoice = defaults.object(forKey: Key.groupsMembersInVoice) as? Bool ?? true
        collapsedMemberSections = (defaults.dictionary(forKey: Key.collapsedMemberSections) as? [String: [String]])?
            .mapValues(Set.init) ?? [:]
        activityImpressions = (defaults.data(forKey: Key.activityImpressions))
            .flatMap { try? JSONDecoder().decode(ActivityImpressions.self, from: $0) } ?? ActivityImpressions()
        storedMediaVolume = defaults.object(forKey: Key.mediaVolume) as? Double ?? 1
        voiceInputDeviceID = defaults.object(forKey: Key.voiceInput) as? String
        voiceOutputDeviceID = defaults.object(forKey: Key.voiceOutput) as? String
        cameraDeviceID = defaults.object(forKey: Key.camera) as? String
        storedVoiceInputVolume = defaults.object(forKey: Key.voiceInputVolume) as? Double ?? 1
        storedVoiceOutputVolume = defaults.object(forKey: Key.voiceOutputVolume) as? Double ?? 1
        // **Decision 4: the old line, converted once to Discord's scale.** It was
        // a linear 0…1 — 0.03 by default, which is −30.5 dB — and the setting
        // that replaces it is the dBFS slider Discord draws. Nobody ever chose
        // automatic sensitivity before it existed, so it starts on, as
        // Discord's does.
        if let decibels = defaults.object(forKey: Key.voiceThresholdDecibels) as? Double {
            storedVoiceThreshold = decibels
        } else if let linear = defaults.object(forKey: Key.voiceThreshold) as? Double {
            // Written here, not by the property's observer: an initialiser's
            // own assignments do not call it.
            storedVoiceThreshold = min(0, max(-100, linear > 0 ? 20 * log10(linear) : -100))
            defaults.set(storedVoiceThreshold, forKey: Key.voiceThresholdDecibels)
            defaults.removeObject(forKey: Key.voiceThreshold)
        }
        automaticInputSensitivity = defaults.object(forKey: Key.automaticSensitivity) as? Bool ?? true
        inputProfile = (defaults.object(forKey: Key.inputProfile) as? String)
            .flatMap(InputProfile.init(rawValue:)) ?? .custom
        echoCancellation = defaults.object(forKey: Key.echoCancellation) as? Bool ?? true
        adaptivePlayout = defaults.bool(forKey: Key.adaptivePlayout)
        automaticGainControl = defaults.object(forKey: Key.automaticGainControl) as? Bool ?? true
        inputMode = (defaults.object(forKey: Key.inputMode) as? String)
            .flatMap(VoiceInputMode.init(rawValue:)) ?? .voiceActivity
        pushToTalkKey = (defaults.object(forKey: Key.pushToTalk) as? Int)
            .flatMap { $0 == Self.noHotkey ? nil : Hotkey(storageValue: $0) }
        goLive = GoLiveSettings(
            resolution: (defaults.object(forKey: Key.goLiveResolution) as? Int)
                .flatMap(StreamResolution.init(rawValue:)) ?? .p720,
            frameRate: (defaults.object(forKey: Key.goLiveFrameRate) as? Int)
                .flatMap(StreamFrameRate.init(rawValue:)) ?? .fps30,
            sharesAudio: defaults.object(forKey: Key.sharesAudio) as? Bool ?? true
        )
        streamAttenuation = defaults.object(forKey: Key.streamAttenuation) as? Bool ?? true
        showsSilentMicWarning = defaults.object(forKey: Key.silenceWarning) as? Bool ?? true
        hidesActivitySuggestions = defaults.bool(forKey: Key.activitySuggestionsDismissed)
        mutesStageMusic = defaults.bool(forKey: Key.stageMusicMuted)
        hasSeenStageWelcome = defaults.bool(forKey: Key.stageWelcomeSeen)
        fakeNitro = defaults.object(forKey: Key.fakeNitro) as? Bool ?? false
        fakeNitroEmoji = defaults.object(forKey: Key.fakeNitroEmoji) as? Bool ?? true
        fakeNitroStickers = defaults.object(forKey: Key.fakeNitroStickers) as? Bool ?? true
        fakeNitroStreamQuality = defaults.object(forKey: Key.fakeNitroStreamQuality) as? Bool ?? true
        fakeNitroSkipsEmbedCheck = defaults.object(forKey: Key.fakeNitroSkipsEmbedCheck) as? Bool ?? false
        autoCompressesImages = defaults.object(forKey: Key.autoCompressesImages) as? Bool ?? false
        syncsThemeAcrossDevices = defaults.object(forKey: Key.syncsThemeAcrossDevices) as? Bool ?? true
        appliesThemeToProfiles = defaults.object(forKey: Key.appliesThemeToProfiles) as? Bool ?? false
        anonymisesFileNames = defaults.object(forKey: Key.anonymisesFileNames) as? Bool ?? false
        anonymisesByDefault = defaults.object(forKey: Key.anonymisesByDefault) as? Bool ?? true
        anonymisingMethod = defaults.string(forKey: Key.anonymisingMethod)
            .flatMap(FileNameAnonymiser.Method.init(rawValue:)) ?? .randomCharacters
        randomisedLength = defaults.object(forKey: Key.randomisedLength) as? Int ?? 7
        consistentFileName = defaults.string(forKey: Key.consistentFileName) ?? "image"
        silentTyping = defaults.object(forKey: Key.silentTyping) as? Bool ?? false
        silentTypingShowsIcon = defaults.object(forKey: Key.silentTypingShowsIcon) as? Bool ?? false
        silentTypingInContextMenu = defaults.object(forKey: Key.silentTypingInContextMenu) as? Bool ?? true
        silentTypingIsOn = defaults.object(forKey: Key.silentTypingIsOn) as? Bool ?? true
        focusStatus = defaults.string(forKey: Key.focusStatus)
            .flatMap(PresenceStatus.init(rawValue:)) ?? .doNotDisturb
        focusCustomStatus = defaults.data(forKey: Key.focusCustomStatus)
            .flatMap { try? JSONDecoder().decode(CustomStatus.self, from: $0) }
        focusRestores = defaults.object(forKey: Key.focusRestores) as? Bool ?? true
        sharesNowPlaying = defaults.object(forKey: Key.sharesNowPlaying) as? Bool ?? false
        nowPlayingPlayers = defaults.dictionary(forKey: Key.nowPlayingPlayers) as? [String: Bool] ?? [:]
        nowPlayingShowsWhilePaused = defaults.object(forKey: Key.nowPlayingShowsWhilePaused) as? Bool ?? false
        nowPlayingShowsThumbnails = defaults.object(forKey: Key.nowPlayingShowsThumbnails) as? Bool ?? true
        nowPlayingShowsButtons = defaults.object(forKey: Key.nowPlayingShowsButtons) as? Bool ?? true
        nowPlayingPrefixesBy = defaults.object(forKey: Key.nowPlayingPrefixesBy) as? Bool ?? true
        nowPlayingMemberListLine = defaults.string(forKey: Key.nowPlayingMemberListLine)
            .flatMap(MediaPresenceLine.init(rawValue:)) ?? .automatic
        nowPlayingExcludedWords = defaults.stringArray(forKey: Key.nowPlayingExcludedWords) ?? []
        nowPlayingFindsCovers = defaults.object(forKey: Key.nowPlayingFindsCovers) as? Bool ?? true
        blockedRPCApplications = defaults.dictionary(forKey: Key.blockedRPCApplications) as? [String: String] ?? [:]
        drawsCustomTypingIndicators = defaults.object(forKey: Key.drawsCustomTypingIndicators) as? Bool ?? true
        showsServerHub = defaults.object(forKey: Key.showsServerHub) as? Bool ?? true
        voiceInviteCardStyle = defaults.string(forKey: Key.voiceInviteCardStyle)
            .flatMap(VoiceInviteCardStyle.init(rawValue:)) ?? .asDiscordDecides
        customPresences = defaults.data(forKey: Key.customPresences)
            .flatMap { try? JSONDecoder().decode([CustomPresence].self, from: $0) } ?? []
        lastCustomPresenceID = defaults.string(forKey: Key.lastCustomPresence).flatMap(UUID.init(uuidString:))
        activeCustomPresenceID = defaults.string(forKey: Key.activeCustomPresence).flatMap(UUID.init(uuidString:))
        priorityPushToTalkKey = (defaults.object(forKey: Key.priorityPushToTalk) as? Int)
            .flatMap { $0 == Self.noHotkey ? nil : Hotkey(storageValue: $0) }
        disabledVideoUserIDs = Set(
            (defaults.stringArray(forKey: Key.disabledVideo) ?? []).compactMap(UInt64.init)
        )
        streamAttenuationStrength = min(100, max(0, defaults.object(forKey: Key.streamAttenuationStrength) as? Double ?? 50))
        playsCallSounds = defaults.object(forKey: Key.callSounds) as? Bool ?? true
        mutesMedia = defaults.object(forKey: Key.mutesMedia) as? Bool ?? false
        loopsVideo = defaults.object(forKey: Key.loopsVideo) as? Bool ?? false
        viewerCinemaMode = defaults.object(forKey: Key.viewerCinemaMode) as? Bool ?? true
        // The pair from before accounts each had their own, read and never written.
        let legacyChannel = (defaults.object(forKey: Key.lastChannel) as? NSNumber)?.uint64Value
        legacyLastPlace = legacyChannel.map {
            LastPlace(guildID: (defaults.object(forKey: Key.lastGuild) as? NSNumber)?.uint64Value, channelID: $0)
        }
        lastPlaces = defaults.data(forKey: Key.lastPlaces)
            .flatMap { try? JSONDecoder().decode([String: LastPlace].self, from: $0) } ?? [:]
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
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            let isOn = ProcessInfo.processInfo.isLowPowerModeEnabled
            MainActor.assumeIsolated { self?.isLowPowerModeOn = isOn }
        }
        thermalStateObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            let isHot = AppSettings.isHot(ProcessInfo.processInfo.thermalState)
            MainActor.assumeIsolated {
                guard let self, self.isRunningHot != isHot else { return }
                self.isRunningHot = isHot
            }
        }
    }

    /// How the microphone is gated.
    /// Discord's three input profiles (its module 621380), in its order.
    enum InputProfile: String, CaseIterable, Hashable, Sendable {
        case voiceIsolation
        case studio
        case custom

        var title: String {
            switch self {
            case .voiceIsolation: "Voice Isolation"
            case .studio: "Studio"
            case .custom: "Custom"
            }
        }
    }

    enum VoiceInputMode: String, CaseIterable, Hashable, Sendable {
        case voiceActivity
        case pushToTalk
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
        static let messageBubbles = "appearance.messageBubbles"
        static let tintsOwnBubbles = "appearance.tintsOwnBubbles"
        static let screenEffects = "appearance.screenEffects"
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
        static let autoClips = "clips.auto"
        static let autoClipsReactions = "clips.autoReactions"
        static let autoClipsGameEvents = "clips.autoGameEvents"
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
        static let railHomeIcon = "appearance.railHomeIcon"
        /// Where the composer's own shape lived before the two bars shared one.
        /// Read once, for migration, and never written again.
        static let legacyComposerShape = "appearance.composerShape"
        static let composerControls = "appearance.composerControls"
        static let composerControlsInline = "appearance.composerControlsInline"
        static let sidebarStyle = "shell.sidebarStyle"
        static let sidebarPages = "shell.sidebarPages"
        static let loadsMessagePreviews = "shell.loadsMessagePreviews"
        static let showsServerBanners = "shell.showsServerBanners"
        static let sidebarShown = "shell.sidebarShown"
        static let sidebarWidth = "shell.sidebarWidth"
        static let nowBarNameplate = "appearance.nowBarNameplate"
        static let showsSummaryBar = "chat.showsSummaryBar"
        static let suppressedCosmetics = "accessibility.suppressedCosmetics"
        static let suppressesOwnCosmetics = "accessibility.suppressesOwnCosmetics"
        static let underlinesLinks = "accessibility.underlinesLinks"
        static let roleColorPlacement = "accessibility.roleColorPlacement"
        static let mutedSpokenDetails = "accessibility.mutedSpokenDetails"
        static let announcesNewMessages = "accessibility.announcesNewMessages"
        static let groupSpacing = "appearance.messageGroupSpacing"
        static let channelSpacing = "appearance.channelSpacing"
        static let categorySpacing = "appearance.categorySpacing"
        static let showsSeconds = "chat.showsSeconds"
        static let alwaysShowsTimestamps = "chat.alwaysShowsTimestamps"
        static let hidesMessageTimes = "chat.hidesMessageTimes"
        static let showsInspector = "diagnostics.showsPerformanceInspector"
        static let developerMode = "advanced.developerMode"
        static let hidesActivityCards = "memberList.hidesActivityCards"
        static let activityImpressions = "memberList.activityImpressions"
        static let memberListOrganization = "memberList.organization"
        static let collapsedMemberSections = "memberList.collapsedSections"
        static let groupsMembersInVoice = "memberList.groupsInVoice"
        static let launchDestination = "startup.launchDestination"
        static let lastGuild = "startup.lastGuildID"
        static let lastChannel = "startup.lastChannelID"
        static let lastPlaces = "startup.lastPlaces"
        static let showsUnreadCounts = "notifications.showsUnreadCounts"
        static let postsNotifications = "notifications.posts"
        static let notificationSound = "notifications.sound"
        static let mentionsOnly = "notifications.mentionsOnly"
        static let skinTone = "expressions.skinTone"
        static let mediaVolume = "media.volume"
        static let mutesMedia = "media.muted"
        static let loopsVideo = "media.loopsVideo"
        static let viewerCinemaMode = "media.viewerCinemaMode"
        static let voiceInput = "voice.inputDevice"
        static let voiceOutput = "voice.outputDevice"
        static let camera = "voice.cameraDevice"
        static let voiceInputVolume = "voice.inputVolume"
        static let voiceOutputVolume = "voice.outputVolume"
        static let inputMode = "voice.inputMode"
        /// The pre-2026-10-06 line, linear 0…1. Read once, to convert.
        static let voiceThreshold = "voice.activityThreshold"
        static let voiceThresholdDecibels = "voice.activityThresholdDecibels"
        static let automaticSensitivity = "voice.automaticInputSensitivity"
        static let inputProfile = "voice.inputProfile"
        static let echoCancellation = "voice.echoCancellation"
        static let adaptivePlayout = "voice.adaptivePlayout"
        static let automaticGainControl = "voice.automaticGainControl"
        static let pushToTalk = "voice.pushToTalkKey"
        /// Share Audio, under the key the old toggle used, so a reader's
        /// choice carries over.
        static let sharesAudio = "voice.sharesSystemAudio"
        static let goLiveResolution = "goLive.resolution"
        static let goLiveFrameRate = "goLive.frameRate"
        static let streamAttenuation = "voice.streamAttenuation"
        static let streamAttenuationStrength = "voice.streamAttenuationStrength"
        static let disabledVideo = "voice.disabledVideoUsers"
        static let silenceWarning = "voice.silenceWarning"
        static let activitySuggestionsDismissed = "voice.activitySuggestionsDismissed"
        static let stageMusicMuted = "voice.stageMusicMuted"
        static let stageWelcomeSeen = "voice.stageWelcomeSeen"
        static let fakeNitro = "fakeNitro.enabled"
        static let fakeNitroEmoji = "fakeNitro.emoji"
        static let fakeNitroStickers = "fakeNitro.stickers"
        static let fakeNitroStreamQuality = "fakeNitro.streamQuality"
        static let fakeNitroSkipsEmbedCheck = "fakeNitro.skipsEmbedCheck"
        static let autoCompressesImages = "uploads.autoCompressImages"
        static let syncsThemeAcrossDevices = "appearance.syncsThemeAcrossDevices"
        static let appliesThemeToProfiles = "appearance.syncProfileThemeWithUserTheme"
        static let anonymisesFileNames = "anonymiseFileNames.enabled"
        static let anonymisesByDefault = "anonymiseFileNames.byDefault"
        static let anonymisingMethod = "anonymiseFileNames.method"
        static let randomisedLength = "anonymiseFileNames.randomisedLength"
        static let consistentFileName = "anonymiseFileNames.consistent"
        static let focusStatus = "focus.status"
        static let focusCustomStatus = "focus.customStatus"
        static let focusRestores = "focus.restores"
        static let sharesNowPlaying = "nowPlaying.enabled"
        static let nowPlayingPlayers = "nowPlaying.players"
        static let nowPlayingShowsWhilePaused = "nowPlaying.showsWhilePaused"
        static let nowPlayingShowsThumbnails = "nowPlaying.showsThumbnails"
        static let nowPlayingShowsButtons = "nowPlaying.showsButtons"
        static let nowPlayingPrefixesBy = "nowPlaying.prefixesBy"
        static let nowPlayingMemberListLine = "nowPlaying.memberListLine"
        static let nowPlayingExcludedWords = "nowPlaying.excludedWords"
        static let nowPlayingFindsCovers = "nowPlaying.findsCovers"
        static let blockedRPCApplications = "activity.blockedRPCApplications"
        static let drawsCustomTypingIndicators = "previews.customTypingIndicators"
        static let showsServerHub = "previews.serverHub"
        static let voiceInviteCardStyle = "previews.voiceInviteCardStyle"
        static let silentTyping = "silentTyping.enabled"
        static let silentTypingShowsIcon = "silentTyping.showIcon"
        static let silentTypingInContextMenu = "silentTyping.contextMenu"
        static let silentTypingIsOn = "silentTyping.isEnabled"
        static let customPresences = "richPresence.presences"
        static let activeCustomPresence = "richPresence.active"
        static let lastCustomPresence = "richPresence.last"
        static let priorityPushToTalk = "voice.priorityPushToTalkKey"
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
