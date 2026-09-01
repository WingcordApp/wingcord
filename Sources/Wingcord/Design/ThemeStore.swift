import AppKit
import Foundation
import Observation

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
    private(set) var choice: ThemeChoice = .preset(.trueBlack)

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

    /// The resolved colours every `Palette` token reads.
    ///
    /// Stored rather than computed: it is read many times per frame across the
    /// window, and re-deriving it would run the gamut fit's sixteen bisections
    /// on every one of those reads.
    private(set) var colors: ThemeColors = .trueBlack

    // MARK: The picture behind it

    /// The image filling the window behind the theme, if the reader set one.
    ///
    /// Its own property so that dragging the blur slider does not invalidate
    /// every view in the app that happens to read a `Palette` token.
    private(set) var backdrop: Backdrop?

    // MARK: Reading

    /// The colours a choice would produce, without selecting it. The gallery's
    /// tiles are drawn from this.
    static func colors(for choice: ThemeChoice, customSeed: ThemeSeed, systemAccent: Bool) -> ThemeColors {
        switch choice {
        case .preset(let preset): preset.colors
        case .custom: ThemeColors(customSeed, followsSystemAccent: systemAccent)
        }
    }

    // MARK: Writing

    func select(_ choice: ThemeChoice) {
        guard choice != self.choice else { return }
        self.choice = choice
        defaults.set(Self.storageValue(for: choice), forKey: Key.choice)
        apply(notifyingDrawnSurfaces: true)
    }

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
        // to a value a caller mutated in place.
        seed = ThemeSeed(
            head: ThemeStop(hue: seed.head.hue, depth: seed.head.depth),
            foot: ThemeStop(hue: seed.foot.hue, depth: seed.foot.depth),
            light: seed.light,
            accentTurn: seed.accentTurn
        )
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
        let resolved = Self.colors(
            for: choice,
            customSeed: customSeed,
            systemAccent: customFollowsSystemAccent
        )
        guard resolved != colors || !isLoaded else { return }
        ThemeRuntime.install(resolved)
        colors = resolved
        guard isLoaded, notifyingDrawnSurfaces else { return }
        // The transcript's rows carry the theme's ink inside their laid-out
        // text, so a colour change is a relayout there even though it is only a
        // repaint everywhere else.
        PresentationRevision.shared.settingsDidChange()
    }

    private let defaults: UserDefaults
    @ObservationIgnored private var accentObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        customSeed = (defaults.object(forKey: Key.customSeed) as? [Double])
            .flatMap(ThemeSeed.init(storageValue:)) ?? customSeed
        customFollowsSystemAccent = defaults.object(forKey: Key.customSystemAccent) as? Bool ?? false
        choice = (defaults.object(forKey: Key.choice) as? String)
            .flatMap(Self.choice(forStorageValue:)) ?? .preset(.trueBlack)
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

    private static func storageValue(for choice: ThemeChoice) -> String {
        switch choice {
        case .preset(let preset): preset.rawValue
        case .custom: customStorageValue
        }
    }

    private static func choice(forStorageValue value: String) -> ThemeChoice? {
        if value == customStorageValue { return .custom }
        return ThemePreset(rawValue: value).map(ThemeChoice.preset)
    }

    /// Not a `ThemePreset` case, and deliberately not one a preset could ever
    /// take: a theme added later called "custom" would otherwise silently
    /// inherit every reader's blend.
    private static let customStorageValue = "·custom"

    private enum Key {
        static let choice = "appearance.theme"
        static let customSeed = "appearance.themeCustomSeed"
        static let customSystemAccent = "appearance.themeCustomSystemAccent"
        static let backdrop = "appearance.backdrop"
    }
}

// MARK: - Seed storage

extension ThemeSeed {
    /// Six doubles, in a fixed order: the head's hue and depth, the foot's, then
    /// the lightness and the accent's turn.
    ///
    /// An array rather than a dictionary or a `Codable`: it is forty-eight bytes
    /// written when a gesture ends, and a JSON round trip to store six numbers
    /// is the expensive way to do it.
    var storageValue: [Double] {
        [head.hue, head.depth, foot.hue, foot.depth, light, accentTurn]
    }

    /// **Four is accepted as well as six**, and it is the one-colour form this
    /// seed had before it grew a second stop. A defaults entry written by an
    /// earlier build decodes into a theme whose two ends are the same hue, which
    /// is exactly what it meant — rather than into nothing, which would silently
    /// reset a reader's blend.
    init?(storageValue: [Double]) {
        switch storageValue.count {
        case 6:
            self.init(
                head: ThemeStop(hue: storageValue[0], depth: storageValue[1]),
                foot: ThemeStop(hue: storageValue[2], depth: storageValue[3]),
                light: storageValue[4],
                accentTurn: storageValue[5]
            )
        case 4:
            self.init(
                hue: storageValue[0],
                depth: storageValue[1],
                light: storageValue[2],
                accentTurn: storageValue[3]
            )
        default:
            return nil
        }
    }
}
