import AppKit
import CoreText
import Synchronization

/// A Unicode emoji sized so its ink fills a square box, and where that ink sits.
///
/// **Discord draws every emoji as a picture that fills its box**, so a box is
/// the emoji's size. Apple's glyph is not drawn at its point size, and nothing
/// about it is linear — measured on this machine:
///
/// - the ink is **1.25x** the point size up to about 16 pt, and **1.0x** from
///   24 pt up, with a transition between;
/// - the advance is wider again — 23 at 16 pt, 1.44x — with the extra on both
///   sides of the ink, and it is rounded to whole points.
///
/// So a glyph sized to the box's height came out a quarter too big, and its
/// advance a half too wide: the drawn surfaces truncated it to "…" and a bio's
/// `Text` cut it off at its sides. The fix is to size by the **ink** and let the
/// advance's spacing overflow the box, where it draws nothing. One copy, for the
/// canvases and for SwiftUI alike — `INVARIANTS.md` §5.55.
nonisolated struct EmojiGlyphMetrics: Equatable, Sendable {
    /// The size the glyph is set at.
    let pointSize: CGFloat
    /// Its ink, from the pen position, in Core Text's space — y up from the
    /// baseline.
    let ink: CGRect
    /// Its advance, which is wider than its ink.
    let advance: CGFloat
    /// The line's ascent at that size, for a painter placing it by its top.
    let ascent: CGFloat

    /// The metrics for `glyph` filling a box `side` points square.
    ///
    /// Remembered per glyph and side: a measurement is a line built and its
    /// ink bounds rendered, and SwiftUI asks for the same answer on every pass
    /// over a bio.
    static func fitting(_ glyph: String, side: CGFloat) -> EmojiGlyphMetrics {
        let key = Key(glyph: glyph, side: side)
        return state.withLock { state in
            if let known = state.known[key] { return known }
            let fitted = fit(glyph, side: side, context: state.context)
            if state.known.count >= Self.capacity { state.known.removeAll(keepingCapacity: true) }
            state.known[key] = fitted
            return fitted
        }
    }

    // MARK: Measuring

    private struct Key: Hashable {
        var glyph: String
        var side: CGFloat
    }

    /// Plenty for every emoji a session draws at every size it draws them, and
    /// small enough to throw away whole when it fills.
    private static let capacity = 512

    private struct State {
        var known: [Key: EmojiGlyphMetrics] = [:]
        /// `CTLineGetImageBounds` needs a context to say where the ink lands.
        /// Nothing is drawn into it.
        let context: CGContext
    }

    private static let state = Mutex(State(context: CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!))

    /// The largest size, no larger than the box, whose ink fits inside it.
    ///
    /// Aimed with the ink measured at the box's own size, then stepped down by a
    /// quarter point where the step between Apple's two scales leaves it over.
    private static func fit(_ glyph: String, side: CGFloat, context: CGContext) -> EmojiGlyphMetrics {
        let probe = measure(glyph, size: side, context: context)
        let extent = max(probe.ink.width, probe.ink.height)
        guard extent > 0 else { return probe }
        var size = min(side, side * side / extent)
        var fitted = measure(glyph, size: size, context: context)
        while max(fitted.ink.width, fitted.ink.height) > side + 0.01, size > 1 {
            size -= 0.25
            fitted = measure(glyph, size: size, context: context)
        }
        return fitted
    }

    private static func measure(_ glyph: String, size: CGFloat, context: CGContext) -> EmojiGlyphMetrics {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: glyph,
            attributes: [.font: NSFont.systemFont(ofSize: size)]
        ))
        var ascent: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, nil, nil)
        return EmojiGlyphMetrics(
            pointSize: size,
            ink: CTLineGetImageBounds(line, context),
            advance: advance,
            ascent: ascent
        )
    }
}
