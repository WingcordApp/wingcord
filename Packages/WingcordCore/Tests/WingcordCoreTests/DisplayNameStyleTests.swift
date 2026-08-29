import Foundation
import Testing
@testable import WingcordCore

/// The display name style contract.
///
/// **The palette tests are the load-bearing ones**, and they are written against
/// colours captured out of a live client rather than against the formula that
/// produced them — a test that re-derives `l * 1.2` and then asserts `l * 1.2`
/// passes on any multiplier at all. Two of the four palettes exist specifically
/// because a single one let a wrong rule look right: `#F42098` sits at L 54,
/// where `× 1.6` and `× 0.4` are indistinguishable from ±32.5, and `#9965f3`
/// sits at L 67, where a flat 60 is indistinguishable from `× 0.89`.
@Suite("Display name styles")
struct DisplayNameStyleTests {

    /// Captured shades agree to the byte except in `neonStroke`, where the
    /// saturation multiply compounds an 8-bit round trip. Nineteen of the
    /// twenty-two below are exact; three are one step out in one channel.
    private func expectColor(
        _ got: UInt32,
        _ want: UInt32,
        _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let delta = (0..<3).map { shift -> Int in
            let s = UInt32(shift * 8)
            return abs(Int((got >> s) & 0xFF) - Int((want >> s) & 0xFF))
        }.max() ?? 0
        #expect(
            delta <= 1,
            "\(label): got #\(String(got, radix: 16)), want #\(String(want, radix: 16))",
            sourceLocation: sourceLocation
        )
    }

    // MARK: Palette

    @Test("Toon's pink palette, captured from a computed style")
    func pinkPalette() {
        let p = DisplayNamePalette(main: 0xF4_20_98)
        expectColor(p.light1, 0xF7_55_B0, "light1")
        expectColor(p.light2, 0xFC_BE_E1, "light2")
        expectColor(p.toonStroke, 0x69_05_3E, "toonStroke")
    }

    @Test("Neon's purple palette, where light2 clamps to white")
    func purplePalette() {
        let p = DisplayNamePalette(main: 0x99_65_F3)
        expectColor(p.light1, 0xC3_A5_F8, "light1")
        expectColor(p.light2, 0xFF_FF_FF, "light2")
        expectColor(p.dark2, 0x1B_05_40, "dark2")
        expectColor(p.neonStroke, 0x7E_33_FF, "neonStroke")
    }

    @Test("A second purple at a different lightness")
    func deepPurplePalette() {
        let p = DisplayNamePalette(main: 0x69_1D_ED)
        expectColor(p.light1, 0x8A_4E_F1, "light1")
        expectColor(p.light2, 0xCB_B1_F9, "light2")
        expectColor(p.dark2, 0x14_04_31, "dark2")
        expectColor(p.neonStroke, 0x7D_33_FF, "neonStroke")
    }

    /// The one that separates a flat saturation from a multiplied one: at S 50
    /// a flat `100` and `s * 1.2` are 40 points apart, where any vivid pick
    /// clamps both to the same answer.
    @Test("A muted blue, which is what pinned neonStroke's saturation")
    func mutedBluePalette() {
        let p = DisplayNamePalette(main: 0x66_99_CC)
        expectColor(p.light1, 0x94_B8_DB, "light1")
        expectColor(p.light2, 0xF0_F5_FA, "light2")
        expectColor(p.dark2, 0x0F_1F_2E, "dark2")
        expectColor(p.neonStroke, 0x5C_99_D6, "neonStroke")
    }

    /// `light2` is `l * 1.6` and a bright pick overruns 100. Clamping is what
    /// makes Toon's three `light2` stops merge with its white ones on a pale
    /// colour, which is the effect changing character rather than a bug.
    @Test("light2 clamps at white rather than wrapping")
    func lightnessClamps() {
        let p = DisplayNamePalette(main: 0xE0_D0_FF)
        #expect(p.light2 == 0xFF_FF_FF)
    }

    /// `min(1, s)` in the flicker keyframe is a guard, not arithmetic: a fully
    /// grey pick must flicker grey rather than flashing coloured.
    @Test("A grey main keeps a grey flicker")
    func greyStaysGrey() {
        let p = DisplayNamePalette(main: 0x80_80_80)
        let r = (p.flickerOff >> 16) & 0xFF
        let g = (p.flickerOff >> 8) & 0xFF
        let b = p.flickerOff & 0xFF
        #expect(r == g && g == b)
    }

    @Test("Hue and saturation survive every derivation")
    func hueAndSaturationHold() {
        let main: UInt32 = 0x2E_8B_57
        let base = HSL(rgb: main)
        let p = DisplayNamePalette(main: main)
        for (label, value) in [
            ("light1", p.light1), ("dark2", p.dark2), ("toonStroke", p.toonStroke),
        ] {
            let derived = HSL(rgb: value)
            #expect(abs(derived.hue - base.hue) < 1.5, "\(label) hue drifted")
            #expect(abs(derived.saturation - base.saturation) < 1.5, "\(label) saturation drifted")
        }
    }

    // MARK: Ids

    /// Four ids are unassigned in Discord's own build. A lookup that indexes an
    /// array draws the wrong face the day one is filled in.
    @Test("The font id range has holes and they stay unresolved")
    func fontIdHoles() {
        for hole in [2, 5, 9, 11] {
            #expect(DisplayNameFont(rawValue: hole) == nil, "id \(hole) should be unassigned")
        }
        #expect(DisplayNameFont(rawValue: 6) == .modern)
        #expect(DisplayNameFont(rawValue: 8) == .eightBit)
        #expect(DisplayNameFont(rawValue: 10) == .vampyre)
        #expect(DisplayNameFont(rawValue: 12) == .tempo)
    }

    @Test("Only the default face ships no file")
    func everyStyledFaceHasAFile() {
        for font in DisplayNameFont.allCases where font != .default {
            #expect(font.postScriptName != nil, "\(font) has no PostScript name")
            #expect(font.fileName != nil, "\(font) has no file")
        }
        #expect(DisplayNameFont.default.postScriptName == nil)
        #expect(DisplayNameFont.default.fileName == nil)
    }

    /// Medieval is the one face whose file name and PostScript name differ, and
    /// collapsing the two is how it silently fails to resolve.
    @Test("Medieval's file and PostScript names are not the same string")
    func medievalNamesDiffer() {
        #expect(DisplayNameFont.medieval.fileName == "Neo-castel")
        #expect(DisplayNameFont.medieval.postScriptName == "Neo-castel-:-")
    }

    @Test("Effect colour counts match the wells each picker draws")
    func effectArity() {
        #expect(DisplayNameEffect.solid.colorCount == 1)
        #expect(DisplayNameEffect.gradient.colorCount == 2)
        #expect(DisplayNameEffect.neon.colorCount == 1)
        #expect(DisplayNameEffect.toon.colorCount == 1)
        #expect(DisplayNameEffect.pop.colorCount == 1)
        #expect(DisplayNameEffect.gummy.colorCount == 4)
        #expect(DisplayNameEffect.prism.colorCount == 5)
    }

    @Test("Solid and Gradient are the two that never move")
    func staticEffects() {
        #expect(!DisplayNameEffect.solid.isAnimated)
        #expect(!DisplayNameEffect.gradient.isAnimated)
        for effect in [DisplayNameEffect.neon, .toon, .pop, .gummy, .prism] {
            #expect(effect.isAnimated, "\(effect) should animate")
        }
    }

    // MARK: The empty-colours state

    /// Discord's own save path writes `[]` for Solid at the default colour. It
    /// means "styled font, default colour" and a renderer that demands
    /// `colors[0]` draws nothing at all for those accounts.
    @Test("Solid with no colours is a real style, not a broken one")
    func emptyColoursAreValid() {
        let style = DisplayNameStyle(font: .journal, effect: .solid, colors: [])
        #expect(style.palette == nil)
        #expect(!style.isPlain)
    }

    @Test("The default face with nothing chosen is indistinguishable from no style")
    func plainStyle() {
        #expect(DisplayNameStyle(font: .default, effect: .solid, colors: []).isPlain)
        #expect(!DisplayNameStyle(font: .default, effect: .neon, colors: []).isPlain)
        #expect(!DisplayNameStyle(font: .tempo, effect: .solid, colors: []).isPlain)
        #expect(!DisplayNameStyle(font: .default, effect: .solid, colors: [0xFF_00_00]).isPlain)
    }
}
