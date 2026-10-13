import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Vencord's `sendAnimatedSticker`: an animated sticker, redrawn as a GIF the
/// plugin's size, for Fake Nitro to put in the tray.
///
/// **ImageIO on both ends.** It hands back an animated PNG's frames already
/// composited — the dispose and blend operations the plugin replays by hand on
/// a canvas — and its GIF encoder quantizes each frame to 256 colours with a
/// transparent index, which is what the plugin's `gifenc` does.
nonisolated enum AnimatedStickerGIF {
    /// The plugin's `stickerSize` default: the GIF is this many pixels square.
    static let side = 160

    /// The GIF, or nil for data that is not an animated picture.
    static func gif(fromAnimatedPNG data: Data, side: Int = side) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.gif.identifier as CFString, count, nil
        ) else { return nil }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for index in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil),
                  let fitted = fitted(frame, side: side)
            else { return nil }
            CGImageDestinationAddImage(destination, fitted, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFUnclampedDelayTime: delay(at: index, in: source),
                ],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// The frame's own delay, in seconds — the plugin's `delay`.
    private static func delay(at index: Int, in source: CGImageSource) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let delay = png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double
            ?? png?[kCGImagePropertyAPNGDelayTime] as? Double
        return delay ?? 0.1
    }

    /// The frame scaled to fit `side` square, centred, as the plugin's canvas
    /// scales by the longer edge.
    private static func fitted(_ frame: CGImage, side: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let scale = CGFloat(side) / CGFloat(max(frame.width, frame.height))
        let width = CGFloat(frame.width) * scale
        let height = CGFloat(frame.height) * scale
        context.interpolationQuality = .high
        context.draw(frame, in: CGRect(
            x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2, width: width, height: height
        ))
        return context.makeImage()
    }
}
