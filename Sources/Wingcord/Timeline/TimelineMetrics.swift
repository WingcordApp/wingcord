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
    /// The chip a command's name is drawn in, on an interaction header.
    ///
    /// Shorter than the line it sits on: it is a token inside a sentence, and a
    /// chip as tall as its row reads as a button rather than as a word.
    static let interactionChipHeight: CGFloat = 17
    static let interactionChipPadding: CGFloat = 5

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

    // MARK: The reply header
    //
    // The quoted line above a reply, and the elbow that ties it to the message
    // underneath. Layout and painter share every number here for the reason the
    // reaction chip's parts are shared: the elbow's corner has to land exactly
    // on the strip's leading edge, and a radius kept in two places drifts into
    // a connector that misses its own row by a point.

    /// The quoted strip's own height. One line, always — a header that wrapped
    /// would push the message it belongs to down the page by an amount that
    /// depends on somebody else's typing.
    static let replyHeight: CGFloat = 17
    /// Between the strip and the author line under it.
    static let replyGap: CGFloat = 2
    /// The quoted author's face.
    static let replyAvatarSide: CGFloat = 16
    /// Between the face and the name, and between the name and the quote.
    static let replyItemGap: CGFloat = 6
    /// The elbow's corner radius and its stroke.
    static let replyElbowRadius: CGFloat = 7
    static let replyElbowWidth: CGFloat = 1.5
    /// Where the elbow's vertical leg sits: the centre of the avatar gutter, so
    /// it rises out of the face the message belongs to.
    static var replyElbowX: CGFloat { horizontalMargin + Metrics.avatarMessage / 2 }
    /// Where its horizontal leg stops — just short of the quoted face.
    static var replyElbowEndX: CGFloat { contentInset - replyItemGap }

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
    /// The band at a button's trailing edge for the mark that says what kind of
    /// button it is — a menu's chevron, a link's arrow. **Reserved by the
    /// layout and respected by the painter**: a mark drawn into space the label
    /// was allowed to fill lands on top of the words, which is exactly what a
    /// link button did.
    static let componentTrailingGlyphRoom: CGFloat = 16
    /// The gutter glyph on a system row — a join, a boost, a pin.
    static let systemGlyphSide: CGFloat = 16

    // The "Only you can see this" note. Layout and painter read the SAME
    // constants, for the reason the component geometry above does.
    static let ephemeralNoteHeight: CGFloat = 16
    static let ephemeralNoteGap: CGFloat = 6
    static let ephemeralNoteGlyphSide: CGFloat = 12
    static let ephemeralNoteGlyphGap: CGFloat = 5
    /// The glyph plus the gap after it, which is what the text is inset by.
    static let ephemeralNoteGlyphRoom: CGFloat = ephemeralNoteGlyphSide + ephemeralNoteGlyphGap
    /// The gap on each side of the dot between the note and the control, plus
    /// the dot. Layout places the control with it; the painter centres the dot
    /// in it.
    static let ephemeralNoteSeparatorRoom: CGFloat = 14


    // MARK: The hover pill
    //
    // The pill is a SwiftUI glass surface overlaid on the scroll view — the
    // canvas cannot draw glass and a floating control is one surface at a time,
    // so composing it is right where the rows are not. What the canvas needs is
    // the same geometry, for one reason: the pill floats over the row's top
    // edge and can overhang the rows either side by a few points, so a pointer
    // reaching for it must not be read as having left the row it belongs to.

    /// The pill's own height.
    static let actionBarHeight: CGFloat = 28
    /// Between the pill and the transcript's trailing edge.
    static let actionBarTrailingInset: CGFloat = 12
    /// How far the pill sits above the row's own top edge.
    static let actionBarRise: CGFloat = 6
    /// The widest the pill can be, used only to reserve the region the pointer
    /// may travel through on its way to it. Over-reserving is safe because the
    /// region is only consulted for the row **already** hovered — see
    /// `TimelineCanvasView.hoveredIndex`.
    static let actionBarMaxWidth: CGFloat = 220

    /// Where the pill sits for a row, in the same space the row frame is in.
    static func actionBarRegion(inRow rowFrame: CGRect) -> CGRect {
        CGRect(
            x: rowFrame.maxX - actionBarMaxWidth,
            y: rowFrame.minY - actionBarRise,
            width: actionBarMaxWidth,
            height: actionBarHeight
        )
    }

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
