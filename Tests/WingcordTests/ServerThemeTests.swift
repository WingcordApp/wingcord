import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Server themes, checked against Discord's own output rather than against a
/// re-reading of its code.
///
/// - **The stops, amounts, base and text colours** are Discord's generator —
///   module `153469`'s `dY`, over module `476931`'s ten presets and its
///   one-colour expansion `kI` — run verbatim in Node on the chroma.js Discord
///   bundles (module `310784`), for every preset in both rooms and five custom
///   colours across the range of `base_mix`.
/// - **The surfaces** are Chrome's own `color-mix(in oklab, <rung> 100%, <base>
///   <amount>)` over Discord's rungs, painted into an sRGB canvas and read
///   back — what Discord's desktop client, being Chromium, puts on screen.
///
/// Running it is what caught the one inversion the reading had made: the
/// generator's first branch is the **dark** room's, so a dark Twilight mixes
/// its base in at 60 % where the port had 30.
@Suite("Server themes")
struct ServerThemeTests {

    nonisolated struct Fixture: Sendable, CustomTestStringConvertible {
        var theme: GuildTheme
        var room: ThemeAppearance
        var stops: [UInt32]
        var veilMix: Double
        var base: Double
        var text: Double
        var baseColor: UInt32
        var textColor: UInt32
        /// Canvas, surface, raised.
        var surfaces: [UInt32]

        init(
            _ theme: GuildTheme, _ room: ThemeAppearance,
            stops: [UInt32], veilMix: Double, base: Double, text: Double,
            baseColor: UInt32, textColor: UInt32, surfaces: [UInt32]
        ) {
            self.theme = theme
            self.room = room
            self.stops = stops
            self.veilMix = veilMix
            self.base = base
            self.text = text
            self.baseColor = baseColor
            self.textColor = textColor
            self.surfaces = surfaces
        }

        var testDescription: String {
            let kind = theme.presetID.map { "Preset \($0)" }
                ?? theme.colors.first.map { "Custom #" + String($0, radix: 16, uppercase: true) }
                ?? "?"
            return "\(kind), \(room == .light ? "light" : "dark")"
        }
    }

    nonisolated static let fixtures: [Fixture] = [
        Fixture(GuildTheme(isEnabled: true, presetID: 1), .dark, stops: [0x69_42_6A, 0x11_17_31], veilMix: 0.30, base: 60, text: 30, baseColor: 0x00_05_1A, textColor: 0xFF_FF_FF,
                surfaces: [0x09_0D_17, 0x0D_12_1D, 0x11_16_21]),
        Fixture(GuildTheme(isEnabled: true, presetID: 2), .dark, stops: [0x8A_3F_7F, 0x2C_0D_25], veilMix: 0.30, base: 60, text: 30, baseColor: 0x1A_00_14, textColor: 0xFF_FF_FF,
                surfaces: [0x16_0B_14, 0x1B_10_1A, 0x1F_13_1E]),
        Fixture(GuildTheme(isEnabled: true, presetID: 3), .dark, stops: [0x9B_2C_2C, 0x2A_0C_0C], veilMix: 0.65, base: 80, text: 30, baseColor: 0x1A_00_00, textColor: 0xF9_EB_EB,
                surfaces: [0x17_09_09, 0x1C_0E_0E, 0x1F_11_11]),
        Fixture(GuildTheme(isEnabled: true, presetID: 4), .dark, stops: [0x6C_52_3D, 0x24_19_12], veilMix: 0.65, base: 80, text: 30, baseColor: 0x1A_0A_00, textColor: 0xF6_F1_EE,
                surfaces: [0x16_0F_0A, 0x1B_13_0F, 0x1E_16_12]),
        Fixture(GuildTheme(isEnabled: true, presetID: 5), .dark, stops: [0x58_69_4E, 0x22_2A_1C], veilMix: 0.65, base: 80, text: 30, baseColor: 0x0B_1A_00, textColor: 0xF2_F5_F0,
                surfaces: [0x0F_16_0C, 0x14_1A_11, 0x17_1E_14]),
        Fixture(GuildTheme(isEnabled: true, presetID: 6), .dark, stops: [0x29_70_71, 0x18_20_3F], veilMix: 0.65, base: 80, text: 30, baseColor: 0x00_05_1A, textColor: 0xED_EF_F8,
                surfaces: [0x07_0D_17, 0x0B_11_1D, 0x0E_14_20]),
        Fixture(GuildTheme(isEnabled: true, presetID: 7), .dark, stops: [0x5E_4C_85, 0x1E_17_40], veilMix: 0.30, base: 60, text: 30, baseColor: 0x04_00_1A, textColor: 0xFF_FF_FF,
                surfaces: [0x0B_0B_17, 0x10_0F_1D, 0x13_13_21]),
        Fixture(GuildTheme(isEnabled: true, presetID: 8), .dark, stops: [0x24_5B_92, 0x14_1D_40], veilMix: 0.30, base: 60, text: 30, baseColor: 0x00_05_1A, textColor: 0xFF_FF_FF,
                surfaces: [0x09_0D_17, 0x0D_12_1D, 0x11_16_21]),
        Fixture(GuildTheme(isEnabled: true, presetID: 9), .dark, stops: [0x53_59_AD, 0x12_12_38], veilMix: 0.30, base: 60, text: 30, baseColor: 0x00_00_1A, textColor: 0xFF_FF_FF,
                surfaces: [0x06_0B_17, 0x0A_10_1E, 0x0E_13_21]),
        Fixture(GuildTheme(isEnabled: true, presetID: 10), .dark, stops: [0x53_3D_9E, 0x1A_10_35], veilMix: 0.30, base: 60, text: 30, baseColor: 0x07_00_1A, textColor: 0xFF_FF_FF,
                surfaces: [0x0D_0A_17, 0x12_0F_1D, 0x15_13_21]),
        Fixture(GuildTheme(isEnabled: true, colors: [0x77_C5_79], angle: 0, baseMix: 0), .dark, stops: [0x2F_6E_30, 0x10_27_11], veilMix: 1.00, base: 100, text: 30, baseColor: 0x00_1A_01, textColor: 0xDB_F0_DC,
                surfaces: [0x0A_16_0B, 0x0E_1B_10, 0x11_1E_13]),
        Fixture(GuildTheme(isEnabled: true, colors: [0xC0_39_2B], angle: 45, baseMix: 74), .dark, stops: [0x6A_1F_18, 0x17_07_05], veilMix: 0.48, base: 70.4, text: 30, baseColor: 0x1A_03_00, textColor: 0xFC_F4_F2,
                surfaces: [0x16_0C_0A, 0x1B_11_0F, 0x1F_14_13]),
        Fixture(GuildTheme(isEnabled: true, colors: [0x10_10_10], angle: 90, baseMix: 50), .dark, stops: [0x26_26_26, 0x00_00_00], veilMix: 0.65, base: 80, text: 30, baseColor: 0x0D_0D_0D, textColor: 0xF2_F2_F2,
                surfaces: [0x10_10_11, 0x14_14_16, 0x17_17_19]),
        Fixture(GuildTheme(isEnabled: true, colors: [0xFF_FF_FF], angle: 0, baseMix: 100), .dark, stops: [0x59_59_59, 0x26_26_26], veilMix: 0.30, base: 60, text: 30, baseColor: 0x0D_0D_0D, textColor: 0xFF_FF_FF,
                surfaces: [0x10_10_11, 0x15_15_17, 0x19_19_1B]),
        Fixture(GuildTheme(isEnabled: true, colors: [0x58_65_F2], angle: 180, baseMix: 30), .dark, stops: [0x0C_17_95, 0x04_08_37], veilMix: 0.79, base: 88, text: 30, baseColor: 0x00_02_1A, textColor: 0xDE_E0_FD,
                surfaces: [0x05_0A_18, 0x09_0E_1D, 0x0B_11_20]),
        Fixture(GuildTheme(isEnabled: true, presetID: 1), .light, stops: [0xFA_9E_FF, 0x5A_7E_FE], veilMix: 0.30, base: 10, text: 40, baseColor: 0xFC_CC_FF, textColor: 0x00_00_00,
                surfaces: [0xF4_F0_F5, 0xFB_F7_FB, 0xFF_FA_FF]),
        Fixture(GuildTheme(isEnabled: true, presetID: 2), .light, stops: [0xE8_93_FF, 0xFF_AD_DC], veilMix: 0.30, base: 10, text: 40, baseColor: 0xFF_CC_E9, textColor: 0x00_00_00,
                surfaces: [0xF4_F0_F3, 0xFC_F7_F9, 0xFF_FA_FD]),
        Fixture(GuildTheme(isEnabled: true, presetID: 3), .light, stops: [0xFF_EB_CA, 0xFF_89_89], veilMix: 0.65, base: 20, text: 40, baseColor: 0xFF_EC_CC, textColor: 0x0F_0A_00,
                surfaces: [0xF5_F2_ED, 0xFC_F9_F3, 0xFF_FC_F7]),
        Fixture(GuildTheme(isEnabled: true, presetID: 4), .light, stops: [0xFF_E7_DA, 0xFF_D8_9B], veilMix: 0.65, base: 20, text: 40, baseColor: 0xFF_DE_CC, textColor: 0x0F_05_00,
                surfaces: [0xF5_F0_ED, 0xFC_F6_F3, 0xFF_FA_F6]),
        Fixture(GuildTheme(isEnabled: true, presetID: 5), .light, stops: [0xB7_D1_9F, 0xB1_DC_A4], veilMix: 0.65, base: 20, text: 40, baseColor: 0xD8_FF_CC, textColor: 0x06_0B_04,
                surfaces: [0xEF_F5_EE, 0xF5_FC_F3, 0xF9_FF_F7]),
        Fixture(GuildTheme(isEnabled: true, presetID: 6), .light, stops: [0xC5_F0_D2, 0x60_AD_B2], veilMix: 0.65, base: 20, text: 40, baseColor: 0xCC_FF_DB, textColor: 0x03_0C_06,
                surfaces: [0xED_F5_F0, 0xF4_FC_F6, 0xF7_FF_F9]),
        Fixture(GuildTheme(isEnabled: true, presetID: 7), .light, stops: [0xB5_9D_F2, 0x8F_89_D2], veilMix: 0.30, base: 10, text: 40, baseColor: 0xDA_CC_FF, textColor: 0x00_00_00,
                surfaces: [0xF1_EF_F5, 0xF8_F7_FC, 0xFC_FA_FF]),
        Fixture(GuildTheme(isEnabled: true, presetID: 8), .light, stops: [0x9A_DB_F7, 0x2D_3C_CA], veilMix: 0.30, base: 10, text: 40, baseColor: 0xCC_F0_FF, textColor: 0x00_00_00,
                surfaces: [0xF0_F3_F5, 0xF7_FA_FB, 0xFA_FE_FF]),
        Fixture(GuildTheme(isEnabled: true, presetID: 9), .light, stops: [0xDB_DB_FF, 0x60_60_FF], veilMix: 0.30, base: 10, text: 40, baseColor: 0xCC_CC_FF, textColor: 0x00_00_00,
                surfaces: [0xEF_EF_F5, 0xF7_F7_FC, 0xFA_FA_FF]),
        Fixture(GuildTheme(isEnabled: true, presetID: 10), .light, stops: [0xC3_BF_FF, 0x81_6B_DC], veilMix: 0.30, base: 10, text: 40, baseColor: 0xCF_CC_FF, textColor: 0x00_00_00,
                surfaces: [0xF0_EF_F5, 0xF7_F7_FC, 0xFB_FA_FF]),
        Fixture(GuildTheme(isEnabled: true, colors: [0x77_C5_79], angle: 0, baseMix: 0), .light, stops: [0x96_D2_98, 0xDD_F1_DE], veilMix: 1.00, base: 30, text: 40, baseColor: 0xCC_FF_CE, textColor: 0x07_12_08,
                surfaces: [0xEA_F6_EB, 0xF1_FC_F1, 0xF4_FF_F4]),
        Fixture(GuildTheme(isEnabled: true, colors: [0xC0_39_2B], angle: 45, baseMix: 74), .light, stops: [0xDF_79_6F, 0xF2_C7_C2], veilMix: 0.48, base: 15.2, text: 40, baseColor: 0xFF_D2_CC, textColor: 0x04_01_01,
                surfaces: [0xF5_EF_EF, 0xFC_F6_F5, 0xFF_F9_F8]),
        Fixture(GuildTheme(isEnabled: true, colors: [0x10_10_10], angle: 90, baseMix: 50), .light, stops: [0x8C_8C_8C, 0xBF_BF_BF], veilMix: 0.65, base: 20, text: 40, baseColor: 0xE6_E6_E6, textColor: 0x08_08_08,
                surfaces: [0xF1_F1_F2, 0xF7_F7_F7, 0xFB_FB_FB]),
        Fixture(GuildTheme(isEnabled: true, colors: [0xFF_FF_FF], angle: 0, baseMix: 100), .light, stops: [0xBF_BF_BF, 0xF2_F2_F2], veilMix: 0.30, base: 10, text: 40, baseColor: 0xE6_E6_E6, textColor: 0x00_00_00,
                surfaces: [0xF2_F2_F3, 0xF9_F9_F9, 0xFD_FD_FD]),
        Fixture(GuildTheme(isEnabled: true, colors: [0x58_65_F2], angle: 180, baseMix: 30), .light, stops: [0x78_83_F5, 0xD7_DA_FC], veilMix: 0.79, base: 24, text: 40, baseColor: 0xCC_D0_FF, textColor: 0x01_03_13,
                surfaces: [0xEB_EC_F6, 0xF2_F3_FC, 0xF5_F6_FF]),    ]

    @Test("The stops are Discord's: its ten presets, and one colour made two", arguments: fixtures)
    func stops(_ fixture: Fixture) throws {
        let theme = try #require(ServerTheme(fixture.theme, room: fixture.room))
        #expect(theme.stops == fixture.stops)
    }

    @Test("The generator's amounts are Discord's", arguments: fixtures)
    func amounts(_ fixture: Fixture) throws {
        let theme = try #require(ServerTheme(fixture.theme, room: fixture.room))
        #expect(theme.veilMix == fixture.veilMix)
        #expect(abs(theme.baseAmount - fixture.base) < 1e-9)
        #expect(theme.textAmount == fixture.text)
    }

    @Test("The base and the text colour are Discord's, byte for byte", arguments: fixtures)
    func tints(_ fixture: Fixture) throws {
        let theme = try #require(ServerTheme(fixture.theme, room: fixture.room))
        #expect(theme.baseColor == fixture.baseColor)
        #expect(theme.textColor == fixture.textColor)
    }

    @Test("Every flat surface is Chrome's own color-mix", arguments: fixtures)
    func surfaces(_ fixture: Fixture) throws {
        let colors = try #require(ServerTheme(fixture.theme, room: fixture.room)).colors
        #expect([colors.canvas, colors.surface, colors.surfaceRaised] == fixture.surfaces)
        #expect(colors.appearance == fixture.room)
        #expect(colors.textTint == fixture.textColor)
        #expect(colors.textTintWeight == fixture.text / (100 + fixture.text))
    }

    @Test("The veils are Discord's custom-client-theme rules, at the rounded mix")
    func veils() throws {
        // Twilight, dark: a mix of 0.30.
        let twilight = try #require(ServerTheme(GuildTheme(isEnabled: true, presetID: 1), room: .dark))
        #expect(abs(twilight.pageVeil - (0.48 + 0.32 * 0.30)) < 1e-12)
        #expect(abs(twilight.frameVeil - (0.45 + 0.30 * 0.30)) < 1e-12)
        // A `base_mix` of 0 stands all the way back: a mix of 1, which is the
        // presets' own 80 % and 75 %.
        let quiet = try #require(ServerTheme(
            GuildTheme(isEnabled: true, colors: [0x77_C5_79]), room: .dark
        ))
        #expect(abs(quiet.pageVeil - 0.80) < 1e-12)
        #expect(abs(quiet.frameVeil - 0.75) < 1e-12)
        // Light: the generator's own 0.95 base under the chat.
        let light = try #require(ServerTheme(GuildTheme(isEnabled: true, presetID: 1), room: .light))
        #expect(abs(light.pageVeil - 0.95 * (0.6 + 0.4 * 0.30)) < 1e-12)
        #expect(abs(light.frameVeil - (0.42 + 0.28 * 0.30)) < 1e-12)
    }

    @Test("Off, or not one Discord can draw, is no theme — and one colour wins over a preset")
    func resolution() {
        #expect(ServerTheme(GuildTheme(isEnabled: false, presetID: 3), room: .dark) == nil)
        #expect(ServerTheme(GuildTheme(isEnabled: true, presetID: 11), room: .dark) == nil)
        #expect(ServerTheme(GuildTheme(isEnabled: true), room: .dark) == nil)
        // Two colours, or explicit stops, is not a custom theme — Discord's
        // own test — so the preset id underneath is what draws.
        let two = GuildTheme(isEnabled: true, presetID: 3, colors: [0xFF_00_00, 0x00_00_FF])
        #expect(ServerTheme(two, room: .dark)?.stops == [0x9B_2C_2C, 0x2A_0C_0C])
        let stopped = GuildTheme(isEnabled: true, colors: [0xFF_00_00], hasGradientStops: true)
        #expect(ServerTheme(stopped, room: .dark) == nil)
        let both = GuildTheme(isEnabled: true, presetID: 3, colors: [0x77_C5_79])
        #expect(ServerTheme(both, room: .dark)?.stops == [0x2F_6E_30, 0x10_27_11])
    }

    @Test("A server's ground wears the reader's room, paints the sidebar, and has no light")
    func ground() throws {
        let theme = try #require(ServerTheme(GuildTheme(isEnabled: true, presetID: 3), room: .light))
        let ground = ThemeGround(server: theme)
        #expect(ground.appearance == .light)
        #expect(ground.paintsFrame)
        #expect(ground.glow == nil)
        #expect(ground.angle == 0)
        #expect(ground.pageVeil == theme.pageVeil)
        #expect(ground.frameVeil == theme.frameVeil)
    }
}
