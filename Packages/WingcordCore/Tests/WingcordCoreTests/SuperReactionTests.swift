import Foundation
import Testing
@testable import WingcordCore

/// Super reactions: the tally, the chip's colours and the effect's choice.
///
/// **Every colour and every hash below was produced by Discord's own code**,
/// run verbatim in Node — modules `478840`, `998304` and `297494` of the web
/// bundle, over the chroma.js it ships (`310784`). So a failure here is the
/// port disagreeing with Discord, never the port disagreeing with a second
/// port of itself.
@Suite("Super reactions")
struct SuperReactionTests {

    // MARK: The tally

    private let fire = EmojiRef(name: "🔥")
    private let shaq = EmojiRef(id: EmojiID(rawValue: 1_122_960_370_512_957_560), name: "x_shaq")

    @Test("A super reaction starts its own half of the entry, with its colours")
    func burstStartsItsHalf() throws {
        let added = try #require(ReactionTally.adding(
            shaq, kind: .burst, isMine: false, colors: [0x40_1B_17, 0x30_11_11, 0, 0x10_10_10], to: []
        ))
        #expect(added == [Reaction(
            emoji: shaq, count: 0, isMine: false,
            burstCount: 1, isMineBurst: false, burstColors: [0x40_1B_17, 0x30_11_11, 0]
        )])
    }

    @Test("The two halves of one emoji are ONE entry")
    func halvesShareAnEntry() throws {
        let plain = try #require(ReactionTally.adding(fire, kind: .normal, isMine: false, to: []))
        let both = try #require(ReactionTally.adding(
            fire, kind: .burst, isMine: true, colors: [0xFF_00_00], to: plain
        ))
        #expect(both.count == 1)
        #expect(both[0].count == 1 && both[0].burstCount == 1)
        #expect(both[0].isMine == false && both[0].isMineBurst)
    }

    @Test("The reader's own echo changes nothing, and says so")
    func ownEchoIsANoOp() throws {
        let mine = try #require(ReactionTally.adding(
            shaq, kind: .burst, isMine: true, colors: [0x11_22_33], to: []
        ))
        // The gateway echoes the reader's reaction back with the SERVER's
        // palette. Discord keeps the first palette an emoji arrived with, and a
        // nil answer is what lets the store skip the write entirely.
        #expect(ReactionTally.adding(
            shaq, kind: .burst, isMine: true, colors: [0x99_99_99], to: mine
        ) == nil)
    }

    @Test("A palette already held is kept; an empty one is filled")
    func paletteIsFirstComeFirstKept() throws {
        let first = try #require(ReactionTally.adding(
            shaq, kind: .burst, isMine: false, colors: [0x11_22_33], to: []
        ))
        let second = try #require(ReactionTally.adding(
            shaq, kind: .burst, isMine: false, colors: [0x99_99_99], to: first
        ))
        #expect(second[0].burstColors == [0x11_22_33])
        #expect(second[0].burstCount == 2)
    }

    @Test("A custom emoji is matched by id, whatever its name or animation says")
    func matchedById() throws {
        let plain = try #require(ReactionTally.adding(shaq, kind: .normal, isMine: false, to: []))
        let renamed = EmojiRef(id: shaq.id, name: "shaq_renamed", isAnimated: true)
        let added = try #require(ReactionTally.adding(renamed, kind: .normal, isMine: false, to: plain))
        #expect(added.count == 1)
        #expect(added[0].count == 2)
    }

    @Test("In a one-to-one conversation, a second 'somebody else' is a duplicate")
    func directMessageDedupe() throws {
        let theirs = try #require(ReactionTally.adding(
            fire, kind: .normal, isMine: false, isDirectMessage: true, to: []
        ))
        #expect(ReactionTally.adding(
            fire, kind: .normal, isMine: false, isDirectMessage: true, to: theirs
        ) == nil)
        // The reader's own still counts, and the other half is untouched by the
        // rule.
        #expect(ReactionTally.adding(
            fire, kind: .normal, isMine: true, isDirectMessage: true, to: theirs
        )?[0].count == 2)
        #expect(ReactionTally.adding(
            fire, kind: .burst, isMine: false, isDirectMessage: true, to: theirs
        )?[0].burstCount == 1)
    }

    @Test("Removing the last of both halves removes the entry")
    func emptyEntryGoes() throws {
        let both = try #require(ReactionTally.adding(
            fire, kind: .burst, isMine: true,
            to: [Reaction(emoji: fire, count: 1, isMine: false)]
        ))
        let burstGone = try #require(ReactionTally.removing(fire, kind: .burst, isMine: true, from: both))
        #expect(burstGone.count == 1 && burstGone[0].burstCount == 0 && !burstGone[0].isMineBurst)
        let allGone = try #require(ReactionTally.removing(fire, kind: .normal, isMine: false, from: burstGone))
        #expect(allGone.isEmpty)
    }

    @Test("The reader cannot remove a reaction they never made")
    func removingANonReactionChangesNothing() {
        let theirs = [Reaction(emoji: fire, count: 3, isMine: false, burstCount: 2)]
        #expect(ReactionTally.removing(fire, kind: .normal, isMine: true, from: theirs) == nil)
        #expect(ReactionTally.removing(fire, kind: .burst, isMine: true, from: theirs) == nil)
        #expect(ReactionTally.removing(shaq, kind: .normal, isMine: false, from: theirs) == nil)
    }

    @Test("Clearing one emoji takes both halves and leaves the rest")
    func clearingAnEmoji() throws {
        let reactions = [
            Reaction(emoji: fire, count: 3, isMine: true, burstCount: 1),
            Reaction(emoji: shaq, count: 1, isMine: false),
        ]
        let cleared = try #require(ReactionTally.removingEmoji(fire, from: reactions))
        #expect(cleared.map(\.emoji) == [shaq])
        #expect(ReactionTally.removingEmoji(EmojiRef(name: "🎉"), from: reactions) == nil)
    }

    // MARK: The chip's colours

    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        var colors: [UInt32]
        var dark: (UInt32, UInt32, Double)
        var light: (UInt32, UInt32, Double)

        init(_ colors: [UInt32], dark: (UInt32, UInt32, Double), light: (UInt32, UInt32, Double)) {
            self.colors = colors
            self.dark = dark
            self.light = light
        }

        var testDescription: String {
            colors.map { "#" + String($0, radix: 16).leftPadded(6) }.joined(separator: " ")
        }
    }

    /// `V(burst_colors, 1, isDark)` from module `478840`, verbatim. The first
    /// row is the `x_shaq` reaction captured in `lottiesuperreaction.har`; the
    /// next eight are chosen edges — white, black, greys, primaries, blurple;
    /// the rest are seeded random palettes of one to five colours.
    nonisolated static let cases: [Case] = [
        Case([0x00_00_00, 0x30_11_11, 0x40_1B_17, 0x60_34_2F, 0x50_27_22, 0x40_17_13, 0x50_30_2C, 0x30_11_0E, 0x70_3D_37, 0x70_43_3E], dark: (0xCA_75_6C, 0xD3_8E_87, 0.2), light: (0xCB_78_70, 0x40_1B_17, 0.1)),
        Case([0xFF_FF_FF], dark: (0xB3_B3_B3, 0xFF_FF_FF, 0.5), light: (0x8D_8D_8D, 0x7F_7F_7F, 0.35)),
        Case([0x00_00_00], dark: (0x9A_9A_9A, 0x7F_7F_7F, 0.5), light: (0x8C_8C_8C, 0x00_00_00, 0.35)),
        Case([0x80_80_80, 0x7F_7F_7F], dark: (0x9A_9A_9A, 0xCD_CD_CD, 0.5), light: (0x8D_8D_8D, 0x4D_4D_4D, 0.35)),
        Case([0xFF_00_00, 0x00_FF_00, 0x00_00_FF], dark: (0xFF_36_36, 0xFF_D0_D0, 0.2), light: (0xFF_4D_4D, 0xB4_00_00, 0.1)),
        Case([0xF5_F5_F4, 0xE8_E6_E3, 0xD0_CD_C8], dark: (0xAB_AB_A2, 0xF5_F5_F4, 0.5), light: (0x93_93_89, 0x7C_7C_72, 0.35)),
        Case([0x58_65_F2], dark: (0x26_30_EC, 0xD0_D3_FC, 0.2), light: (0x70_7B_F3, 0x28_39_EE, 0.1)),
        Case([0xFE_E7_5C, 0xEB_45_9E], dark: (0xDC_BC_00, 0xFE_E7_5C, 0.2), light: (0xCD_AC_00, 0x5E_50_01, 0.1)),
        Case([0x10_10_10, 0xFA_FA_FA, 0x77_77_77], dark: (0xAE_AE_AE, 0xFA_FA_FA, 0.5), light: (0x8D_8D_8D, 0x7A_7A_7A, 0.35)),
        Case([0xF0_6B_BB, 0xDC_12_19, 0x36_57_FE, 0xF4_7C_B1], dark: (0x05_05_FF, 0xCC_D5_FE, 0.2), light: (0x67_81_FF, 0x04_2D_FE, 0.1)),
        Case([0x32_84_33], dark: (0x5B_C2_5B, 0xA3_DC_A3, 0.2), light: (0x3E_A7_3E, 0x24_5F_25, 0.1)),
        Case([0x3D_DD_24, 0x13_9A_21, 0x30_BD_CF, 0x20_AE_B6, 0x93_D2_8B], dark: (0x36_C6_23, 0x77_E7_66, 0.2), light: (0x2B_B7_1A, 0x18_5A_0E, 0.1)),
        Case([0xAC_8A_DB, 0xFC_45_6A, 0x30_6A_8F, 0x83_EB_5D, 0x8E_75_17], dark: (0xFF_13_40, 0xFE_C2_CE, 0.2), light: (0xFE_50_73, 0xA7_03_24, 0.1)),
        Case([0x09_68_E4], dark: (0x3D_8C_F7, 0xC0_DA_FD, 0.2), light: (0x38_88_F7, 0x07_52_B2, 0.1)),
        Case([0x93_48_02, 0x54_C0_8E, 0xCA_FB_A5], dark: (0xF8_9B_3E, 0xFD_C6_92, 0.2), light: (0xE4_6F_01, 0x7A_3C_02, 0.1)),
        Case([0x2D_25_CE, 0xC7_51_24], dark: (0x56_56_E0, 0xCD_CC_F6, 0.2), light: (0x81_7C_E7, 0x2D_25_CE, 0.1)),
        Case([0xBF_BA_CE], dark: (0xA6_A0_BA, 0xCD_C9_D9, 0.2), light: (0x8F_87_A8, 0x55_4D_6B, 0.1)),
        Case([0x04_51_17, 0xB2_26_8C, 0xA0_86_AB], dark: (0xDA_5D_BA, 0xF3_C9_E9, 0.2), light: (0xDE_57_B7, 0x9D_22_7B, 0.1)),
        Case([0x2E_E0_1D, 0xF2_64_92], dark: (0x25_CE_1B, 0x57_E7_49, 0.2), light: (0x25_B0_17, 0x11_56_0B, 0.1)),
        Case([0x50_1D_47, 0xFE_3E_B6, 0x96_F1_79, 0xE3_BC_51], dark: (0xFF_0E_9A, 0xFE_BB_E5, 0.2), light: (0xFF_33_B6, 0xA5_01_65, 0.1)),
        Case([0x19_CB_35, 0x7F_E2_A8, 0x89_D9_E1], dark: (0x1B_CE_36, 0x49_E9_62, 0.2), light: (0x17_B0_2E, 0x0A_58_17, 0.1)),
        Case([0x81_3D_0F, 0xFC_8F_9D, 0xF0_FF_17, 0x6E_83_26], dark: (0xA8_B4_00, 0xF0_FF_17, 0.2), light: (0xC3_CD_00, 0x47_4D_00, 0.1)),
        Case([0xB1_E1_66, 0x83_33_BA], dark: (0xA4_65_D2, 0xE0_C9_F0, 0.2), light: (0xAC_73_DB, 0x75_2E_A6, 0.1)),
        Case([0x80_C3_11], dark: (0x7F_BF_10, 0x9D_EB_1B, 0.2), light: (0x7A_B8_0F, 0x35_50_07, 0.1)),
        Case([0xAF_B2_89, 0x02_C1_D8, 0x79_51_5D], dark: (0x00_C7_E8, 0x0F_E4_FD, 0.2), light: (0x00_B4_CD, 0x02_52_5B, 0.1)),
        Case([0xC8_A0_FF, 0xCC_A4_AB, 0x57_9C_D2], dark: (0x65_A2_D2, 0xBB_D8_EC, 0.2), light: (0x4B_93_D1, 0x25_5B_87, 0.1)),
        Case([0x2D_A4_57, 0xEA_B5_EC, 0x4A_C1_E8, 0x01_2F_BE], dark: (0x7F_7F_7F, 0x8F_D9_F1, 0.2), light: (0x1A_9D_C7, 0x0E_57_6F, 0.1)),
        Case([0xAD_B5_6E, 0xD4_1C_CB, 0xB9_7F_97], dark: (0xE8_4F_E0, 0xF7_C3_F5, 0.2), light: (0xE7_48_DF, 0x8F_13_89, 0.1)),
        Case([0xBF_55_A7, 0x79_98_A1, 0x12_7D_8F], dark: (0x21_C6_E2, 0x6A_DA_EC, 0.2), light: (0x18_A0_B8, 0x0C_55_61, 0.1)),
        Case([0x06_EF_3C, 0xEC_7D_58, 0x2F_D1_65, 0xA7_FC_74], dark: (0x07_C8_30, 0x06_EF_3C, 0.2), light: (0x01_D0_2B, 0x02_59_17, 0.1)),
        Case([0xD5_FA_31, 0xEC_0D_ED, 0x3C_AC_B2], dark: (0xF6_38_F6, 0xFA_B1_FA, 0.2), light: (0xF6_3F_F6, 0x8C_09_8D, 0.1)),
        Case([0x12_3C_46], dark: (0x49_B9_D3, 0x76_C8_DC, 0.2), light: (0x2D_95_AE, 0x12_3C_46, 0.1)),
        Case([0xE3_CE_64, 0x6D_2C_4F], dark: (0xD8_B1_27, 0xE3_CE_64, 0.2), light: (0xA9_91_1F, 0x65_58_12, 0.1)),
        Case([0x5B_EB_63, 0x6D_7D_75, 0x2E_4A_1F, 0x59_6C_52], dark: (0x1A_CA_23, 0x5B_EB_63, 0.2), light: (0x17_B0_24, 0x09_53_0E, 0.1)),
        Case([0x81_0B_80, 0xE6_EC_4C, 0xDF_98_8E], dark: (0xC2_C2_25, 0xE6_EC_4C, 0.2), light: (0xB0_B1_16, 0x4B_4D_08, 0.1)),
        Case([0x71_9E_2B, 0x6B_A6_2F, 0xD7_A6_75], dark: (0x82_C6_3D, 0xAC_DB_7C, 0.2), light: (0x6C_A6_2A, 0x37_56_18, 0.1)),
        Case([0xE4_ED_EB, 0x3A_22_77], dark: (0x7E_65_D2, 0xC2_B3_EA, 0.2), light: (0x8F_73_DB, 0x3A_22_77, 0.1)),
        Case([0x61_1B_46], dark: (0xD2_65_A5, 0xE3_9C_C5, 0.2), light: (0xDA_70_B0, 0x61_1B_46, 0.1)),
        Case([0x5F_46_4E], dark: (0xAA_8C_94, 0xDB_CE_D2, 0.2), light: (0xA1_87_88, 0x5F_46_4E, 0.1)),
    ]

    @Test("The chip's colours are Discord's, in both rooms", arguments: cases)
    func paletteMatchesDiscord(_ expected: Case) throws {
        let palette = try #require(SuperReactionPalette(colors: expected.colors))
        #expect(palette.dark.background == expected.dark.0, "dark fill")
        #expect(palette.dark.accent == expected.dark.1, "dark accent")
        #expect(palette.dark.opacity == expected.dark.2, "dark opacity")
        #expect(palette.light.background == expected.light.0, "light fill")
        #expect(palette.light.accent == expected.light.1, "light accent")
        #expect(palette.light.opacity == expected.light.2, "light opacity")
    }

    @Test("No colours is no palette, which Discord draws as a plain chip")
    func noColoursNoPalette() {
        #expect(SuperReactionPalette(colors: []) == nil)
    }

    // MARK: The effect

    /// `Q7(accent, 2)` from module `998304`: the pair each effect's red and blue
    /// are repainted in.
    nonisolated static let tints: [(UInt32, UInt32, UInt32)] = [
        (0xD3_8E_87, 0x8E_87_D3, 0x87_D3_8E),
        (0x40_1B_17, 0x33_2B_78, 0x2B_78_33),
        (0xFF_FF_FF, 0x7A_7A_B8, 0x7A_B8_7A),
        (0x7F_7F_7F, 0x59_59_A5, 0x59_A5_59),
        (0x00_00_00, 0x1B_1B_32, 0x1B_32_1B),
        (0xCD_CD_CD, 0x48_48_86, 0x48_86_48),
        (0x4D_4D_4D, 0x36_36_64, 0x36_64_36),
        (0xFF_D0_D0, 0x04_04_FF, 0x04_FF_04),
        (0xB4_00_00, 0x00_00_B4, 0x00_B4_00),
        (0xF5_F5_F4, 0xB6_67_B6, 0x67_B6_B6),
        (0x7C_7C_72, 0xA0_4E_A0, 0x4E_A0_A0),
        (0xD0_D3_FC, 0x1F_F0_10, 0xF0_10_1F),
        (0x28_39_EE, 0x39_EE_28, 0xEE_28_39),
        (0xFE_E7_5C, 0xE6_5C_FE, 0x5C_FE_E6),
        (0x5E_50_01, 0x90_02_AA, 0x02_AA_90),
        (0xFA_FA_FA, 0x74_74_B4, 0x74_B4_74),
        (0x7A_7A_7A, 0x55_55_9E, 0x55_9E_55),
        (0xCC_D5_FE, 0x32_F9_05, 0xF9_05_32),
        (0x04_2D_FE, 0x2E_FE_04, 0xFE_04_2E),
        (0xA3_DC_A3, 0xDC_A3_A3, 0xA3_A3_DC),
        (0x24_5F_25, 0x5F_25_24, 0x25_24_5F),
        (0x77_E7_66, 0xE7_66_77, 0x66_77_E7),
        (0x18_5A_0E, 0x5A_0E_18, 0x0E_18_5A),
        (0xFE_C2_CE, 0x04_33_F0, 0x33_F0_04),
        (0xA7_03_24, 0x03_24_A7, 0x24_A7_03),
        (0xC0_DA_FD, 0x6A_EA_07, 0xEA_07_6A),
        (0x07_52_B2, 0x51_B2_07, 0xB2_07_51),
        (0xFD_C6_92, 0xC6_92_FD, 0x92_FD_C6),
        (0x7A_3C_02, 0x3C_02_7A, 0x02_7A_3C),
        (0xCD_CC_F6, 0x25_D1_28, 0xD1_28_25),
        (0x2D_25_CE, 0x25_CE_2D, 0xCE_2D_25),
        (0xCD_C9_D9, 0x38_9E_52, 0x9E_52_38),
        (0x55_4D_6B, 0x31_87_48, 0x87_48_31),
        (0xF3_C9_E9, 0x2C_A1_C4, 0xA1_C4_2C),
        (0x9D_22_7B, 0x22_7A_9D, 0x7A_9D_22),
        (0x57_E7_49, 0xE7_49_56, 0x49_56_E7),
        (0x11_56_0B, 0x9A_14_1F, 0x14_1F_9A),
        (0xFE_BB_E5, 0x03_95_EA, 0x95_EA_03),
        (0xA5_01_65, 0x01_66_A5, 0x66_A5_01),
        (0x49_E9_62, 0xE9_61_49, 0x61_49_E9),
        (0x0A_58_17, 0x9D_29_12, 0x29_12_9D),
        (0xF0_FF_17, 0xFF_17_F0, 0x17_F0_FF),
        (0x47_4D_00, 0x9A_00_8D, 0x00_8D_9A),
        (0xE0_C9_F0, 0x34_BA_82, 0xBA_82_34),
        (0x75_2E_A6, 0x2E_A6_76, 0xA6_76_2E),
        (0x9D_EB_1B, 0xEB_1B_9B, 0x1B_9B_EB),
        (0x35_50_07, 0x97_0D_64, 0x0D_64_97),
        (0x0F_E4_FD, 0xE5_FD_0F, 0xFD_0F_E5),
        (0x02_52_5B, 0x95_A6_04, 0xA6_04_95),
        (0xBB_D8_EC, 0x7A_AB_30, 0xAB_30_7A),
        (0x25_5B_87, 0x5B_87_25, 0x87_25_5B),
        (0x8F_D9_F1, 0xD9_F1_8F, 0xF1_8F_D9),
        (0x0E_57_6F, 0x57_6F_0E, 0x6F_0E_57),
        (0xF7_C3_F5, 0x1C_CC_D2, 0xCC_D2_1C),
        (0x8F_13_89, 0x13_89_8F, 0x89_8F_13),
        (0x6A_DA_EC, 0xDB_EC_6A, 0xEC_6A_DB),
        (0x0C_55_61, 0x56_61_0C, 0x61_0C_56),
        (0x06_EF_3C, 0xEF_3C_06, 0x3C_06_EF),
        (0x02_59_17, 0xA4_29_04, 0x29_04_A4),
        (0xFA_B1_FA, 0x0D_D1_D1, 0xD1_D1_0D),
        (0x8C_09_8D, 0x09_8D_8D, 0x8D_8D_09),
        (0x76_C8_DC, 0xC8_DC_76, 0xDC_76_C8),
        (0x12_3C_46, 0x70_83_22, 0x83_22_70),
        (0xE3_CE_64, 0xCE_64_E3, 0x64_E3_CE),
        (0x65_58_12, 0x58_12_65, 0x12_65_58),
        (0x5B_EB_63, 0xEB_62_5B, 0x62_5B_EB),
        (0x09_53_0E, 0x98_1A_10, 0x1A_10_98),
        (0xE6_EC_4C, 0xEC_4C_E7, 0x4C_E7_EC),
        (0x4B_4D_08, 0x92_0F_8E, 0x0F_8E_92),
        (0xAC_DB_7C, 0xDB_7C_AC, 0x7C_AC_DB),
        (0x37_56_18, 0x56_18_37, 0x18_37_56),
        (0xC2_B3_EA, 0x2D_A4_4D, 0xA4_4D_2D),
        (0x3A_22_77, 0x22_77_3A, 0x77_3A_22),
        (0xE3_9C_C5, 0x9C_C5_E3, 0xC5_E3_9C),
        (0x61_1B_46, 0x1B_46_61, 0x46_61_1B),
        (0xDB_CE_D2, 0x3C_5A_A0, 0x5A_A0_3C),
        (0x5F_46_4E, 0x2D_45_78, 0x45_78_2D),
    ]

    @Test("The effect is repainted in Discord's pair")
    func tintsMatchDiscord() {
        for (accent, first, second) in Self.tints {
            let pair = SuperReactionEffect.tints(for: accent)
            #expect(pair.0 == first && pair.1 == second, "accent #\(String(accent, radix: 16))")
        }
    }

    /// `H` from module `297494` over channel + message + name, and the index it
    /// picks. The first row is the captured reaction: index 8 is StarBlast,
    /// and StarBlast's chunk is exactly what the capture loaded on hover.
    nonisolated static let hashes: [(String, Int64, Int)] = [
        ("x_shaq", 6927264602, 8),
        ("🇹🇷", 6218522982, 0),
        ("🏳️‍⚧️", 6705462027, 3),
        ("👍", 5910372702, 0),
        ("pepepog", 6934262160, 12),
        ("FeelsBadMan", 5790782732, 14),
        ("😂", 5910373139, 5),
        ("a", 5905482509, 11),
        ("", 5074299182, 2),
        (String(repeating: "ÿ", count: 50), 3163210098, 6),
    ]

    @Test("The effect is chosen exactly as Discord chooses it")
    func effectChoiceMatchesDiscord() {
        let channel = ChannelID(rawValue: 1_522_308_942_204_637_325)
        let message = MessageID(rawValue: 1_522_309_183_544_885_345)
        for (name, hash, index) in Self.hashes {
            #expect(SuperReactionEffect.javaScriptHash("\(channel.rawValue)\(message.rawValue)\(name)") == hash)
            #expect(SuperReactionEffect.index(channelID: channel, messageID: message, emojiName: name) == index)
        }
        #expect(SuperReactionEffect.names[8] == "StarBlast")
        #expect(SuperReactionEffect.names.count == 18)
    }

    @Test("Red and blue are replaced everywhere, and nothing else is touched")
    func recolourIsATextSubstitution() throws {
        let json = Data(#"{"c":{"k":[1,0,0,1]},"d":{"k":[0,0,1,1]},"e":{"k":[1,0,0,0.5]},"f":[1,0,0]}"#.utf8)
        let out = try #require(String(data: SuperReactionEffect.recolored(json, accent: 0xD3_8E_87), encoding: .utf8))
        let (first, second) = SuperReactionEffect.tints(for: 0xD3_8E_87)
        func fraction(_ c: UInt32, _ shift: UInt32) -> Double { Double(c >> shift & 0xFF) / 255 }
        #expect(out.contains("[\(fraction(first, 16)),\(fraction(first, 8)),\(fraction(first, 0)),1]"))
        #expect(out.contains("[\(fraction(second, 16)),\(fraction(second, 8)),\(fraction(second, 0)),1]"))
        #expect(out.contains("[\(fraction(first, 16)),\(fraction(first, 8)),\(fraction(first, 0)),0.5]"))
        // A three-element array has no trailing comma and is not a keyed colour.
        #expect(out.contains(#""f":[1,0,0]"#))
    }

    @Test("A wide emoji rewrites only the first slot and the first anchor")
    func wideEmojiIsFitted() throws {
        let json = Data(#"{"w":128,"h":128,"a":{"a":0,"k":[64,64,0]},"x":{"w":128,"h":128},"y":{"a":{"a":0,"k":[64,64,0]}}}"#.utf8)
        let out = try #require(String(
            data: SuperReactionEffect.fitted(json, pictureWidth: 64, pictureHeight: 32), encoding: .utf8
        ))
        #expect(out == #"{"w":128,"h":64.0,"a":{"a":0,"k":[64,32.0,0]},"x":{"w":128,"h":128},"y":{"a":{"a":0,"k":[64,64,0]}}}"#)
        // Square, at any size, is untouched.
        #expect(SuperReactionEffect.fitted(json, pictureWidth: 44, pictureHeight: 44) == json)
    }
}

private extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
