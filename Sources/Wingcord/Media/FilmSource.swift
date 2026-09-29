import CoreGraphics
import Foundation
import ImageIO

/// One picture's frames, decoded on demand at the size it is drawn.
///
/// **Every frame, at the asset's own timing and the drawn resolution.** The
/// filmstrip this sits beside samples a long loop down to forty-eight frames and
/// a large one down to whatever fits six megabytes — a sticker authored at
/// thirty frames a second played at twelve, and a GIF at a third of its frames.
/// Nothing here drops a frame; memory is bounded instead by what is on screen,
/// see `FilmLayer`.
///
/// **All decoding happens on this source's own serial queue.** An image source
/// decodes a GIF frame by compositing it over the frames before it, and one
/// thread walking it forward is both the safe way and the fast one.
nonisolated final class FilmSource: @unchecked Sendable {
    let frameCount: Int
    /// The time each frame ends, cumulative, so a lookup is a binary search.
    let ends: [Double]
    /// One full cycle.
    let duration: Double
    /// The shortest frame, which sets how often a player has to look.
    let shortestFrame: Double
    /// The bytes one decoded frame occupies at `maximumPixelSize`.
    let bytesPerFrame: Int

    private let source: CGImageSource
    private let options: CFDictionary
    private let queue = DispatchQueue(label: "dev.wingcord.film", qos: .userInitiated)

    /// Reads an asset's frames, or nil when it cannot be read.
    ///
    /// - Parameter stills: whether one frame is worth reading. **A "GIF" of one
    ///   frame is common** — a caption meme saved as a GIF so it can be
    ///   favourited, a still WebP under a `.gif` name — and what it should
    ///   become depends on the owner. One that draws its own still underneath
    ///   wants nil, before anything is decoded (`AnimatedDecoration`); one that
    ///   leaves its box empty for this picture wants the frame, because nothing
    ///   else will draw it (the transcript's layers, a profile effect's).
    init?(data: Data, maximumPixelSize: Int, stills: Bool = false) {
        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 || (stills && count == 1) else { return nil }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
        guard let first = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }

        var ends: [Double] = []
        ends.reserveCapacity(count)
        var clock: Double = 0
        var shortest = Double.infinity
        for index in 0..<count {
            let delay = Self.frameDelay(of: source, at: index)
            clock += delay
            shortest = min(shortest, delay)
            ends.append(clock)
        }
        self.source = source
        self.options = options
        self.frameCount = count
        self.ends = ends
        self.duration = clock
        self.shortestFrame = shortest
        self.bytesPerFrame = first.height * first.bytesPerRow
        self.firstFrame = first
    }

    /// Frame zero, decoded while reading the source — what a player shows the
    /// moment it has anything at all.
    let firstFrame: CGImage

    /// Every frame's bytes together.
    var residentCost: Int { bytesPerFrame * frameCount }

    /// One frame: a picture to show, and nothing to play.
    var isStill: Bool { frameCount == 1 }

    /// The frame showing `time` seconds into an endless loop.
    func index(at time: Double) -> Int {
        guard duration > 0 else { return 0 }
        var offset = time.truncatingRemainder(dividingBy: duration)
        if offset < 0 { offset += duration }
        var low = 0
        var high = ends.count - 1
        while low < high {
            let mid = (low + high) / 2
            if ends[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The frame showing `time` seconds in, for a picture that plays once when
    /// `looping` is false.
    ///
    /// **Past its end a one-shot holds its last frame rather than wrapping**,
    /// which is what APNG's `num_plays: 1` means and what a browser does. A
    /// profile effect's catalogue gives each layer a SLOT, and the asset's own
    /// length is not the same number: SpongeBob's is a 4125 ms APNG in a
    /// 6000 ms slot, and the looping lookup had him walk on a second time.
    func index(at time: Double, looping: Bool) -> Int {
        guard !looping, time >= duration else { return index(at: max(0, time)) }
        return frameCount - 1
    }

    /// Decodes one frame on this source's queue and hands it back there.
    func decode(_ index: Int, then deliver: @escaping @Sendable (CGImage?) -> Void) {
        queue.async { [self] in
            deliver(CGImageSourceCreateThumbnailAtIndex(source, index, options))
        }
    }

    /// Decodes every frame on this source's queue, in order.
    func decodeAll(then deliver: @escaping @Sendable ([CGImage]?) -> Void) {
        queue.async { [self] in
            var frames: [CGImage] = [firstFrame]
            frames.reserveCapacity(frameCount)
            for index in 1..<frameCount {
                guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options) else {
                    deliver(nil)
                    return
                }
                frames.append(frame)
            }
            deliver(frames)
        }
    }

    /// A delay below this is what an authoring tool writes when it means "as
    /// fast as possible"; browsers substitute a tenth of a second, and so does
    /// this.
    private static let minimumDelay: Double = 0.011
    private static let substituteDelay: Double = 0.1

    /// One frame's delay, from whichever container dictionary applies — the
    /// author's unclamped number first, because the clamped one has had a floor
    /// applied that quietly slows every fast asset. `AnimatedImage` reads it
    /// too: one rule for how long a frame lasts.
    static func frameDelay(of source: CGImageSource, at index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any]
        else { return substituteDelay }
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let webp = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any]
        let raw = (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
            ?? (png?[kCGImagePropertyAPNGDelayTime] as? Double)
            ?? (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
            ?? (webp?[kCGImagePropertyWebPUnclampedDelayTime] as? Double)
            ?? (webp?[kCGImagePropertyWebPDelayTime] as? Double)
        guard let raw, raw > minimumDelay else { return substituteDelay }
        return raw
    }
}
