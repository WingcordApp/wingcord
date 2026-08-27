import Foundation
import WingcordCore

/// One piece of media the viewer can show.
///
/// **A snapshot, not a reference into the store.** The viewer is opened from a
/// message and then lives on its own: the message can be edited or deleted, the
/// channel can be evicted by the LRU, and the picture on screen must not blink
/// out from under the reader because of any of it. Everything the surface draws
/// is copied in here at the moment of the click — a few URLs and a filename,
/// which is cheaper than the resolve it replaces.
nonisolated struct MediaItem: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        /// A still picture.
        case image
        /// **May** animate. GIF, APNG and animated WebP all arrive here, and the
        /// stage degrades to a still when the decode reports one frame — which
        /// is a real case for all three formats, and one no header can rule out
        /// without reading the whole container.
        case animated
        case video
    }

    var id: AttachmentID
    var kind: Kind
    /// The original upload on `cdn.discordapp.com`, byte for byte what was sent.
    ///
    /// Used directly for video and for anything animated: the media proxy
    /// re-encodes what it resizes, and re-encoding a GIF is how a viewer ends up
    /// showing a still of something that moves.
    var sourceURL: URL
    /// The resizable rendition host. A still is requested from here at the rung
    /// covering the stage, so opening a 12-megapixel phone photo does not
    /// download 12 megapixels to draw 1200 of them.
    var proxyURL: String
    /// The rendition the transcript already has in cache, at the size it drew.
    ///
    /// **The viewer's first frame, and the reason it opens with no flash.** The
    /// full-size decode takes a fetch; this one is already resident, and drawing
    /// it immediately is the difference between a lightbox that opens and one
    /// that opens onto a grey rectangle.
    var posterURL: URL?
    /// The width the transcript drew it at, in points.
    ///
    /// Carried because the cache key is `(url, pixel size)` and both halves have
    /// to match the transcript's exactly — a peek built from a different width
    /// looks in a slot nothing was ever put in.
    var posterWidth: CGFloat
    var filename: String
    var contentType: String?
    var byteCount: Int
    /// The asset's own pixel dimensions, when Discord sent them.
    ///
    /// Nil is a real state and is not substituted for: the stage lays out from
    /// the decoded picture when it lands, and guessing a shape here is what
    /// makes a viewer jump the moment the real one arrives.
    var pixelWidth: Int?
    var pixelHeight: Int?
    var altText: String?
    var durationSeconds: Double?
    var isSpoiler: Bool

    /// The widths the proxy is asked for.
    ///
    /// **Rungs rather than the exact stage width**, for the same reason
    /// `CDN.rung` exists: the cache key carries the pixel size, so a window
    /// dragged twenty points wider would otherwise be a different URL, a
    /// different entry and a second download of the same picture. Six rungs
    /// cover every window on every display this app can be opened on.
    static let renditionRungs = [640, 1024, 1600, 2048, 3072, 4096]

    /// The best URL for a stage `pixels` wide.
    ///
    /// Past the asset's own width the answer is the **original**: the proxy
    /// would re-encode it to serve back the same resolution, and a viewer at
    /// 100% should show the file that was uploaded rather than a transcode of
    /// it.
    func renditionURL(forPixelWidth pixels: Int) -> URL {
        guard kind == .image else { return sourceURL }
        let rung = Self.renditionRungs.first { $0 >= pixels } ?? Self.renditionRungs[Self.renditionRungs.count - 1]
        if let pixelWidth, rung >= pixelWidth { return sourceURL }
        return CDN.resizedAttachment(proxyURL: proxyURL, width: CGFloat(rung), scale: 1) ?? sourceURL
    }

    /// The intrinsic aspect ratio, or nil when Discord sent no dimensions.
    var aspectRatio: Double? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    var isVideo: Bool { kind == .video }

    /// Builds an item from an attachment, or nil when it is not something the
    /// viewer can show.
    ///
    /// **Nil is the gate on the whole surface.** A `.zip` in a message is drawn
    /// in the same box a picture is, and opening a lightbox onto bytes nobody
    /// can render is worse than the click doing nothing — the caller sends
    /// those to the browser instead.
    init?(_ attachment: Attachment, posterWidth: CGFloat) {
        guard let sourceURL = URL(string: attachment.url) else { return nil }
        let type = attachment.contentType ?? ""
        let kind: Kind
        if type.hasPrefix("video/") {
            kind = .video
        } else if Self.mayAnimate(type: type, filename: attachment.filename) {
            kind = .animated
        } else if type.hasPrefix("image/") {
            kind = .image
        } else {
            return nil
        }

        id = attachment.id
        self.kind = kind
        self.sourceURL = sourceURL
        proxyURL = attachment.proxyURL
        posterURL = CDN.resizedAttachment(proxyURL: attachment.proxyURL, width: posterWidth)
        self.posterWidth = posterWidth
        filename = attachment.filename
        contentType = attachment.contentType
        byteCount = attachment.size
        pixelWidth = attachment.width
        pixelHeight = attachment.height
        altText = attachment.description
        durationSeconds = attachment.durationSeconds
        isSpoiler = attachment.isSpoiler
    }

    /// Whether an asset is worth attempting a filmstrip decode on.
    ///
    /// A hint, not an answer — the decode is the answer, and it says no for the
    /// single-frame GIFs people upload constantly. But it is a hint worth
    /// having: attempting a multi-frame decode on every JPEG in a channel is a
    /// container walk per picture for a question already settled by the type.
    private static func mayAnimate(type: String, filename: String) -> Bool {
        if type == "image/gif" || type == "image/apng" || type == "image/webp" { return true }
        let suffix = filename.lowercased()
        return suffix.hasSuffix(".gif") || suffix.hasSuffix(".apng") || suffix.hasSuffix(".webp")
    }
}

/// What the viewer is showing, and what it can move between.
///
/// **One value on the store, one presenter at the window root**, the same shape
/// every other surface raised from the drawn transcript takes — the canvas
/// cannot host a presentation at all, so a click writes this and stops.
///
/// The whole message's media travels with it, because a lightbox that cannot
/// step to the next picture in the same message is one people close and reopen
/// four times.
nonisolated struct MediaViewerRequest: Equatable, Sendable {
    var items: [MediaItem]
    var index: Int
    /// Who posted it and when, for the info card. On the request rather than on
    /// each item: it belongs to the message, and copying it per attachment would
    /// be the same two fields three times.
    var authorName: String
    var sentAt: Date

    var current: MediaItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    var hasSiblings: Bool { items.count > 1 }

    /// Steps by `delta`, wrapping. Wrapping rather than stopping: a two-picture
    /// message is the common case, and a Next that greys out after one press is
    /// a control that spends most of its life disabled.
    mutating func step(_ delta: Int) {
        guard items.count > 1 else { return }
        index = (index + delta % items.count + items.count) % items.count
    }
}
