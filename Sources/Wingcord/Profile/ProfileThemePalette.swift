import CoreGraphics
import Foundation
import WingcordCore

/// A profile's colours, derived from its artwork when the account set none.
///
/// **Discord themes a profile even with `theme_colors: null`**, by quantising
/// the person's own artwork — and a client that only reads the field draws
/// every such profile flat grey, which is most Nitro accounts. Captured from
/// Discord's own store, which keys by artwork URL and keeps the first two
/// swatches:
///
/// ```js
/// let palette = await getPalette(url);            // getPalette(image, 5, 10)
/// store[url] = [...palette.slice(0, 2), ...];     // primary, secondary
/// ```
///
/// No scoring, no vibrance heuristic — the quantiser's own ordering *is* the
/// answer. See `MedianCutQuantizer`.
///
/// **The three input parameters matter as much as the algorithm**, and each was
/// established by measuring what Discord renders rather than assumed:
///
///  - **WebP, not PNG.** Lossy, so the pixels genuinely differ.
///  - **128 pixels.** At 256 a different swatch wins outright — on one test
///    profile the answer moves 157 units, from his face to the near-black
///    behind his head.
///  - **Every tenth pixel.** Discord's `quality` argument, and it changes which
///    box the median cut lands in.
///
/// Verified against three live profiles, on the two whose derived colour is
/// directly measurable: within **3 and 4 units of 255**. The remainder is this
/// client's WebP decode against Chrome's, plus the display-profile conversion
/// in the screenshots the targets came from — not the algorithm.
nonisolated enum ProfileThemePalette {
    /// The rendition to quantise, in pixels. Also the CDN rung, so this is one
    /// number rather than two that can drift apart.
    static let pixelSize = 128
    /// Discord's `quality`: take every Nth pixel.
    static let stride = 10
    /// How many boxes the quantiser is asked for. Only the first two are used,
    /// but asking for fewer changes where every cut lands.
    static let swatchCount = 5

    /// The primary and secondary, as the 24-bit values `theme_colors` would
    /// have carried — so a derived theme and a chosen one reach the surfaces
    /// through exactly the same path and cannot diverge in treatment.
    ///
    /// Empty when the artwork yields nothing, which is a real answer: a profile
    /// with no usable colour keeps the neutral ground rather than being given a
    /// colour nobody chose.
    static func derive(from image: CGImage) -> [UInt32] {
        guard let pixels = sample(image), !pixels.isEmpty else { return [] }
        return MedianCutQuantizer.palette(of: pixels, count: swatchCount)
            .prefix(2)
            .map { UInt32($0.x) << 16 | UInt32($0.y) << 8 | UInt32($0.z) }
    }

    /// Discord's `createPixelArray`, exactly.
    ///
    /// **Both rejections are load-bearing.** Dropping near-transparent pixels
    /// keeps a decoration's alpha out of the count, and dropping near-white
    /// keeps a photograph's blown highlights from becoming somebody's theme —
    /// which is why an avatar shot against a window does not come out white.
    private static func sample(_ image: CGImage) -> [SIMD3<UInt8>]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var pixels: [SIMD3<UInt8>] = []
        pixels.reserveCapacity(width * height / stride + 1)
        var index = 0
        while index < width * height {
            let offset = index * 4
            let red = buffer[offset], green = buffer[offset + 1]
            let blue = buffer[offset + 2], alpha = buffer[offset + 3]
            if alpha >= 125, !(red > 250 && green > 250 && blue > 250) {
                pixels.append(SIMD3(red, green, blue))
            }
            index += stride
        }
        return pixels
    }
}
