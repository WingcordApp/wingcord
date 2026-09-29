import CoreGraphics
import Foundation
import WingcordCore

/// Discord's loading placeholders as pictures, decoded once each.
///
/// **Read from the painters, off the main actor**, so the cache is `NSCache`,
/// which is safe from any thread. A placeholder is at most 32 pixels on its
/// long side — four kilobytes — and the decode is a few thousand cosines, so
/// a hundred of them cost less than one attachment.
nonisolated final class PlaceholderImages: @unchecked Sendable {
    static let shared = PlaceholderImages()

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()

    private init() {
        cache.countLimit = 400
    }

    /// The picture a placeholder stands for, stretched by whoever draws it.
    func image(_ base64: String?) -> CGImage? {
        guard let base64, !base64.isEmpty else { return nil }
        if let hit = cache.object(forKey: base64 as NSString) { return hit.image }
        guard let pixels = MediaPlaceholder.decode(base64: base64),
              let provider = CGDataProvider(data: Data(pixels.rgba) as CFData),
              let image = CGImage(
                  width: pixels.width,
                  height: pixels.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: pixels.width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else { return nil }
        cache.setObject(Box(image), forKey: base64 as NSString)
        return image
    }
}
