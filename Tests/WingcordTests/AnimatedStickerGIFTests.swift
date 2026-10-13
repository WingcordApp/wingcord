import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Wingcord

/// Fake Nitro's animated sticker: an animated PNG in, the plugin's 160-pixel
/// square GIF out, every frame and its delay kept.
struct AnimatedStickerGIFTests {

    /// Two frames of a 100×50 animated PNG, red then blue, 0.2 s and 0.5 s.
    private func animatedPNG() throws -> Data {
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.png.identifier as CFString, 2, nil
        ))
        for (red, delay) in [(1.0, 0.2), (0.0, 0.5)] {
            let context = try #require(CGContext(
                data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(red: red, green: 0, blue: 1 - red, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
            let image = try #require(context.makeImage())
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay],
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test("Every frame becomes a 160-pixel GIF frame with its own delay")
    func converts() throws {
        let gif = try #require(AnimatedStickerGIF.gif(fromAnimatedPNG: try animatedPNG()))
        let source = try #require(CGImageSourceCreateWithData(gif as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.gif.identifier)
        #expect(CGImageSourceGetCount(source) == 2)
        let frame = try #require(CGImageSourceCreateImageAtIndex(source, 1, nil))
        #expect(frame.width == AnimatedStickerGIF.side && frame.height == AnimatedStickerGIF.side)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 1, nil) as? [CFString: Any]
        let delay = (properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        #expect(abs((delay ?? 0) - 0.5) < 0.011)
    }

    @Test("Bytes that are not a picture give nothing")
    func refusesNoise() {
        #expect(AnimatedStickerGIF.gif(fromAnimatedPNG: Data("not a picture".utf8)) == nil)
    }
}
