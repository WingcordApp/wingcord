import CoreGraphics
import Foundation

/// The viewer stage's geometry: where a picture sits at a given zoom and pan,
/// and how far either is allowed to go.
///
/// **All of it is pure arithmetic, deliberately.** The stage itself is an AppKit
/// view driving a `CALayer`'s frame from a display link, which is the one place
/// in this app where a wrong number is completely invisible — the code compiles,
/// the picture appears, and it is a few points off or drifts a little further
/// from centre with every pinch. Keeping the decisions here means they can be
/// asserted against, and `MediaZoomTests` does.
///
/// `scale` is a **multiple of the fit scale**, not an absolute one. That is what
/// lets 1 always mean "the whole picture is visible" whatever the window is
/// doing, so a resize never leaves the reader at a zoom that no longer has a
/// meaning.
nonisolated struct MediaZoom: Equatable, Sendable {
    /// 1 fits the stage. Below 1 only ever happens under resistance.
    var scale: CGFloat = 1
    /// The picture's centre, offset from the stage's centre, in points.
    var offset: CGPoint = .zero

    static let fit = MediaZoom()

    var isFit: Bool { abs(scale - 1) < 0.001 && offset == .zero }
}

/// One stage's fixed inputs: what is being shown, and how big the box is.
nonisolated struct MediaStageGeometry: Equatable, Sendable {
    /// The picture's own pixel size.
    var contentPixels: CGSize
    /// The stage, in points.
    var viewport: CGSize
    /// The display's backing scale, so "100%" means one image pixel per device
    /// pixel rather than per point.
    var displayScale: CGFloat = 2
    /// How far the picture at fit keeps from the stage's edges, per side: clear
    /// of the viewer's buttons above and its zoom bar below, so a big picture
    /// never runs under them and their glass never mirrors it into an
    /// unreadable bar (Alex, 2026-11-18). Symmetric, so the picture stays
    /// centred on the stage. Zoomed in, it may go anywhere.
    var fitInset: CGSize = .zero
    /// Whether the picture at fit stops at its own size — one image pixel to a
    /// point — rather than being blown up to fill the stage, as Discord's own
    /// viewer stops it.
    var capsAtNaturalSize = false

    /// The point size the picture is drawn at when it exactly fits.
    ///
    /// Aspect-**fit**: a lightbox that crops is a lightbox that hides the part of
    /// the picture somebody opened it to see.
    var fitSize: CGSize {
        guard contentPixels.width > 0, contentPixels.height > 0,
              viewport.width > 0, viewport.height > 0
        else { return .zero }
        let area = CGSize(
            width: max(1, viewport.width - fitInset.width * 2),
            height: max(1, viewport.height - fitInset.height * 2)
        )
        var ratio = min(
            area.width / contentPixels.width,
            area.height / contentPixels.height
        )
        if capsAtNaturalSize { ratio = min(ratio, 1) }
        return CGSize(
            width: contentPixels.width * ratio,
            height: contentPixels.height * ratio
        )
    }

    /// The zoom at which one image pixel covers one device pixel.
    ///
    /// Below 1 for anything smaller than the stage, which is most emoji-sized
    /// uploads — so it is a *candidate* for the maximum rather than the maximum
    /// itself.
    var actualSizeScale: CGFloat {
        let fit = fitSize
        guard fit.width > 0, displayScale > 0 else { return 1 }
        return (contentPixels.width / displayScale) / fit.width
    }

    /// How far in the reader may go.
    ///
    /// Three at minimum so a small picture can still be inspected, and capped so
    /// a pinch cannot ask the compositor for a texture the size of a wall.
    var maximumScale: CGFloat {
        min(16, max(3, actualSizeScale))
    }

    /// The zoom a double-click goes to from fit.
    ///
    /// Actual size where that is a step up, twice fit where the picture is
    /// smaller than the stage and actual size would be a step *down* — which is
    /// the answer that makes a double-click on a small picture do nothing at
    /// all.
    var toggleScale: CGFloat {
        min(maximumScale, max(2, actualSizeScale))
    }

    /// The picture's rect inside the stage.
    func contentRect(_ zoom: MediaZoom) -> CGRect {
        let fit = fitSize
        let size = CGSize(width: fit.width * zoom.scale, height: fit.height * zoom.scale)
        return CGRect(
            x: (viewport.width - size.width) / 2 + zoom.offset.x,
            y: (viewport.height - size.height) / 2 + zoom.offset.y,
            width: size.width,
            height: size.height
        )
    }

    /// How far the picture may be pushed from centre before its edge would come
    /// inside the stage, per axis.
    ///
    /// Zero on an axis the picture does not overflow — a picture narrower than
    /// the stage is centred and stays centred, because a horizontally centred
    /// image that can be nudged sideways reads as broken rather than as free.
    func panLimit(_ scale: CGFloat) -> CGSize {
        let fit = fitSize
        return CGSize(
            width: max(0, (fit.width * scale - viewport.width) / 2),
            height: max(0, (fit.height * scale - viewport.height) / 2)
        )
    }

    /// The nearest offset that keeps the picture inside its limits.
    func clamped(_ offset: CGPoint, scale: CGFloat) -> CGPoint {
        let limit = panLimit(scale)
        return CGPoint(
            x: min(limit.width, max(-limit.width, offset.x)),
            y: min(limit.height, max(-limit.height, offset.y))
        )
    }

    /// The offset a live drag should show: 1:1 inside the limits, progressively
    /// resisted outside them.
    ///
    /// **A hard stop at the edge reads as frozen** — §3 — so the picture keeps
    /// following the pointer past its bound, just less and less, and springs
    /// back on release.
    func resisted(_ offset: CGPoint, scale: CGFloat) -> CGPoint {
        let limit = panLimit(scale)
        return CGPoint(
            x: Motion.clampWithResistance(
                offset.x,
                to: -limit.width...limit.width,
                limit: max(1, viewport.width)
            ),
            y: Motion.clampWithResistance(
                offset.y,
                to: -limit.height...limit.height,
                limit: max(1, viewport.height)
            )
        )
    }

    /// A zoom change that keeps the point under the pointer where it is.
    ///
    /// **Zoom without an anchor is zoom about the centre**, which is what makes
    /// a pinch on a detail in the corner send that detail off the edge. The
    /// content point under `anchor` is resolved before the change and put back
    /// underneath it afterwards.
    func anchoredOffset(
        from zoom: MediaZoom,
        to newScale: CGFloat,
        anchor: CGPoint
    ) -> CGPoint {
        let rect = contentRect(zoom)
        guard rect.width > 0, rect.height > 0 else { return zoom.offset }
        // Where in the picture the pointer is, 0...1 on each axis.
        let unit = CGPoint(
            x: (anchor.x - rect.minX) / rect.width,
            y: (anchor.y - rect.minY) / rect.height
        )
        let fit = fitSize
        let size = CGSize(width: fit.width * newScale, height: fit.height * newScale)
        let origin = CGPoint(x: anchor.x - unit.x * size.width, y: anchor.y - unit.y * size.height)
        return CGPoint(
            x: origin.x + size.width / 2 - viewport.width / 2,
            y: origin.y + size.height / 2 - viewport.height / 2
        )
    }

    /// Where a flick would come to rest, clamped to what is reachable.
    ///
    /// Projection rather than the release point — §3 — so a fast short flick
    /// travels and a slow long drag does not.
    func projectedRest(from offset: CGPoint, velocity: CGPoint, scale: CGFloat) -> CGPoint {
        clamped(
            CGPoint(
                x: Motion.projectedPosition(from: offset.x, velocity: velocity.x),
                y: Motion.projectedPosition(from: offset.y, velocity: velocity.y)
            ),
            scale: scale
        )
    }
}
