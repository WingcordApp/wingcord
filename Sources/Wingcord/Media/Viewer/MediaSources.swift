import AppKit
import Foundation
import WingcordCore

/// Where the pictures the viewer opens are on screen, and which one is out of
/// its box.
///
/// **The viewer flies a picture out of its thumbnail and back into it**
/// (REDESIGN.md D8), so it has to know where that thumbnail is — when it opens,
/// and again when it closes, after the reader may have paged to another picture
/// of the same message. The surfaces that draw thumbnails register here and
/// answer by attachment; the viewer asks, and tells them which picture to leave
/// out while it is in the air or on stage, so there is never a second copy of
/// it standing in the cell.
///
/// **By surface, not by message**: a picture can be on screen in the transcript
/// and in the inspector's grid at once, and the flight has to come out of the
/// one that was clicked — `MediaViewerRequest.origin` names it.
@MainActor
final class MediaSources {
    static let shared = MediaSources()

    /// One of a message's attachments, by its place in `attachments`.
    struct Key: Hashable, Sendable {
        var messageID: MessageID
        var attachmentIndex: Int
    }

    /// Where a forward's own files are numbered from in a `Key`: far past any
    /// message's own, so one index space holds both and the flight knows which
    /// box to leave from.
    static let forwardedIndexBase = 10_000

    /// Where an embed's pictures are numbered from: past a forward's, a
    /// hundred places an embed, so the viewer flies a picture out of its own
    /// box in the card.
    static let embedIndexBase = 20_000

    static func embedIndex(embed: Int, image: Int) -> Int {
        embedIndexBase + embed * 100 + image
    }

    /// A thumbnail on screen.
    struct Thumbnail {
        /// In window coordinates.
        var frame: CGRect
        var cornerRadius: CGFloat
        /// Whether the cell crops the picture to fill, as a mosaic does, or
        /// fits it, as a lone picture's box — shaped like the picture — does.
        var cropsToFill: Bool
        weak var window: NSWindow?
    }

    struct Provider {
        var origin: MediaViewerRequest.Origin
        /// Where a picture's thumbnail is now, or nil when it is not drawn.
        var thumbnail: (Key) -> Thumbnail?
        /// Leaves this picture's box empty — nil puts every picture back.
        var lift: (Key?) -> Void
    }

    private var providers: [ObjectIdentifier: Provider] = [:]

    func register(_ owner: AnyObject, provider: Provider) {
        providers[ObjectIdentifier(owner)] = provider
    }

    func unregister(_ owner: AnyObject) {
        if let provider = providers.removeValue(forKey: ObjectIdentifier(owner)) {
            provider.lift(nil)
        }
    }

    func thumbnail(for key: Key, origin: MediaViewerRequest.Origin) -> Thumbnail? {
        for provider in providers.values where provider.origin == origin {
            if let thumbnail = provider.thumbnail(key) { return thumbnail }
        }
        return nil
    }

    /// Takes `key` out of its box on the surface it came from, or puts every
    /// picture back with nil.
    func lift(_ key: Key?, origin: MediaViewerRequest.Origin) {
        for provider in providers.values where key == nil || provider.origin == origin {
            provider.lift(key)
        }
    }
}
