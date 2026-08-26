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
    static let conversationStartHeight: CGFloat = 120
    /// One placeholder group in the history runway.
    static let skeletonHeight: CGFloat = 56
    /// The quiet "still loading" line shown before the first page lands.
    static let loadingRowHeight: CGFloat = 36

    /// Between the message text and an attachment under it.
    static let attachmentGap: CGFloat = 6
    /// Between reaction chips and the content above them.
    static let reactionGap: CGFloat = 6
    static let reactionChipHeight: CGFloat = 22

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
