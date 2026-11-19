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
    /// The attachment's place among its message's `attachments` — what the
    /// transcript's thumbnail is found by (`MediaSources`). Not the item's
    /// place in the viewer, which skips what it cannot show.
    var attachmentIndex: Int = 0
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
    /// What makes a video a Discord clip — its title, game, people and
    /// timeline — for the player's faces, markers and timeline comments
    /// (docs/CLIPS-PRESENCE.md, D16). Nil for every other video.
    var clip: AttachmentClip?
    /// A GIF that is an MP4 (a `gifv` from Tenor or Giphy): played muted and
    /// looping, with no transport, as an animation rather than a video.
    var loopsSilently = false
    /// Whether smaller renditions can be asked of Discord's media proxy.
    /// False for a picture served from elsewhere — a game's screenshots, from
    /// IGDB or the store — which is shown as it is (`renditionURL`).
    var isProxied = true
    /// The GIF as the account's favourites key it, for the viewer's star
    /// (Alex, 2026-11-17). Nil for everything that isn't a GIF.
    var favoriteGIF: GIF? = nil

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
        guard kind == .image, isProxied else { return sourceURL }
        let rung = Self.renditionRungs.first { $0 >= pixels } ?? Self.renditionRungs[Self.renditionRungs.count - 1]
        if let pixelWidth, rung >= pixelWidth { return sourceURL }
        let source = pixelWidth.flatMap { width in
            pixelHeight.map { CGSize(width: width, height: $0) }
        }
        return CDN.resizedAttachment(proxyURL: proxyURL, width: CGFloat(rung), sourceSize: source, scale: 1)
            ?? sourceURL
    }

    /// The intrinsic aspect ratio, or nil when Discord sent no dimensions.
    var aspectRatio: Double? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    var isVideo: Bool { kind == .video }

    /// Played in AVKit's own player (decision 24): every video but a clip,
    /// whose bar carries its marks, and a GIF's MP4, which has no bar.
    var usesSystemPlayer: Bool { isVideo && clip == nil && !loopsSilently }

    /// Builds an item from an attachment, or nil when it is not something the
    /// viewer can show.
    ///
    /// **Nil is the gate on the whole surface.** A `.zip` in a message is drawn
    /// in the same box a picture is, and opening a lightbox onto bytes nobody
    /// can render is worse than the click doing nothing — the caller sends
    /// those to the browser instead.
    /// - Parameter posterURL: the URL the transcript drew this attachment
    ///   from. **The key has to be the transcript's exactly** — the same
    ///   `width` *and* `height` the CDN was asked for — or the peek looks in a
    ///   slot nothing was put in, and the viewer opens on nothing until its own
    ///   rendition arrives. Rebuilt from the width alone when there is none
    ///   (the inspector's tiles, which draw their own).
    init?(_ attachment: Attachment, posterWidth: CGFloat, posterURL: URL? = nil, attachmentIndex: Int = 0) {
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
        self.attachmentIndex = attachmentIndex
        self.sourceURL = sourceURL
        proxyURL = attachment.proxyURL
        self.posterURL = posterURL ?? (kind == .video
            ? CDN.videoPoster(proxyURL: attachment.proxyURL, width: posterWidth, sourceSize: attachment.pixelSize)
                ?? URL(string: attachment.proxyURL).flatMap { $0.isFileURL ? $0 : nil }
            : CDN.resizedAttachment(proxyURL: attachment.proxyURL, width: posterWidth, sourceSize: attachment.pixelSize))
        self.posterWidth = posterWidth
        filename = attachment.filename
        contentType = attachment.contentType
        byteCount = attachment.size
        pixelWidth = attachment.width
        pixelHeight = attachment.height
        altText = attachment.description
        durationSeconds = attachment.durationSeconds
        isSpoiler = attachment.isSpoiler
        clip = kind == .video ? attachment.clip : nil
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
    /// The surface the picture was opened from — where its flight starts and
    /// ends (`MediaSources`).
    enum Origin: Equatable, Sendable {
        case transcript
        case inspector
    }

    var items: [MediaItem]
    var index: Int
    /// The message the pictures belong to, for finding their thumbnails.
    var messageID: MessageID?
    /// Where that message is — what a clip's timeline comment is sent to.
    var channelID: ChannelID?
    var origin: Origin = .transcript
    /// Who posted it and when, for the info card. On the request rather than on
    /// each item: it belongs to the message, and copying it per attachment would
    /// be the same two fields three times.
    var authorName: String
    var sentAt: Date
    /// Where the opened video picks up: the place the chat's own player had
    /// reached when it was double-clicked (decision 24).
    var startsAt: (item: AttachmentID, seconds: Double)? = nil
    /// Raised from inside a sheet — a game profile's media, a profile board's
    /// clips — so it is drawn by the presenter above the sheets rather than
    /// the one under the profiles (`presentsMedia(aboveSheets:)`).
    var isAboveSheets = false

    static func == (lhs: MediaViewerRequest, rhs: MediaViewerRequest) -> Bool {
        lhs.items == rhs.items && lhs.index == rhs.index && lhs.messageID == rhs.messageID
            && lhs.channelID == rhs.channelID && lhs.origin == rhs.origin && lhs.authorName == rhs.authorName
            && lhs.sentAt == rhs.sentAt && lhs.startsAt?.item == rhs.startsAt?.item
            && lhs.startsAt?.seconds == rhs.startsAt?.seconds
            && lhs.isAboveSheets == rhs.isAboveSheets
    }

    var current: MediaItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    var hasSiblings: Bool { items.count > 1 }

    /// The thumbnail the current picture flies to and from.
    var sourceKey: MediaSources.Key? {
        guard let messageID, let current else { return nil }
        return MediaSources.Key(messageID: messageID, attachmentIndex: current.attachmentIndex)
    }

    /// The item `delta` places away, wrapping as `step` does — what the
    /// gallery lays beside the picture on stage.
    func item(offsetBy delta: Int) -> MediaItem? {
        guard items.count > 1 else { return nil }
        return items[(index + delta % items.count + items.count) % items.count]
    }

    /// Steps by `delta`, wrapping. Wrapping rather than stopping: a two-picture
    /// message is the common case, and a Next that greys out after one press is
    /// a control that spends most of its life disabled.
    mutating func step(_ delta: Int) {
        guard items.count > 1 else { return }
        index = (index + delta % items.count + items.count) % items.count
    }
}
