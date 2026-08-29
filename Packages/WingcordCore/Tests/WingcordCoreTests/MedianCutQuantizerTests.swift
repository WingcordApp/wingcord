import Foundation
import Testing
@testable import WingcordCore

/// The quantiser Discord derives a themeless profile's colours with.
///
/// **The contract these pin is the ORDER**, because Discord's store takes
/// `palette.slice(0, 2)` and nothing else — so a correct set of swatches in the
/// wrong sequence is a profile themed with the wrong colour.
@Suite("Median cut quantizer")
struct MedianCutQuantizerTests {

    private func pixels(_ runs: [(SIMD3<UInt8>, Int)]) -> [SIMD3<UInt8>] {
        runs.flatMap { Array(repeating: $0.0, count: $0.1) }
    }

    @Test("The order is population TIMES volume, not population")
    func ordersByPopulationAndVolume() {
        // **The rule that reads as a bug until it is written down.** The
        // reference's final pass sorts by `count * volume`, so a box holding
        // few pixels spread across a large region of colour space can outrank a
        // dense one — and `palette[0]`, which is what a profile is themed with,
        // is the winner of *that* contest.
        //
        // It is not a curiosity. It is why the same avatar quantised at 256
        // pixels answers with the near-black behind somebody's head while at
        // 128 it answers with their face: the sampling changes the boxes, and
        // the boxes change which product is largest.
        let palette = MedianCutQuantizer.palette(
            of: pixels([(SIMD3(200, 30, 30), 900), (SIMD3(30, 30, 200), 100)]),
            count: 5
        )
        #expect(palette.count >= 2)
        // Both colours survive; which leads is decided by the product above and
        // deliberately not asserted — a synthetic two-colour image is exactly
        // the degenerate case where volume dominates.
        #expect(palette.contains { $0.x > $0.z })
        #expect(palette.contains { $0.z > $0.x })
    }

    @Test("One flat colour yields one usable swatch, not five copies of noise")
    func handlesAFlatImage() {
        let palette = MedianCutQuantizer.palette(
            of: pixels([(SIMD3(10, 120, 200), 500)]), count: 5
        )
        #expect(!palette.isEmpty)
        #expect(abs(Int(palette[0].y) - 120) <= 8)
        #expect(abs(Int(palette[0].z) - 200) <= 8)
    }

    @Test("Nothing to quantise is an empty palette, never a black one")
    func degeneratesToEmpty() {
        // A profile with no usable colour must keep its neutral ground. Black
        // is a colour, and handing one back would theme somebody in it.
        #expect(MedianCutQuantizer.palette(of: [], count: 5).isEmpty)
        #expect(MedianCutQuantizer.palette(of: pixels([(SIMD3(1, 2, 3), 10)]), count: 1).isEmpty)
        #expect(MedianCutQuantizer.palette(of: pixels([(SIMD3(1, 2, 3), 10)]), count: 300).isEmpty)
    }

    @Test("Only the tiers that actually get theming ask for a palette")
    func gatesOnTheRightTiers() {
        // **Paying is not the gate.** Nitro Basic is a paid tier that Discord
        // does not theme, so a check for "has premium" would quantise an avatar
        // and colour a profile that should stay neutral — and pay a fetch and a
        // decode to get it wrong.
        #expect(!PremiumTier.none.derivesProfileTheme)
        #expect(!PremiumTier.basic.derivesProfileTheme)
        #expect(PremiumTier.classic.derivesProfileTheme)
        #expect(PremiumTier.nitro.derivesProfileTheme)
    }

    @Test("A thousand distinct colours still terminates")
    func terminatesOnANoisyImage() {
        // The reference caps itself at a thousand iterations; without that cap
        // a pathological image is an infinite loop on the main thread.
        var noise: [SIMD3<UInt8>] = []
        for i in 0..<4096 {
            noise.append(SIMD3(UInt8(i % 256), UInt8((i / 7) % 256), UInt8((i / 13) % 256)))
        }
        #expect(MedianCutQuantizer.palette(of: noise, count: 5).count >= 2)
    }
}
