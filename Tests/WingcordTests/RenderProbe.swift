import AppKit
import CoreGraphics
import Foundation
import Testing

/// Draws into a bitmap and reports how much of it changed.
///
/// **A render check is the only real test of a canvas.** A painter that draws
/// nothing compiles, lays out, reports the right size and renders a perfectly
/// empty view — every other kind of test passes on it.
///
/// **And the first version of a check like this is usually wrong in the same
/// way**: black ink on a black ground asserts nothing. So the ground is MID-GREY
/// and the answer is "what differs from it", rather than a brightness — which
/// would only catch ink that happens to be lighter than what it is drawn on.
///
/// One copy, shared by every drawn surface's tests. Two copies of a probe is two
/// places for the flip below to be got wrong, and getting it wrong produces ink
/// either way.
@MainActor
enum RenderProbe {

    static let ground = CGFloat(0.5)

    static func inkFraction(
        width: Int = 240,
        height: Int = 48,
        _ draw: (CGContext, CGRect) -> Void
    ) -> Double {
        guard width > 0, height > 0 else { return 0 }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let grey = UInt8(ground * 255)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = grey
            pixels[index + 1] = grey
            pixels[index + 2] = grey
            pixels[index + 3] = 255
        }

        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                Issue.record("could not create a bitmap context")
                return
            }
            // The canvases are flipped (top-left origin); a bitmap context is
            // not. Flipping here means the painter draws exactly as it does on
            // screen rather than upside down, which would still produce ink and
            // hide a real geometry bug.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)

            let frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            draw(context, frame)
            NSGraphicsContext.restoreGraphicsState()
        }

        var differing = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index] != grey {
            differing += 1
        }
        return Double(differing) / Double(width * height)
    }
}
