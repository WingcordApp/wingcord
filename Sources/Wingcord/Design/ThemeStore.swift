import AppKit
import Foundation
import Observation
import WingcordCore

/// The reader's theme, and the picture behind it.
///
/// **Its own store rather than a section of `AppSettings`**, for the reason that
/// file's header is entirely about: every `didSet` on an `@Observable` runs
/// during `init`, and a `didSet` that reaches another singleton whose own `init`
/// reaches back deadlocks the launch. `AppSettings` already talks to
/// `PresentationRevision`, and `PresentationRevision` reads `AppSettings`; adding
/// a third party to that cycle is how a launch hang gets built. This store talks
/// to `ThemeRuntime`, which is a lock and an enum and has no initialiser to wait
/// on, and it holds the same `isLoaded` latch for the one call that does escape.
///
/// **One observable property carries the colours.** Every `Palette` token reads
/// `colors` and nothing else, so a theme change invalidates exactly the views
/// that paint with it, and changing the *backdrop* — a different property —
/// invalidates only the two views that draw it.
@Observable
@MainActor
final class ThemeStore {
    static let shared = ThemeStore()

    /// False until `init` has returned. Nothing that escapes this type may
    /// happen before then — see the note above.
    @ObservationIgnored private var isLoaded = false

    // MARK: What is selected

    /// The chosen theme.
    ///
    /// Stored as a case name rather than an ordinal, so reordering
    /// `ThemePreset` cannot silently change what an existing preference means.
    private(set) var choice: ThemeChoice = .system

    /// The reader's own blend, kept whether or not it is the one selected.
    ///
    /// **Beside the selection, not inside it.** Stepping through the ten to
    /// compare them and coming back to Custom has to find the blend still there;
    /// a selection that carried its own payload would throw the reader's work
    /// away every time they looked at something else.
    private(set) var customSeed = ThemePreset.nightfall.seed

    /// Whether the custom blend keeps the reader's system accent colour rather
    /// than deriving one from its hue.
    private(set) var customFollowsSystemAccent = false

    /// How far the reader has asked every theme's ground to come forward,
    /// `0...1`. See `ThemeSeed.vividness`, and `DiscordTheme.readingVeil` for
    /// what it means for one of Discord's.
    ///
    /// **Settable, for the slider's binding** — every other write here is a
    /// method, but a slider wants a property. The `didSet` is guarded by
    /// `isLoaded`: an `@Observable`'s observers run during `init`, which is the
    /// deadlock the note at the top of this type is about.
    var vividness = 0.0 {
        didSet {
            guard isLoaded, vividness != oldValue else { return }
            defaults.set(vividness, forKey: Key.vividness)
            apply(notifyingDrawnSurfaces: !isAdjusting)
        }
    }

    /// The resolved colours every `Palette` token reads.
    ///
    /// Stored rather than computed: it is read many times per frame across the
    /// window, and re-deriving it would run the gamut fit's sixteen bisections
    /// on every one of those reads.
    private(set) var colors: ThemeColors = .trueBlack

    /// What the window's ground is made of, for the views that draw it.
    ///
    /// **Its own property, and compared on its own.** Two themes can share every
    /// flat colour and differ entirely in their ground — Sunset and Midnight
    /// Blurple derive the same tint — so a change that tested only `colors`
    /// would leave the window showing the theme before.
    private(set) var ground: ThemeGround = .trueBlack

    // MARK: The picture behind it

    /// The image filling the window behind the theme, if the reader set one.
    ///
    /// Its own property so that dragging the blur slider does not invalidate
    /// every view in the app that happens to read a `Palette` token.
    private(set) var backdrop: Backdrop?

    // MARK: A wallpaper's dark room

    /// Set while a wallpaper picture is behind the window and the reader asked
    /// for the dark room then (`WallpaperStore.forcesDarkAppearance`). A light
    /// theme is drawn as True Black meanwhile — its own choice is not touched
    /// and nothing is persisted, as a server's theme is an override too.
    private(set) var wallpaperForcesDark = false

    func setWallpaperForcesDark(_ forces: Bool) {
        guard forces != wallpaperForcesDark else { return }
        wallpaperForcesDark = forces
        apply(notifyingDrawnSurfaces: true)
    }

    // MARK: A server's theme

    /// The theme of the server the reader is in, while it is the one drawn —
    /// see `AppModel.activeServerTheme`. Nil is the reader's own.
    ///
    /// **An override, never a choice.** Nothing here is persisted and nothing
    /// the reader chose moves: leaving the server puts their own theme back
    /// exactly as it was, because it never stopped being the selection.
    private(set) var serverTheme: ActiveServerTheme?

    /// What the window's ground cross-fades on: a change of choice, or going
    /// into or out of a themed server — never an edit. See `ThemeGroundLayer`.
    var groundIdentity: GroundIdentity {
        GroundIdentity(choice: choice, server: serverTheme?.guildID)
    }

    /// The reader's picture, unless a server's theme is on — which **replaces
    /// the room, picture and all**. A server theme under a photograph would
    /// reach nothing but the surfaces, and "Use my theme" is the setting for a
    /// reader who wants their own.
    var shownBackdrop: Backdrop? { serverTheme == nil ? backdrop : nil }

    struct GroundIdentity: Equatable {
        var choice: ThemeChoice
        var server: GuildID?
    }

    // MARK: Reading

    /// The colours a choice would produce, without selecting it. The gallery's
    /// tiles are drawn from this.
    static func colors(
        for choice: ThemeChoice,
        customSeed: ThemeSeed,
        systemAccent: Bool,
        vividness: Double
    ) -> ThemeColors {
        switch choice {
        case .system: following.colors(vividness: vividness)
        case .preset(let preset): preset.colors(vividness: vividness)
        // Discord's flat surfaces are its tokens; vividness thins its veils and
        // touches nothing else.
        case .discord(let theme): theme.colors
        case .custom: ThemeColors(customSeed.at(vividness: vividness), followsSystemAccent: systemAccent)
        }
    }

    /// The ground a choice would produce, without selecting it.
    static func ground(for choice: ThemeChoice, customSeed: ThemeSeed, vividness: Double) -> ThemeGround {
        switch choice {
        case .system: following.ground(vividness: vividness)
        case .preset(let preset): preset.ground(vividness: vividness)
        case .discord(let theme): ThemeGround(theme, vividness: vividness)
        case .custom: ThemeGround(customSeed.at(vividness: vividness))
        }
    }

    /// The preset "Sync with computer" is drawing now.
    ///
    /// **Read while nothing is pinned**: `apply` lets go of the app's
    /// appearance before resolving this choice, so the app's effective
    /// appearance is the system's. Read under a pin it would be the pin.
    private static var following: ThemePreset {
        let dark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return .following(systemIsDark: dark)
    }

    // MARK: Writing

    /// Puts a server's theme on, or takes it off.
    func setServerTheme(_ theme: ActiveServerTheme?) {
        guard theme != serverTheme else { return }
        serverTheme = theme
        apply(notifyingDrawnSurfaces: true)
    }

    func select(_ choice: ThemeChoice) {
        guard adopt(choice) else { return }
        onChoose?(choice)
    }

    /// Selects a theme the account brought — "Sync theme across my devices"
    /// — without telling `onChoose`, which would write it straight back.
    /// - Returns: whether anything changed.
    @discardableResult
    func adopt(_ choice: ThemeChoice) -> Bool {
        guard choice != self.choice else { return false }
        self.choice = choice
        defaults.set(Self.storageValue(for: choice), forKey: Key.choice)
        apply(notifyingDrawnSurfaces: true)
        return true
    }

    /// Told of each theme the reader chooses, so the session can write it to
    /// the account. Set by the session; nil signed out.
    @ObservationIgnored var onChoose: ((ThemeChoice) -> Void)?

    /// Starts a picker gesture.
    ///
    /// **What this suppresses is the relayout, not the repaint.** Every SwiftUI
    /// surface follows the drag live, because they read `colors` and it is being
    /// written on every event. The two *drawn* canvases cannot: their rows hold
    /// `CTFrame`s with the theme's ink baked into them, so following a drag
    /// there means re-framesetting the whole transcript sixty times a second to
    /// change the tint of a code block. They catch up when the gesture ends,
    /// which is one relayout for a gesture instead of hundreds.
    func beginAdjusting() { isAdjusting = true }

    func endAdjusting() {
        guard isAdjusting else { return }
        isAdjusting = false
        PresentationRevision.shared.settingsDidChange()
    }

    @ObservationIgnored private var isAdjusting = false

    /// Edits the custom blend, selecting it if it was not already selected.
    ///
    /// One entry point rather than a setter per field: the picker moves two of
    /// the four at once when it shuffles, and four separate writes would derive
    /// the palette — and invalidate the window — four times for one change.
    func editCustom(_ transform: (inout ThemeSeed) -> Void) {
        var seed = customSeed
        transform(&seed)
        // Re-run through the initialisers so hue wrapping and every clamp apply
        // to a value a caller mutated in place — and stored without the
        // reader's vividness, which belongs to the reader rather than the blend.
        seed = seed.normalized.at(vividness: 0)
        let choiceChanged = choice != .custom
        guard seed != customSeed || choiceChanged else { return }
        customSeed = seed
        choice = .custom
        defaults.set(seed.storageValue, forKey: Key.customSeed)
        if choiceChanged { defaults.set(Self.storageValue(for: .custom), forKey: Key.choice) }
        apply(notifyingDrawnSurfaces: !isAdjusting)
    }

    func setCustomFollowsSystemAccent(_ follows: Bool) {
        guard follows != customFollowsSystemAccent else { return }
        customFollowsSystemAccent = follows
        defaults.set(follows, forKey: Key.customSystemAccent)
        choice = .custom
        defaults.set(Self.storageValue(for: .custom), forKey: Key.choice)
        apply(notifyingDrawnSurfaces: true)
    }

    func setBackdrop(_ backdrop: Backdrop?) {
        guard backdrop != self.backdrop else { return }
        // The previous picture is this app's copy of a file the reader chose —
        // see `BackdropLibrary.adopt`. Nothing else can reference it, so leaving
        // it behind would be an orphan in Application Support that grows by one
        // every time somebody changes their mind.
        if let outgoing = self.backdrop, outgoing.fileName != backdrop?.fileName {
            BackdropLibrary.discard(outgoing.fileName)
        }
        self.backdrop = backdrop
        defaults.set(backdrop?.storageValue, forKey: Key.backdrop)
        // Driven from here rather than from a view's `onChange`, so a picture is
        // being decoded before anything asks to draw it — and so the one place
        // that knows the backdrop moved is the one place that says so.
        BackdropRenderer.shared.refresh(for: backdrop)
    }

    // MARK: Resolution

    /// Derives the palette and publishes it to both sides of the main actor.
    ///
    /// **`ThemeRuntime` first, the observable property second.** The assignment
    /// is what wakes SwiftUI, and a canvas that repaints in response has to find
    /// the new theme already installed or it draws one frame of the old ground.
    private func apply(notifyingDrawnSurfaces: Bool) {
        // "Sync with computer" holds no appearance of its own: the system's is
        // the room, so it is let through before the choice is resolved.
        if choice == .system { Self.releaseAppearance() }
        let chosen = Self.colors(
            for: choice,
            customSeed: customSeed,
            systemAccent: customFollowsSystemAccent,
            vividness: vividness
        )
        // A light room under a wallpaper the reader wants dark is drawn as True
        // Black for as long as the picture is up — see `wallpaperForcesDark`.
        let forcedDark = wallpaperForcesDark && chosen.appearance == .light
        let dark = ThemePreset.following(systemIsDark: true)
        let own = forcedDark ? dark.colors(vividness: vividness) : chosen
        // A server's theme is drawn in the reader's own room: it carries a
        // version for each, and choosing which is the reader's theme's job.
        let server = serverTheme.flatMap { ServerTheme($0.theme, room: own.appearance) }

        // The ground first and on its own test — see `ground`. Written only
        // when it moved: an `@Observable` setter invalidates its readers
        // whether or not the value changed.
        let resolvedGround = server.map(ThemeGround.init(server:))
            ?? (forcedDark
                ? dark.ground(vividness: vividness)
                : Self.ground(for: choice, customSeed: customSeed, vividness: vividness))
        if resolvedGround != ground { ground = resolvedGround }

        let resolved = server?.colors ?? own
        // Before the colours go out, so every view woken by them — and the
        // transcript's text style, rebuilt on the appearance change — resolves
        // against the room it is about to be in. **And before the test below**:
        // True Black chosen while "Sync with computer" was already drawing it
        // changes no colour, but it does change who owns the appearance — and
        // left unpinned, the next switch to Light would put the system's black
        // labels on its near-black ground.
        if choice != .system || forcedDark { Self.pinAppearance(resolved.appearance) }
        BubbleTint.setLight(resolved.appearance == .light)
        guard resolved != colors || !isLoaded else { return }
        ThemeRuntime.install(resolved)
        colors = resolved
        guard isLoaded, notifyingDrawnSurfaces else { return }
        // The transcript's rows carry the theme's ink inside their laid-out
        // text, so a colour change is a relayout there even though it is only a
        // repaint everywhere else.
        PresentationRevision.shared.settingsDidChange()
    }

    /// **A chosen theme's appearance is the app's, whatever the system's is.**
    ///
    /// Every surface here is built for the room the theme makes, so a dark
    /// theme in a Mac set to Light has to stay dark: left to the system, it drew
    /// the system's black labels on this app's near-black ground — which is what
    /// every build did before a light theme existed, on any Mac in Light mode.
    /// App-wide rather than per window, so the settings windows, menus and
    /// alerts are the same room as the workspace.
    ///
    /// "Sync with computer" is the one choice that pins nothing: its room is
    /// always the system's appearance, so there is never a mismatch to prevent.
    private static func pinAppearance(_ appearance: ThemeAppearance) {
        let name: NSAppearance.Name = appearance == .light ? .aqua : .darkAqua
        guard NSApplication.shared.appearance?.name != name else { return }
        NSApplication.shared.appearance = NSAppearance(named: name)
    }

    /// Lets the system's appearance through — "Sync with computer".
    private static func releaseAppearance() {
        guard NSApplication.shared.appearance != nil else { return }
        NSApplication.shared.appearance = nil
    }

    /// The system's appearance moved. Only "Sync with computer" follows it;
    /// every other choice has its own pinned.
    private func systemAppearanceDidChange() {
        guard isLoaded, choice == .system else { return }
        apply(notifyingDrawnSurfaces: true)
    }

    private let defaults: UserDefaults
    @ObservationIgnored private var accentObserver: NSObjectProtocol?
    @ObservationIgnored private var appearanceObserver: NSKeyValueObservation?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        customSeed = (defaults.object(forKey: Key.customSeed) as? [Double])
            .flatMap(ThemeSeed.init(storageValue:)) ?? customSeed
        customFollowsSystemAccent = defaults.object(forKey: Key.customSystemAccent) as? Bool ?? false
        vividness = min(1, max(0, defaults.object(forKey: Key.vividness) as? Double ?? 0))
        choice = (defaults.object(forKey: Key.choice) as? String)
            .flatMap(Self.choice(forStorageValue:)) ?? .system
        backdrop = (defaults.object(forKey: Key.backdrop) as? [String: Any])
            .flatMap(Backdrop.init(storageValue:))
        // A picture whose file is gone — a reader who emptied Application
        // Support, or a defaults entry that outlived a reinstall — is not a
        // backdrop. Left in place it would draw as a black rectangle over the
        // theme, which reads as the theme being broken.
        if let backdrop, !BackdropLibrary.exists(backdrop.fileName) {
            self.backdrop = nil
            defaults.removeObject(forKey: Key.backdrop)
        }
        apply(notifyingDrawnSurfaces: false)

        // A theme that follows the system accent has to hear when it moves.
        // `PresentationRevision` watches the *appearance*, which is a different
        // signal and does not fire for this.
        accentObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let store = ThemeStore.shared
                guard store.colors.accent == nil else { return }
                ThemeRuntime.install(store.colors)
                PresentationRevision.shared.settingsDidChange()
            }
        }

        // Light ⇄ dark, for "Sync with computer". `[weak self]` rather than
        // `.shared`: this store is still being made, and reaching for the
        // singleton from inside its own initialiser waits on itself.
        appearanceObserver = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.systemAppearanceDidChange() }
        }

        // Last, and after every assignment above: from here on a setter may talk
        // to the rest of the app.
        isLoaded = true
        // Safe here and not one line earlier: `BackdropRenderer`'s own
        // initialiser holds nothing and reaches for nothing, so it cannot wait
        // on the `dispatch_once` token this frame is holding — which is the
        // deadlock `AppSettings`' header is about.
        BackdropRenderer.shared.refresh(for: self.backdrop)
    }

    // No `deinit`. This is a process-lifetime singleton, so the observer above
    // is deliberately held rather than balanced — the same arrangement, and the
    // same reasoning, as `PresentationRevision`'s.

    // MARK: Persistence

    static func storageValue(for choice: ThemeChoice) -> String {
        switch choice {
        case .system: systemStorageValue
        case .preset(let preset): preset.rawValue
        case .discord(let theme): discordStoragePrefix + theme.rawValue
        case .custom: customStorageValue
        }
    }

    static func choice(forStorageValue value: String) -> ThemeChoice? {
        if value == systemStorageValue { return .system }
        if value == customStorageValue { return .custom }
        if value.hasPrefix(discordStoragePrefix) {
            return DiscordTheme(rawValue: String(value.dropFirst(discordStoragePrefix.count)))
                .map(ThemeChoice.discord)
        }
        return ThemePreset(rawValue: value).map(ThemeChoice.preset)
    }

    /// Not a `ThemePreset` case, and deliberately not one a preset could ever
    /// take: a theme added later called "custom" would otherwise silently
    /// inherit every reader's blend.
    private static let customStorageValue = "·custom"

    /// "Sync with computer", out of the presets' namespace for the same reason.
    private static let systemStorageValue = "·system"

    /// Discord's themes live in a namespace of their own for the same reason:
    /// both sets name themes after the sky, and a house preset called "sunset"
    /// would otherwise quietly become Discord's.
    private static let discordStoragePrefix = "discord·"

    private enum Key {
        static let choice = "appearance.theme"
        static let customSeed = "appearance.themeCustomSeed"
        static let customSystemAccent = "appearance.themeCustomSystemAccent"
        static let vividness = "appearance.themeVividness"
        static let backdrop = "appearance.backdrop"
    }
}

// MARK: - Seed storage

extension ThemeSeed {
    /// Doubles in a fixed order: the head's hue and depth, the foot's, the
    /// lightness, the accent's turn, the angle — then a hue and a depth for
    /// each colour between the ends, in walk order.
    ///
    /// An array rather than a dictionary or a `Codable`: it is a few dozen bytes
    /// written when a gesture ends, and a JSON round trip to store a handful of
    /// numbers is the expensive way to do it.
    var storageValue: [Double] {
        [head.hue, head.depth, foot.hue, foot.depth, light, accentTurn, angle]
            + middle.flatMap { [$0.hue, $0.depth] }
    }

    /// **Every older form is accepted**, because a blend that fails to decode is
    /// silently replaced — and a reader who built one would see their theme
    /// reset for no reason they could find:
    ///
    /// - **four**, the one-colour form before the seed grew a second stop,
    ///   decodes to a theme whose two ends are the same hue;
    /// - **six**, the two-colour form before it grew an angle and a middle,
    ///   decodes at the house angle with nothing between the ends.
    init?(storageValue: [Double]) {
        let count = storageValue.count
        switch count {
        case 4:
            self.init(
                hue: storageValue[0],
                depth: storageValue[1],
                light: storageValue[2],
                accentTurn: storageValue[3]
            )
        case 6:
            self.init(
                head: ThemeStop(hue: storageValue[0], depth: storageValue[1]),
                foot: ThemeStop(hue: storageValue[2], depth: storageValue[3]),
                light: storageValue[4],
                accentTurn: storageValue[5]
            )
        case 7, 9, 11, 13:
            let middle = stride(from: 7, to: count, by: 2).map {
                ThemeStop(hue: storageValue[$0], depth: storageValue[$0 + 1])
            }
            self.init(
                head: ThemeStop(hue: storageValue[0], depth: storageValue[1]),
                middle: middle,
                foot: ThemeStop(hue: storageValue[2], depth: storageValue[3]),
                light: storageValue[4],
                accentTurn: storageValue[5],
                angle: storageValue[6]
            )
        default:
            return nil
        }
    }
}
