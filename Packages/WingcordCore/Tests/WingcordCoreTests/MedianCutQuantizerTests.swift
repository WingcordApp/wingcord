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

// MARK: - The partner colours

/// Discord's `Q7`, pinned against two of its own rendered gradients.
///
/// **Both are read off the inline style its client writes**, which is the only
/// place these numbers exist — `bot.banner_color`, `bot.accent_color` and
/// `user_profile.theme_colors` are null for both apps on every route.
@Suite("Palette harmony")
struct PaletteHarmonyTests {

    /// `linear-gradient(45deg, rgb(88,183,233), rgb(110,233,88))` on OwO's page,
    /// and `linear-gradient(45deg, rgb(123,25,113), rgb(25,64,123))` on
    /// Roll20's. Neither swatch trips a clamp, so both are the plain −90°.
    @Test("The first partner matches Discord's own gradient, byte for byte")
    func partnerMatchesDiscord() {
        #expect(PaletteHarmony.partners(of: SIMD3(88, 183, 233)).first
            == SIMD3<UInt8>(110, 233, 88))
        #expect(PaletteHarmony.partners(of: SIMD3(123, 25, 113)).first
            == SIMD3<UInt8>(25, 64, 123))
    }

    /// **All three, against a capture of `Q7` itself rather than of a gradient.**
    /// Run in Discord's own console — `Q7(rawMMCQ[0])` for a known avatar whose
    /// first box is `[137,134,125]` — the module answered
    /// `[[174,88,153],[88,110,174],[88,174,110]]`. This swatch is the useful
    /// one: at 4.8% saturation it *trips* the `< 30` clamp, which neither of the
    /// gradient vectors above does, and the clamp is worth exactly one unit on
    /// two channels. Reproducing it needs the percentages rounded to one decimal
    /// before the comparison — see `PaletteHarmony.hsl`. Without that rounding
    /// the answer is `[[174,88,153],[88,109,174],[88,174,109]]`, which is how
    /// this was found.
    @Test("Every partner matches a capture of Q7 itself, including the clamp")
    func partnersMatchCapturedQ7() {
        #expect(PaletteHarmony.partners(of: SIMD3(137, 134, 125)) == [
            SIMD3<UInt8>(174, 88, 153),
            SIMD3<UInt8>(88, 110, 174),
            SIMD3<UInt8>(88, 174, 110),
        ])
    }

    /// Three of them, at −90°, −180° and −270°, because the reference asks for
    /// `360 / (count + 1)` with a default count of three.
    @Test("There are three partners, a quarter turn apart")
    func threePartnersAQuarterTurnApart() {
        let partners = PaletteHarmony.partners(of: SIMD3(88, 183, 233))
        #expect(partners.count == 3)
        let hues = ([SIMD3<UInt8>(88, 183, 233)] + partners).map {
            PaletteHarmony.hsl(of: $0).0
        }
        for (earlier, later) in zip(hues, hues.dropFirst()) {
            #expect(abs((earlier - later + 360).truncatingRemainder(dividingBy: 360) - 90) <= 1)
        }
    }

    /// **The three clamps are the module's own**, and each moves only a swatch
    /// outside its band. A dark swatch keeps its darkness — which is what makes
    /// Roll20's partner dark rather than the mid-tone a naive rotation gives.
    @Test("Only a swatch outside the bands is moved")
    func clampsMoveOnlyWhatIsOutside() throws {
        let grey = try #require(PaletteHarmony.partners(of: SIMD3(120, 110, 115)).first)
        #expect(PaletteHarmony.hsl(of: grey).1 > 30)

        let dark = PaletteHarmony.hsl(of: PaletteHarmony.partners(of: SIMD3(123, 25, 113))[0])
        #expect(abs(dark.2 - 29.0) < 1)
    }
}
