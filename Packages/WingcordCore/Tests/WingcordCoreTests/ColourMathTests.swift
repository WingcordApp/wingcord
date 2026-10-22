import Foundation
import Testing
@testable import WingcordCore

@Suite("Colour picker arithmetic")
struct ColourMathTests {

    @Test("A colour survives the trip through HSB")
    func roundTrip() {
        for rgb: UInt32 in [0xF0_6E_B3, 0x00_00_00, 0xFF_FF_FF, 0x58_65_F2, 0x2A_AE_A6, 0xFF_00_00, 0x12_34_56] {
            #expect(HSBColour(rgb: rgb).rgb == rgb)
        }
    }

    @Test("A grey keeps the hue the rail had")
    func greyKeepsHue() {
        let teal = HSBColour(hue: 0.5, saturation: 0.8, brightness: 0.8)
        let grey = HSBColour(rgb: 0x80_80_80).keepingHue(of: teal)
        #expect(grey.hue == 0.5)
        #expect(grey.rgb == 0x80_80_80)
        let black = HSBColour(rgb: 0).keepingHue(of: teal)
        #expect(black.hue == 0.5)
        #expect(black.saturation == 0.8)
    }

    @Test("Hex is read the ways people type it")
    func parse() {
        #expect(ColourText.parse("#f06eb3") == 0xF0_6E_B3)
        #expect(ColourText.parse(" F06EB3 ") == 0xF0_6E_B3)
        #expect(ColourText.parse("#F6B") == 0xFF_66_BB)
        #expect(ColourText.parse("zzzzzz") == nil)
        #expect(ColourText.parse("#12345") == nil)
        #expect(ColourText.hex(0xF0_6E_B3) == "#F06EB3")
        #expect(ColourText.hex(0x0A) == "#00000A")
    }

    @Test("Colours are called something")
    func names() {
        #expect(ColourText.name(0xFF_00_00) == "Cherry")
        #expect(ColourText.name(0xF0_6E_B3) == "Bubblegum")
        #expect(ColourText.name(0x00_00_00) == "Ink")
        #expect(ColourText.name(0xFF_FF_FF) == "Snow")
        #expect(ColourText.name(0x0B_1F_4A).hasPrefix("Midnight"))
        #expect(ColourText.name(0xBF_E8_FF).hasPrefix("Pastel"))
    }

    @Test("The rail's detents pull only when close")
    func detents() {
        let near = HueDetent.snap(0.506)
        #expect(near.detent?.name == "Lagoon")
        #expect(near.hue == 0.5)
        let far = HueDetent.snap(0.53)
        #expect(far.detent == nil)
        #expect(far.hue == 0.53)
        // Across the seam, red is close to both ends.
        #expect(HueDetent.snap(0.996).detent?.name == "Cherry")
    }

    @Test("Red is at both ends of the rail, and the thumb stays at its end")
    func railSeam() {
        let right = HueDetent.settle(0.998)
        #expect(right.position == 1)
        #expect(right.hue == 0)
        #expect(right.detent?.name == "Cherry")
        #expect(HueDetent.settle(1.4).position == 1)
        let left = HueDetent.settle(0.003)
        #expect(left.position == 0)
        let lagoon = HueDetent.settle(0.506)
        #expect(lagoon.position == 0.5)
        let free = HueDetent.settle(0.53)
        #expect(free.position == 0.53 && free.detent == nil)
    }

    @Test("Surprise colours stay readable")
    func surprise() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let colour = HSBColour.surprise(using: &generator)
            #expect(colour.brightness >= 0.7)
            #expect((0.5...0.85).contains(colour.saturation))
        }
    }
}
