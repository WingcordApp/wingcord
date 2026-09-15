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
///  - **80 pixels**, and this is a correction. It was 128, on a measurement
///    taken against a single dark avatar where only the *first* swatch was
///    checkable. Driven against a capture of Discord's own `S4` output —
///    `[137,134,125]` then `[213,212,211]` for a known avatar — the rungs
///    disagree about the **second** box, which is the one the card body is
///    painted with:
///
///    ```
///    src=64   #8c8982  #2e2f2d  #d8d8d4
///    src=80   #87847c  #d5d4d3  #2b2c2b   <- Discord's pair, in Discord's order
///    src=128  #8d8b84  #2f3130  #d8d8d5
///    src=256  #8d8b84  #2f3232  #d9d8d6
///    ```
///
///    At every rung but 80 the near-black behind the subject wins second place
///    and the light colour falls to third. `HANDOFF.md` recorded that as a
///    property of derived palettes — "the second of those is very often the
///    near-black *behind* the subject" — and it was a property of asking for
///    the wrong picture. 80 is the rung the profile surfaces themselves
///    request, and the palette store is keyed by the URL, so it is the rung
///    Discord quantises.
///  - **Every tenth pixel.** Discord's `quality` argument, and it changes which
///    box the median cut lands in.
///  - **No resample.** The image is quantised at the size it arrives.
///
/// **The three above were established by sweeping the input against a captured
/// output; module `515718` has since been read, and it agrees.** `Sf` verbatim,
/// which is what `S4` resolves to:
///
/// ```js
/// let a = i.width  = (e.width  === 0 ? 128 : e.width),
///     s = i.height = (e.height === 0 ? 128 : e.height);
/// r.drawImage(e, 0, 0, a, s);
/// … for (let r = 0; r < a * s; r += quality) { let a2 = 4 * r; …
///     if ((d === undefined || d >= 125) && !(s > 250 && l > 250 && o > 250)) push([s,l,o]) }
/// let d = quantize(pixels, 5); return d.palette();
/// ```
///
/// Two things that reading settled and nothing else could have:
///
///  - **The canvas is the image's OWN size.** The 128 is a *fallback* for an
///    image reporting zero width, not a size everything is resampled into —
///    which is how it has been described second-hand. So the rung IS the
///    quantised size, and there is no interpolation anywhere in the pipeline.
///  - **`S4` is memoized on the URL string.** That is what makes the rung a
///    property of the *surface*: two surfaces asking for two sizes of the same
///    face get two palettes, because they are two cache entries built from two
///    pictures. There is no single palette for a person.
///
/// Verified against the captured pair above: the secondary is **exact**, and
/// the primary is within **2 units** on every channel. The remainder is this
/// client's WebP decode against Chrome's, not the algorithm.
nonisolated enum ProfileThemePalette {
    /// The rendition a **profile** is quantised from, in pixels. Also the CDN
    /// rung it is fetched at, so one number rather than two that can drift
    /// apart. See the note above for what it cost to get wrong.
    static let profilePixelSize = 80

    /// The rendition an **application icon** is quantised from.
    ///
    /// **A second number, and the instinct to collapse the two is the trap.**
    /// Discord's palette store is keyed by the *URL*, and a URL carries its
    /// size — so a surface that renders an avatar at 80 and one that renders an
    /// icon at 128 do not share a palette, they compute different ones from
    /// different pictures. There is no single answer for a person; there is an
    /// answer per rendition.
    ///
    /// 128 is verified for this one, byte for byte, against two gradients
    /// Discord actually rendered — see `AppIconGradient` and
    /// `PaletteHarmonyTests`. Changing it to match the profile's 80 would throw
    /// that away for a tidiness that is not true.
    static let applicationPixelSize = 128
    /// Discord's `quality`: take every Nth **pixel**.
    ///
    /// Pixels, not bytes, and the module says so — `for (r = 0; r < count;
    /// r += quality) { a = 4 * r; … }`. The index strides; the byte offset is
    /// derived from it.
    static let stride = 10
    /// How many boxes the quantiser is asked for. Only the first two survive
    /// into the palette, but asking for fewer changes where every cut lands.
    static let swatchCount = 5

    /// The whole palette, as the 24-bit values `theme_colors` would have
    /// carried — so a derived theme and a chosen one reach the surfaces through
    /// exactly the same path and cannot diverge in treatment.
    ///
    /// **Five, and the shape is Discord's own:** the first two raw boxes,
    /// followed by three partners synthesised from the *first* of them. Read
    /// straight off the store's action:
    ///
    /// ```js
    /// let t = await S4(url), n = Q7(t[0]);
    /// palette: { ...i.palette, [e]: [...t.slice(0, 2), ...n] }
    /// ```
    ///
    /// The two consumers split on that array and are why the order matters: the
    /// full profile takes `[0]` for the banner and `[1]` for the card body,
    /// while the sidebar destructures `[i] = …` and keeps only `[0]`. Nothing
    /// in this client draws the three partners yet; they are here because the
    /// palette is one value and half of one is how a surface ends up inventing
    /// the rest.
    ///
    /// Empty when the artwork yields nothing, which is a real answer: a profile
    /// with no usable colour keeps the neutral ground rather than being given a
    /// colour nobody chose.
    static func derive(from image: CGImage) -> [UInt32] {
        let pair = swatches(from: image)
        guard let primary = pair.first else { return [] }
        return (pair + PaletteHarmony.partners(of: primary))
            .map { UInt32($0.x) << 16 | UInt32($0.y) << 8 | UInt32($0.z) }
    }

    /// The same two swatches, before they are packed into `theme_colors`'
    /// shape.
    ///
    /// **Split out because the app directory needs the swatch itself.** Its
    /// banner for an app with no artwork is `[primary, Q7(primary)[0]]`, and
    /// `PaletteHarmony` takes a colour rather than a packed integer — see
    /// `AppIconGradient`. One sampling and one quantiser for both surfaces.
    static func swatches(from image: CGImage) -> [SIMD3<UInt8>] {
        guard let pixels = sample(image), !pixels.isEmpty else { return [] }
        return Array(MedianCutQuantizer.palette(of: pixels, count: swatchCount).prefix(2))
    }

    /// Discord's `createPixelArray`, exactly — checked against the module's
    /// own source rather than against its behaviour.
    ///
    /// **Both rejections are load-bearing.** Dropping near-transparent pixels
    /// keeps a decoration's alpha out of the count, and dropping near-white
    /// keeps a photograph's blown highlights from becoming somebody's theme —
    /// which is why an avatar shot against a window does not come out white.
    ///
    /// **The channels are un-premultiplied on the way out, and that is not a
    /// formality.** `getImageData` hands back *straight* RGBA; a Core Graphics
    /// bitmap context cannot draw into an unpremultiplied format at all, so the
    /// only faithful reading is to undo the multiply. It changes nothing for an
    /// opaque avatar and everything for a PNG with soft edges — those pixels
    /// pass the `>= 125` gate and would otherwise be counted darker than they
    /// are, pulling the histogram toward black exactly where somebody's
    /// artwork fades out.
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
                pixels.append(Self.straight(red, green, blue, alpha))
            }
            index += stride
        }
        return pixels
    }

    /// Premultiplied channels, put back the way `getImageData` reports them.
    ///
    /// Opaque pixels — every pixel of nearly every avatar — pass straight
    /// through, so this costs a compare on the common path.
    @inline(__always)
    private static func straight(
        _ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8
    ) -> SIMD3<UInt8> {
        guard alpha < 255, alpha > 0 else { return SIMD3(red, green, blue) }
        let scale = 255.0 / Double(alpha)
        return SIMD3(
            UInt8(clamping: Int((Double(red) * scale).rounded())),
            UInt8(clamping: Int((Double(green) * scale).rounded())),
            UInt8(clamping: Int((Double(blue) * scale).rounded()))
        )
    }
}
