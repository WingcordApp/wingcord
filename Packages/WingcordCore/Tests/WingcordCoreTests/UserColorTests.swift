import Foundation
import Testing
@testable import WingcordCore

/// Scaling the saturation of colour that came from a person.
@Suite("User colour")
struct UserColorTests {

    private func channels(_ value: UInt32) -> (Int, Int, Int) {
        (Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF))
    }

    @Test("Full saturation is the identity, exactly")
    func fullIsIdentity() {
        // The setting is off by default, so this is the path every colour in the
        // app takes. It must return the input untouched — not merely close,
        // because a round trip through HSL loses a unit on about half of them
        // and every role colour in the window would shift the day this shipped.
        for value: UInt32 in [0xFF_00_FF, 0x5865_F2, 0x00_00_00, 0xFF_FF_FF, 0x23_A5_5A] {
            #expect(UserColor.desaturated(value, by: 1) == value)
        }
    }

    @Test("Zero leaves the grey of that colour's own brightness")
    func zeroIsGreyOfTheSameLightness() {
        // Not black, and not a fixed grey: the point is that a dark role stays
        // dark and a pale one stays pale, so two roles distinguishable by
        // lightness still are.
        let (r, g, b) = channels(UserColor.desaturated(0xFF_00_00, by: 0))
        #expect(r == g && g == b)
        // Pure red is lightness 0.5, so its grey is mid.
        #expect(abs(r - 128) <= 1)

        let dark = channels(UserColor.desaturated(0x40_00_00, by: 0))
        let pale = channels(UserColor.desaturated(0xFF_C0_C0, by: 0))
        #expect(dark.0 < pale.0, "lightness order has to survive")
    }

    @Test("Hue and lightness survive a partial scale")
    func keepsHueAndLightness() {
        let original: UInt32 = 0xE0_40_40
        let muted = UserColor.desaturated(original, by: 0.5)
        let (r, g, b) = channels(muted)
        let (r0, g0, _) = channels(original)
        // Still red-dominant, so the colour is still recognisably itself.
        #expect(r > g && r > b)
        // Closer to grey than it was.
        #expect(r - g < r0 - g0)
    }

    @Test("A colour with no saturation is returned untouched")
    func greyIsUnchanged() {
        // No hue to preserve and nothing to scale, so the round trip would only
        // add rounding error.
        for value: UInt32 in [0x00_00_00, 0x80_80_80, 0xFF_FF_FF] {
            #expect(UserColor.desaturated(value, by: 0.3) == value)
        }
    }

    @Test("A negative factor is clamped rather than inverting the colour")
    func clampsBelowZero() {
        let (r, g, b) = channels(UserColor.desaturated(0x30_A0_60, by: -2))
        #expect(r == g && g == b)
    }
}
