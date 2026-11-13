import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The window's picture, made to fit the reports service's limit
/// (`ReportsWorker/src/config.ts`: 4 MB). A big window on a Retina display
/// can come out larger as a PNG; it is scaled down until it fits rather than
/// turned away, and dropped only if it never does.
nonisolated enum ScreenshotFitting {
    static let limit = 4 * 1024 * 1024

    static func fit(_ png: Data, limit: Int = limit) -> Data? {
        if png.count <= limit { return png }
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        var side = Double(max(width, height))
        var size = png.count
        for _ in 0..<4 {
            // A picture's bytes grow with its area, the square of its side:
            // aim a little under the limit.
            side *= (Double(limit) / Double(size)).squareRoot() * 0.9
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, Int(side)),
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let data = encode(image)
            else { return nil }
            if data.count <= limit { return data }
            size = data.count
        }
        return nil
    }

    private static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
