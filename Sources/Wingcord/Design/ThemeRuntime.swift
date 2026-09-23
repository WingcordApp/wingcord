import AppKit
import CoreGraphics
import Foundation
import Synchronization

// MARK: - Reaching the theme from both sides of the main actor
//
// `Palette` is read from two places with opposite requirements, and one storage
// scheme cannot serve both:
//
//  - **SwiftUI bodies**, on the main actor, which must *observe* the theme.
//    Eighty call sites read `Palette.canvas`, `Palette.accent` and their
//    siblings, and none of them takes a parameter. If a read there registers no
//    observation dependency, changing the theme repaints nothing until something
//    else happens to invalidate the view — which reads as a picker that does not
//    work.
//  - **The two drawn canvases**, off the main actor, which must *not* touch an
//    observable at all. `TimelineRowPainter` and `MemberRowPainter` are
//    `nonisolated` and run on a background executor; a main-actor read from
//    there is a compile error at best and a data race at worst.
//
// So the theme lives in two places that are written together: a lock-backed copy
// for the painters, and the observable store for the views. `ThemeAccess` picks
// between them by which thread is asking, which is the only signal available at
// a `nonisolated` static property with no parameters.
//
// THE COST OF THE MAIN-ACTOR PATH is one `Thread.isMainThread` — a thread-local
// read — plus an observation-registrar lookup. That is a handful of nanoseconds
// against a `Color` that SwiftUI is about to resolve and rasterise, and it is
// what buys eighty call sites the ability to observe a theme without one of them
// being edited.
//
// THE COST OF THE PAINTER PATH is one uncontended lock and a forty-byte memcpy,
// and `ThemeColors` is packed integers precisely so there is no retain traffic
// in it. `ThemeInk` goes further and hands the painters finished `CGColor`s,
// which is strictly less work than the `NSColor(Palette.x).cgColor` they used to
// build per row per frame.

/// The lock-backed copy of the theme, for readers that are not on the main
/// actor.
///
/// Written only from `ThemeStore`, which is main-actor, and only when the theme
/// actually changes.
nonisolated enum ThemeRuntime {
    private static let box = Mutex(ThemeColors.trueBlack)

    static var colors: ThemeColors { box.withLock { $0 } }

    /// Publishes a theme to every off-main reader.
    ///
    /// **Called before the observable store assigns its own property**, so a
    /// surface woken by the resulting invalidation cannot read the previous
    /// theme and draw one frame of the old ground.
    ///
    /// `@MainActor` because resolving the system accent reads the current
    /// appearance, which is main-actor state — and because the only caller is.
    @MainActor
    static func install(_ colors: ThemeColors) {
        box.withLock { $0 = colors }
        ThemeInk.install(colors)
    }
}

/// How `Palette` reaches whichever copy is correct for the caller.
nonisolated enum ThemeAccess {
    @inline(__always)
    static var colors: ThemeColors {
        // `Thread.isMainThread` rather than an actor hop: this is read from a
        // `nonisolated` computed property that a main-actor SwiftUI body calls
        // synchronously, and there is nowhere to `await`.
        if Thread.isMainThread {
            return MainActor.assumeIsolated { ThemeStore.shared.colors }
        }
        return ThemeRuntime.colors
    }
}

// MARK: - Ink for the drawn surfaces

/// The theme's colours as `CGColor`, resolved once per theme change.
///
/// **This exists because of what it replaces.** The painters used to write
/// `NSColor(Palette.surfaceRaised).cgColor` inline in a draw — a SwiftUI-to-AppKit
/// colour bridge and a fresh `CGColor` allocation, per row, per repaint, for a
/// value that changes a handful of times in a session. Every one of those sites
/// now reads a finished object.
///
/// Held behind the same kind of lock as `ThemeRuntime` and for the same reason:
/// the readers are `nonisolated` and run off the main actor.
///
/// `@unchecked Sendable`: every field is a `CGColor`, which is immutable once
/// created and documented as safe to read from any thread. The value is built on
/// the main actor when a theme is installed and only ever read afterwards — the
/// same arrangement, and the same reasoning, as `MessageTextStyle`'s fonts.
nonisolated struct ThemeInk: @unchecked Sendable {
    let canvas: CGColor
    let surface: CGColor
    let surfaceRaised: CGColor
    /// `surfaceRaised` at 85%, which is what an embed's card, a component's
    /// button and a poll's row are filled with. Pre-multiplied here rather than
    /// derived at each draw: `CGColor.copy(alpha:)` allocates, and a bot channel
    /// is nothing but rows that carry one of these.
    let cardFill: CGColor
    let accent: CGColor
    /// A row under the pointer on a drawn canvas, and the rule down the side of
    /// a quote. White at 7% and 15%, or black at 5% and 9% in a light room —
    /// **relative fills, deliberately unthemed**, and here only so a painter does
    /// not have to bridge a `Color` to get them.
    let hoverFill: CGColor
    let selectionFill: CGColor
    /// The pill behind a member row's typing dots.
    ///
    /// **The accent, not a status colour.** Typing is not a presence state —
    /// somebody idle or on Do Not Disturb can be typing — so borrowing a
    /// presence tint would say something the pill does not mean. It takes the
    /// theme's accent, which is what the app already uses for "this is
    /// happening now".
    let typingPill: CGColor
    /// Whether the theme is a light room. See `lift(_:)`.
    let isLight: Bool

    /// A painter's relative fill: white at `alpha` in a dark room, black at
    /// three quarters of it in a light one — `Color.relative` for a context that
    /// has no appearance to ask, resolved from the theme rather than from the
    /// thread, because a painter runs off the main actor and a thread's current
    /// appearance there is not the window's.
    func lift(_ alpha: CGFloat) -> CGColor {
        isLight
            ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha * 0.75)
            : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)
    }

    private static let box = Mutex(ThemeInk(.trueBlack, systemAccent: Self.fallbackAccent))

    static var current: ThemeInk { box.withLock { $0 } }

    /// **Main-actor**, because `controlAccentColor` is a catalog colour and
    /// resolving one reads the current appearance.
    @MainActor
    static func install(_ colors: ThemeColors) {
        let ink = ThemeInk(colors, systemAccent: resolvedSystemAccent())
        box.withLock { $0 = ink }
    }

    private init(_ colors: ThemeColors, systemAccent: CGColor) {
        canvas = Self.color(colors.canvas)
        surface = Self.color(colors.surface)
        let raised = Self.color(colors.surfaceRaised)
        surfaceRaised = raised
        cardFill = raised.copy(alpha: 0.85) ?? raised
        // A painter needs a concrete value and cannot draw with
        // `Color.accentColor`, which is a *style* the renderer evaluates against
        // the appearance rather than a colour. A theme that follows the system
        // therefore draws with the reader's control accent, resolved once — which
        // is what the per-row `NSColor` bridge was doing anyway.
        accent = colors.accent.map(Self.color) ?? systemAccent
        // `Palette.hoverFill` and `selectionFill`, resolved for the theme's own
        // appearance: a painter draws into a context, not into a view with an
        // appearance to ask.
        switch colors.appearance {
        case .dark:
            hoverFill = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07)
            selectionFill = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.15)
        case .light:
            hoverFill = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.05)
            selectionFill = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.09)
        }
        typingPill = accent
        isLight = colors.appearance == .light
    }

    private static func color(_ packed: UInt32) -> CGColor {
        CGColor(
            srgbRed: CGFloat((packed >> 16) & 0xFF) / 255,
            green: CGFloat((packed >> 8) & 0xFF) / 255,
            blue: CGFloat(packed & 0xFF) / 255,
            alpha: 1
        )
    }

    /// macOS's default blue, for the one moment before a theme has been
    /// installed — the static initialiser above may run on any thread, and
    /// resolving a catalog colour there would be reading the appearance off the
    /// main actor.
    private static let fallbackAccent = CGColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1)

    /// **The conversion is not optional.** `controlAccentColor` is a catalog
    /// colour with no components until it is resolved, and handing an
    /// unconverted one to a `CGContext` is how a draw ends up with a colour
    /// space the context cannot fill in.
    @MainActor
    private static func resolvedSystemAccent() -> CGColor {
        NSColor.controlAccentColor.usingColorSpace(.sRGB)?.cgColor ?? fallbackAccent
    }
}
