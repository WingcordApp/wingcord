import Foundation
import Testing
@testable import WingcordCore

/// Discord's contrast step (`998304`'s `lZ`), which is what makes a dark pick
/// read on a dark theme — and what this client skipped, drawing every styled
/// name darker than its owner saw it.
@Suite("Display name legibility")
struct DisplayNameLegibilityTests {

    private func luminance(_ packed: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((packed >> shift) & 0xFF) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    @Test("A navy pick is lightened until it reads on the dark ground")
    func navyIsLightened() {
        let navy: UInt32 = 0x1B_2A_8C
        let ground = DisplayNameStyle.darkGround
        #expect(contrast(navy, ground) < 3)
        let moved = DisplayNameStyle.legible(navy, on: ground, ratio: 3)
        #expect(contrast(moved, ground) >= 3)
        #expect(luminance(moved) > luminance(navy))
        // The hue is the pick's own: only the lightness moved.
        #expect(abs(HSL(rgb: moved).hue - HSL(rgb: navy).hue) < 2)
    }

    @Test("A colour that already reads is left exactly as it was sent")
    func brightIsUntouched() {
        let pink: UInt32 = 0xF4_20_98
        #expect(DisplayNameStyle.legible(pink, on: DisplayNameStyle.darkGround, ratio: 3) == pink)
    }

    @Test("On a light ground the same step darkens")
    func paleIsDarkenedOnLight() {
        let pale: UInt32 = 0xEA_A9_D5
        let ground = DisplayNameStyle.lightGround
        let moved = DisplayNameStyle.legible(pale, on: ground, ratio: 3)
        #expect(luminance(moved) < luminance(pale))
        #expect(contrast(moved, ground) >= 3)
    }

    @Test("Ten steps at most, a twentieth of lightness each — never past the cap")
    func stepsAreBounded() {
        // Black on the dark ground cannot be reached in ten steps of five:
        // the loop stops at L 50 rather than running on to white.
        let moved = DisplayNameStyle.legible(0x00_00_00, on: 0x00_00_00, ratio: 21)
        #expect(Int(HSL(rgb: moved).lightness.rounded()) == 50)
    }

    @Test("Ramps ask for two and a half, flat effects for three")
    func ratiosPerEffect() {
        #expect(DisplayNameEffect.gradient.minimumContrast == 2.5)
        #expect(DisplayNameEffect.glow.minimumContrast == 2.5)
        #expect(DisplayNameEffect.prism.minimumContrast == 2.5)
        for effect in [DisplayNameEffect.solid, .neon, .toon, .pop, .gummy] {
            #expect(effect.minimumContrast == 3)
        }
    }

    @Test("Every colour of a style is moved, and Toon is checked against its own stroke")
    func wholeStyle() {
        let style = DisplayNameStyle(font: .journal, effect: .gradient, colors: [0x1B_2A_8C, 0x5B_1F_A8])
        let moved = style.legible(on: DisplayNameStyle.darkGround)
        #expect(moved.font == .journal)
        #expect(moved.effect == .gradient)
        #expect(moved.colors.count == 2)
        for colour in moved.colors {
            #expect(contrast(colour, DisplayNameStyle.darkGround) >= 2.5)
        }

        // Toon's ground is #333 whatever the surface: a pick that reads on it
        // is not darkened for a light card.
        let toon = DisplayNameStyle(font: .default, effect: .toon, colors: [0xF4_20_98])
        #expect(toon.legible(on: DisplayNameStyle.lightGround) == toon)
    }

    @Test("A style with no colours has nothing to move")
    func emptyIsUntouched() {
        let style = DisplayNameStyle(font: .sakura, effect: .solid, colors: [])
        #expect(style.legible(on: DisplayNameStyle.darkGround) == style)
    }

    @Test("The face alone keeps the font and drops the paint")
    func faceOnly() {
        let style = DisplayNameStyle(font: .sakura, effect: .prism, colors: [1, 2, 3, 4, 5])
        #expect(style.faceOnly == DisplayNameStyle(font: .sakura, effect: .solid, colors: []))
        #expect(DisplayNameStyle(font: .default, effect: .neon, colors: [1]).faceOnly.isPlain)
        #expect(style.cycle == 2)
        #expect(DisplayNameStyle(font: .default, effect: .neon, colors: [1]).cycle == 4)
    }

    @Test("Toon's stroke has a floor and Neon's follows the pick up to sixty")
    func derivedShades() {
        // L 10: `0.4 * l` would be 4, and the floor is 12.
        let dark = DisplayNamePalette(main: 0x00_00_33)
        #expect(Int(HSL(rgb: dark.toonStroke).lightness.rounded()) == 12)
        // L 10 again: a tenth lighter, not pinned to sixty.
        #expect(Int(HSL(rgb: dark.neonStroke).lightness.rounded()) == 20)
        // A bright pick is capped.
        let bright = DisplayNamePalette(main: 0x99_65_F3)
        #expect(Int(HSL(rgb: bright.neonStroke).lightness.rounded()) == 60)
    }

    @Test("Online on a phone and nowhere bigger is a phone; a headset wins")
    func presenceClient() {
        #expect(PresenceClient(isOnMobile: false, isOnVR: false) == .desktop)
        #expect(PresenceClient(isOnMobile: true, isOnVR: false) == .mobile)
        #expect(PresenceClient(isOnMobile: true, isOnVR: true) == .vr)
        #expect(Presence(userID: UserID(rawValue: 1), status: .online, isOnVR: true).client == .vr)
    }
}
