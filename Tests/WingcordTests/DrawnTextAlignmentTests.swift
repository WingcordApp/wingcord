import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Wingcord

/// Where drawn text actually lands.
///
/// **This suite exists because the bug it pins was invisible to every other
/// kind of test.** `drawText` took an `NSTextAlignment` and set it on a
/// paragraph style — which `CTLine` ignores, since alignment is resolved by a
/// framesetter laying lines into a column and there is no column when a line is
/// drawn straight into a context. Every centred label in the app was therefore
/// drawn hard against the leading edge of the box it was centred in: the letters
/// inside a chip, an avatar's monogram, the play glyph on a video, the unread
/// band's NEW. The code read correctly, compiled, produced ink, and put it in
/// the wrong place.
///
/// So these assert a *position*, not the presence of ink. A test that only
/// checked something was drawn passed against the defect for as long as it
/// existed.
@MainActor
@Suite("Drawn text alignment")
struct DrawnTextAlignmentTests {

    private static let width = 200
    private static let height = 24

    /// Draws one label into a bitmap and answers where its ink sits, as a
    /// fraction of the box: 0 is hard left, 1 is hard right.
    private func inkCenter(alignment: NSTextAlignment) -> Double? {
        let bytesPerRow = Self.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * Self.height)

        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: Self.width,
                      height: Self.height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                Issue.record("could not create a bitmap context")
                return
            }
            context.translateBy(x: 0, y: CGFloat(Self.height))
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            TimelineRowPainter.drawText(
                "NEW",
                font: NSFont.systemFont(ofSize: 11, weight: .bold),
                color: .white,
                at: CGPoint(x: 0, y: 4),
                maxWidth: CGFloat(Self.width),
                alignment: alignment,
                context: context
            )
            NSGraphicsContext.restoreGraphicsState()
        }

        var first: Int?
        var last: Int?
        for column in 0..<Self.width {
            var isInked = false
            for row in 0..<Self.height where pixels[row * bytesPerRow + column * 4] != 0 {
                isInked = true
                break
            }
            guard isInked else { continue }
            if first == nil { first = column }
            last = column
        }
        guard let first, let last else { return nil }
        return (Double(first) + Double(last)) / 2 / Double(Self.width)
    }

    @Test("Left-aligned text starts at the origin it was given")
    func leftAligned() throws {
        let center = try #require(inkCenter(alignment: .left))
        // A three-letter label in a 200pt box: its midpoint sits well inside the
        // first fifth if it is hard against the left edge.
        #expect(center < 0.2)
    }

    @Test("Centred text is centred, not drawn at the leading edge")
    func centred() throws {
        let center = try #require(inkCenter(alignment: .center))
        let distanceFromMiddle = abs(center - 0.5)
        #expect(distanceFromMiddle < 0.03)
    }

    @Test("Right-aligned text ends at the trailing edge")
    func rightAligned() throws {
        let center = try #require(inkCenter(alignment: .right))
        #expect(center > 0.8)
    }

    /// The three alignments must be three different answers. Asserting each
    /// separately still passes if the function quietly draws everything in one
    /// place that happens to satisfy all three tolerances.
    @Test("The three alignments are three different places")
    func allDistinct() throws {
        let left = try #require(inkCenter(alignment: .left))
        let center = try #require(inkCenter(alignment: .center))
        let right = try #require(inkCenter(alignment: .right))
        let leftToCenter = center - left
        let centerToRight = right - center
        #expect(leftToCenter > 0.2)
        #expect(centerToRight > 0.2)
    }
}
