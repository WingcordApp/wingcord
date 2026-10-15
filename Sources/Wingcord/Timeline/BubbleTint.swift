import CoreGraphics
import Foundation
import Synchronization

/// What a bubble is filled with, for the painter, which runs off the main actor.
///
/// **Two grounds, chosen by what is behind the transcript** (REDESIGN.md R6):
///
///  - **Frosted** — a wallpaper picture or scene is up, and `BubbleFrostView`
///    shows its blurred copy through every bubble's outline. The fill here is
///    smoke over that frost (milk in a light room), **sized by the picture**:
///    exactly as much as the words need to keep 4.5:1 over the frost's
///    brightest patch (its darkest, for milk), and never less than a floor
///    that still reads as glass. The reader's bubble is the clearer of the
///    two, everybody else's a step denser, and a hairline rim catches the
///    light at the edge.
///  - **Plain** — the theme's own ground: a neutral lift, the reader's
///    brighter than everybody else's. No accent either way; the accent is the
///    reader's opt-in (`TimelineSettings.tintsOwnBubbles`).
///
/// Installed from the main actor whenever the wallpaper or the room changes;
/// read by value, so a painter mid-frame keeps a consistent set.
nonisolated struct BubbleTint: Sendable {
    var own: CGColor
    var ownHover: CGColor
    var other: CGColor
    var otherHover: CGColor
    /// A tapback or reaction chip somebody else put there. Over a frost, the
    /// denser smoke; on the theme's ground, a lift that holds its own over the
    /// bubble it rides.
    var badge: CGColor
    var badgeHover: CGColor
    /// The glass's edge, on a frosted bubble only.
    var rim: CGColor?

    private struct Inputs: Sendable {
        var frost: FrostLevels?
        var isLight = false
        /// Reduce Transparency: no frost, and fills that hide what is behind.
        var reducesTransparency = false
        /// Increase Contrast: denser fills and an edge every bubble wears.
        var increasesContrast = false
    }

    private static let box = Mutex((inputs: Inputs(), tint: BubbleTint.make(Inputs())))

    static var current: BubbleTint { box.withLock { $0.tint } }

    /// The levels of the frost behind the transcript, or nil when there is
    /// none.
    static func setFrost(_ levels: FrostLevels?) {
        box.withLock { state in
            guard state.inputs.frost != levels else { return }
            state.inputs.frost = levels
            state.tint = make(state.inputs)
        }
    }

    /// The two display options that change a bubble — read by the main actor
    /// from the system and handed over whenever they change.
    static func setAccessibility(reducesTransparency: Bool, increasesContrast: Bool) {
        box.withLock { state in
            guard state.inputs.reducesTransparency != reducesTransparency
                || state.inputs.increasesContrast != increasesContrast
            else { return }
            state.inputs.reducesTransparency = reducesTransparency
            state.inputs.increasesContrast = increasesContrast
            state.tint = make(state.inputs)
        }
    }

    /// Whether the wallpaper's frost may show through the bubbles: not under
    /// Reduce Transparency, which asks for surfaces that hide what is behind.
    static var showsFrost: Bool { box.withLock { !$0.inputs.reducesTransparency } }

    /// Whether the room is light — a light room's bubbles are milky, with dark
    /// words, rather than smoky with white ones.
    static func setLight(_ light: Bool) {
        box.withLock { state in
            guard state.inputs.isLight != light else { return }
            state.inputs.isLight = light
            state.tint = make(state.inputs)
        }
    }

    /// The tint for a set of inputs, without installing it — for tests, and
    /// for anything that wants to know without changing what is painted.
    static func resolve(
        frost: FrostLevels?,
        isLight: Bool,
        reducesTransparency: Bool = false,
        increasesContrast: Bool = false
    ) -> BubbleTint {
        make(Inputs(
            frost: frost, isLight: isLight,
            reducesTransparency: reducesTransparency, increasesContrast: increasesContrast
        ))
    }

    private static func make(_ inputs: Inputs) -> BubbleTint {
        let base = makeBase(inputs)
        guard inputs.increasesContrast, !inputs.reducesTransparency else { return base }
        // **Increase Contrast**: every bubble wears a firm edge, and the fill
        // between the words and the picture is a step denser.
        var tint = base
        let denser: (CGColor) -> CGColor = { color in
            color.copy(alpha: min(color.alpha + 0.12, 0.94)) ?? color
        }
        tint.own = denser(tint.own)
        tint.ownHover = denser(tint.ownHover)
        tint.other = denser(tint.other)
        tint.otherHover = denser(tint.otherHover)
        tint.badge = denser(tint.badge)
        tint.badgeHover = denser(tint.badgeHover)
        tint.rim = inputs.isLight ? black(0.28) : white(0.38)
        return tint
    }

    private static func makeBase(_ inputs: Inputs) -> BubbleTint {
        if inputs.reducesTransparency {
            // **Reduce Transparency**: solid fills — the picture behind does
            // not come through — and an edge only where contrast was asked for.
            let rim: CGColor? = inputs.increasesContrast ? (inputs.isLight ? black(0.28) : white(0.38)) : nil
            return inputs.isLight
                ? BubbleTint(
                    own: grey(0.86), ownHover: grey(0.83),
                    other: grey(0.93), otherHover: grey(0.90),
                    badge: grey(0.89), badgeHover: grey(0.86),
                    rim: rim
                )
                : BubbleTint(
                    own: grey(0.24), ownHover: grey(0.27),
                    other: grey(0.16), otherHover: grey(0.19),
                    badge: grey(0.21), badgeHover: grey(0.24),
                    rim: rim
                )
        }
        switch (inputs.frost, inputs.isLight) {
        case (let frost?, false):
            let needed = smoke(over: frost.brightest)
            let clear = min(max(0.30, needed), 0.72)
            let dense = min(clear + 0.16, 0.86)
            // The hover lifts the smoke a little, never below what the words need.
            return BubbleTint(
                own: black(clear), ownHover: black(max(needed, clear - 0.06)),
                other: black(dense), otherHover: black(max(needed, dense - 0.06)),
                badge: black(dense), badgeHover: black(max(needed, dense - 0.06)),
                rim: white(0.14)
            )
        case (let frost?, true):
            let clear = min(max(0.42, milk(over: frost.darkest)), 0.82)
            let dense = min(clear + 0.16, 0.92)
            return BubbleTint(
                own: white(clear), ownHover: white(min(clear + 0.08, 0.95)),
                other: white(dense), otherHover: white(min(dense + 0.08, 0.95)),
                badge: white(dense), badgeHover: white(min(dense + 0.08, 0.95)),
                rim: white(0.55)
            )
        case (nil, false):
            return BubbleTint(
                own: white(0.20), ownHover: white(0.24),
                other: white(0.10), otherHover: white(0.14),
                badge: white(0.18), badgeHover: white(0.24),
                rim: nil
            )
        case (nil, true):
            return BubbleTint(
                own: black(0.10), ownHover: black(0.13),
                other: black(0.05), otherHover: black(0.08),
                badge: black(0.09), badgeHover: black(0.13),
                rim: nil
            )
        }
    }

    // MARK: Sizing the smoke and the milk

    /// The lightest a bubble may be, in relative luminance, under the ink
    /// ramp's white words (94 %) for them to keep 4.5:1 — 0.155 gives 4.7:1.
    private static let lightestUnderWhite = 0.155
    /// The darkest it may be under the ramp's dark words (88 %) — 0.229 gives
    /// 4.5:1.
    private static let darkestUnderDark = 0.229

    /// The black that brings a patch of `luminance` down to
    /// `lightestUnderWhite`. Black at alpha `a` scales the patch's encoded
    /// value by `1 - a`.
    private static func smoke(over luminance: Double) -> Double {
        let patch = encoded(luminance), limit = encoded(lightestUnderWhite)
        return patch > limit ? 1 - limit / patch : 0
    }

    /// The white that lifts a patch of `luminance` up to `darkestUnderDark`.
    /// White at alpha `a` moves the encoded value `a` of the way to 1.
    private static func milk(over luminance: Double) -> Double {
        let patch = encoded(luminance), limit = encoded(darkestUnderDark)
        return patch < limit ? (limit - patch) / (1 - patch) : 0
    }

    /// Relative luminance to its sRGB-encoded grey.
    private static func encoded(_ luminance: Double) -> Double {
        luminance <= 0.0031308 ? luminance * 12.92 : 1.055 * pow(luminance, 1 / 2.4) - 0.055
    }

    private static func grey(_ value: Double) -> CGColor {
        CGColor(srgbRed: value, green: value, blue: value + 0.015, alpha: 1)
    }

    private static func white(_ alpha: Double) -> CGColor {
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)
    }

    private static func black(_ alpha: Double) -> CGColor {
        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha)
    }
}
