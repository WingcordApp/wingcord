import AppKit
import CoreGraphics
import Testing
@testable import Wingcord

/// Every emoji keeps its own shape inside the box it is given.
///
/// **Geometric, because the failure is.** A custom emoji drawn to a square box
/// was stretched to it — a wide one squeezed into a different picture — and a
/// Unicode glyph sized to the box's height spilled out of its sides and was cut
/// off. Both draw perfectly well and look plausible; only the arithmetic says
/// they are wrong.
@Suite("Emoji fit their box")
struct EmojiFitTests {

    /// A bitmap of a given shape. The fit reads nothing but its dimensions.
    private func picture(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    private let box = CGRect(x: 10, y: 20, width: 16, height: 16)

    @Test("A wide emoji is letterboxed, not squeezed")
    func wide() throws {
        let fitted = TimelineRowPainter.fittedRect(
            try picture(width: 64, height: 32), in: box, covering: false
        )
        #expect(fitted == CGRect(x: 10, y: 24, width: 16, height: 8))
    }

    @Test("A tall emoji is pillarboxed")
    func tall() throws {
        let fitted = TimelineRowPainter.fittedRect(
            try picture(width: 30, height: 60), in: box, covering: false
        )
        #expect(fitted == CGRect(x: 14, y: 20, width: 8, height: 16))
    }

    @Test("Covering still fills the box and hangs out of it")
    func covering() throws {
        let fitted = TimelineRowPainter.fittedRect(
            try picture(width: 64, height: 32), in: box, covering: true
        )
        #expect(fitted == CGRect(x: 2, y: 20, width: 32, height: 16))
    }

    @Test(
        "A Unicode emoji's ink fills its box and stays inside it",
        arguments: ["❌", "👍", "🫠", "🏳️‍🌈", "👨‍👩‍👧‍👦", "❤️"]
    )
    func glyph(_ glyph: String) {
        for side: CGFloat in [11, 12, 16, 20, 24, 48] {
            let metrics = EmojiGlyphMetrics.fitting(glyph, side: side)
            let extent = max(metrics.ink.width, metrics.ink.height)
            #expect(extent <= side + 0.01, "\(glyph) at \(side): ink \(extent)")
            // Filled, not shrunk: a quarter-point step is the only slack.
            #expect(extent >= side * 0.9, "\(glyph) at \(side): ink \(extent)")
        }
    }
}
