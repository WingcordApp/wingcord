import SwiftUI

// MARK: - Flyout metrics
//
// The second surface in Wingcord whose geometry was *measured* rather than
// designed, by the method written up in `docs/HANDOFF.md` under "Replicating a
// window is a measurement problem". Every number below came out of the live
// reference: its window frame from the window server, its internal geometry from
// captures of the panel composited over black, grey, white, red and blue with a
// matching "closed" capture of the same pixels for the ground.
//
// Nothing here should be rounded toward a tidier number. The halves are real —
// 57.5, 13.8, 25.5 — and the rhythm only reads correctly when the whole set is
// kept. Where a value differs from the reference on purpose it says so.

nonisolated enum HotkeyMetrics {

    // MARK: The window

    /// The panel's own size. Larger than what is drawn, because the shadow needs
    /// somewhere to fall: the visible flyout is `bodyWidth × bodyHeight` inset
    /// `shadowMargin` on every side, and the tail lives inside the top margin.
    static let panelWidth: CGFloat = 346
    static let panelHeight: CGFloat = 196
    static let shadowMargin: CGFloat = 13

    static let bodyWidth = panelWidth - shadowMargin * 2   // 320
    static let bodyHeight = panelHeight - shadowMargin * 2 // 170

    /// Between the anchoring control's edge and the panel's. The tail crosses
    /// exactly this span, which is why it is not a design choice: shrink it and
    /// the tail's tip ends up inside the button.
    static let anchorGap: CGFloat = 7

    // MARK: The body

    /// Continuous, not circular. Fitted against the reference's own corner over
    /// 62 rows: continuous 21 lands at 0.19px RMS, circular 21 at 0.36px, and
    /// 20 and 22 are three times worse in both styles.
    static let cornerRadius: CGFloat = 21

    /// The rim. One point wide, with a vertical gradient in its opacity — the
    /// top and bottom edges are three times the sides, which is what makes the
    /// panel read as lit from above and below rather than outlined.
    static let borderWidth: CGFloat = 1
    static let borderTopOpacity: Double = 0.30
    static let borderSideOpacity: Double = 0.098
    static let borderBottomOpacity: Double = 0.20

    // MARK: The tail

    /// Where the cone's apex would be, above the body's top edge, if the tip
    /// were a point. It is not — the drawn tip is `tailTipRadius` of fillet,
    /// which puts the topmost ink 1.4 below the panel's own top edge.
    static let tailHeight: CGFloat = 12.95
    /// Half the cone's span where it meets the body. Very nearly `tailHeight`,
    /// which is what makes the sides 45° — the reference's measured slope is
    /// 0.983, not 1.
    static let tailHalfWidth: CGFloat = 12.72
    /// The tip is a fillet, not a point.
    static let tailTipRadius: CGFloat = 5.5
    /// Where the tail meets the body the outline leaves the cone and lands
    /// further out, tangent to the body's edge.
    ///
    /// It IS a circular fillet, and a large one — six points against a cone
    /// thirteen tall. Measured subpixel against the reference: its outline
    /// leaves the cone about 1.8 above the body's edge and lands about 2.4
    /// further out, which is the tangent geometry of a six-point arc and not of
    /// the two-point one it looks like.
    static let tailBaseRadius: CGFloat = 7

    // MARK: Key caps

    static let capHeight: CGFloat = 21.7
    /// A modifier's glyph is narrow, so every cap is at least square-ish. Both
    /// numbers are measured: ⌘ lands at exactly 24 and Space at exactly 45.
    static let capMinWidth: CGFloat = 24
    static let capHorizontalPadding: CGFloat = 6
    static let capSpacing: CGFloat = 4
    static let capRadius: CGFloat = 4

    /// The caps' top edge, from the body's. **Not centred in the space above the
    /// divider** — the reference holds this row and the hint row at fixed
    /// heights, which is how the hint can vanish while recording without the
    /// keys jumping.
    static let capsTop: CGFloat = 57.8
    /// A half point of light along the cap's top edge, and a half point of shade
    /// just under its bottom one. Both measured against the cap's own fill: the
    /// light is white at 15% over two device rows, the shade is black at 37% one
    /// row below the cap.
    static let capHighlightOpacity: Double = 0.33
    static let capShadowOpacity: Double = 0.5
    static let capShadowOffset: CGFloat = 0.75
    static let capShadowBlur: CGFloat = 0.25

    // MARK: The hint

    /// The hint row's own box. Its height is the info glyph's; the sentence is
    /// centred in it.
    static let hintTop: CGFloat = 92
    static let hintHeight: CGFloat = 18
    static let hintGlyphSide: CGFloat = 14
    static let hintGlyphGap: CGFloat = 5.5
    /// The sentence's box centre sits above its ink centre by half the
    /// difference between ascender and descender; the glyph's does not. Nudging
    /// the text down by this puts both inks on the line the reference has them
    /// on. Measured against a render, not reasoned about.
    static let hintTextBaselineNudge: CGFloat = -0.5

    // MARK: The footer

    /// The hairline, from the body's top edge. Half a point — one device pixel
    /// on a Retina display, and exactly what the reference draws.
    static let dividerY: CGFloat = 130
    static let dividerHeight: CGFloat = 0.5

    static var footerHeight: CGFloat { bodyHeight - dividerY }  // 40

    static let footerLeading: CGFloat = 16
    static let footerTrailing: CGFloat = 12
    /// Between every item on the footer's trailing side.
    static let footerSpacing: CGFloat = 6
    static let markSide: CGFloat = 14
    static let markGap: CGFloat = 8

    /// The outlined chips that name a key in the footer.
    static let chipHeight: CGFloat = 18
    static let chipMinWidth: CGFloat = 18
    static let chipHorizontalPadding: CGFloat = 4
    static let chipRadius: CGFloat = 6
    static let chipBorderWidth: CGFloat = 1

    // MARK: The flash
    //
    // When a binding is accepted the panel washes green from the top edge down.
    // Both durations are measured off a 240 Hz capture, frame by frame: it holds
    // for ten frames and fades over thirty-nine.

    static let flashHold: TimeInterval = 0.167
    static let flashFade: TimeInterval = 0.645

    /// The fade's shape, fitted to the reference's own thirty-nine frames.
    ///
    /// Neither `.linear` nor `.easeOut`: the measured curve sits between them
    /// and is closer to `1 - (1 - p)^1.2`. Fitting a cubic to the samples lands
    /// at 0.015 RMS against 0.049 for linear and 0.099 for `.easeOut`, which is
    /// the difference between a flash that decays the way the reference's does
    /// and one that visibly lingers.
    static let flashFadeCurve = Animation.timingCurve(0.10, 0.00, 0.45, 0.65, duration: flashFade)

    /// The wash's strength at the top edge, drawn additively over the material.
    ///
    /// Solved rather than picked: the reference's own delta at the top is
    /// (5.1, 15.6, 6.6) over its material, and `Color.green` at 7.5% in
    /// `.plusLighter` reproduces all three channels to within one and a half
    /// parts in 255. A normal blend cannot — every channel of the reference's
    /// delta is positive, which no blend toward a saturated green produces.
    static let flashOpacity: Double = 0.075

    // MARK: Type
    //
    // The reference draws in Inter, because its settings window is a web view
    // and Inter is what its frontend bundles. Wingcord draws in the system font,
    // matched by OPTICAL SIZE rather than by nominal size: the reference's
    // 11px caps and 13px hint have Inter's larger x-height, and SF Pro needs
    // half a point more to put the same amount of ink on screen. Both sizes were
    // settled by rendering every candidate and ranking by ink width and shape.
    //
    // Fixed sizes, not relative styles — unlike the settings window, whose rows
    // grow with the system text size. This panel is a fixed 346×196 and a
    // sentence that grew inside it would be a sentence clipped by it.

    static let capLabel = Font.system(size: 11.5)
    static let hint = Font.system(size: 13.5)
    static let wordmark = Font.system(size: 11.5, weight: .medium)
    static let footerLabel = Font.system(size: 11.5)
    static let chipLabel = Font.system(size: 10)
}

// MARK: - Surfaces
//
// Every fill is relative to what is behind it, for the same reason the settings
// window's are: what is behind it is a translucent panel over the reader's
// desktop, and an absolute hex would be one specific grey over one specific
// wallpaper. The opacities are solved values — each was recovered from the
// reference's own pixels against a known ground.

nonisolated enum HotkeySurface {

    /// What the panel's glass is lifted by.
    ///
    /// **Solved, not chosen.** `.glassEffect(.regular)` alone lands consistently
    /// darker than the reference's material — twelve parts in 255 over black,
    /// seven over mid grey, four over white. One white overlay corrects all
    /// three at once, and the fit across five backdrops puts it at 4.8% with a
    /// residual of 3.6 parts in 255. Above the glass rather than tinted into it,
    /// for the same reason every surface in the settings window is: a value over
    /// a material is measurable and a value inside one is whatever the system
    /// decides to do with it.
    static let lift = Color.white.opacity(0.048)

    /// A key cap, over the panel's material.
    static let cap = Color.white.opacity(0.107)
    /// The half-point of light along a cap's top edge, over the cap's own fill.
    static let capHighlight = Color.white.opacity(HotkeyMetrics.capHighlightOpacity)
    /// The half-point of shade under a cap. Strong, and it is what makes the cap
    /// sit *on* the panel rather than in it.
    ///
    /// **Drawn as its own offset shape, not as `.shadow` on the fill.** A drop
    /// shadow is scaled by the alpha of the thing casting it, and the cap's fill
    /// is white at eleven percent — so `.shadow` on it produces a shade at
    /// eleven percent of the strength asked for, which is no shade at all.
    static let capShadow = Color.black.opacity(HotkeyMetrics.capShadowOpacity)
    /// The hairline over the footer.
    static let divider = Color.white.opacity(0.093)
    /// The outline of a footer chip.
    static let chipBorder = Color.white.opacity(0.18)
}
