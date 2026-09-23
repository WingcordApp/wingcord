import AppKit
import CoreText
import Foundation
import Lottie
import WingcordCore

/// The pictures a super reaction is made of: the emoji at the size Discord
/// hands its effects, the palette Discord derives from that picture, and the
/// effect's own artwork, recoloured and fitted.
///
/// **Everything expensive happens once and off the main actor.** An effect is
/// decompressed, recoloured and parsed in a detached task and the parsed
/// animation is cached — hovering a chip replays the same effect, and a second
/// parse of a hundred kilobytes of JSON for an answer already in hand is the
/// per-frame waste this app does not do. What reaches the main actor is a
/// finished `LottieAnimation` and a finished `CGImage`.
nonisolated enum SuperReactionArt {

    /// The side Discord's palette is quantised at — `Br`'s default of 32 in
    /// module `104142`, which Discord's URL builder then multiplies by the
    /// display's scale. Captured: the hover that played StarBlast fetched the
    /// emoji at `?size=64`. **Kept for the palette**, because the colours are
    /// a function of exactly which pixels are sampled.
    static let paletteSide: CGFloat = 32

    /// The side an effect is handed its emoji at.
    ///
    /// **Not Discord's 32, deliberately.** The effect draws the emoji into a
    /// 128-unit slot of a 300-unit composition played 142 points wide — about
    /// 61 points, and more while it pops — so Discord's 32-point picture is
    /// drawn soft. This asks for the size it is actually drawn at.
    static let effectSide: CGFloat = 64

    // MARK: The emoji

    /// The emoji as a picture, or nil where there is none to be had.
    ///
    /// **A custom emoji's still, never its animation.** Discord hands an
    /// animated one's GIF to the SVG `<image>` the effect draws into; a Lottie
    /// image layer here takes one bitmap, so the effect shows the first frame
    /// — while the chip underneath keeps playing its own.
    ///
    /// A Unicode emoji is drawn by Apple Color Emoji, which is the art this
    /// client shows for it everywhere else. Discord's own is Twemoji; a chip
    /// whose effect showed a different drawing of its emoji than the chip does
    /// would be two emoji.
    static func emojiImage(_ emoji: EmojiRef, side: CGFloat, scale: CGFloat) async -> CGImage? {
        let pixels = Int((side * scale).rounded(.up))
        guard let id = emoji.id else {
            return glyphImage(emoji.name, pixels: pixels)
        }
        guard let url = CDN.emoji(id: id, animated: false, side: side, scale: scale)
        else { return nil }
        return await ImageStore.shared.image(for: ImageStore.Key(url: url, maximumPixelSize: pixels))
    }

    /// A Unicode emoji as a square bitmap, the glyph's own ink filling it.
    ///
    /// Sized from the ink, not from the font: Apple Color Emoji's glyphs sit
    /// inside an em square with an ascent and descent of their own, so a font
    /// of `pixels` points draws a glyph noticeably smaller than the square and
    /// off its centre. One measure at a trial size, then the real size is the
    /// trial scaled by how far the ink fell short — the bitmap strike is then
    /// drawn at its own size rather than resampled by a transform.
    static func glyphImage(_ glyph: String, pixels: Int) -> CGImage? {
        guard pixels > 0, !glyph.isEmpty,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                  bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let side = CGFloat(pixels)

        func line(size: CGFloat) -> CTLine {
            let font = CTFontCreateWithName("AppleColorEmoji" as CFString, size, nil)
            return CTLineCreateWithAttributedString(
                NSAttributedString(string: glyph, attributes: [.font: font])
            )
        }

        let trial = line(size: side)
        let trialInk = CTLineGetImageBounds(trial, context)
        guard !trialInk.isNull, trialInk.width > 0, trialInk.height > 0 else { return nil }
        let size = side * min(side / trialInk.width, side / trialInk.height)
        let fitted = line(size: size)
        let ink = CTLineGetImageBounds(fitted, context)
        guard !ink.isNull else { return nil }

        context.textPosition = CGPoint(
            x: (side - ink.width) / 2 - ink.minX,
            y: (side - ink.height) / 2 - ink.minY
        )
        CTLineDraw(fitted, context)
        return context.makeImage()
    }

    // MARK: The palette

    /// The colours a super reaction the reader adds starts with — Discord's
    /// `getEmojiColors`: the quantiser a themeless profile is coloured by, run
    /// over the emoji's 32-point picture.
    ///
    /// **They are what the reader's chip keeps.** The gateway echoes the
    /// reaction back with the server's own palette, and Discord's reducer
    /// ignores it for an emoji that already has one — so these colours, not
    /// the server's, are the ones the reader sees on their own super reaction
    /// until the channel is loaded again.
    static func palette(for emoji: EmojiRef, scale: CGFloat) async -> [UInt32] {
        guard let image = await emojiImage(emoji, side: paletteSide, scale: scale) else { return [] }
        return await Task.detached(priority: .userInitiated) {
            ProfileThemePalette.palette(of: image).prefix(3).map {
                UInt32($0.x) << 16 | UInt32($0.y) << 8 | UInt32($0.z)
            }
        }.value
    }

    // MARK: The effect

    /// One effect, recoloured for `accent` and fitted to a picture of the given
    /// size, parsed — or nil when the bundled file cannot be read.
    static func animation(
        index: Int,
        accent: UInt32,
        pictureWidth: Int,
        pictureHeight: Int
    ) async -> LottieAnimation? {
        // Only the aspect changes the text, and a square is untouched — see
        // `SuperReactionEffect.fitted` — so the key carries the height the slot
        // will be fitted to rather than the picture's pixels.
        let slotHeight = pictureWidth > 0 && pictureHeight > 0 && pictureWidth != pictureHeight
            ? Int((SuperReactionEffect.imageSide / Double(pictureWidth) * Double(pictureHeight)).rounded())
            : Int(SuperReactionEffect.imageSide)
        let key = "\(index):\(accent):\(slotHeight)" as NSString
        if let hit = cache.object(forKey: key) { return hit.animation }

        let parsed = await Task.detached(priority: .userInitiated) { () -> LottieAnimation? in
            guard SuperReactionEffect.names.indices.contains(index),
                  let url = Bundle.module.url(
                      forResource: SuperReactionEffect.names[index],
                      withExtension: "lzfse",
                      subdirectory: "SuperReactions"
                  ),
                  let packed = try? Data(contentsOf: url),
                  let json = try? (packed as NSData).decompressed(using: .lzfse) as Data
              else { return nil }
            let prepared = SuperReactionEffect.fitted(
                SuperReactionEffect.recolored(json, accent: accent),
                pictureWidth: pictureWidth,
                pictureHeight: pictureHeight
            )
            return try? LottieAnimation.from(data: prepared)
        }.value
        guard let parsed else { return nil }
        cache.setObject(Box(parsed), forKey: key)
        return parsed
    }

    /// Parsed effects, most recently played kept. Six, because a screen rarely
    /// holds more distinct super reactions than that, and a parsed effect is a
    /// few hundred kilobytes of keyframes.
    ///
    /// `nonisolated(unsafe)` because `NSCache` is not marked `Sendable` and is
    /// documented thread-safe; the reference itself never changes.
    private nonisolated(unsafe) static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 6
        return cache
    }()

    private final class Box: Sendable {
        let animation: LottieAnimation
        init(_ animation: LottieAnimation) { self.animation = animation }
    }
}

/// Hands every effect the one picture it asks for: the emoji.
///
/// All eighteen effects have exactly one image asset, `image_0`, so there is
/// nothing to choose between.
nonisolated struct SuperReactionImageProvider: AnimationImageProvider {
    let image: CGImage

    func imageForAsset(asset: ImageAsset) -> CGImage? { image }
}
