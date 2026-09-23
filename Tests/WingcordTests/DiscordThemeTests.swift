import CoreGraphics
import Foundation
import Testing
@testable import Wingcord

/// Discord's themes, checked against Discord's own output rather than against a
/// re-reading of its code.
///
/// Every colour in the table below was produced by the thing it pins:
///
/// - **`tint` and `text`** are module `345815` of Discord's web bundle, run verbatim in Node
///   on the chroma.js Discord bundles (module `310784`), over the preset table
///   in module `385803`.
/// - **`canvas`, `surface` and `raised`** are Chrome 151's own
///   `color-mix(in oklab, <token> 100%, <tint> 50%)` over Discord's dark rungs
///   `#121214`, `#1A1A1E` and `#202024`, or its light ones `#F3F3F4`, `#FBFBFB`
///   and `#FFFFFF`, painted into an sRGB canvas and read back — which is what
///   Discord's desktop client, being Chromium, puts on screen. Seven of the
///   light ones land outside sRGB and Chrome clips them; the port must too.
///
/// So a failure here is the port disagreeing with Discord, never the port
/// disagreeing with a second port of itself.
@Suite("Discord themes")
struct DiscordThemeTests {

    nonisolated struct Expected: Sendable, CustomTestStringConvertible {
        var theme: DiscordTheme
        var tint: UInt32
        var canvas: UInt32
        var surface: UInt32
        var raised: UInt32
        var text: UInt32 = 0

        var testDescription: String { theme.title }
    }

    nonisolated static let expected: [Expected] = [
        Expected(theme: .mintApple, tint: 0xE8_FF_CC, canvas: 0xEF_F7_E7, surface: 0xF5_FD_EC, raised: 0xF7_FF_EE, text: 0x00_4D_3A),
        Expected(theme: .citrusSherbert, tint: 0xFF_EE_CC, canvas: 0xF7_F1_E7, surface: 0xFC_F7_EC, raised: 0xFF_F9_EE, text: 0x4D_17_00),
        Expected(theme: .retroRaincloud, tint: 0xCC_ED_FF, canvas: 0xE6_F1_F8, surface: 0xEC_F6_FC, raised: 0xEE_F9_FF, text: 0x00_52_80),
        Expected(theme: .hanami, tint: 0xD0_FF_CC, canvas: 0xE8_F7_E7, surface: 0xED_FD_EC, raised: 0xF0_FF_EE, text: 0x4D_00_0A),
        Expected(theme: .sunrise, tint: 0xFF_F7_CC, canvas: 0xF7_F4_E7, surface: 0xFC_FA_EC, raised: 0xFF_FC_EE, text: 0x4D_00_2A),
        Expected(theme: .cottonCandy, tint: 0xCC_D7_FF, canvas: 0xE6_EA_F8, surface: 0xEB_EF_FD, raised: 0xEE_F2_FF, text: 0x4D_00_0E),
        Expected(theme: .lofiVibes, tint: 0xF2_FF_CC, canvas: 0xF3_F7_E7, surface: 0xF8_FD_EC, raised: 0xFB_FF_EE, text: 0x00_2A_80),
        Expected(theme: .desertKhaki, tint: 0xFF_E4_CC, canvas: 0xF7_EE_E7, surface: 0xFD_F3_EB, raised: 0xFF_F6_EE, text: 0x4D_40_00),
        Expected(theme: .sunset, tint: 0x08_00_1A, canvas: 0x0E_0B_17, surface: 0x13_10_1D, raised: 0x17_14_21, text: 0xFF_EF_E5),
        Expected(theme: .chromaGlow, tint: 0x00_0E_1A, canvas: 0x0B_11_16, surface: 0x11_16_1D, raised: 0x14_1A_21, text: 0xE5_FE_FF),
        Expected(theme: .forest, tint: 0x00_1A_02, canvas: 0x0D_15_0E, surface: 0x12_1A_15, raised: 0x16_1E_19, text: 0xFF_F8_E5),
        Expected(theme: .crimsonMoon, tint: 0x1A_00_00, canvas: 0x16_0C_0B, surface: 0x1C_11_12, raised: 0x20_15_16, text: 0xFF_E5_E5),
        Expected(theme: .midnightBlurple, tint: 0x08_00_1A, canvas: 0x0E_0B_17, surface: 0x13_10_1D, raised: 0x17_14_21, text: 0xA2_99_FF),
        Expected(theme: .mars, tint: 0x1A_06_00, canvas: 0x15_0E_0C, surface: 0x1B_14_13, raised: 0x1F_17_16, text: 0xFF_EC_E5),
        Expected(theme: .dusk, tint: 0x16_00_1A, canvas: 0x14_0C_16, surface: 0x1A_11_1D, raised: 0x1E_15_21, text: 0x99_B6_FF),
        Expected(theme: .underTheSea, tint: 0x02_1A_00, canvas: 0x0E_15_0E, surface: 0x13_1B_14, raised: 0x17_1E_18, text: 0xE5_FF_FD),
        Expected(theme: .retroStorm, tint: 0x00_10_1A, canvas: 0x0C_12_16, surface: 0x11_17_1D, raised: 0x15_1B_21, text: 0x99_DA_FF),
        Expected(theme: .neonNights, tint: 0x1A_00_14, canvas: 0x16_0C_14, surface: 0x1B_11_1B, raised: 0x1F_15_1F, text: 0xE5_FF_FD),
        Expected(theme: .strawberryLemonade, tint: 0x1A_00_0E, canvas: 0x16_0C_12, surface: 0x1C_11_19, raised: 0x20_15_1C, text: 0xFF_F6_E5),
        Expected(theme: .aurora, tint: 0x00_09_1A, canvas: 0x0B_0F_16, surface: 0x10_15_1D, raised: 0x13_18_21, text: 0x99_AB_FF),
        Expected(theme: .sepia, tint: 0x1A_0F_00, canvas: 0x15_11_0D, surface: 0x1A_17_14, raised: 0x1E_1B_17, text: 0xFF_F3_E5),
        Expected(theme: .blurpleTwilight, tint: 0x02_00_1A, canvas: 0x0A_0C_17, surface: 0x0F_11_1E, raised: 0x12_14_22, text: 0x99_A3_FF),
    ]

    private static func hex(_ value: UInt32) -> String {
        "#" + String(value, radix: 16, uppercase: true).leftPadding(to: 6)
    }

    @Test("The table covers every theme, once")
    func tableIsComplete() {
        #expect(Self.expected.map(\.theme) == DiscordTheme.allCases)
    }

    @Test("The surface tint is Discord's, byte for byte", arguments: expected)
    func tintMatchesDiscord(_ expected: Expected) {
        #expect(
            Self.hex(expected.theme.surfaceTint) == Self.hex(expected.tint),
            "the derivation in module 345815 gives \(Self.hex(expected.tint))"
        )
    }

    @Test("The text tint is Discord's, byte for byte", arguments: expected)
    func textTintMatchesDiscord(_ expected: Expected) {
        #expect(Self.hex(expected.theme.textTint) == Self.hex(expected.text))
        #expect(expected.theme.colors.textTint == expected.text)
    }

    @Test("Every flat surface is Chrome's own color-mix", arguments: expected)
    func surfacesMatchChrome(_ expected: Expected) {
        let colors = expected.theme.colors
        #expect(Self.hex(colors.canvas) == Self.hex(expected.canvas))
        #expect(Self.hex(colors.surface) == Self.hex(expected.surface))
        #expect(Self.hex(colors.surfaceRaised) == Self.hex(expected.raised))
    }

    @Test("A Discord theme keeps the reader's accent")
    func noAccentOfItsOwn() {
        // Discord keeps its brand colour under every theme; this app's
        // equivalent is the reader's system accent.
        #expect(DiscordTheme.allCases.allSatisfy { $0.colors.accent == nil })
    }

    @Test("A Discord ground is Discord's gradient, through Discord's veils, with no light of ours")
    func groundIsDiscords() {
        for theme in DiscordTheme.allCases {
            let ground = ThemeGround(theme)
            #expect(ground.angle == theme.angle)
            // One gradient for both columns: the veils are the only difference.
            #expect(ground.page == theme.gradient)
            #expect(ground.frame == theme.gradient)
            #expect(ground.pageVeil == (theme.base == .light ? 0.85 : 0.80))
            #expect(ground.frameVeil == (theme.base == .light ? 0.70 : 0.75))
            #expect(ground.appearance == theme.base)
            #expect(theme.colors.appearance == theme.base)
            #expect(ground.paintsFrame)
            #expect(ground.glow == nil)
        }
        #expect(DiscordTheme.allCases.filter { $0.base == .light }.count == 8)
    }

    @Test("The names, and their order, are Discord's picker's")
    func namesAndOrder() {
        // Discord's en-US strings, in the order `385803` lists them: the light
        // presets, the dark ones, and Blurple Twilight appended from its own list.
        #expect(DiscordTheme.allCases.map(\.title) == [
            "Mint Apple", "Citrus Sherbert", "Retro Raincloud", "Hanami", "Sunrise",
            "Cotton Candy", "LoFi Vibes", "Desert Khaki",
            "Sunset", "Chroma Glow", "Forest", "Crimson Moon", "Midnight Blurple",
            "Mars", "Dusk", "Under the Sea", "Retro Storm", "Neon Nights",
            "Strawberry Lemonade", "Aurora", "Sepia", "Blurple Twilight",
        ])
    }

    @Test("Stops run forward along the line, inside it")
    func stopsAreOrdered() {
        for theme in DiscordTheme.allCases {
            let locations = theme.stops.map(\.location)
            #expect(locations.count >= 2, "\(theme.title) is not a gradient")
            #expect(locations == locations.sorted(), "\(theme.title) runs backwards")
            #expect(locations.allSatisfy { (0...1).contains($0) }, "\(theme.title) leaves its line")
            #expect(theme.gradient.stops.count == locations.count)
        }
    }

    // MARK: The line

    @Test("A gradient line ends where CSS ends it", arguments: DiscordTheme.allCases.map(\.angle) + [0, 90, 180, 270])
    func gradientAxisMatchesCSS(_ angle: Double) {
        // CSS's definition, stated independently of the implementation: the
        // line's ends are where the perpendiculars through the box's two
        // farthest corners cross it. Measured along the direction of travel,
        // the start is the smallest corner projection and the end the largest.
        let box = CGRect(x: 0, y: 0, width: 1_280, height: 820)
        let radians = angle * .pi / 180
        let direction = CGVector(dx: sin(radians), dy: -cos(radians))
        func along(_ point: CGPoint) -> Double {
            Double(point.x - box.midX) * direction.dx + Double(point.y - box.midY) * direction.dy
        }
        let corners = [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY),
        ].map(along)

        let (start, end) = GradientAxis.endpoints(angle: angle, in: box)
        #expect(abs(along(start) - corners.min()!) < 1e-6)
        #expect(abs(along(end) - corners.max()!) < 1e-6)
        // And it runs through the centre, so no stop is shifted sideways.
        #expect(abs((start.x + end.x) / 2 - box.midX) < 1e-6)
        #expect(abs((start.y + end.y) / 2 - box.midY) < 1e-6)
    }

    @Test("180° runs straight down the middle, top to foot")
    func verticalLine() {
        let (start, end) = GradientAxis.endpoints(angle: 180, in: CGRect(x: 0, y: 0, width: 900, height: 600))
        #expect(abs(start.x - 450) < 1e-9 && abs(start.y) < 1e-9)
        #expect(abs(end.x - 450) < 1e-9 && abs(end.y - 600) < 1e-9)
    }

    // MARK: Persistence

    @Test("Every choice survives being stored")
    func choicesRoundTrip() {
        let choices: [ThemeChoice] = ThemePreset.allCases.map(ThemeChoice.preset)
            + DiscordTheme.allCases.map(ThemeChoice.discord)
            + [.custom]
        for choice in choices {
            let stored = ThemeStore.storageValue(for: choice)
            #expect(ThemeStore.choice(forStorageValue: stored) == choice, "\(stored) came back as something else")
        }
    }

    @Test("A Discord theme's bare name is not a stored choice")
    func namespacesDoNotCollide() {
        // The prefix is what keeps a future house theme called "sunset" from
        // quietly becoming Discord's for every reader who chose Discord's.
        #expect(ThemeStore.choice(forStorageValue: "sunset") == nil)
        #expect(ThemeStore.storageValue(for: .discord(.sunset)) != DiscordTheme.sunset.rawValue)
    }
}

private extension String {
    func leftPadding(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
