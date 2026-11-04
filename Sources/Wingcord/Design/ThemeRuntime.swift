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
    /// Whether the theme is a light room. See `lift(_:)`.
    let isLight: Bool

    /// What words sit on, anywhere but the reader's own bubble.
    let plates: TextPlateInk
    /// The same in the other room, for prose on a surface that isn't in the
    /// theme's: a pale profile in a dark app. The theme's accent on the house's
    /// neutral ground. See `plates(isLight:)`.
    private let otherRoomPlates: TextPlateInk
    /// Where a picture will be, while it loads: `surfaceRaised` at half.
    let placeholderFill: CGColor

    // MARK: Bubbles — see `MessageBubble`

    /// The reader's own bubble: the accent, **deepened in lightness until
    /// white reads on it at 4.5:1** (`InkContrast.legible`). Hue and chroma
    /// kept, so a themed room's bubble is still its accent; macOS's own blue
    /// comes out a step darker than Messages', which sits under that floor.
    let ownBubble: CGColor
    let ownBubbleHover: CGColor
    /// What words sit on inside the reader's own bubble — white, where the
    /// room's plates are the accent and would vanish into it.
    let ownBubblePlates: TextPlateInk
    /// Everybody else's bubble: a neutral lift of the ground, the room's own
    /// grey rather than a colour of its own.
    let otherBubble: CGColor
    let otherBubbleHover: CGColor
    /// Laid over somebody else's bubble that mentions the reader — the row's
    /// yellow, kept inside the bubble the mention is in.
    let mentionedBubbleTint: CGColor

    /// A painter's relative fill: white at `alpha` in a dark room, black at
    /// three quarters of it in a light one — `Color.relative` for a context that
    /// has no appearance to ask, resolved from the theme rather than from the
    /// thread, because a painter runs off the main actor and a thread's current
    /// appearance there is not the window's.
    func lift(_ alpha: CGFloat) -> CGColor { Self.lift(alpha, isLight: isLight) }

    private static func lift(_ alpha: CGFloat, isLight: Bool) -> CGColor {
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
        let isLight = colors.appearance == .light
        self.isLight = isLight
        let placeholder = raised.copy(alpha: 0.5) ?? raised
        placeholderFill = placeholder
        plates = Self.roomPlates(canvas: colors.canvas, isLight: isLight, accent: accent, placeholder: placeholder)
        otherRoomPlates = Self.roomPlates(
            canvas: (isLight ? ThemeColors.trueBlack : ThemeColors.porcelain).canvas,
            isLight: !isLight,
            accent: accent,
            // The theme's raised surface would be a dark blot on a pale card.
            placeholder: Self.lift(0.10, isLight: !isLight)
        )

        let bubble = InkContrast.legible(Self.packed(accent), on: 0xFF_FF_FF)
        ownBubble = Self.color(bubble)
        ownBubbleHover = Self.blend(bubble, toward: 0xFF_FF_FF, by: 0.08)
        ownBubblePlates = TextPlateInk(
            quoteRule: Self.white(0.55),
            codeFill: Self.white(0.16),
            codeBorder: Self.white(0.28),
            mentionFill: Self.white(0.22),
            mentionHoverFill: Self.white(0.40),
            timestampFill: Self.white(0.18),
            // Opaque, for the reason the room's own covers are.
            spoilerHidden: Self.blend(bubble, toward: 0xFF_FF_FF, by: 0.30),
            spoilerHiddenHover: Self.blend(bubble, toward: 0xFF_FF_FF, by: 0.38),
            spoilerRevealed: Self.white(0.14),
            emojiPlaceholder: Self.white(0.20)
        )
        otherBubble = Self.lift(0.12, isLight: isLight)
        otherBubbleHover = Self.lift(0.16, isLight: isLight)
        mentionedBubbleTint = CGColor(srgbRed: 0.98, green: 0.80, blue: 0.08, alpha: isLight ? 0.22 : 0.16)
    }

    /// What words sit on in a room with this ground.
    private static func roomPlates(
        canvas: UInt32, isLight: Bool, accent: CGColor, placeholder: CGColor
    ) -> TextPlateInk {
        TextPlateInk(
            quoteRule: lift(0.26, isLight: isLight),
            codeFill: accent.copy(alpha: isLight ? 0.06 : 0.08) ?? accent,
            codeBorder: lift(0.12, isLight: isLight),
            mentionFill: accent.copy(alpha: isLight ? 0.15 : 0.24) ?? accent,
            mentionHoverFill: accent,
            timestampFill: lift(0.10, isLight: isLight),
            spoilerHidden: blend(canvas, toward: isLight ? 0 : 0xFF_FF_FF, by: isLight ? 0.34 : 0.22),
            spoilerHiddenHover: blend(canvas, toward: isLight ? 0 : 0xFF_FF_FF, by: isLight ? 0.40 : 0.28),
            spoilerRevealed: lift(0.08, isLight: isLight),
            emojiPlaceholder: placeholder
        )
    }

    /// What words sit on in a surface that is light or dark on its own account.
    func plates(isLight wanted: Bool) -> TextPlateInk {
        wanted == isLight ? plates : otherRoomPlates
    }

    private static func white(_ alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)
    }

    /// A colour as the 24-bit sRGB integer `InkContrast` works in — macOS's
    /// own blue for one that cannot be read back, as `fallbackAccent` is.
    private static func packed(_ color: CGColor) -> UInt32 {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let components = color.converted(to: space, intent: .defaultIntent, options: nil)?.components,
              components.count >= 3
        else { return 0x00_7A_FF }
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return byte(components[0]) << 16 | byte(components[1]) << 8 | byte(components[2])
    }

    /// `from` moved `fraction` of the way to `to`, opaque.
    private static func blend(_ from: UInt32, toward to: UInt32, by fraction: CGFloat) -> CGColor {
        func channel(_ shift: UInt32) -> CGFloat {
            let a = CGFloat((from >> shift) & 0xFF) / 255
            let b = CGFloat((to >> shift) & 0xFF) / 255
            return a + (b - a) * fraction
        }
        return CGColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
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

/// The fills a block of words sits on — a quote's rule, a code box, a mention's
/// plate, a spoiler's cover — for one kind of ground.
///
/// **A value of its own because there are two grounds.** The room's plates are
/// the accent at a whisper, which is right on the reading surface and invisible
/// on the reader's own bubble, which *is* the accent; there they are white. The
/// painter is handed one set or the other and draws the same way with either.
nonisolated struct TextPlateInk: @unchecked Sendable {
    /// The rule down a quote's leading edge (`--spine-default`).
    let quoteRule: CGColor
    /// Inline code and a fenced block: the accent at a whisper
    /// (`--background-code`, blurple at 8%) inside a hairline (`--border-normal`).
    let codeFill: CGColor
    let codeBorder: CGColor
    /// A mention's plate (`--mention-background`) — the accent at a quarter.
    let mentionFill: CGColor
    /// The same plate under the pointer, under white ink.
    let mentionHoverFill: CGColor
    /// An inline timestamp's plate (`--background-mod-normal`).
    let timestampFill: CGColor
    /// A concealed spoiler, and the same under the pointer.
    ///
    /// **Opaque, and that is the whole job.** The words are drawn in their own
    /// ink underneath, and a translucent cover lets them through — so it is the
    /// ground lifted toward its ink, which keeps a themed room's hue.
    let spoilerHidden: CGColor
    let spoilerHiddenHover: CGColor
    /// A revealed spoiler's plate (`--background-mod-subtle`).
    let spoilerRevealed: CGColor
    /// Where an inline emoji will be, while it loads.
    let emojiPlaceholder: CGColor

    /// What an AutoMod rule matched — Discord's `.highlight`: its yellow
    /// (`--yellow-new-36`, #FDB833) at 30%, in every theme.
    static let highlightFill = CGColor(srgbRed: 253 / 255, green: 184 / 255, blue: 51 / 255, alpha: 0.3)
}
