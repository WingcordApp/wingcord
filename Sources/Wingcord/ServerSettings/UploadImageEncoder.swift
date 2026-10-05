import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WingcordCore

/// Turns a chosen picture into what a JSON image route takes.
///
/// **A still is re-encoded to PNG, never relabelled**, and where a byte budget
/// is given it is shrunk — the original size first, then 512, 256 and 128 on
/// the longest side — until it fits. A GIF goes up as itself: re-encoding it
/// would keep one frame of an animation somebody chose on purpose.
///
/// `nonisolated` and free of AppKit, so the decode runs wherever its caller
/// puts it, which is off the main actor.
nonisolated enum UploadImageEncoder {
    static func prepared(_ bytes: Data, isGIF: Bool, maximumBytes: Int?) -> ImageData? {
        if isGIF { return .gif(bytes) }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let longest = max(full.width, full.height)
        var sides = [longest]
        for side in [512, 256, 128] where side < longest { sides.append(side) }

        var smallest: Data?
        for side in sides {
            let image = side == longest ? full : thumbnail(source, side: side)
            guard let image, let png = encodePNG(image) else { continue }
            smallest = png
            if let maximumBytes, png.count > maximumBytes { continue }
            return .png(png)
        }
        // Still over budget at 128: the route's own refusal is the honest
        // answer, and it carries Discord's words.
        return smallest.map(ImageData.png)
    }

    private static func thumbnail(_ source: CGImageSource, side: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ] as CFDictionary)
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
