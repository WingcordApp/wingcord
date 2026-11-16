import CoreGraphics
import Foundation
import WingcordCore

/// One of an embed's pictures on its way to the viewer: the picture as the
/// embed carries it, where the transcript drew it (`MediaSources.embedIndex`,
/// so the viewer flies it out of its own box), and the rendition already
/// decoded for it.
nonisolated struct EmbedPicture: Sendable {
    var media: Embed.Media
    var sourceIndex: Int
    var posterWidth: CGFloat
    var posterURL: URL?

    /// The picture as a file, which is what the viewer shows: the embed's own
    /// full-size link and its proxy, its size, and a type read off its name
    /// (an unfurl carries none).
    var attachment: Attachment {
        let filename = URL(string: media.url)?.lastPathComponent ?? "image"
        let ext = (filename as NSString).pathExtension.lowercased()
        let type = switch ext {
        case "gif": "image/gif"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "avif": "image/avif"
        default: "image/png"
        }
        return Attachment(
            // The same picture, the same id, from one run to the next — a
            // `hashValue` is seeded afresh every launch.
            id: AttachmentID(rawValue: Self.stableID(media.url)),
            filename: filename.isEmpty ? "image.png" : filename,
            url: media.url,
            proxyURL: media.proxyURL ?? media.url,
            contentType: type,
            width: media.width,
            height: media.height,
            description: media.altText,
            isMarkedAnimated: media.isMarkedAnimated
        )
    }

    /// FNV-1a over the link's bytes.
    static func stableID(_ url: String) -> UInt64 {
        url.utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
    }
}
