import CoreGraphics
import Testing
@testable import Wingcord

/// Whether a banner's top is too bright for white labels on clear glass
/// (Alex, 2026-11-18, his Image 146).
@Suite("Banner brightness")
struct BannerBrightnessTests {
    /// A 120 × 40 banner: `top` across its upper half, `bottom` under it.
    private func banner(top: CGFloat, bottom: CGFloat) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: 120, height: 40, bitsPerComponent: 8, bytesPerRow: 480,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Core Graphics draws bottom-up: y 0 to 20 is the picture's lower half.
        context.setFillColor(CGColor(srgbRed: bottom, green: bottom, blue: bottom, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 20))
        context.setFillColor(CGColor(srgbRed: top, green: top, blue: top, alpha: 1))
        context.fill(CGRect(x: 0, y: 20, width: 120, height: 20))
        return context.makeImage()!
    }

    @Test("A white banner dims the glass; a dark one leaves it clear")
    func whiteAndDark() {
        #expect(BannerBrightness.isBright(banner(top: 1, bottom: 1)))
        #expect(!BannerBrightness.isBright(banner(top: 0.1, bottom: 0.1)))
    }

    @Test("Only the top decides: the corners are where the labels sit")
    func topDecides() {
        #expect(BannerBrightness.isBright(banner(top: 0.95, bottom: 0.05)))
        #expect(!BannerBrightness.isBright(banner(top: 0.05, bottom: 0.95)))
    }

    @Test("The line is where white text would fall under 4.5:1")
    func threshold() {
        // sRGB 0.35 is about L 0.10 (reads), 0.6 about L 0.32 (does not).
        #expect(!BannerBrightness.isBright(banner(top: 0.35, bottom: 0.35)))
        #expect(BannerBrightness.isBright(banner(top: 0.6, bottom: 0.6)))
    }
}
