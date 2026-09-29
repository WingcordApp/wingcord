import CoreGraphics
import Foundation

/// One GIF, as Discord's own `/gifs` routes return it.
///
/// **Fetched through Discord, never through the provider directly.** These
/// routes are Discord's proxy over whichever GIF backend it currently uses, so
/// the shape survives that backend changing and no provider API key has to ship
/// inside this binary.
public struct GIF: Hashable, Sendable, Identifiable {
    /// The canonical URL. This is what a message carries — every other client
    /// unfurls it back into a GIF embed.
    public var url: URL
    /// The rendition the grid draws.
    ///
    /// **A picture wherever this client chose it** — the search routes answer
    /// with an MP4 in `src`, and `drawable` passes it over, because an image
    /// decoder draws nothing from one. A favourite's is Discord's own choice,
    /// and for Tenor that is the MP4; `isVideo` says so.
    public var previewURL: URL?
    public var width: Int?
    public var height: Int?
    /// Whether `previewURL` is a video — an MP4 to play, not a picture to
    /// decode. **Most favourites from Tenor are**: Discord's client stores a
    /// favourite's rendition with its kind (`format` 2), and handed to the
    /// image decoders that rendition was a tile that never resolved.
    public var isVideo: Bool

    /// The URL is the identity: these routes carry no id of their own, and two
    /// results with the same URL are the same GIF.
    public var id: String { url.absoluteString }

    /// Width over height, for a masonry column that has to reserve height
    /// before the image arrives. Square is the safe answer when the route
    /// omits the dimensions.
    /// The first candidate this app can turn into pixels.
    ///
    /// **A video rendition is dropped rather than preferred: there is no player
    /// anywhere in the image path**, so an MP4 is a placeholder that never
    /// resolves — which is what made every tile in the picker a grey square the
    /// first time the search decode preferred `src`.
    ///
    /// Here rather than beside the search decode because two surfaces build a
    /// `GIF` now: a Tenor result, and an unfurled link in the transcript. A
    /// second copy of this list is a second place for a `.webm` to slip through
    /// into somebody's favourites.
    public static func drawable(_ candidates: URL?...) -> URL? {
        drawable(candidates)
    }

    public static func drawable(_ candidates: [URL?]) -> URL? {
        let video: Set<String> = ["mp4", "m4v", "mov", "webm"]
        return candidates
            .compactMap(\.self)
            .first { !video.contains($0.pathExtension.lowercased()) }
    }

    public var aspectRatio: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 1 }
        return CGFloat(width) / CGFloat(height)
    }

    public init(url: URL, previewURL: URL?, width: Int?, height: Int?, isVideo: Bool = false) {
        self.url = url
        self.previewURL = previewURL
        self.width = width
        self.height = height
        self.isVideo = isVideo
    }
}

/// A named tile on the GIF picker's landing screen — Discord's own categories,
/// which is what makes the tab open on something to browse rather than on a
/// bare search field.
public struct GIFCategory: Hashable, Sendable, Identifiable {
    public var name: String
    public var previewURL: URL?

    public var id: String { name }

    public init(name: String, previewURL: URL?) {
        self.name = name
        self.previewURL = previewURL
    }
}

/// `GET /gifs/trending`: the categories, plus the first page of trending.
public struct GIFLanding: Sendable {
    public var categories: [GIFCategory]
    public var trending: [GIF]

    public init(categories: [GIFCategory], trending: [GIF]) {
        self.categories = categories
        self.trending = trending
    }
}
