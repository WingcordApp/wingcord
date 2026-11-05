import AppKit
import Foundation

/// Box art for `--demo`'s games that have none on the CDN: a portrait poster
/// drawn on this Mac from a system symbol on a gradient — the shape a cover
/// takes, never a copy of a game's own. Written once to the caches folder and
/// handed out as a file URL, which `GameMediaRef.url` carries as it is.
enum DemoGameArt {
    typealias RGB = (Double, Double, Double)

    static func cover(symbol: String, top: RGB, bottom: RGB, name: String) -> URL? {
        art(symbol: symbol, top: top, bottom: bottom, file: "\(name)-cover", size: NSSize(width: 300, height: 400), glyph: 150, lift: 20)
    }

    /// A square of the same: a game's icon, or a role's.
    static func tile(symbol: String, top: RGB, bottom: RGB, name: String) -> URL? {
        art(symbol: symbol, top: top, bottom: bottom, file: "\(name)-tile", size: NSSize(width: 128, height: 128), glyph: 72, lift: 0)
    }

    /// A wide picture of the same, standing in for a screenshot or an invite's
    /// splash: what a post's mosaic and the invite sheet's right side are laid
    /// out against.
    struct Scene {
        var name: String
        var symbol: String
        var top: RGB
        var bottom: RGB
        var size = CGSize(width: 1200, height: 800)
    }

    static func picture(_ scene: Scene) -> URL? {
        art(
            symbol: scene.symbol, top: scene.top, bottom: scene.bottom, file: scene.name,
            size: NSSize(width: scene.size.width, height: scene.size.height),
            glyph: min(scene.size.width, scene.size.height) * 0.42, lift: 0
        )
    }

    private static func art(
        symbol: String, top: RGB, bottom: RGB, file name: String, size: NSSize, glyph glyphSize: CGFloat, lift: CGFloat
    ) -> URL? {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wingcord Demo Games", isDirectory: true)
        let file = folder.appendingPathComponent("\(name).png")
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return file }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = NSImage(size: size, flipped: false) { rect in
            let colour = { (rgb: RGB) in NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1) }
            NSGradient(starting: colour(top), ending: colour(bottom))?.draw(in: rect, angle: -90)
            let configuration = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.black.withAlphaComponent(0.55)]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                let drawn = glyph.size
                glyph.draw(in: NSRect(
                    x: (rect.width - drawn.width) / 2,
                    y: (rect.height - drawn.height) / 2 - lift,
                    width: drawn.width,
                    height: drawn.height
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
