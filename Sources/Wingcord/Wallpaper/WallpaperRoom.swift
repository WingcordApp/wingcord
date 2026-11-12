import CoreGraphics
import Foundation

/// Where the window's colours come from while something other than the theme is
/// behind it — Appearance › Pictures › Colours.
///
/// **One look, one palette.** The theme and the wallpaper used to be two
/// settings that knew nothing of each other: the desktop or a photograph went
/// behind the window and every embed, card and sheet kept the colour of
/// whichever theme had been chosen before it — navy cards in a grey window.
/// Now what is behind the window decides the colours on it, unless the reader
/// asks to keep the theme's on purpose.
nonisolated enum WallpaperColours: String, CaseIterable, Identifiable, Sendable, Codable {
    /// From what is behind the window: a picture's own colour, and no colour
    /// over the desktop.
    case automatic
    /// No colour: the house greys, light or dark as the theme is.
    case neutral
    /// The chosen theme's, kept over the picture.
    case theme

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .neutral: "Neutral"
        case .theme: "My Theme"
        }
    }
}

/// The colour a picture leans to, in Oklab's polar terms.
nonisolated struct WallpaperTone: Hashable, Sendable {
    /// Degrees, `0..<360`, to the nearest whole one — two decodes of one
    /// picture must not be two themes.
    var hue: Double
    /// The chroma of the picture's average colour. A grey photograph has none.
    var chroma: Double

    init(hue: Double, chroma: Double) {
        self.hue = hue.rounded()
        self.chroma = (chroma * 200).rounded() / 200
    }

    /// Below this the picture has no colour worth lending: a room tinted from
    /// a grey photograph's rounding error is a random hue.
    static let leastChroma = 0.02

    /// The seed of the room this colour makes.
    ///
    /// **A quiet room, not a loud one.** The picture is already the colour in
    /// the window; the surfaces over it only have to belong to it. The depth
    /// follows the picture's own chroma and stops well short of the house
    /// themes' — and shorter still in the olive band, where a dark ground at
    /// any depth is a dirty grey (`PlumageShuffle.hueBands`).
    var seed: ThemeSeed {
        var depth = min(0.62, max(0.2, chroma / 0.16))
        if (70...100).contains(hue) { depth = min(depth, 0.3) }
        return ThemeSeed(hue: hue, depth: depth, light: 0.42)
    }
}

/// The room a wallpaper asks the theme for.
nonisolated enum WallpaperRoom: Hashable, Sendable {
    /// The chosen theme's own.
    case theme
    /// The house greys.
    case neutral
    /// A room in the picture's colour.
    case toned(WallpaperTone)

    /// - Parameter tone: the picture's colour, or nil where it has none or
    ///   has not been read.
    static func resolve(
        source: WallpaperSource,
        colours: WallpaperColours,
        tone: WallpaperTone?
    ) -> WallpaperRoom {
        if source == .theme || colours == .theme { return .theme }
        if source == .desktop || colours == .neutral { return .neutral }
        guard let tone, tone.chroma >= WallpaperTone.leastChroma else { return .neutral }
        return .toned(tone)
    }
}

extension WallpaperMedia {
    /// The colour a picture leans to, read from a small copy of it — handed
    /// the frost, which is the picture already blurred past its detail.
    ///
    /// The hue is the chroma-weighted mean, so a sunset over a grey sea is
    /// orange rather than the muddy average of the two; the chroma is the
    /// plain average's, which is what the blurred picture actually shows and
    /// what falls to nothing when two hues oppose each other.
    static func tone(of image: CGImage) -> WallpaperTone? {
        let width = 32, height = 20
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var weightedA = 0.0, weightedB = 0.0, sumA = 0.0, sumB = 0.0
        let count = width * height
        for pixel in 0..<count {
            let packed = UInt32(pixels[pixel * 4]) << 16
                | UInt32(pixels[pixel * 4 + 1]) << 8
                | UInt32(pixels[pixel * 4 + 2])
            let colour = Oklch(packedRGB: packed)
            let radians = colour.hue * .pi / 180
            let a = colour.chroma * cos(radians), b = colour.chroma * sin(radians)
            sumA += a
            sumB += b
            weightedA += a * colour.chroma
            weightedB += b * colour.chroma
        }
        let meanA = sumA / Double(count), meanB = sumB / Double(count)
        let chroma = (meanA * meanA + meanB * meanB).squareRoot()
        guard weightedA != 0 || weightedB != 0 else { return WallpaperTone(hue: 0, chroma: 0) }
        var hue = atan2(weightedB, weightedA) * 180 / .pi
        if hue < 0 { hue += 360 }
        return WallpaperTone(hue: hue, chroma: chroma)
    }
}
