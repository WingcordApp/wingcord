import CoreGraphics
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The stage's geometry, which is the one part of the viewer where a wrong
/// number is completely invisible: the code compiles, the picture appears, and
/// it is a few points off or drifts a little further from centre with every
/// pinch.
@Suite("Media stage geometry")
struct MediaStageGeometryTests {

    /// A 2:1 picture in a 4:3 box, so the fit is decided by the width and there
    /// is letterboxing above and below.
    private let wide = MediaStageGeometry(
        contentPixels: CGSize(width: 800, height: 400),
        viewport: CGSize(width: 400, height: 300),
        displayScale: 2
    )

    /// The same box, a picture that exactly matches its aspect.
    private let square = MediaStageGeometry(
        contentPixels: CGSize(width: 800, height: 600),
        viewport: CGSize(width: 400, height: 300),
        displayScale: 2
    )

    @Test("Fitting letterboxes rather than cropping")
    func fitSize() {
        #expect(wide.fitSize == CGSize(width: 400, height: 200))
        #expect(square.fitSize == CGSize(width: 400, height: 300))
    }

    @Test("A dimension that does not overflow cannot be panned")
    func panLimitsAreZeroWhereNothingOverflows() {
        let limit = wide.panLimit(1)
        #expect(limit.width == 0)
        #expect(limit.height == 0)

        // At 1.5x the width overflows and the height still does not: 600 wide
        // against a 400 viewport, 300 tall against 300.
        let zoomed = wide.panLimit(1.5)
        #expect(zoomed.width == 100)
        #expect(zoomed.height == 0)
    }

    @Test("Clamping keeps the picture's edges outside the stage")
    func clamping() {
        let clamped = square.clamped(CGPoint(x: 900, y: -900), scale: 2)
        #expect(clamped.x == 200)
        #expect(clamped.y == -150)
    }

    @Test("A drag tracks 1:1 inside its bounds and resists outside them")
    func resistance() {
        // Well inside: no resistance at all, or a drag would feel laggy in the
        // middle of its own range.
        let inside = square.resisted(CGPoint(x: 50, y: 0), scale: 2)
        #expect(abs(inside.x - 50) < 0.001)

        // Past the bound: still moving, but no longer 1:1 — and never as far as
        // the pointer went.
        let outside = square.resisted(CGPoint(x: 400, y: 0), scale: 2)
        #expect(outside.x > 200)
        #expect(outside.x < 400)
    }

    @Test("Zooming keeps the point under the pointer under the pointer")
    func zoomIsAnchored() {
        let anchor = CGPoint(x: 100, y: 75)
        let before = square.contentRect(.fit)
        let unitBefore = CGPoint(
            x: (anchor.x - before.minX) / before.width,
            y: (anchor.y - before.minY) / before.height
        )

        let offset = square.anchoredOffset(from: .fit, to: 2, anchor: anchor)
        let after = square.contentRect(MediaZoom(scale: 2, offset: offset))
        let unitAfter = CGPoint(
            x: (anchor.x - after.minX) / after.width,
            y: (anchor.y - after.minY) / after.height
        )

        #expect(abs(unitAfter.x - unitBefore.x) < 0.0001)
        #expect(abs(unitAfter.y - unitBefore.y) < 0.0001)
    }

    @Test("Actual size is the maximum for a large picture")
    func maximumIsActualSize() {
        let photograph = MediaStageGeometry(
            contentPixels: CGSize(width: 4000, height: 3000),
            viewport: CGSize(width: 400, height: 300),
            displayScale: 2
        )
        #expect(photograph.actualSizeScale == 5)
        #expect(photograph.maximumScale == 5)
    }

    /// A picture smaller than the stage is already drawn larger than its own
    /// pixels, so "actual size" is a step *down* — and a double click that zooms
    /// out is one that appears to do nothing.
    @Test("A small picture still zooms in on a double click")
    func toggleNeverZoomsOut() {
        let small = MediaStageGeometry(
            contentPixels: CGSize(width: 100, height: 100),
            viewport: CGSize(width: 400, height: 400),
            displayScale: 2
        )
        #expect(small.actualSizeScale < 1)
        #expect(small.toggleScale == 2)
        #expect(small.maximumScale == 3)
    }

    @Test("A flick lands where it was going, not past the edge")
    func projectionIsClamped() {
        let rest = square.projectedRest(
            from: CGPoint(x: 100, y: 0),
            velocity: CGPoint(x: 4000, y: 0),
            scale: 2
        )
        #expect(rest.x == 200)
    }

    /// Degenerate inputs are real: the stage is laid out before anything has
    /// been decoded, and a size of zero must not produce a NaN that Core
    /// Animation then refuses to draw.
    @Test("An empty stage produces no geometry rather than a NaN")
    func emptyGeometry() {
        let empty = MediaStageGeometry(contentPixels: .zero, viewport: .zero)
        #expect(empty.fitSize == .zero)
        let rect = empty.contentRect(.fit)
        #expect(rect.width == 0)
        #expect(!rect.origin.x.isNaN)
    }
}

/// What the viewer can open, and where it asks for the bytes.
@Suite("Media items")
struct MediaItemTests {

    private func attachment(
        _ filename: String,
        type: String?,
        width: Int? = 800,
        height: Int? = 600
    ) -> WingcordCore.Attachment {
        WingcordCore.Attachment(
            id: AttachmentID(rawValue: 42),
            filename: filename,
            url: "https://cdn.discordapp.com/attachments/1/2/\(filename)",
            proxyURL: "https://media.discordapp.net/attachments/1/2/\(filename)",
            contentType: type,
            size: 1234,
            width: width,
            height: height
        )
    }

    @Test("Each media type resolves to the stage that can show it")
    func kinds() {
        #expect(MediaItem(attachment("a.png", type: "image/png"), posterWidth: 200)?.kind == .image)
        #expect(MediaItem(attachment("a.gif", type: "image/gif"), posterWidth: 200)?.kind == .animated)
        #expect(MediaItem(attachment("a.mp4", type: "video/mp4"), posterWidth: 200)?.kind == .video)
    }

    /// The extension is the fallback for an upload with no content type, which
    /// is what a client that did not set one produces.
    @Test("A missing content type falls back to the extension")
    func extensionFallback() {
        #expect(MediaItem(attachment("a.gif", type: nil), posterWidth: 200)?.kind == .animated)
        #expect(MediaItem(attachment("a.txt", type: nil), posterWidth: 200) == nil)
    }

    /// A lightbox onto bytes nobody can render is worse than the click doing
    /// nothing — the caller sends these to the browser instead.
    @Test("Anything the viewer cannot show is refused")
    func nonMediaIsRefused() {
        #expect(MediaItem(attachment("a.zip", type: "application/zip"), posterWidth: 200) == nil)
        #expect(MediaItem(attachment("a.pdf", type: "application/pdf"), posterWidth: 200) == nil)
    }

    @Test("A rendition under the source's own width comes from the proxy")
    func smallRenditionUsesTheProxy() throws {
        let item = try #require(MediaItem(attachment("a.png", type: "image/png"), posterWidth: 200))
        let url = item.renditionURL(forPixelWidth: 500)
        #expect(url.host() == "media.discordapp.net")
        #expect(url.query()?.contains("width=640") == true)
    }

    /// Past the asset's own width the proxy would re-encode it to serve back the
    /// same resolution, and a viewer at 100% should show the file that was
    /// uploaded rather than a transcode of it.
    @Test("A rendition at or above the source's width is the original")
    func largeRenditionUsesTheOriginal() throws {
        let item = try #require(MediaItem(attachment("a.png", type: "image/png"), posterWidth: 200))
        #expect(item.renditionURL(forPixelWidth: 2048) == item.sourceURL)
    }

    /// The media proxy re-encodes what it resizes, and re-encoding a GIF is how
    /// a viewer ends up showing a still of something that moves.
    @Test("Animated and video assets are never resized")
    func movingAssetsUseTheOriginal() throws {
        let gif = try #require(MediaItem(attachment("a.gif", type: "image/gif"), posterWidth: 200))
        let clip = try #require(MediaItem(attachment("a.mp4", type: "video/mp4"), posterWidth: 200))
        #expect(gif.renditionURL(forPixelWidth: 64) == gif.sourceURL)
        #expect(clip.renditionURL(forPixelWidth: 64) == clip.sourceURL)
    }

    @Test("A spoilered upload is carried as one")
    func spoiler() throws {
        let item = try #require(
            MediaItem(attachment("SPOILER_a.png", type: "image/png"), posterWidth: 200)
        )
        #expect(item.isSpoiler)
    }

    /// Nil dimensions are a real state: the stage lays out from the decoded
    /// picture instead, and substituting a square here is what makes a viewer
    /// jump the moment the real one arrives.
    @Test("Missing dimensions produce no aspect ratio")
    func missingDimensions() throws {
        let item = try #require(
            MediaItem(attachment("a.png", type: "image/png", width: nil, height: nil), posterWidth: 200)
        )
        #expect(item.aspectRatio == nil)
    }
}

/// Stepping between the pictures in one message.
@Suite("Media viewer request")
struct MediaViewerRequestTests {

    private func request(count: Int, index: Int = 0) -> MediaViewerRequest {
        var items: [MediaItem] = []
        for position in 0..<count {
            let attachment = WingcordCore.Attachment(
                id: AttachmentID(rawValue: UInt64(position + 1)),
                filename: "a\(position).png",
                url: "https://cdn.discordapp.com/attachments/1/2/a\(position).png",
                proxyURL: "https://media.discordapp.net/attachments/1/2/a\(position).png",
                contentType: "image/png",
                size: 1,
                width: 100,
                height: 100
            )
            if let item = MediaItem(attachment, posterWidth: 100) { items.append(item) }
        }
        return MediaViewerRequest(items: items, index: index, authorName: "Ada", sentAt: .now)
    }

    /// Wrapping rather than stopping: a two-picture message is the common case,
    /// and a Next that greys out after one press is a control that spends most
    /// of its life disabled.
    @Test("Stepping past the end wraps")
    func wrapping() {
        var subject = request(count: 3, index: 2)
        subject.step(1)
        #expect(subject.index == 0)
        subject.step(-1)
        #expect(subject.index == 2)
    }

    @Test("A single attachment has nothing to step to")
    func single() {
        var subject = request(count: 1)
        #expect(!subject.hasSiblings)
        subject.step(1)
        #expect(subject.index == 0)
    }

    @Test("The current item is the one at the index")
    func current() {
        let subject = request(count: 3, index: 1)
        #expect(subject.current?.filename == "a1.png")
    }
}

/// The two labels under a scrubber, which have to stay the same width as the
/// number under them changes or the bar jitters as it plays.
@Suite("Media time labels")
struct MediaTimeLabelTests {

    @Test("Seconds are always two digits")
    func padding() {
        #expect(mediaTimeLabel(0) == "0:00")
        #expect(mediaTimeLabel(9) == "0:09")
        #expect(mediaTimeLabel(61) == "1:01")
    }

    @Test("An hour adds a field rather than counting past sixty")
    func hours() {
        #expect(mediaTimeLabel(3600) == "1:00:00")
        #expect(mediaTimeLabel(3661) == "1:01:01")
        #expect(mediaTimeLabel(59 * 60 + 59) == "59:59")
    }

    /// A negative remaining time is reachable for a moment at the end of a clip,
    /// where the clock has overrun the reported duration.
    @Test("A negative time reads as zero rather than as nonsense")
    func negative() {
        #expect(mediaTimeLabel(-5) == "0:00")
    }
}
