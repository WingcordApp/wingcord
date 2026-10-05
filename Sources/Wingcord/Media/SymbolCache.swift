import AppKit
import CoreGraphics
import Foundation

/// Rendered SF Symbols, held for the process.
///
/// **A drawn canvas cannot use an `Image`, and rendering a symbol is not free.**
/// `NSImage(systemSymbolName:)` resolves a font, applies a configuration and
/// rasterises — and a `#welcome` channel is a hundred rows each drawing one, on
/// every repaint of every scroll. The bitmap for a given name, size, weight and
/// colour is the same bitmap every time, so it is produced once.
///
/// The tint is baked into the bitmap rather than applied at draw time through a
/// clip: `CGContext.clip(to:mask:)` requires a `DeviceGray` image with no alpha,
/// which a symbol bitmap is not — so the obvious "one grey bitmap, many colours"
/// arrangement silently clips nothing and paints a filled rectangle. A palette
/// configuration is the supported way to colour one, and the cache key carries
/// the colour for exactly that reason.
///
/// The table is tiny and bounded by the symbols the transcript actually draws —
/// a handful of names across two or three tints — so there is nothing to evict.
nonisolated final class SymbolCache: @unchecked Sendable {
    static let shared = SymbolCache()

    private struct Key: Hashable {
        var name: String
        /// Rounded to a whole point: a fractional size produces a bitmap
        /// indistinguishable from its neighbour and a cache that never hits.
        var pointSize: Int
        var tint: Int
    }

    private let lock = NSLock()
    private var images: [Key: CGImage] = [:]

    /// The symbol, rasterised in `tint`. Nil for a name the system does not
    /// have — which is a typo, and drawing nothing is the honest result.
    func image(name: String, pointSize: CGFloat, tint: NSColor) -> CGImage? {
        let key = Key(
            name: name,
            pointSize: Int(pointSize.rounded()),
            tint: Self.token(of: tint)
        )
        lock.lock()
        defer { lock.unlock() }
        if let hit = images[key] { return hit }

        let configuration = NSImage.SymbolConfiguration(
            pointSize: CGFloat(key.pointSize), weight: .semibold
        )
        .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))

        guard let symbol = NSImage.symbol(named: name)?
            .withSymbolConfiguration(configuration),
            let built = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        images[key] = built
        return built
    }

    /// A colour as one comparable integer.
    ///
    /// Through `sRGB` explicitly: a dynamic system colour has no components at
    /// all until it is converted, and asking one for `redComponent` directly
    /// traps. Alpha is part of the key because a disabled control is the same
    /// colour at a different weight.
    private static func token(of color: NSColor) -> Int {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        let red = Int(rgb.redComponent * 255)
        let green = Int(rgb.greenComponent * 255)
        let blue = Int(rgb.blueComponent * 255)
        let alpha = Int(rgb.alphaComponent * 255)
        return red << 24 | green << 16 | blue << 8 | alpha
    }
}
