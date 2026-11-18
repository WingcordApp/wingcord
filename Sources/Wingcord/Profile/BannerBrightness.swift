import CoreGraphics
import Foundation
import Synchronization
import SwiftUI

/// Whether the top of a profile banner is too bright for the white labels on
/// the clear glass laid over it (Alex, 2026-11-18, his Image 146: "on bright
/// banners these pills are unreadable").
///
/// **The HIG's own answer, inside the glass.** "Only use clear over visually
/// rich backgrounds… For clear over bright content, consider a dark dimming
/// layer at 35% opacity; no additional layer is needed over sufficiently dark
/// content." So a bright banner's corner controls get black in their material
/// (`View.chromeOverBanner`) and a dark one's stay clear. Only a picture banner
/// decides it: a pale card without one keeps clear glass and the card's dark
/// ink, because a dark disc there was the grey disc of Alex's images 55 and 56.
///
/// **Measured once per banner and cached by URL**: a 48-pixel decode from the
/// image store, which already holds the banner's bytes because it is on
/// screen, read off the main thread. An animated banner is judged by its
/// first frame.
nonisolated enum BannerBrightness {
    /// Over this, white text on the clear glass reads under WCAG's 4.5:1 —
    /// `1.05 / (L + 0.05) = 4.5` at L ≈ 0.183.
    static let threshold = 0.183

    /// How much black goes into the glass over a bright banner. The HIG says
    /// 35 %, but at 35 % white text over a white banner still reads at about
    /// 2.4:1; at 50 % it is about 4:1, close to Discord's own backing.
    static let dimming = 0.5

    private static let known = Mutex<[URL: Bool]>([:])

    /// A banner already measured, so a profile opened again is right on its
    /// first frame instead of fading into it.
    static func cached(_ url: URL) -> Bool? {
        known.withLock { $0[url] }
    }

    static func isBright(_ url: URL) async -> Bool {
        if let answer = cached(url) { return answer }
        guard let image = await ImageStore.shared.image(
            for: ImageStore.Key(url: url, maximumPixelSize: 48),
            bucket: .artwork
        ) else { return false }
        let answer = isBright(image)
        known.withLock { $0[url] = answer }
        return answer
    }

    /// The brighter quarter of the top two fifths, where the corner controls
    /// sit: a banner bright across its top dims them, one bright speck does
    /// not.
    static func isBright(_ image: CGImage) -> Bool {
        let width = 24
        let height = max(1, Int((Double(image.height) * Double(width) / Double(max(1, image.width))).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return false }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        // A bitmap context's memory runs from the top row down.
        let rows = max(1, Int((Double(height) * 0.4).rounded(.up)))
        var levels: [Double] = []
        levels.reserveCapacity(rows * width)
        for row in 0..<rows {
            for column in 0..<width {
                let index = (row * width + column) * 4
                let packed = UInt32(data[index]) << 16 | UInt32(data[index + 1]) << 8 | UInt32(data[index + 2])
                levels.append(InkContrast.luminance(packed))
            }
        }
        levels.sort()
        return levels[min(levels.count - 1, levels.count * 3 / 4)] > threshold
    }
}

extension EnvironmentValues {
    /// Whether the glass labels here sit over a bright banner, which dims
    /// their glass (`BannerBrightness`).
    @Entry var isOverBrightBanner = false
}
