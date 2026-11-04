import AppKit
import CoreText
import Foundation
import WingcordCore

/// One message's text, laid out at one width.
///
/// Built once and reused until the width, the text or the presentation style
/// changes. Holding the `CTFrame` rather than re-framesetting at draw time is
/// the whole point: framesetting is where the cost is, and drawing an existing
/// frame is a blit of already-positioned glyphs.
///
/// The link and emoji rectangles are resolved **here**, at layout time, rather
/// than during hit testing or painting. A pointer moving across a transcript
/// asks "what is under me?" on every event, and walking CoreText runs to answer
/// that is work done at pointer rate rather than at layout rate.
nonisolated final class TimelineTextBlock: @unchecked Sendable {
    let text: MessageText
    let frame: CTFrame
    let size: CGSize
    /// Where each inline emoji's box landed, in the block's own coordinates
    /// (origin top-left, y increasing downward).
    let emojiRects: [(rect: CGRect, emoji: EmojiRef)]
    /// Standard emoji in the text, outside code, each with its box — what a
    /// click on one opens the default emoji card from. A standard emoji is a
    /// glyph rather than a run delegate, so it is found by its grapheme.
    let unicodeEmojiRects: [(rect: CGRect, emoji: EmojiRef)]
    /// Where each inline SF Symbol's box landed, in the block's own coordinates.
    let symbolRects: [(rect: CGRect, name: String)]
    /// Clickable regions, resolved once.
    let linkRects: [(rect: CGRect, target: MessageText.LinkTarget)]
    /// Concealed regions, painted over until revealed — one per line a spoiler
    /// crosses, each carrying **which** spoiler it belongs to, so a spoiler that
    /// wraps is revealed by one click rather than one per line.
    let spoilerRects: [(rect: CGRect, spoiler: Int)]
    /// The plate under each plated run, one per line it crosses, with the
    /// index of its `MessageText.Plate`.
    let plateRects: [(rect: CGRect, plate: Int)]
    /// The rule down each quote's leading edge.
    let quoteRules: [CGRect]
    /// The box around each fenced code block.
    let codeBlockRects: [CGRect]
    /// Each line's place, for selection: which characters it holds and the
    /// band it occupies, in the block's own coordinates.
    private let lineBoxes: [LineBox]
    /// How many lines the words broke into.
    var lineCount: Int { lineBoxes.count }
    /// The first line's baseline, from the block's top. What a send's flight
    /// lines the words up on, so they leave the composer without jumping.
    var firstBaseline: CGFloat { lineBoxes.first?.baseline ?? 0 }

    private struct LineBox {
        let line: CTLine
        let range: CFRange
        let originX: CGFloat
        let top: CGFloat
        let baseline: CGFloat
        let bottom: CGFloat
    }

    /// - Parameter hugsText: lay the words out at the width their widest line
    ///   takes rather than at `width`. **A bubble's shape is that width**;
    ///   everywhere else §4.85 holds and a block is the width it was given.
    init(text: MessageText, width: CGFloat, style: MessageTextStyle, hugsText: Bool = false) {
        self.text = text

        let framesetter = CTFramesetterCreateWithAttributedString(text.attributed)
        // **A fenced block at either edge reserves its own box.** CoreText
        // honours a paragraph's space before and after only BETWEEN
        // paragraphs — never above the frame's first line or below its last —
        // so a block that opens or closes the message would have its box drawn
        // over the line above or the row below.
        let insets = Self.edgeInsets(for: text, style: style)
        var laid = Self.frame(of: framesetter, width: width, bottomInset: insets.bottom)
        var width = width
        // **Relaid at the hugged width rather than drawn in the wide frame**, so
        // every rectangle resolved below — a code block's box, a spoiler's
        // cover — spans the bubble rather than the lane. Kept only when it
        // breaks the same lines: a frame that wrapped differently is a frame
        // somebody measured wrong, and the wide one is still right.
        if hugsText, let hugged = Self.huggedWidth(of: laid.frame, in: text.attributed), hugged < width {
            let narrow = Self.frame(of: framesetter, width: hugged, bottomInset: insets.bottom)
            if Self.lineCount(of: narrow.frame) == Self.lineCount(of: laid.frame) {
                laid = narrow
                width = hugged
            }
        }
        let frameHeight = laid.height
        size = CGSize(width: width, height: frameHeight + insets.top + insets.bottom)
        frame = laid.frame

        var runs = ResolvedRuns()
        Self.resolveRuns(
            in: frame,
            // Line origins are measured from the path's own origin, so the
            // flip is taken from the top of the path, not of the block.
            frameTop: insets.top + frameHeight,
            width: width,
            text: text,
            emojiWidth: style.emojiWidth,
            emojiAscent: style.emojiAscent,
            symbolSide: style.symbolSide,
            codeBlockPadding: style.codeBlockPadding,
            into: &runs
        )
        emojiRects = runs.emoji
        unicodeEmojiRects = runs.unicodeEmoji
        symbolRects = runs.symbols
        linkRects = runs.links
        spoilerRects = runs.spoilers
        plateRects = runs.plates
        quoteRules = runs.quotes
        codeBlockRects = runs.codeBlocks
        lineBoxes = Self.lineBoxes(in: frame, frameTop: insets.top + frameHeight)
    }

    private static func lineBoxes(in frame: CTFrame, frameTop: CGFloat) -> [LineBox] {
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return [] }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        return zip(lines, origins).map { line, origin in
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let baseline = frameTop - origin.y
            return LineBox(
                line: line, range: CTLineGetStringRange(line), originX: origin.x,
                top: baseline - ascent, baseline: baseline, bottom: baseline + descent
            )
        }
    }

    /// The words framed into a column `width` wide, and the column's height.
    private static func frame(
        of framesetter: CTFramesetter,
        width: CGFloat,
        bottomInset: CGFloat
    ) -> (frame: CTFrame, height: CGFloat) {
        var fitRange = CFRange()
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            &fitRange
        )
        // Round up. A fractional height leaves the next row starting on a
        // half-pixel, and a column of rows each half a point short accumulates
        // into a visible drift against the scroll position.
        let height = ceil(suggested.height)
        let path = CGPath(
            rect: CGRect(x: 0, y: bottomInset, width: width, height: height),
            transform: nil
        )
        return (CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), height)
    }

    /// The width the widest line actually takes: its origin and its ink,
    /// **less its trailing whitespace** (§2.8 — CoreText counts it), plus the
    /// trailing inset a fenced block's paragraph keeps from the column's edge,
    /// or a hugged column would break that block's lines one character early.
    private static func huggedWidth(of frame: CTFrame, in text: NSAttributedString) -> CGFloat? {
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return nil }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var widest: CGFloat = 0
        for (line, origin) in zip(lines, origins) {
            let ink = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            let start = CTLineGetStringRange(line).location
            let paragraph = start < text.length
                ? text.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle
                : nil
            let trailingInset = paragraph.map { max(0, -$0.tailIndent) } ?? 0
            widest = max(widest, origin.x + ink + trailingInset)
        }
        return ceil(widest)
    }

    private static func lineCount(of frame: CTFrame) -> Int {
        CFArrayGetCount(CTFrameGetLines(frame))
    }

    // MARK: Selection

    /// The character boundary nearest a point in the block's own coordinates:
    /// above the text is its start, below it its end — and the end is where
    /// the words stop, short of an "(edited)" after them.
    func characterIndex(at point: CGPoint) -> Int {
        let length = text.selectableLength
        guard let first = lineBoxes.first, point.y >= first.top else { return 0 }
        guard let box = lineBoxes.first(where: { point.y < $0.bottom }) else { return length }
        let index = CTLineGetStringIndexForPosition(box.line, CGPoint(x: point.x - box.originX, y: 0))
        return index == kCFNotFound ? min(box.range.location, length) : min(max(0, index), length)
    }

    /// Where the "(edited)" after a changed message's words landed, in the
    /// block's own coordinates — what its tooltip answers over.
    var editedMarkRect: CGRect? {
        text.editedMark.flatMap { selectionRects(for: $0.range).first }
    }

    /// Where the character at `index` sits on its line's baseline, in the
    /// block's own coordinates — what Look Up draws its lit copy of the
    /// words from. Nil past the last line.
    func baselineOrigin(at index: Int) -> CGPoint? {
        guard let box = lineBoxes.first(where: {
            index >= $0.range.location && index < $0.range.location + max(1, $0.range.length)
        }) else { return nil }
        let offset = CTLineGetOffsetForStringIndex(box.line, index, nil)
        return CGPoint(x: box.originX + offset, y: box.baseline)
    }

    /// The highlight for `range`: one band per line it crosses.
    func selectionRects(for range: NSRange) -> [CGRect] {
        var rects: [CGRect] = []
        for box in lineBoxes {
            let start = max(range.location, box.range.location)
            let end = min(NSMaxRange(range), box.range.location + box.range.length)
            guard start < end else { continue }
            let from = CTLineGetOffsetForStringIndex(box.line, start, nil)
            let to = CTLineGetOffsetForStringIndex(box.line, end, nil)
            rects.append(CGRect(
                x: box.originX + min(from, to), y: box.top,
                width: abs(to - from), height: box.bottom - box.top
            ))
        }
        return rects
    }

    /// The word around a character — a double-click's selection.
    func wordRange(at index: Int) -> NSRange {
        let length = text.selectableLength
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        return text.attributed.doubleClick(at: min(max(0, index), length - 1))
    }

    /// The room a fenced block at the very start or end of the text needs
    /// outside the frame: its margin and padding above, its padding below.
    private static func edgeInsets(
        for text: MessageText,
        style: MessageTextStyle
    ) -> (top: CGFloat, bottom: CGFloat) {
        guard let first = text.codeBlocks.first, let last = text.codeBlocks.last else {
            return (0, 0)
        }
        return (
            first.location == 0 ? style.codeBlockLeading : 0,
            NSMaxRange(last) == text.attributed.length ? style.codeBlockPadding : 0
        )
    }

    /// Every standard emoji in the text, by its UTF-16 range — outside inline
    /// code and code blocks, where Discord draws the characters as code and a
    /// click opens nothing.
    ///
    /// One walk of the graphemes, and only for a text that has an emoji
    /// scalar in it at all, which most messages do not.
    private static func unicodeEmojiRanges(in text: MessageText) -> [(NSRange, EmojiRef)] {
        let string = text.attributed.string
        guard string.unicodeScalars.contains(where: {
            $0.properties.isEmojiPresentation || $0.value == 0xFE0F
        }) else { return [] }
        let code = text.codeBlocks + text.plates.compactMap {
            if case .code = $0.kind { $0.range } else { nil }
        }
        var ranges: [(NSRange, EmojiRef)] = []
        var offset = 0
        for character in string {
            let length = character.utf16.count
            if character.isEmojiCluster {
                let range = NSRange(location: offset, length: length)
                if !code.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                    ranges.append((range, EmojiRef(name: String(character))))
                }
            }
            offset += length
        }
        return ranges
    }

    /// Everything one walk over the lines produces.
    private struct ResolvedRuns {
        var emoji: [(CGRect, EmojiRef)] = []
        var unicodeEmoji: [(CGRect, EmojiRef)] = []
        var symbols: [(CGRect, String)] = []
        var links: [(CGRect, MessageText.LinkTarget)] = []
        var spoilers: [(CGRect, Int)] = []
        var plates: [(CGRect, Int)] = []
        var quotes: [CGRect] = []
        var codeBlocks: [CGRect] = []
    }

    /// Walks the laid-out lines once, resolving every rectangle the painter and
    /// the pointer will need.
    ///
    /// CoreText works in a bottom-left origin; the canvas is top-left. The
    /// conversion happens once, here, so nothing downstream has to remember
    /// which space it is in.
    private static func resolveRuns(
        in frame: CTFrame,
        frameTop: CGFloat,
        width: CGFloat,
        text: MessageText,
        emojiWidth: CGFloat,
        emojiAscent: CGFloat,
        symbolSide: CGFloat,
        codeBlockPadding: CGFloat,
        into resolved: inout ResolvedRuns
    ) {
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return }
        let standardEmoji = unicodeEmojiRanges(in: text)
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        // The vertical extent of each quote and code block, grown line by line.
        var quoteSpans = [(top: CGFloat, bottom: CGFloat)?](repeating: nil, count: text.quotes.count)
        var blockSpans = [(top: CGFloat, bottom: CGFloat)?](
            repeating: nil, count: text.codeBlocks.count
        )

        for (lineIndex, line) in lines.enumerated() {
            let origin = origins[lineIndex]
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            // Flip: CoreText's origin is the baseline measured from the bottom.
            let baselineY = frameTop - origin.y
            let lineRange = CTLineGetStringRange(line)
            let lineTop = baselineY - ascent
            let lineBottom = baselineY + descent

            // Inline boxes — emoji and symbols. One walk over the runs for
            // both: a second pass would be a second walk of every glyph run on
            // every line of every message that has one.
            if !text.inlineEmoji.isEmpty || !text.inlineSymbols.isEmpty,
               let runs = CTLineGetGlyphRuns(line) as? [CTRun]
            {
                for run in runs {
                    let runRange = CTRunGetStringRange(run)
                    guard runRange.length == 1 else { continue }
                    if let emoji = text.inlineEmoji[runRange.location] {
                        let offset = CTLineGetOffsetForStringIndex(line, runRange.location, nil)
                        resolved.emoji.append((
                            CGRect(
                                x: origin.x + offset,
                                y: baselineY - emojiAscent,
                                width: emojiWidth,
                                height: emojiAscent + descent
                            ),
                            emoji
                        ))
                    } else if let name = text.inlineSymbols[runRange.location] {
                        let offset = CTLineGetOffsetForStringIndex(line, runRange.location, nil)
                        resolved.symbols.append((
                            CGRect(
                                x: origin.x + offset,
                                y: baselineY - symbolSide * 0.86,
                                width: symbolSide,
                                height: symbolSide
                            ),
                            name
                        ))
                    }
                }
            }

            for (range, emoji) in standardEmoji {
                guard let span = span(of: range, on: line, lineRange: lineRange) else { continue }
                resolved.unicodeEmoji.append((
                    CGRect(x: origin.x + span.start, y: lineTop,
                           width: span.end - span.start, height: ascent + descent),
                    emoji
                ))
            }

            // Link rectangles: one per line the link crosses, so a link that
            // wraps is two hit regions rather than one box covering the gap
            // between them.
            for link in text.links {
                guard let span = span(of: link.range, on: line, lineRange: lineRange) else {
                    continue
                }
                resolved.links.append((
                    CGRect(
                        x: origin.x + span.start,
                        y: lineTop,
                        width: span.end - span.start,
                        height: ascent + descent
                    ),
                    link.target
                ))
            }

            for (index, spoiler) in text.spoilers.enumerated() {
                guard let span = span(of: spoiler, on: line, lineRange: lineRange) else { continue }
                resolved.spoilers.append((
                    CGRect(
                        x: origin.x + span.start - 2,
                        y: lineTop,
                        width: span.end - span.start + 4,
                        height: ascent + descent
                    ),
                    index
                ))
            }

            // A plate hugs its own face, not the line: inline code is 85% of
            // the text around it, and a plate the height of the line would
            // stand a head taller than the letters it holds.
            for (index, plate) in text.plates.enumerated() {
                guard let span = span(of: plate.range, on: line, lineRange: lineRange) else {
                    continue
                }
                let (runAscent, runDescent) = runExtent(of: plate.range, on: line)
                // The trailing air is kerned INTO the run, so only the leading
                // edge reaches out; a segment that opens mid-plate after a wrap
                // starts flush with its text.
                let opens = span.clipped.location == plate.range.location
                let minX = origin.x + span.start - (opens ? plate.padding : 0)
                resolved.plates.append((
                    CGRect(
                        x: minX,
                        y: baselineY - runAscent,
                        width: origin.x + span.end - minX,
                        height: runAscent + runDescent
                    ),
                    index
                ))
            }

            for (index, quote) in text.quotes.enumerated()
            where intersect(lineRange, quote) != nil {
                let span = quoteSpans[index]
                quoteSpans[index] = (
                    min(span?.top ?? lineTop, lineTop),
                    max(span?.bottom ?? lineBottom, lineBottom)
                )
            }
            for (index, block) in text.codeBlocks.enumerated()
            where intersect(lineRange, block) != nil {
                let span = blockSpans[index]
                blockSpans[index] = (
                    min(span?.top ?? lineTop, lineTop),
                    max(span?.bottom ?? lineBottom, lineBottom)
                )
            }
        }

        for span in quoteSpans.compactMap({ $0 }) {
            resolved.quotes.append(CGRect(
                x: 0,
                y: span.top,
                width: MessageTextStyle.quoteRuleWidth,
                height: span.bottom - span.top
            ))
        }
        // The box spans the block's width and its padding above and below —
        // the space the first and last line's paragraph margins reserved.
        for span in blockSpans.compactMap({ $0 }) {
            resolved.codeBlocks.append(CGRect(
                x: 0,
                y: span.top - codeBlockPadding,
                width: width,
                height: span.bottom - span.top + codeBlockPadding * 2
            ))
        }
    }

    /// Where `range` falls on one line: its x extent, and the part of the range
    /// the line holds. Nil when the line holds none of it.
    private static func span(
        of range: NSRange,
        on line: CTLine,
        lineRange: CFRange
    ) -> (start: CGFloat, end: CGFloat, clipped: NSRange)? {
        guard let clipped = intersect(lineRange, range) else { return nil }
        let start = CTLineGetOffsetForStringIndex(line, clipped.location, nil)
        let end = CTLineGetOffsetForStringIndex(line, NSMaxRange(clipped), nil)
        guard end > start else { return nil }
        return (start, end, clipped)
    }

    /// The tallest ascent and descent among the runs `range` covers on a line —
    /// a plate's own face, rather than the line's.
    private static func runExtent(of range: NSRange, on line: CTLine) -> (CGFloat, CGFloat) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return (0, 0) }
        for run in runs {
            let runRange = CTRunGetStringRange(run)
            guard intersect(runRange, range) != nil else { continue }
            var runAscent: CGFloat = 0
            var runDescent: CGFloat = 0
            var runLeading: CGFloat = 0
            _ = CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &runAscent, &runDescent, &runLeading)
            ascent = max(ascent, runAscent)
            descent = max(descent, runDescent)
        }
        return (ascent, descent)
    }

    private static func intersect(_ line: CFRange, _ range: NSRange) -> NSRange? {
        let lower = max(line.location, range.location)
        let upper = min(line.location + line.length, range.location + range.length)
        guard upper > lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    /// What is under a point in this block, if anything.
    ///
    /// The rect comes back with the target because the click needs somewhere to
    /// anchor a card: a mention opens a profile, and a profile that appears at
    /// the pointer reads as a menu rather than as belonging to that person.
    func link(at point: CGPoint) -> (rect: CGRect, target: MessageText.LinkTarget)? {
        for entry in linkRects where entry.rect.contains(point) { return entry }
        return nil
    }
}
