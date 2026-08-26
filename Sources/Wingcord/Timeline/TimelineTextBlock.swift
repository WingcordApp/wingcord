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
    /// Clickable regions, resolved once.
    let linkRects: [(rect: CGRect, target: MessageText.LinkTarget)]
    /// Concealed regions, painted over until revealed.
    let spoilerRects: [CGRect]

    init(text: MessageText, width: CGFloat, style: MessageTextStyle) {
        self.text = text

        let framesetter = CTFramesetterCreateWithAttributedString(text.attributed)
        let constraints = CGSize(width: width, height: .greatestFiniteMagnitude)
        var fitRange = CFRange()
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            constraints,
            &fitRange
        )
        // Round up. A fractional height leaves the next row starting on a
        // half-pixel, and a column of rows each half a point short accumulates
        // into a visible drift against the scroll position.
        size = CGSize(width: width, height: ceil(suggested.height))

        let path = CGPath(
            rect: CGRect(origin: .zero, size: CGSize(width: width, height: size.height)),
            transform: nil
        )
        frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )

        var emojiRects: [(CGRect, EmojiRef)] = []
        var linkRects: [(CGRect, MessageText.LinkTarget)] = []
        var spoilerRects: [CGRect] = []
        Self.resolveRuns(
            in: frame,
            blockHeight: size.height,
            text: text,
            emojiWidth: style.emojiWidth,
            emojiAscent: style.emojiAscent,
            into: &emojiRects,
            links: &linkRects,
            spoilers: &spoilerRects
        )
        self.emojiRects = emojiRects
        self.linkRects = linkRects
        self.spoilerRects = spoilerRects
    }

    /// Walks the laid-out lines once, resolving every rectangle the painter and
    /// the pointer will need.
    ///
    /// CoreText works in a bottom-left origin; the canvas is top-left. The
    /// conversion happens once, here, so nothing downstream has to remember
    /// which space it is in.
    private static func resolveRuns(
        in frame: CTFrame,
        blockHeight: CGFloat,
        text: MessageText,
        emojiWidth: CGFloat,
        emojiAscent: CGFloat,
        into emojiRects: inout [(CGRect, EmojiRef)],
        links: inout [(CGRect, MessageText.LinkTarget)],
        spoilers: inout [CGRect]
    ) {
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        for (lineIndex, line) in lines.enumerated() {
            let origin = origins[lineIndex]
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            // Flip: CoreText's origin is the baseline measured from the bottom.
            let baselineY = blockHeight - origin.y
            let lineRange = CTLineGetStringRange(line)

            // Emoji boxes.
            if !text.inlineEmoji.isEmpty,
               let runs = CTLineGetGlyphRuns(line) as? [CTRun]
            {
                for run in runs {
                    let runRange = CTRunGetStringRange(run)
                    guard let emoji = text.inlineEmoji[runRange.location],
                          runRange.length == 1
                    else { continue }
                    let offset = CTLineGetOffsetForStringIndex(line, runRange.location, nil)
                    emojiRects.append((
                        CGRect(
                            x: origin.x + offset,
                            y: baselineY - emojiAscent,
                            width: emojiWidth,
                            height: emojiAscent + descent
                        ),
                        emoji
                    ))
                }
            }

            // Link rectangles: one per line the link crosses, so a link that
            // wraps is two hit regions rather than one box covering the gap
            // between them.
            for link in text.links {
                guard let intersection = intersect(lineRange, link.range) else { continue }
                let startX = CTLineGetOffsetForStringIndex(line, intersection.location, nil)
                let endX = CTLineGetOffsetForStringIndex(
                    line,
                    intersection.location + intersection.length,
                    nil
                )
                guard endX > startX else { continue }
                links.append((
                    CGRect(
                        x: origin.x + startX,
                        y: baselineY - ascent,
                        width: endX - startX,
                        height: ascent + descent
                    ),
                    link.target
                ))
            }

            for spoiler in text.spoilers {
                guard let intersection = intersect(lineRange, spoiler) else { continue }
                let startX = CTLineGetOffsetForStringIndex(line, intersection.location, nil)
                let endX = CTLineGetOffsetForStringIndex(
                    line,
                    intersection.location + intersection.length,
                    nil
                )
                guard endX > startX else { continue }
                spoilers.append(CGRect(
                    x: origin.x + startX - 2,
                    y: baselineY - ascent,
                    width: endX - startX + 4,
                    height: ascent + descent
                ))
            }
        }
    }

    private static func intersect(_ line: CFRange, _ range: NSRange) -> NSRange? {
        let lower = max(line.location, range.location)
        let upper = min(line.location + line.length, range.location + range.length)
        guard upper > lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    /// What is under a point in this block, if anything.
    func linkTarget(at point: CGPoint) -> MessageText.LinkTarget? {
        for entry in linkRects where entry.rect.contains(point) { return entry.target }
        return nil
    }
}
