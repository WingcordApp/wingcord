import AppKit
import UniformTypeIdentifiers

/// What a paste carries that is a file rather than text.
///
/// Two shapes, asked in this order:
///
///  1. **Files** — copied in the Finder. The pasteboard holds their URLs, and
///     beside them their names as text and their icons as a picture, neither
///     of which is what was copied.
///  2. **A picture with no file behind it** — a screenshot taken to the
///     clipboard, an image copied from a browser. Written to a file first,
///     because a message's attachments are files, and named `image.png`, which
///     is the name a browser hands Discord's box a pasted picture under.
///
/// **A picture only when it is what was copied.** The pasteboard lists its
/// types in the order the source prefers them, and text copied from a layout
/// app carries a picture of itself behind the text — pasting that as an image
/// would take away the words somebody copied. So the picture is taken only when
/// it comes before any text on the list, which is the case for a screenshot and
/// for a browser's Copy Image.
enum PastedFiles {

    static func read(from pasteboard: NSPasteboard) -> [URL]? {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls
        }
        guard let picture = picture(on: pasteboard) else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Pasted", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: "image.\(picture.fileExtension)")
            try picture.data.write(to: url)
            return [url]
        } catch {
            return nil
        }
    }

    private struct Picture {
        var data: Data
        var fileExtension: String
    }

    /// Formats sent as they are: a GIF keeps its motion that way, and the
    /// others are ones Discord shows.
    private static let direct: [(NSPasteboard.PasteboardType, String)] = [
        (NSPasteboard.PasteboardType(UTType.gif.identifier), "gif"),
        (.png, "png"),
        (NSPasteboard.PasteboardType(UTType.jpeg.identifier), "jpg"),
        (NSPasteboard.PasteboardType(UTType.webP.identifier), "webp"),
    ]
    private static let pictureTypes: Set<NSPasteboard.PasteboardType> = Set(direct.map(\.0)).union([
        .tiff, NSPasteboard.PasteboardType(UTType.heic.identifier),
    ])
    private static let textTypes: Set<NSPasteboard.PasteboardType> = [.string, .rtf, .rtfd, .html]

    private static func picture(on pasteboard: NSPasteboard) -> Picture? {
        let types = pasteboard.types ?? []
        guard let firstPicture = types.firstIndex(where: pictureTypes.contains) else { return nil }
        if let firstText = types.firstIndex(where: textTypes.contains), firstText < firstPicture {
            return nil
        }
        for (type, fileExtension) in direct {
            if let data = pasteboard.data(forType: type) {
                return Picture(data: data, fileExtension: fileExtension)
            }
        }
        // TIFF — a screenshot, most apps — and HEIC become PNG: Discord does
        // not show a TIFF, and PNG keeps every pixel of what was copied.
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        return Picture(data: png, fileExtension: "png")
    }
}
