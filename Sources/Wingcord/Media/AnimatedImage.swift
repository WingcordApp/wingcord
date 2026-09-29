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

    /// The shortest frame, which sets how often a player has to look.
    var shortestFrame: Double {
        var previous = 0.0
        var shortest = duration
        for end in ends {
            shortest = min(shortest, end - previous)
            previous = end
        }
        return max(shortest, 0.001)
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
        for index in 0..<count { delays.append(FilmSource.frameDelay(of: source, at: index)) }

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
        // **Only the bytes bound it — never a frame count.** A cap of
        // forty-eight thinned every long loop whatever its size; a decoration
        // at row size is fifty kilobytes a frame, and its whole loop fits.
        // Past the budget, frames are **sampled down rather than truncated**:
        // a truncated loop stops halfway and jumps, and the kept frames absorb
        // the delay of the ones dropped, so the cycle keeps its length.
        let keep = sampleIndices(count: count, budget: affordable)

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
}
