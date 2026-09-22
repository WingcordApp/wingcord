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
nonisolated struct DisplayNameGlyphRun {

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
    /// The line's own ascent and descent, unrounded.
    ///
    /// **`size.height` is these two rounded UP together, and that is why they
    /// are kept.** A layer host positions the whole box and never needs them; a
    /// painter placing this run against text drawn by `CTLineDraw` elsewhere has
    /// to land on the same baseline, and deriving it from the rounded height
    /// leaves the effect up to a point above the name it is meant to be.
    ///
    /// **They describe the FIRST line**, which is the same thing on a run of
    /// one. `DisplayNameEffectPainter` is the only reader and the transcript is
    /// the only surface that uses it, where a name always has exactly one line —
    /// see `lineCount`.
    let ascent: CGFloat
    let descent: CGFloat
    /// How many lines the name came out as.
    ///
    /// One unless the caller asked for more. The painter path asserts on it
    /// rather than assuming: a run of two lines placed by a single-line baseline
    /// would draw the second one through whatever is under the name.
    let lineCount: Int
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
    /// - Parameter maximumWidth: the widest this may come out. Past it the
    ///   text wraps, or — on the last line it is allowed — is truncated with an
    ///   ellipsis.
    /// - Parameter maximumLines: how many lines the name may take. **One by
    ///   default, so every existing caller is unchanged.** A profile gives a
    ///   name two, which is what Discord does: a long display name reads as a
    ///   name that wraps, where the same name truncated reads as a client that
    ///   cannot show it.
    ///
    /// **Truncation belongs here, and it is why the full profile broke on a
    /// long name.** A styled name is an `NSViewRepresentable`, so the
    /// `.lineLimit(1)` at the call site reaches nothing — it applies to
    /// `Text`, and this is a layer tree. The representable answered
    /// `sizeThatFits` with the text's whole measured width whatever it was
    /// proposed, so a name like "…reWasntA12 (You may Ping…)" reported nine
    /// hundred points, the header's `HStack` grew to hold it, and the card
    /// went with it: everything in the panel shifted out of the window.
    ///
    /// `CTLineCreateTruncatedLine` rather than a character count: the width
    /// of a name in one of these faces is not its length, and clipping mid
    /// glyph reads as a rendering fault rather than as a name that is too
    /// long.
    init?(
        text: String,
        font: NSFont,
        tracking: CGFloat,
        perGlyph: Bool,
        maximumWidth: CGFloat? = nil,
        maximumLines: Int = 1
    ) {
        guard !text.isEmpty else { return nil }

        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if tracking != 0 { attributes[.kern] = tracking }
        let attributed = NSAttributedString(string: text, attributes: attributes)

        let lines = Self.lay(
            out: attributed,
            attributes: attributes,
            maximumWidth: maximumWidth,
            maximumLines: max(1, maximumLines)
        )
        guard !lines.isEmpty else { return nil }

        // **One metric for every line, not each line's own.** A wrapped name
        // whose second line happened to carry no descender would otherwise sit
        // a point or two closer to the first than a name that did, which reads
        // as uneven leading rather than as two different names.
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var widest: CGFloat = 0
        for line in lines {
            var lineAscent: CGFloat = 0
            var lineDescent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil)
            ascent = max(ascent, lineAscent)
            descent = max(descent, lineDescent)
            widest = max(widest, Self.visibleWidth(of: line))
        }
        let lineHeight = ascent + descent
        let height = lineHeight * CGFloat(lines.count)
        guard widest > 0, height > 0 else { return nil }
        size = CGSize(width: widest.rounded(.up), height: height.rounded(.up))
        self.ascent = ascent
        self.descent = descent
        lineCount = lines.count

        let whole = CGMutablePath()
        var letters: [Glyph] = []
        if perGlyph { letters.reserveCapacity(text.count) }

        for (index, line) in lines.enumerated() {
            // The run's space is y-up with the origin at the box's bottom-left,
            // so the first line sits highest. For a single line this is `descent`
            // exactly, which is what this code did before it could wrap.
            let bottom = height - CGFloat(index + 1) * lineHeight
            letters += Self.collect(
                line: line,
                baseline: bottom + descent,
                lineBottom: bottom,
                lineHeight: lineHeight,
                perGlyph: perGlyph,
                into: whole
            )
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

    /// Breaks the name into at most `maximumLines` lines at `maximumWidth`.
    ///
    /// **`CTTypesetterSuggestLineBreak` rather than a character count**, for the
    /// reason truncation uses `CTLineCreateTruncatedLine`: the width of a name
    /// in one of these faces is not its length, and these faces are chosen by
    /// their owners rather than by this app.
    ///
    /// The last line this is allowed to make is truncated if there is more text
    /// after it — so a name too long even for two lines ends in an ellipsis
    /// rather than simply stopping.
    private static func lay(
        out attributed: NSAttributedString,
        attributes: [NSAttributedString.Key: Any],
        maximumWidth: CGFloat?,
        maximumLines: Int
    ) -> [CTLine] {
        // The token is drawn in the same face, so the ellipsis belongs to the
        // name rather than arriving in the system font beside it.
        //
        // **`CTLineCreateTruncatedLine` overshoots the width it is given** — by
        // about three points at 24pt, measured — because it fits the token
        // against the *raw* bounds rather than the visible ones. That was true
        // of the single-line path too and nobody noticed, because a name three
        // points over its cap only shows up where something is laid out beside
        // it. So the answer is checked and the ask reduced by the overshoot,
        // which converges on the first retry; the loop is bounded rather than
        // trusted.
        func truncate(_ line: CTLine, to width: CGFloat) -> CTLine {
            guard visibleWidth(of: line) > width else { return line }
            let token = CTLineCreateWithAttributedString(
                NSAttributedString(string: "\u{2026}", attributes: attributes)
            )
            var ask = width
            var best = line
            for _ in 0..<3 {
                guard ask > 0,
                      let attempt = CTLineCreateTruncatedLine(line, Double(ask), .end, token)
                else { break }
                best = attempt
                let over = visibleWidth(of: attempt) - width
                guard over > 0.01 else { return attempt }
                ask -= over + 0.5
            }
            return best
        }

        let whole = CTLineCreateWithAttributedString(attributed)
        guard let maximumWidth, maximumWidth > 0 else { return [whole] }
        guard maximumLines > 1 else { return [truncate(whole, to: maximumWidth)] }

        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length
        var lines: [CTLine] = []
        var start = 0
        while start < length && lines.count < maximumLines {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(maximumWidth))
            // A width too narrow for even one character would otherwise spin
            // here for ever. One character a line is wrong; a hang is worse.
            let taken = max(1, count)
            let isLast = lines.count == maximumLines - 1
            let range = CFRange(
                location: start,
                length: isLast ? length - start : taken
            )
            let line = CTTypesetterCreateLine(typesetter, range)
            lines.append(isLast ? truncate(line, to: maximumWidth) : line)
            start += taken
        }
        return lines
    }

    /// A line's width with its trailing whitespace taken off.
    ///
    /// **The break `CTTypesetterSuggestLineBreak` suggests keeps the space it
    /// broke at**, and that space counts toward `CTLineGetTypographicBounds`. So
    /// a wrapped name measured raw comes out wider than the width it was wrapped
    /// to — by one space per line — and the box it reports is wider than the
    /// column that asked for it. Every text stack subtracts this; ours has to as
    /// well, and a test asserting the wrapped width against the cap is what
    /// found it.
    private static func visibleWidth(of line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
    }

    /// Walks one line's glyphs into the run's own space.
    ///
    /// - Parameter baseline: where this line's baseline sits, measured up from
    ///   the box's bottom.
    /// - Parameter lineBottom: the foot of this line's own box, in the same
    ///   space. **Not the ink box**: CSS scales an inline-block about the centre
    ///   of its line box, so Gummy pivoting on ink bounds would swing a
    ///   descender around the wrong point.
    /// - Returns: the per-letter boxes, or an empty array when `perGlyph` is
    ///   false — Gummy is the one effect that asks for them.
    private static func collect(
        line: CTLine,
        baseline: CGFloat,
        lineBottom: CGFloat,
        lineHeight: CGFloat,
        perGlyph: Bool,
        into whole: CGMutablePath
    ) -> [Glyph] {
        var letters: [Glyph] = []
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
                let origin = CGPoint(x: positions[index].x, y: positions[index].y + baseline)
                var placement = CGAffineTransform(translationX: origin.x, y: origin.y)
                let box = CGRect(
                    x: origin.x, y: lineBottom,
                    width: advances[index].width, height: lineHeight
                )
                guard let outline = CTFontCreatePathForGlyph(runFont, glyphs[index], &placement)
                else {
                    // A space has no outline and that is not a failure — it
                    // still owns a box, and Gummy squashes an empty one so the
                    // wave keeps its phase across it.
                    if perGlyph { letters.append(Glyph(path: CGMutablePath(), box: box)) }
                    continue
                }
                whole.addPath(outline)
                if perGlyph { letters.append(Glyph(path: outline, box: box)) }
            }
        }
        return letters
    }
}
