import Foundation
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
@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

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
            PresentationRevision.shared.textScaleDidChange()
        }
    }

    /// Compact mode: tighter message rows, no run spacing.
    var isCompactMode = false {
        didSet { defaults.set(isCompactMode, forKey: Key.compactMode) }
    }

    /// Whether the member list is shown by default in a new guild.
    var showsMemberListByDefault = true {
        didSet { defaults.set(showsMemberListByDefault, forKey: Key.showsMemberList) }
    }

    // MARK: Chat

    /// 24-hour timestamps regardless of locale.
    var uses24HourTime = false {
        didSet { defaults.set(uses24HourTime, forKey: Key.use24Hour) }
    }

    /// Whether link previews unfurl.
    var showsEmbeds = true {
        didSet { defaults.set(showsEmbeds, forKey: Key.showsEmbeds) }
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

    // MARK: Diagnostics

    /// Shows the performance inspector overlay.
    var showsPerformanceInspector = false {
        didSet { defaults.set(showsPerformanceInspector, forKey: Key.showsInspector) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Read through `object(forKey:)` rather than `bool(forKey:)`: the
        // typed accessors return `false` for a key that was never written, which
        // is indistinguishable from a deliberate `false` and silently overrides
        // every default that should be `true`.
        storedTextScale = defaults.object(forKey: Key.textScale) as? Double ?? 1.0
        isCompactMode = defaults.object(forKey: Key.compactMode) as? Bool ?? false
        showsMemberListByDefault = defaults.object(forKey: Key.showsMemberList) as? Bool ?? true
        uses24HourTime = defaults.object(forKey: Key.use24Hour) as? Bool ?? false
        showsEmbeds = defaults.object(forKey: Key.showsEmbeds) as? Bool ?? true
        playsAnimatedContent = defaults.object(forKey: Key.playsAnimated) as? Bool ?? true
        loadsImagesAutomatically = defaults.object(forKey: Key.loadsImages) as? Bool ?? true
        showsPerformanceInspector = defaults.object(forKey: Key.showsInspector) as? Bool ?? false
    }

    private enum Key {
        static let textScale = "appearance.textScale"
        static let compactMode = "appearance.compactMode"
        static let showsMemberList = "appearance.showsMemberList"
        static let use24Hour = "chat.use24HourTime"
        static let showsEmbeds = "chat.showsEmbeds"
        static let playsAnimated = "chat.playsAnimatedContent"
        static let loadsImages = "chat.loadsImagesAutomatically"
        static let showsInspector = "diagnostics.showsPerformanceInspector"
    }
}
