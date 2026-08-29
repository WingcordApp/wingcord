import AppKit
import CoreText

/// A display name laid out once, as outlines.
///
/// **Every effect paints the same glyphs; only the fill moves.** Five of the
/// seven never touch geometry at all, and the two that do move it by transform.
/// So the text is shaped once into `CGPath`s here and never measured again —
/// nothing in the render path calls Core Text, and a repaint costs the
/// compositor a quad rather than a framesetting pass.
///
/// Outlines rather than a `CATextLayer` because the effects need what a text
/// layer cannot give: a stroke under the fill (`paint-order: stroke fill`), a
/// gradient clipped to the glyphs, and per-letter transforms.
///
/// The coordinate space is **y-up with the origin at the box's bottom-left**,
/// which is Core Graphics' and Core Animation's own. The view is deliberately
/// not flipped so no path has to be mirrored on the way out.
struct DisplayNameGlyphRun {

    /// One letter, as `display: inline-block` sees it.
    struct Glyph {
        /// The outline, already positioned in the run's space.
        let path: CGPath
        /// The layout box — advance wide, line tall — that a per-letter
        /// transform scales about. **Not the ink box**: CSS scales an
        /// inline-block about the centre of its line box, so using the ink
        /// bounds would pivot a descender around the wrong point.
        let box: CGRect
    }

    /// The advance width and line height the label occupies. Effects bleed
    /// outside it — Neon's glow, Toon's and Pop's strokes — the same way
    /// Discord's negative margins let them.
    let size: CGSize
    /// The whole run as one outline.
    let path: CGPath
    /// The same outlines split per letter. Built only when the effect needs
    /// them, because Gummy is the one effect that does.
    let glyphs: [Glyph]
    /// The advance of "0" in this face at this size — CSS's `1ch`, and the unit
    /// Prism's tile is counted in.
    let zeroAdvance: CGFloat

    /// Lays out `text`, or returns nil when there is nothing to draw.
    ///
    /// - Parameter perGlyph: whether to split the run. Skipped for every effect
    ///   but Gummy, since it is the only one that transforms letters
    ///   independently.
    init?(text: String, font: NSFont, tracking: CGFloat, perGlyph: Bool) {
        guard !text.isEmpty else { return nil }

        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if tracking != 0 { attributes[.kern] = tracking }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let height = ascent + descent
        guard width > 0, height > 0 else { return nil }
        size = CGSize(width: width.rounded(.up), height: height.rounded(.up))

        let whole = CGMutablePath()
        var letters: [Glyph] = []
        if perGlyph { letters.reserveCapacity(text.count) }

        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            // The run's own font, not the one asked for: Core Text substitutes
            // per run for anything the chosen face has no glyph for, and asking
            // the wrong font for a path yields the wrong outline or none.
            let runFont = unsafeBitCast(
                CFDictionaryGetValue(
                    CTRunGetAttributes(run),
                    Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()
                ),
                to: CTFont.self
            )

            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetAdvances(run, CFRange(), &advances)

            for index in 0..<count {
                let origin = CGPoint(x: positions[index].x, y: positions[index].y + descent)
                var placement = CGAffineTransform(translationX: origin.x, y: origin.y)
                guard let outline = CTFontCreatePathForGlyph(runFont, glyphs[index], &placement)
                else {
                    // A space has no outline and that is not a failure — it
                    // still owns a box, and Gummy squashes an empty one so the
                    // wave keeps its phase across it.
                    if perGlyph {
                        letters.append(
                            Glyph(
                                path: CGMutablePath(),
                                box: CGRect(
                                    x: origin.x, y: 0,
                                    width: advances[index].width, height: height
                                )
                            )
                        )
                    }
                    continue
                }
                whole.addPath(outline)
                if perGlyph {
                    letters.append(
                        Glyph(
                            path: outline,
                            box: CGRect(
                                x: origin.x, y: 0,
                                width: advances[index].width, height: height
                            )
                        )
                    )
                }
            }
        }

        guard !whole.isEmpty else { return nil }
        path = whole
        glyphs = letters

        var zero: CGGlyph = 0
        var advance = CGSize.zero
        let ctFont = font as CTFont
        if CTFontGetGlyphsForCharacters(ctFont, [unichar(48)], &zero, 1) {
            CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &zero, &advance, 1)
        }
        // A face with no digit still needs a cycle; the em is the honest
        // stand-in and only Prism ever asks.
        zeroAdvance = advance.width > 0 ? advance.width : font.pointSize
    }
}
