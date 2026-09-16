import CoreGraphics
import Foundation
import Testing
@testable import Wingcord

/// `ImageStore.decode`, and the format `CGImageSource` cannot open.
///
/// **Discord ships its illustration as SVG.** The tenure badge artwork, and a
/// good deal else under `/assets/`, is vector — and a client that only knows
/// `CGImageSource` draws nothing for any of it, silently, because the failure
/// looks exactly like an image that has not arrived yet.
@MainActor
@Suite("Image decode")
struct ImageStoreDecodeTests {

    /// A red circle on a transparent ground, in the same shape Discord's own
    /// assets are written in — a `viewBox`, no `<?xml?>` prologue, `fill="none"`
    /// on the root.
    private static let svg = """
    <svg width="61" height="61" viewBox="0 0 61 61" fill="none" \
    xmlns="http://www.w3.org/2000/svg">\
    <circle cx="30.5" cy="30.5" r="30" fill="#FF0000"/></svg>
    """

    @Test("An SVG decodes, and at the size it was asked for")
    func svgDecodes() throws {
        let image = try #require(
            ImageStore.decode(Data(Self.svg.utf8), maximumPixelSize: 120)
        )
        // Square source, so both sides land on the cap — the same contract
        // `kCGImageSourceThumbnailMaxPixelSize` has for a bitmap.
        #expect(image.width == 120)
        #expect(image.height == 120)
    }

    @Test("It rasterises at the drawn size rather than the authored one")
    func svgScales() throws {
        let small = try #require(ImageStore.decode(Data(Self.svg.utf8), maximumPixelSize: 32))
        #expect(small.width == 32)
        // The whole point of the branch: 61 points of authored artwork drawn
        // into 240 without the softness a bitmap upscale would have.
        let large = try #require(ImageStore.decode(Data(Self.svg.utf8), maximumPixelSize: 240))
        #expect(large.width == 240)
    }

    @Test("And it actually draws ink, rather than an empty bitmap")
    func svgHasInk() throws {
        let image = try #require(ImageStore.decode(Data(Self.svg.utf8), maximumPixelSize: 40))
        // **The failure this guards is a decode that succeeds and draws
        // nothing**, which every size assertion above would still pass.
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(
                x: 0, y: 0, width: image.width, height: image.height
            ))
        }
        let centre = (image.height / 2 * image.width + image.width / 2) * 4
        #expect(pixels[centre] > 200)
        #expect(pixels[centre + 3] > 200)
    }

    /// Discord's tenure artwork is **not square and not all one shape**: the
    /// eight share a height of 69 and run 60, 61, 68, 69, 78, 84, 99, 104 wide.
    /// A decoder that squares them squashes the top four, which is exactly what
    /// a `.frame(width:height:)` on a `.resizable()` image did to Diamond.
    @Test("A wide drawing keeps its authored aspect")
    func svgKeepsAspect() throws {
        let wide = """
        <svg width="78" height="69" viewBox="0 0 78 69" fill="none" \
        xmlns="http://www.w3.org/2000/svg">\
        <rect width="78" height="69" fill="#00FF00"/></svg>
        """
        let image = try #require(ImageStore.decode(Data(wide.utf8), maximumPixelSize: 156))
        // The cap is the LONGEST side, as it is for a bitmap.
        #expect(image.width == 156)
        #expect(image.height == 138)
    }

    @Test("Nonsense decodes to nothing rather than to an empty picture")
    func rubbishFails() {
        #expect(ImageStore.decode(Data("not an image".utf8), maximumPixelSize: 64) == nil)
        #expect(ImageStore.decode(Data(), maximumPixelSize: 64) == nil)
    }
}
