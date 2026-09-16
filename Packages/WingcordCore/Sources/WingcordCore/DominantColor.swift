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
        split(&boxes, histogram, by: .population, until: populationFraction * Double(count))
        split(&boxes, histogram, by: .volume, until: Double(count - boxes.count))
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
        until target: Double
    ) {
        // **Boxes PRODUCED by this pass, starting at one, not boxes in the
        // queue** — the reference's `o`, and the difference is a whole split.
        // Its first pass runs until `o >= 0.75 * count`, which for five colours
        // is `o >= 3.75` and therefore FOUR boxes; a truncated `Int(3.75)`
        // compared against the queue's size stops at three, and the fourth
        // split then happens in the second pass under the other priority. Five
        // boxes either way, and a different five.
        var colors = 1.0
        var iterations = 0
        while iterations < maxIterations {
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
            if colors >= target { return }
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

// MARK: - The partner colours

/// The colours Discord derives *from* a palette swatch.
///
/// **The other half of the same store, and a port rather than a guess.** Where
/// `MedianCutQuantizer` answers what colour a picture *is*, this answers what
/// Discord puts next to it — webpack module `998304`, export `Q7`, called on the
/// first swatch and appended to the palette:
///
/// ```js
/// let t = await getPalette(url);            // 5 swatches, 128px, quality 10
/// store[url] = [...t.slice(0, 2), ...Q7(t[0])]
/// ```
///
/// The app directory's banner for an app with no artwork then reads
/// `[primary, secondary, partner] = store[url]` and draws
/// `linear-gradient(45deg, primary, partner ?? secondary)`.
///
/// **Three colours, at −90°, −180° and −270°**, all sharing one saturation and
/// lightness with the swatch they came from — `360 / (count + 1)` with the
/// reference's own default of three. The three clamps below are the module's,
/// and they are the reason a dark swatch stays dark where a naive rotation would
/// not: only a colour outside the bands is moved.
///
/// Verified against two of Discord's own rendered gradients, byte for byte:
///
/// ```
/// OwO     rgb(88,183,233)  → rgb(110,233,88)
/// Roll20  rgb(123,25,113)  → rgb(25,64,123)
/// ```
public enum PaletteHarmony {

    /// How many partners the reference asks for. The *first* is what the
    /// gradient uses; the other two exist because the same function feeds
    /// surfaces that want a triad.
    public static let partnerCount = 3

    /// The partners of one swatch, in the reference's order.
    public static func partners(
        of swatch: SIMD3<UInt8>,
        count: Int = partnerCount
    ) -> [SIMD3<UInt8>] {
        guard count > 0 else { return [] }
        var (hue, saturation, lightness) = hsl(of: swatch)
        // **The three clamps are the module's own.** A washed-out swatch is
        // pushed up so the partner is not grey, and one at either end of the
        // lightness range is pulled back so the pair stays distinguishable
        // against the page. Anything already inside the bands is left exactly
        // as it is, which is why a dark swatch keeps its darkness.
        if saturation < 30 { saturation += 30 }
        if lightness > 80 { lightness -= 40 }
        if lightness < 20 { lightness += 15 }

        let step = 360.0 / Double(count + 1)
        var partners: [SIMD3<UInt8>] = []
        partners.reserveCapacity(count)
        while partners.count < count {
            hue -= step
            if hue < 0 { hue += 360 }
            partners.append(rgb(hue: hue, saturation: saturation, lightness: lightness))
        }
        return partners
    }

    /// The reference's `rgbToHsl`: degrees, and percentages rounded to one
    /// decimal. **The rounding is not cosmetic** — the clamps above compare
    /// against it, so a swatch at 29.96% saturation is treated as 30.0 and left
    /// alone where the unrounded value would be pushed.
    static func hsl(of colour: SIMD3<UInt8>) -> (Double, Double, Double) {
        let r = Double(colour.x) / 255, g = Double(colour.y) / 255, b = Double(colour.z) / 255
        let high = max(r, g, b), low = min(r, g, b)
        let delta = high - low
        var hue: Double
        if delta == 0 {
            hue = 0
        } else if high == r {
            hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if high == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue = (60 * hue).rounded()
        if hue < 0 { hue += 360 }
        let lightness = (high + low) / 2
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        return (
            hue,
            (saturation * 1000).rounded() / 10,
            (lightness * 1000).rounded() / 10
        )
    }

    /// The reference's `hslToRgb`, which is the CSS specification's own form
    /// rather than the sector-by-sector one. They agree; this is the one the
    /// rounding was measured through.
    static func rgb(hue: Double, saturation: Double, lightness: Double) -> SIMD3<UInt8> {
        let l = lightness / 100
        let a = saturation * min(l, 1 - l) / 100
        func channel(_ n: Double) -> UInt8 {
            let k = (n + hue / 30).truncatingRemainder(dividingBy: 12)
            let value = l - a * max(min(k - 3, 9 - k, 1), -1)
            return UInt8(max(0, min(255, (255 * value).rounded())))
        }
        return SIMD3(channel(0), channel(8), channel(4))
    }
}
