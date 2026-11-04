import AppKit
import Foundation

/// Box art for `--demo`'s games that have none on the CDN: a portrait poster
/// drawn on this Mac from a system symbol on a gradient — the shape a cover
/// takes, never a copy of a game's own. Written once to the caches folder and
/// handed out as a file URL, which `GameMediaRef.url` carries as it is.
enum DemoGameArt {
    typealias RGB = (Double, Double, Double)

    static func cover(symbol: String, top: RGB, bottom: RGB, name: String) -> URL? {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wingcord Demo Games", isDirectory: true)
        let file = folder.appendingPathComponent("\(name)-cover.png")
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return file }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let size = NSSize(width: 300, height: 400)
        let image = NSImage(size: size, flipped: false) { rect in
            let colour = { (rgb: RGB) in NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1) }
            NSGradient(starting: colour(top), ending: colour(bottom))?.draw(in: rect, angle: -90)
            let configuration = NSImage.SymbolConfiguration(pointSize: 150, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.black.withAlphaComponent(0.55)]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                let glyphSize = glyph.size
                glyph.draw(in: NSRect(
                    x: (rect.width - glyphSize.width) / 2,
                    y: (rect.height - glyphSize.height) / 2 - 20,
                    width: glyphSize.width,
                    height: glyphSize.height
                ))
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        try? png.write(to: file)
        return file
    }
}
