import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// The sampling step in front of the quantiser.
///
/// Small, and worth pinning anyway: both of its rejections change which colour
/// a person's profile ends up wearing, and neither is visible in the output
/// when it silently stops working.
@Suite("Profile theme palette")
struct ProfileThemePaletteTests {

    /// An image whose left `whiteFraction` is pure white and whose right is
    /// `colour`.
    private func image(colour: (UInt8, UInt8, UInt8), whiteFraction: Double) -> CGImage {
        let side = 128
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let boundary = Int(Double(side) * whiteFraction)
        for y in 0..<side {
            for x in 0..<side {
                let o = (y * side + x) * 4
                let white = x < boundary
                bytes[o] = white ? 255 : colour.0
                bytes[o + 1] = white ? 255 : colour.1
                bytes[o + 2] = white ? 255 : colour.2
                bytes[o + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private func channels(_ value: UInt32) -> (Int, Int, Int) {
        (Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF))
    }

    @Test("Near-white is thrown away before quantising")
    func rejectsNearWhite() {
        // A photograph shot against a window is mostly blown highlight. Without
        // this rejection that person's profile comes out white — and white is
        // the one theme that makes a card indistinguishable from an unthemed
        // one, so the failure looks like the feature never ran.
        let derived = ProfileThemePalette.derive(
            from: image(colour: (30, 90, 200), whiteFraction: 0.75)
        )
        #expect(!derived.isEmpty)
        let (r, g, b) = channels(derived[0])
        #expect(b > r, "the blue quarter should win over the white three quarters")
        #expect(g > r)
        #expect(!(r > 240 && g > 240 && b > 240), "white leaked into the palette")
    }

    @Test("A picture with nothing but near-white yields no theme at all")
    func allWhiteYieldsNothing() {
        // Empty rather than black: a profile with no usable colour keeps its
        // neutral ground, and handing back a colour nobody chose is worse than
        // handing back none.
        #expect(ProfileThemePalette.derive(
            from: image(colour: (255, 255, 255), whiteFraction: 1)
        ).isEmpty)
    }

    @Test("The colour survives the stride")
    func samplesEveryTenthPixel() {
        // Sampling is what makes this affordable, and it is also what decides
        // which swatch wins — so the sampled subset still has to describe the
        // picture.
        let derived = ProfileThemePalette.derive(
            from: image(colour: (200, 40, 40), whiteFraction: 0)
        )
        #expect(!derived.isEmpty)
        let (r, g, b) = channels(derived[0])
        #expect(abs(r - 200) <= 8)
        #expect(abs(g - 40) <= 8)
        #expect(abs(b - 40) <= 8)
    }

    @Test("Each rendition size is the CDN rung its URL builder asks for")
    func sizeMatchesTheRung() {
        // Two numbers that must agree, per surface: quantising the same picture
        // at another size picks a different swatch outright, so the size the URL
        // requests and the size the decode is capped at cannot drift apart.
        for size in [ProfileThemePalette.profilePixelSize,
                     ProfileThemePalette.applicationPixelSize] {
            #expect(CDN.rung(forSide: CGFloat(size) / 2, scale: 2) == size, "\(size)")
        }
    }

    @Test("A profile is quantised at 80, which is the rung Discord's own palette used")
    func profileRungIsEighty() {
        // Driven against a capture of Discord's `S4` output for a known avatar —
        // `#89867d` then `#d5d4d3`. At 64, 128 and 256 this client's quantiser
        // puts the near-black behind the subject in second place and the light
        // colour third; at 80 the pair and the ORDER are Discord's, with the
        // secondary exact. See `ProfileThemePalette` for the sweep.
        #expect(ProfileThemePalette.profilePixelSize == 80)
        // And the application path keeps its own, which was verified byte for
        // byte against two gradients Discord rendered.
        #expect(ProfileThemePalette.applicationPixelSize == 128)
    }

    @Test("A derived palette is five colours in Discord's own order")
    func paletteIsFive() {
        // `[...t.slice(0, 2), ...Q7(t[0])]`, read off the store's own action.
        // The surfaces split on that array — the full profile takes [0] and [1],
        // the sidebar keeps only [0] — so the shape is the answer.
        let palette = ProfileThemePalette.derive(
            from: image(colour: (200, 40, 40), whiteFraction: 0.1)
        )
        // **Two raw boxes plus three partners — where there ARE two boxes.** A
        // picture of one colour quantises to one, and inventing a second would
        // be the client deciding a body colour nobody's artwork contains. The
        // shape that always holds is the tail.
        #expect(palette.count == min(2, palette.count - 3) + 3)
        #expect(palette.count >= 4)
        let primary = SIMD3<UInt8>(
            UInt8(palette[0] >> 16 & 0xFF),
            UInt8(palette[0] >> 8 & 0xFF),
            UInt8(palette[0] & 0xFF)
        )
        let partners = PaletteHarmony.partners(of: primary).map {
            UInt32($0.x) << 16 | UInt32($0.y) << 8 | UInt32($0.z)
        }
        #expect(Array(palette.suffix(3)) == partners)
    }
}
