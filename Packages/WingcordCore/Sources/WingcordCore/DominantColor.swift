import Foundation

/// Modified median-cut quantisation, as Discord ships it.
///
/// **A port, not an approximation.** Discord derives a profile's colours from
/// the person's artwork when they have set no `theme_colors`, and it does so
/// with the `quantize` module (webpack `531325`) driven by
/// `getPalette(image, 5, 10)`. The constants below are that module's: five
/// significant bits per channel, a 32768-entry histogram, 1000 iterations, and
/// a first pass that splits by population until 0.75 of the requested colour
/// count is reached before a second that splits by population x volume.
///
/// **Every one of those details is load-bearing, and so are the two outside
/// this type.** Verified against three live profiles by measuring the colour
/// Discord actually renders: the avatar has to be the **WebP** rendition, at
/// **128** pixels, sampled at **quality 10**. Get any one of them wrong and the
/// answer is not merely off — a different swatch wins. On one test profile the
/// 256-pixel PNG answers with the near-black behind his head, 157 units from
/// what Discord shows, while the 128-pixel WebP answers within 4.
///
/// Pure and `nonisolated`: pixels in, palette out, no image decoding, so the
/// decode can happen wherever the caller likes and this can be tested without
/// one.
///
/// **Every box carries its own population, and that is the difference between
/// milliseconds and a visible stall.** A box's count is a scan of its slice of
/// the histogram — up to 32768 buckets for the root — and the queue is re-sorted
/// on every split, so computing it inside the comparator is thousands of full
/// scans for an answer that cannot change. It is computed exactly once per box:
/// once for the root, and thereafter straight out of the median cut's own
/// partial sums, which already hold both halves. The reference memoises the
/// same value for the same reason.
public enum MedianCutQuantizer {
    /// Bits kept per channel. Five gives the 32768-bucket histogram.
    static let significantBits = 5
    private static let shift = 8 - significantBits
    private static let maxIterations = 1000
    private static let populationFraction = 0.75

    @inline(__always)
    static func index(_ r: Int, _ g: Int, _ b: Int) -> Int { (r << 10) + (g << 5) + b }

    /// The palette, most significant swatch first.
    ///
    /// Discord takes the first two of these as a profile's primary and
    /// secondary — `[...palette.slice(0, 2), ...]` in its own store — so the
    /// ORDER is the answer, not a detail of the return type.
    public static func palette(of pixels: [SIMD3<UInt8>], count: Int) -> [SIMD3<UInt8>] {
        guard !pixels.isEmpty, count >= 2, count <= 256 else { return [] }

        var histogram = [Int](repeating: 0, count: 1 << (significantBits * 3))
        var lower = SIMD3(Int.max, Int.max, Int.max)
        var upper = SIMD3(Int.min, Int.min, Int.min)
        for pixel in pixels {
            let cell = SIMD3(Int(pixel.x) >> shift, Int(pixel.y) >> shift, Int(pixel.z) >> shift)
            histogram[index(cell.x, cell.y, cell.z)] += 1
            lower.replace(with: cell, where: cell .< lower)
            upper.replace(with: cell, where: cell .> upper)
        }
        guard all(lower .<= upper) else { return [] }

        let root = Box(lower: lower, upper: upper, count: pixels.count)
        var boxes = [root]
        split(&boxes, histogram, by: .population, until: Int(populationFraction * Double(count)))
        split(&boxes, histogram, by: .volume, until: count)
        boxes.sort { $0.count * $0.volume < $1.count * $1.volume }
        return boxes.reversed().map { $0.average(histogram) }
    }

    private enum Priority { case population, volume }

    /// One box of colour space, and the whole of the algorithm's state.
    ///
    /// A struct rather than a class: boxes are copied when they split and the
    /// queue is re-sorted constantly, so reference semantics would buy nothing
    /// and cost an allocation per split.
    private struct Box {
        var lower: SIMD3<Int>
        var upper: SIMD3<Int>
        /// How many sampled pixels fall inside. **Carried, never recomputed** —
        /// see the note on the type.
        var count: Int

        var volume: Int {
            let extent = upper &- lower &+ 1
            return extent.x * extent.y * extent.z
        }

        func priority(_ kind: Priority) -> Int {
            kind == .population ? count : count * volume
        }

        /// The swatch this box resolves to: its population-weighted centre, or
        /// its geometric centre when it holds nothing.
        func average(_ histogram: [Int]) -> SIMD3<UInt8> {
            let mult = Double(1 << MedianCutQuantizer.shift)
            var total = 0.0
            var sum = SIMD3<Double>()
            for r in lower.x...upper.x {
                for g in lower.y...upper.y {
                    for b in lower.z...upper.z {
                        let weight = Double(histogram[MedianCutQuantizer.index(r, g, b)])
                        guard weight > 0 else { continue }
                        total += weight
                        sum += weight * (SIMD3(Double(r), Double(g), Double(b)) + 0.5) * mult
                    }
                }
            }
            let value = total > 0
                ? sum / total
                : (SIMD3<Double>(lower &+ upper &+ 1) * mult) / 2
            // Truncated, not rounded: the reference does `~~x`, and rounding
            // instead moves roughly half the swatches by a unit.
            return SIMD3(
                UInt8(clamping: Int(value.x)),
                UInt8(clamping: Int(value.y)),
                UInt8(clamping: Int(value.z))
            )
        }
    }

    private static func split(
        _ boxes: inout [Box],
        _ histogram: [Int],
        by kind: Priority,
        until target: Int
    ) {
        var colors = boxes.count
        var iterations = 0
        while iterations < maxIterations, colors < target {
            boxes.sort { $0.priority(kind) < $1.priority(kind) }
            let box = boxes.removeLast()
            guard box.count > 0 else {
                boxes.insert(box, at: 0)
                iterations += 1
                continue
            }
            guard let cut = medianCut(box, histogram) else {
                boxes.append(box)
                return
            }
            boxes.append(cut.0)
            if let second = cut.1 {
                boxes.append(second)
                colors += 1
            }
            iterations += 1
        }
    }

    /// Splits `box` along its longest axis at the population median.
    ///
    /// Returns both halves **with their populations already known**: the
    /// running sums built here are exactly what a count would have to rescan
    /// for, so handing them back costs nothing and saves two full scans per
    /// split.
    private static func medianCut(_ box: Box, _ histogram: [Int]) -> (Box, Box?)? {
        let extent = box.upper &- box.lower &+ 1
        let longest = max(extent.x, max(extent.y, extent.z))
        let axis = longest == extent.x ? 0 : (longest == extent.y ? 1 : 2)
        let low = box.lower[axis], high = box.upper[axis]
        guard low < high else { return nil }

        var running = 0
        var partial = [Int](repeating: 0, count: high + 2)
        for slice in low...high {
            var sum = 0
            switch axis {
            case 0:
                for g in box.lower.y...box.upper.y {
                    for b in box.lower.z...box.upper.z { sum += histogram[index(slice, g, b)] }
                }
            case 1:
                for r in box.lower.x...box.upper.x {
                    for b in box.lower.z...box.upper.z { sum += histogram[index(r, slice, b)] }
                }
            default:
                for r in box.lower.x...box.upper.x {
                    for g in box.lower.y...box.upper.y { sum += histogram[index(r, g, slice)] }
                }
            }
            running += sum
            partial[slice] = running
        }
        let total = running
        guard total > 0 else { return nil }

        for slice in low...high where partial[slice] > total / 2 {
            let leftWidth = slice - low, rightWidth = high - slice
            // The reference's own asymmetry: it cuts toward the wider half.
            var cut = leftWidth <= rightWidth
                ? min(high - 1, slice + rightWidth / 2)
                : max(low, slice - 1 - leftWidth / 2)
            while cut < high, partial[cut] == 0 { cut += 1 }
            var remainder = total - partial[cut]
            while remainder == 0, cut > low, partial[cut - 1] != 0 {
                cut -= 1
                remainder = total - partial[cut]
            }
            var lowerBox = box, upperBox = box
            lowerBox.upper[axis] = cut
            lowerBox.count = partial[cut]
            upperBox.lower[axis] = cut + 1
            upperBox.count = remainder
            let upperIsReal = upperBox.lower[axis] <= upperBox.upper[axis]
            return (lowerBox, upperIsReal ? upperBox : nil)
        }
        return nil
    }
}
