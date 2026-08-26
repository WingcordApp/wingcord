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

    static func geometry(
        viewport: CGRect,
        documentHeight: CGFloat,
        currentFrame: CGRect,
        overscan: CGFloat = TimelineMetrics.overscan,
        minimumBuffer: CGFloat = TimelineMetrics.minimumRetainedBuffer
    ) -> Geometry {
        let documentHeight = max(1, documentHeight)
        let width = max(1, viewport.width)
        let canvasHeight = min(documentHeight, max(1, viewport.height + overscan * 2))
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
}
