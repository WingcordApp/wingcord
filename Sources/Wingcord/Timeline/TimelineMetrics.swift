import AppKit
import CoreGraphics
import Foundation

/// Every number the transcript's geometry is built from.
///
/// One place, so the layout engine and the painter cannot disagree — a painter
/// that draws an avatar two points from where the layout reserved space for it
/// produces a transcript that looks *almost* right, which is the hardest kind of
/// defect to see and the easiest to introduce by keeping two copies of a number.
nonisolated enum TimelineMetrics {
    /// Leading and trailing margin of the transcript.
    static let horizontalMargin: CGFloat = 16
    /// Between the avatar and the text column.
    static let avatarGap: CGFloat = 12
    /// The author gutter: avatar plus gap. Everything textual starts here.
    static var contentInset: CGFloat { horizontalMargin + Metrics.avatarMessage + avatarGap }

    /// Above a run's first message. Runs are what the eye groups by, so the gap
    /// between them has to be clearly larger than the gap inside one.
    static let runSpacing: CGFloat = 10
    /// The same gap under Compact. Still clearly larger than `lineSpacing`, or
    /// the runs stop being the thing the eye groups by and the transcript
    /// becomes one undifferentiated column — which is a denser page that is
    /// harder to read, not a denser page that fits more.
    static let compactRunSpacing: CGFloat = 5
    /// Between messages inside one run.
    static let lineSpacing: CGFloat = 2
    /// Below a run's last message.
    static let runBottomPadding: CGFloat = 2

    /// The header line: author name and timestamp.
    static let headerHeight: CGFloat = 20
    /// Between the header and the first line of text.
    static let headerGap: CGFloat = 1

    static let daySeparatorHeight: CGFloat = 34
    static let unreadDividerHeight: CGFloat = 26

    // The unread band's label. Layout does not need these — the row is a fixed
    // height — but the painter draws three things that have to agree with each
    // other, and a chip whose padding lives at one call site and whose width
    // lives at another is the geometry that drifts first.
    static let unreadLabelHeight: CGFloat = 16
    /// Each side, inside the capsule.
    static let unreadLabelPadding: CGFloat = 8
    /// Between the rule and the capsule.
    static let unreadLabelGap: CGFloat = 8
    /// Built once. `NSFont.systemFont` goes through the font manager, and this
    /// is drawn per repaint of a row that stays on screen for as long as the
    /// reader is catching up.
    ///
    /// `nonisolated(unsafe)` for the same reason `MessageTextStyle` is
    /// `@unchecked Sendable`: an `NSFont` is immutable once created and safe to
    /// read from any thread, and this one is never written after launch.
    nonisolated(unsafe) static let unreadLabelFont = NSFont.systemFont(
        ofSize: 9, weight: .heavy
    )
    static let conversationStartHeight: CGFloat = 120
    /// One placeholder group in the history runway.
    static let skeletonHeight: CGFloat = 56
    /// The quiet "still loading" line shown before the first page lands.
    static let loadingRowHeight: CGFloat = 36
    /// The "this did not load" block: a symbol, a headline and the reason.
    static let historyUnavailableHeight: CGFloat = 108

    /// Between the message text and an attachment under it.
    static let attachmentGap: CGFloat = 6
    /// Between reaction chips and the content above them.
    static let reactionGap: CGFloat = 6
    static let reactionChipHeight: CGFloat = 22

    // The reaction chip's parts. Layout and painter read the SAME constants,
    // because they are two halves of one geometry and drifting them is
    // invisible until it isn't.
    //
    // `reactionGlyphSide` is MEASURED, not chosen. Apple Color Emoji advances
    // about 1.46x its point size — 19.0pt at size 13 — so the 16pt box this
    // replaced was narrower than every single emoji it was asked to hold, and
    // `drawText`'s tail truncation duly replaced each one with an ellipsis.
    // That is the whole of "reactions render as ...".
    static let reactionEmojiFontSize: CGFloat = 13
    static let reactionGlyphSide: CGFloat = 19
    static let reactionLeadingInset: CGFloat = 6
    static let reactionGlyphGap: CGFloat = 4
    static let reactionTrailingInset: CGFloat = 7

    /// A chip's width, given the width its count label measured to.
    static func reactionChipWidth(countWidth: CGFloat) -> CGFloat {
        reactionLeadingInset + reactionGlyphSide + reactionGlyphGap
            + countWidth + reactionTrailingInset
    }

    // A button an app attached. Layout and painter read the SAME constants —
    // two halves of one geometry, and drifting them is invisible until it isn't.
    static let componentHeight: CGFloat = 30
    static let componentPadding: CGFloat = 12
    static let componentGap: CGFloat = 6
    static let componentGlyphSide: CGFloat = 16
    static let componentGlyphGap: CGFloat = 5
    /// The gutter glyph on a system row — a join, a boost, a pin.
    static let systemGlyphSide: CGFloat = 16

    /// The quote rule's width and its distance from the text it marks.
    static let quoteRuleWidth: CGFloat = 3
    static let quoteRuleInset: CGFloat = 4

    /// How far above and below the viewport the canvas keeps painted content.
    ///
    /// **This is the single number that decides how often anything happens at
    /// all while scrolling.** The canvas only repositions when it is about to
    /// run out of buffer, so between moves the clip view slides over a static
    /// layer and the compositor does the whole scroll on the GPU. Larger means
    /// rarer moves and a bigger backing layer; 320 is roughly a third of a
    /// viewport, which puts a repaint at worst every ~240 points of travel.
    static let overscan: CGFloat = 320

    /// The least buffer the canvas may have left before it repositions.
    static let minimumRetainedBuffer: CGFloat = 80

    /// How close to the top the viewport must come before the next page of
    /// history is requested.
    ///
    /// Deliberately far: paging is a chain — reach the top, fetch, land, reach
    /// the top again — and every link is a round trip the reader waits through.
    /// Starting the request 8,000 points early means a fast flick usually never
    /// meets the end of the content at all.
    static let historyPrefetchDistance: CGFloat = 8_000
}
