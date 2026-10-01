import CoreGraphics
import Foundation

/// Decides where the viewport-sized canvas sits inside the document.
///
/// A pure function with no view in it, so the rule that decides how often a
/// scroll costs anything can be tested against a table of positions instead of
/// against a running window.
///
/// The rule: **if the canvas still covers the viewport and retains a minimum
/// buffer on both sides, do not move it.** That is what makes a scroll free —
/// the clip view slides over a static layer — and it is why the answer is
/// "keep the current frame" far more often than it is a new one.
nonisolated enum TimelineViewportPolicy {

    struct Geometry: Equatable, Sendable {
        var frame: CGRect
        var bounds: CGRect
    }

    /// The smallest document that still scrolls to nothing: the band between
    /// the chrome and the bar, rather than the whole clip view.
    ///
    /// **A content inset does not shrink the clip view.** It moves the
    /// scrollable range — the minimum to `-top`, the maximum to
    /// `document + bottom - viewport` — while the clip view keeps the surface's
    /// full height, which is the entire reason content passes *under* the
    /// chrome and the composer at all.
    ///
    /// So padding a short document out to the viewport's own height leaves a
    /// range of `top + bottom` points that should not exist: a channel with
    /// three messages in it scrolls, and lands with its first message behind the
    /// toolbar. Padding it to the readable band instead makes the maximum equal
    /// the minimum, and the surface stays where it belongs.
    static func readableHeight(
        viewport: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        max(0, viewport - max(0, topInset) - max(0, bottomInset))
    }

    /// The empty space above the first row.
    ///
    /// **A channel too short to fill its window sits on the composer**, the
    /// way Discord's does (`.scrollerContent { justify-content: flex-end;
    /// min-height: 100% }`): the leftover goes above the content, not below it.
    /// The transcript used to start at the top and leave the leftover between
    /// the last message and the composer — the "space between the composer and
    /// the messages", and the channel header stranded at the top of an empty
    /// channel. Zero once the rows fill the band, so nothing changes for a
    /// channel long enough to scroll.
    static func leadingSpace(
        rowsHeight: CGFloat,
        viewport: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        max(0, readableHeight(viewport: viewport, topInset: topInset, bottomInset: bottomInset) - rowsHeight)
    }

    static func geometry(
        viewport rawViewport: CGRect,
        documentHeight: CGFloat,
        currentFrame: CGRect,
        overscan: CGFloat = TimelineMetrics.overscan,
        minimumBuffer: CGFloat = TimelineMetrics.minimumRetainedBuffer
    ) -> Geometry {
        let documentHeight = max(1, documentHeight)
        let width = max(1, rawViewport.width)

        // **Clipped to the document before anything is decided.** The transcript
        // runs UNDER the composer and pays for it with a bottom content inset,
        // so a clip view scrolled fully down reports a viewport whose foot is
        // one composer past the end of the content. The canvas is clamped to the
        // document and can never cover that strip — there is nothing there — so
        // a covers-the-viewport test written against the raw rect is false for
        // the whole of the bottom of every channel, and the canvas is then
        // repositioned on *every scroll tick* in exactly the region people read
        // in. That is the one thing this type exists to prevent.
        let viewport = CGRect(
            x: rawViewport.minX,
            y: rawViewport.minY,
            width: rawViewport.width,
            height: max(0, min(rawViewport.maxY, documentHeight) - rawViewport.minY)
        )
        // Sized from the RAW viewport, which is the clip view's own height and
        // does not change as the reader scrolls. Sizing it from the clipped rect
        // would shrink the canvas near the foot of a channel — and a canvas that
        // changes size is a canvas that is re-laid-out and repainted, which is
        // the cost this whole type exists to avoid.
        let canvasHeight = min(documentHeight, max(1, rawViewport.height + overscan * 2))
        let maximumOriginY = max(0, documentHeight - canvasHeight)

        let coversViewport =
            abs(currentFrame.width - width) < 0.5
            && abs(currentFrame.height - canvasHeight) < 0.5
            && currentFrame.minY <= viewport.minY + 0.5
            && currentFrame.maxY >= viewport.maxY - 0.5
            && currentFrame.minY >= -0.5
            && currentFrame.maxY <= documentHeight + 0.5

        // A buffer counts as retained when it exists OR when the canvas is
        // already flush against that end of the document — there is nothing more
        // to reveal in that direction, so no buffer is needed.
        let retainsLeading =
            currentFrame.minY <= 0.5
            || viewport.minY - currentFrame.minY >= minimumBuffer
        let retainsTrailing =
            currentFrame.maxY >= documentHeight - 0.5
            || currentFrame.maxY - viewport.maxY >= minimumBuffer

        if coversViewport, retainsLeading, retainsTrailing {
            return Geometry(
                frame: currentFrame,
                bounds: CGRect(
                    x: 0,
                    y: currentFrame.minY,
                    width: currentFrame.width,
                    height: currentFrame.height
                )
            )
        }

        let originY = min(maximumOriginY, max(0, viewport.minY - overscan))
        let frame = CGRect(x: 0, y: originY, width: width, height: canvasHeight)
        return Geometry(
            frame: frame,
            bounds: CGRect(x: 0, y: originY, width: width, height: canvasHeight)
        )
    }

    /// Whether the viewport is close enough to the bottom that a new message
    /// should scroll it down.
    ///
    /// **Hysteresis, not a threshold.** A boolean derived from a continuous
    /// signal needs a band, or a transcript parked one viewport from the bottom
    /// flips on every rubber-band and on every late relayout — an image
    /// arriving, an embed unfurling — and each flip is a state change the whole
    /// window observes.
    static func isNearBottom(
        viewport: CGRect,
        documentHeight: CGFloat,
        wasNearBottom: Bool
    ) -> Bool {
        let distance = documentHeight - viewport.maxY
        return wasNearBottom ? distance < 120 : distance < 24
    }

    /// Whether the next page of history should be requested.
    static func shouldLoadEarlier(
        viewport: CGRect,
        hasMore: Bool,
        isLoading: Bool
    ) -> Bool {
        hasMore && !isLoading && viewport.minY < TimelineMetrics.historyPrefetchDistance
    }

    /// Whether the page below a window cut off from the present should be
    /// requested: `shouldLoadEarlier`'s rule, at the other end.
    static func shouldLoadLater(
        viewport: CGRect,
        documentHeight: CGFloat,
        hasMore: Bool,
        isLoading: Bool
    ) -> Bool {
        hasMore && !isLoading
            && documentHeight - viewport.maxY < TimelineMetrics.historyPrefetchDistance
    }

    /// Whether the control that returns to the present should show.
    ///
    /// **Always, while the window is cut off from the present** — nothing else
    /// on screen says so, and its foot looks like any other. Otherwise once
    /// the reader is more than a screen above the foot, which is where finding
    /// the way back by hand starts to cost; with hysteresis, so a transcript
    /// parked near that line does not flicker the control on every late
    /// relayout.
    ///
    /// - Parameter bottomInset: the composer's cover. The foot is where the
    ///   clip view rests scrolled fully down, one inset past the document.
    static func showsJumpToPresent(
        viewport: CGRect,
        documentHeight: CGFloat,
        bottomInset: CGFloat,
        reachesPresent: Bool,
        wasShowing: Bool
    ) -> Bool {
        guard reachesPresent else { return true }
        let distance = documentHeight + bottomInset - viewport.maxY
        return distance > viewport.height * (wasShowing ? 0.5 : 1)
    }
}
