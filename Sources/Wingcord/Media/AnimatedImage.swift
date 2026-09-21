import CoreGraphics
import Foundation
import ImageIO

/// A decoded, immutable filmstrip: every frame already at the size it will be
/// drawn, plus the timeline needed to pick one.
///
/// **Decoded once, held whole, drawn by lookup.** The alternative — keeping the
/// `CGImageSource` and decoding the current frame on demand — costs a decode per
/// frame per view forever, which is 0.65 ms of main thread each time on a
/// measured APNG. This pays that cost once, off the main thread, and every draw
/// afterwards is an array index.
///
/// The trade is memory, and it is a real one: **33 KB per frame at 92 px**,
/// measured. A sixty-frame decoration is ~2 MB, so the frame budget below and
/// `AnimatedImageStore`'s byte ceiling are not tidiness — they are what stops a
/// roster of decorated members costing eighty megabytes of resident pixels.
nonisolated struct AnimatedImage: Sendable {
    /// Frames in order, already downsampled.
    let frames: [CGImage]
    /// The time each frame *ends*, cumulative. Lookup is a binary search over
    /// this rather than a scan, so a hundred-frame asset costs seven comparisons
    /// instead of a hundred.
    let ends: [Double]
    /// One full cycle.
    let duration: Double
    /// Resident bytes, so the cache's ceiling means something.
    let cost: Int

    var frameCount: Int { frames.count }

    /// The frame showing at `time` seconds into an endlessly looping playback.
    func frame(at time: Double) -> CGImage { frames[index(at: time)] }

    /// The frame showing at `time`, for an asset that plays **once**.
    ///
    /// **Past the end it holds the last frame rather than wrapping**, which is
    /// what APNG's `acTL num_plays: 1` means and what an `<img>` does with one.
    ///
    /// The distinction exists because a caller's idea of how long a thing lasts
    /// and the asset's own are not the same number. A profile effect's
    /// catalogue entry gives SpongeBob a 6000 ms slot; the APNG is 4125 ms. Fed
    /// through the looping lookup, the last 1875 ms of that slot replayed the
    /// first 1875 ms of the animation — he walked on, flew away, and walked on
    /// again before being cut off mid-stride.
    func frame(at time: Double, looping: Bool) -> CGImage {
        guard !looping else { return frame(at: time) }
        guard frames.count > 1 else { return frames[0] }
        guard time < duration else { return frames[frames.count - 1] }
        return frames[index(at: max(0, time))]
    }

    /// Which frame `time` lands on.
    ///
    /// Separate from `frame(at:)` because the draw path compares indices to
    /// decide whether anything changed — at 24 fps over a 12 fps asset, half the
    /// ticks resolve to the frame already on screen, and comparing images
    /// instead would mean handing the compositor an identical bitmap.
    func index(at time: Double) -> Int {
        guard frames.count > 1, duration > 0 else { return 0 }
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

    // MARK: Decoding

    /// The most frames one asset may hold.
    ///
    /// Assets longer than this are **sampled down rather than truncated**: a
    /// truncated loop stops halfway and jumps, which is worse than a slightly
    /// coarser one. The kept frames absorb the delay of the ones dropped, so the
    /// cycle still takes exactly as long as it should and stays in step with
    /// itself.
    static let frameBudget = 48

    /// The most bytes one filmstrip may occupy.
    ///
    /// **A frame cap alone is not a memory bound, because frames are not one
    /// size.** At 92 px a decoration frame is 33 KB, so forty-eight of them is
    /// 1.6 MB — comfortable. A profile banner at 640x216 is 553 KB *per frame*,
    /// and the same forty-eight would be 26 MB for one picture, more than the
    /// whole cache is allowed to hold. So the real ceiling is bytes, and the
    /// frame count is whatever fits underneath it.
    ///
    /// The cost of that on a large asset is a coarser loop, and it is a
    /// deliberate trade: a banner that drifts at eleven frames is worth far more
    /// than one that evicts every avatar on screen to play smoothly.
    static let byteBudget = 6 * 1024 * 1024

    /// What a full loop costs at a given drawn size, so a caller can ask for
    /// one instead of guessing at megabytes.
    ///
    /// **The budget is a FRAME COUNT wearing a memory unit** — §"A per-asset
    /// byte budget is a FRAME COUNT, and the caller owns it" — and a number
    /// picked by hand is right for one asset at one size. A profile banner
    /// drawn 360 points wide decodes around 576 KB a frame, so the 12 MB it
    /// used to ask for bought twenty of a sixty-frame loop: every third frame,
    /// which is what "the banner renders at very low fps" is. This is the
    /// arithmetic that was being done in a comment.
    ///
    /// Never below the default, so a small asset does not end up with a
    /// *smaller* allowance than it has always had.
    static func budget(forDrawn size: CGSize, scale: CGFloat = 2) -> Int {
        let pixels = max(1, size.width * scale) * max(1, size.height * scale)
        return max(byteBudget, Int(pixels * 4) * frameBudget)
    }

    /// A delay below this is what an authoring tool writes when it means "as
    /// fast as possible", and every renderer substitutes a real interval rather
    /// than spinning. This is the same substitution browsers make.
    private static let minimumDelay: Double = 0.011
    private static let substituteDelay: Double = 0.1

    /// Decodes an animated asset, or returns nil when it is not one.
    ///
    /// Nil for a single-frame image is deliberate and load-bearing: the caller
    /// then uses the ordinary static path, so a still avatar never pays for a
    /// filmstrip, a clock subscription or a layer of its own.
    static func decode(
        _ data: Data,
        maximumPixelSize: Int,
        byteBudget: Int = AnimatedImage.byteBudget
    ) -> AnimatedImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }

        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }

        var delays: [Double] = []
        delays.reserveCapacity(count)
        for index in 0..<count { delays.append(delay(of: source, at: index)) }

        // How many frames the budget actually affords at this size. One frame
        // is decoded first to find out — guessing from the source's dimensions
        // would ignore the downsample that is the whole point of the exercise.
        let probeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        guard let probe = CGImageSourceCreateThumbnailAtIndex(
            source, 0, probeOptions as CFDictionary
        ) else { return nil }
        let bytesPerFrame = max(1, probe.height * probe.bytesPerRow)
        let affordable = max(2, byteBudget / bytesPerFrame)

        // Which frames to keep. Evenly spaced, always including the first.
        let keep = sampleIndices(count: count, budget: min(frameBudget, affordable))

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            // Forces the decode HERE, off the main thread, rather than deferring
            // it to the first draw — which for an animation would land inside a
            // display pass, once per frame.
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]

        var frames: [CGImage] = []
        var ends: [Double] = []
        var bytes = 0
        var clock: Double = 0
        frames.reserveCapacity(keep.count)
        ends.reserveCapacity(keep.count)

        for (position, index) in keep.enumerated() {
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source, index, options as CFDictionary
            ) else { continue }
            // This frame stands in for itself and every frame dropped after it,
            // so it inherits their time.
            let upTo = position + 1 < keep.count ? keep[position + 1] : count
            var span: Double = 0
            for dropped in index..<upTo { span += delays[dropped] }
            clock += span
            frames.append(image)
            ends.append(clock)
            bytes += image.height * image.bytesPerRow
        }

        guard frames.count > 1, clock > 0 else { return nil }
        return AnimatedImage(frames: frames, ends: ends, duration: clock, cost: bytes)
    }

    /// Evenly spaced indices, first frame always included.
    static func sampleIndices(count: Int, budget: Int) -> [Int] {
        guard count > budget, budget > 0 else { return Array(0..<count) }
        var result: [Int] = []
        result.reserveCapacity(budget)
        for step in 0..<budget {
            let index = (step * count) / budget
            // `(step * count) / budget` is monotonic but can repeat at small
            // budgets; a repeat would give a frame zero duration.
            if result.last != index { result.append(index) }
        }
        return result
    }

    /// One frame's delay, from whichever container dictionary applies.
    ///
    /// APNG, GIF and animated WebP each report this under their own key, and
    /// each has a clamped and an unclamped form. The unclamped one is the
    /// author's actual number; the clamped one has already had a floor applied
    /// by the framework, so preferring it would quietly slow every fast asset.
    private static func delay(of source: CGImageSource, at index: Int) -> Double {
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
