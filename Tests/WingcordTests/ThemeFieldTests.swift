import Foundation
import SwiftUI
import Testing
@testable import Wingcord

/// The house themes' ground: the walk from head to foot, the frame that carries
/// more of it than the page, and the light in the corner.
///
/// Each of these fails silently in the window. A walk that took the long way
/// round the wheel puts the opposite hue in the middle of the transcript; a frame
/// that stopped being lighter is a sidebar that no longer says anything; and a
/// True Black that picked up the new treatment is the default appearance
/// changing for every reader who never chose a theme.
@Suite("House theme field")
struct ThemeFieldTests {

    /// Every preset with a hue of its own — all but the neutrals.
    static let hued = ThemePreset.allCases.filter { !$0.isStated && $0 != .graphite }
    /// Every preset whose room is derived from its seed.
    static let derived = ThemePreset.allCases.filter { !$0.isStated }

    @Test("The walk begins at canvas and ends at the lit end")
    func walkEnds() {
        for preset in ThemePreset.allCases {
            let seed = preset.seed
            #expect(seed.field(at: 0) == seed.canvas)
            #expect(seed.field(at: 1) == seed.canvasLit)
            #expect(abs(seed.canvasLit.lightness - seed.canvas.lightness - ThemeSeed.washRise) < 1e-12)
        }
    }

    @Test("The walk turns the short way round the wheel")
    func shortWay() {
        // Ember's ends sit either side of zero. The long way round is through
        // cyan, which is the whole of the bug this guards.
        let ember = ThemePreset.ember.seed
        #expect(ember.head.hue == 358)
        let middle = ember.field(at: 0.5).hue
        #expect(abs(middle - 33) < 1e-9, "the middle of crimson to amber is \(middle)°")
    }

    @Test("Each hued preset spreads its ends wide, and never lands its foot in olive")
    func spread() {
        for preset in Self.hued {
            let seed = preset.seed
            let apart = PlumageShuffle.separation(seed.head.hue, seed.foot.hue)
            #expect((60...90).contains(apart), "\(preset.title) is \(apart)° end to end")
            #expect(!(70...100).contains(seed.foot.hue), "\(preset.title)'s foot is olive")
        }
    }

    @Test("The frame is lighter and more colourful than the page, all the way along")
    func frameCarriesTheColour() {
        for preset in Self.derived {
            let seed = preset.seed
            for step in 0...4 {
                let t = Double(step) / 4
                let page = seed.field(at: t)
                let frame = seed.frame(at: t)
                #expect(frame.lightness > page.lightness)
                #expect(frame.chroma >= page.chroma)
                #expect(frame.hue == page.hue, "one line: the frame may not drift in hue")
            }
        }
    }

    @Test("The light is the foot's hue, lifted clear of the ground")
    func glowFollowsTheFoot() {
        for preset in Self.derived {
            let seed = preset.seed
            #expect(seed.glow.hue == seed.canvasLit.hue)
            #expect(seed.glow.lightness == seed.canvasLit.lightness + ThemeSeed.glowRise)
        }
        // Graphite's is a grey light, because its foot is nearly grey.
        #expect(ThemePreset.graphite.seed.glow.chroma < 0.02)
    }

    @Test("A house ground: the field sampled, a painted frame, no veils, a light")
    func houseGround() {
        for preset in Self.derived {
            let ground = preset.ground
            #expect(ground.angle == ThemeSeed.fieldAngle)
            #expect(ground.page.stops.map(\.location) == [0, 0.25, 0.5, 0.75, 1])
            #expect(ground.frame.stops.count == ground.page.stops.count)
            #expect(ground.page != ground.frame)
            #expect(ground.pageVeil == 0 && ground.frameVeil == 0)
            #expect(ground.paintsFrame)
            #expect(ground.glow != nil)
        }
    }

    @Test("True Black is exactly what it was")
    func trueBlackIsStated() {
        #expect(ThemePreset.trueBlack.colors == ThemeColors.trueBlack)
        #expect(ThemeColors.trueBlack.canvas == 0x0A_0A_0C)
        #expect(ThemeColors.trueBlack.surface == 0x14_14_17)
        #expect(ThemeColors.trueBlack.surfaceRaised == 0x1C_1C_20)
        #expect(ThemeColors.trueBlack.accent == nil)

        let ground = ThemePreset.trueBlack.ground
        #expect(ground == .trueBlack)
        #expect(!ground.paintsFrame, "the house theme's sidebar is the desktop's vibrancy")
        #expect(ground.glow == nil)
        #expect(ground.page == ground.frame)
    }

    @Test("Porcelain is a light room, stated, with a deeper frame")
    func porcelainIsLight() {
        let colors = ThemePreset.porcelain.colors
        #expect(colors == ThemeColors.porcelain)
        #expect(colors.appearance == .light)
        #expect(colors.accent == nil)
        // Up the ladder: a card is brighter than the page, a row brighter again.
        #expect(InkContrast.luminance(colors.surface) > InkContrast.luminance(colors.canvas))
        #expect(InkContrast.luminance(colors.surfaceRaised) > InkContrast.luminance(colors.surface))

        let ground = ThemePreset.porcelain.ground
        #expect(ground == .porcelain)
        #expect(ground.appearance == .light)
        #expect(ground.paintsFrame)
        #expect(ground.glow == nil)
        #expect(ThemePreset.porcelain.ground(vividness: 1) == .porcelain)
        // Every house room but this one is dark.
        #expect(ThemePreset.allCases.filter { $0.colors.appearance == .light } == [.porcelain])
    }

    @Test("The store resolves a preset to its cached ground")
    func storeUsesTheCache() {
        for preset in ThemePreset.allCases {
            #expect(ThemeStore.ground(for: .preset(preset), customSeed: preset.seed, vividness: 0) == preset.ground)
        }
    }

    @Test("Shuffle stays inside the band the presets use")
    func shuffleBand() {
        var generator = SeededGenerator(seed: 0x5EED)
        var seed = ThemePreset.nightfall.seed
        for _ in 0..<200 {
            seed = PlumageShuffle.next(after: seed, using: &generator)
            let apart = PlumageShuffle.separation(seed.head.hue, seed.foot.hue)
            let band = PlumageShuffle.footOffsetRange
            #expect(apart > band.lowerBound - 1e-9 && apart < band.upperBound + 1e-9,
                    "a shuffle landed \(apart)° end to end")
        }
    }
}

/// Plumage's larger blends: three to five colours and a turned line.
@Suite("Plumage blends")
struct PlumageBlendTests {

    static let five = ThemeSeed(
        head: ThemeStop(hue: 250, depth: 0.7),
        middle: [
            ThemeStop(hue: 290, depth: 0.8),
            ThemeStop(hue: 330, depth: 0.85),
            ThemeStop(hue: 10, depth: 0.9),
        ],
        foot: ThemeStop(hue: 45, depth: 0.92),
        light: 0.42,
        accentTurn: 0.25,
        angle: 212
    )

    @Test("Every form a blend has ever been stored in still reads")
    func storageRoundTrip() {
        #expect(ThemeSeed(storageValue: Self.five.storageValue) == Self.five)
        #expect(Self.five.storageValue.count == 13)

        let two = ThemePreset.nebula.seed
        #expect(ThemeSeed(storageValue: two.storageValue) == two)

        // Six numbers: a blend from before the angle and the middle existed.
        let legacy = ThemeSeed(storageValue: [255, 0.76, 335, 0.92, 0.425, 0.015])
        #expect(legacy?.middle == [])
        #expect(legacy?.angle == ThemeSeed.fieldAngle)
        // Four: the one-colour form before the seed had a second stop.
        #expect(ThemeSeed(storageValue: [286, 0.2, 0.4, 0])?.head == ThemeSeed(storageValue: [286, 0.2, 0.4, 0])?.foot)
        // Anything else is not a blend.
        #expect(ThemeSeed(storageValue: [1, 2, 3, 4, 5, 6, 7, 8]) == nil)
    }

    @Test("The walk passes through every stop, at its own place on the line")
    func walkThroughEveryStop() {
        let seed = Self.five
        for (index, anchor) in seed.anchors.enumerated() {
            let stop = seed.stop(at: seed.position(ofAnchor: index))
            #expect(abs(stop.hue - anchor.hue) < 1e-9 || abs(abs(stop.hue - anchor.hue) - 360) < 1e-9)
            #expect(abs(stop.depth - anchor.depth) < 1e-9)
        }
        // Each leg goes the short way: 330° to 10° passes through 350°, not 170°.
        let midLeg = seed.stop(at: (seed.position(ofAnchor: 2) + seed.position(ofAnchor: 3)) / 2)
        #expect(abs(midLeg.hue - 350) < 1e-9)
    }

    @Test("A colour added on the thread does not move the ground")
    func addingOnTheThreadIsInvisible() {
        let two = ThemePreset.mulberry.seed
        var three = two
        three.middle = [two.stop(at: 0.5)]
        for step in 0...8 {
            let t = Double(step) / 8
            #expect(abs(two.stop(at: t).hue - three.stop(at: t).hue) < 1e-9)
            #expect(abs(two.stop(at: t).depth - three.stop(at: t).depth) < 1e-9)
        }
    }

    @Test("Five colours are sampled leg by leg, at the blend's own angle")
    func groundOfAFiveColourBlend() {
        let ground = ThemeGround(Self.five)
        #expect(ground.angle == 212)
        #expect(ground.page.stops.count == 4 * ThemeGround.samplesPerLeg + 1)
        #expect(ground.frame.stops.count == ground.page.stops.count)
    }

    @Test("No more than five colours, however many are asked for")
    func middleIsCapped() {
        let crowded = ThemeSeed(
            head: ThemeStop(hue: 0, depth: 0.5),
            middle: Array(repeating: ThemeStop(hue: 90, depth: 0.5), count: 7),
            foot: ThemeStop(hue: 180, depth: 0.5),
            light: 0.4
        )
        #expect(crowded.middle.count == ThemeSeed.maximumMiddle)
        #expect(crowded.anchors.count == 5)
    }

    @Test("Shuffle keeps the reader's colour count and falls toward the composer")
    func shuffleKeepsTheCount() {
        var generator = SeededGenerator(seed: 0xC0FFEE)
        for count in 0...ThemeSeed.maximumMiddle {
            var seed = Self.five
            seed.middle = Array(Self.five.middle.prefix(count))
            let next = PlumageShuffle.next(after: seed, using: &generator)
            #expect(next.middle.count == count)
            #expect(PlumageShuffle.angleRange.contains(next.angle))
        }
    }

    @Test("A selection follows its role when the walk changes shape")
    func selectionByRole() {
        var seed = ThemePreset.nightfall.seed
        #expect(PlumageStop.foot.index(in: seed) == 1)
        seed.middle = [ThemeStop(hue: 260, depth: 0.8)]
        #expect(PlumageStop.foot.index(in: seed) == 2)
        #expect(PlumageStop.middle(0).label(in: seed) == "Colour 2 of 3")
        // A middle colour that no longer exists falls to the foot.
        #expect(PlumageStop.middle(4).index(in: seed) == 2)
        #expect(PlumageStop.foot.next(in: seed) == .head)
        #expect(PlumageStop.widestLeg(in: seed) == 1)
    }
}

/// Vividness, and the floor that keeps coloured type readable as it rises.
@Suite("Vividness and ink")
struct VividnessTests {

    @Test("At zero, every theme is exactly what it was")
    func zeroChangesNothing() {
        for preset in ThemePreset.allCases {
            #expect(preset.colors(vividness: 0) == preset.colors)
            #expect(preset.ground(vividness: 0) == preset.ground)
        }
        for theme in DiscordTheme.allCases {
            #expect(ThemeGround(theme, vividness: 0) == ThemeGround(theme))
        }
    }

    @Test("Vividness lifts the whole ramp and widens its colour")
    func liftsTheRamp() {
        let calm = ThemePreset.nebula.seed
        let vivid = calm.at(vividness: 1)
        #expect(abs(vivid.groundLightness - calm.groundLightness - ThemeSeed.vividLift) < 1e-12)
        // Every step of the ramp moves together, so a card stays a card.
        #expect(abs((vivid.surface.lightness - vivid.canvas.lightness)
            - (calm.surface.lightness - calm.canvas.lightness)) < 1e-12)
        #expect(vivid.field(at: 0.5).chroma > calm.field(at: 0.5).chroma)
        #expect(vivid.glowStrength > calm.glowStrength)
    }

    @Test("True Black does not move")
    func trueBlackIgnoresIt() {
        #expect(ThemePreset.trueBlack.colors(vividness: 1) == .trueBlack)
        #expect(ThemePreset.trueBlack.ground(vividness: 1) == .trueBlack)
    }

    @Test("Discord's veils run from its presets' to its editor's most vivid")
    func discordVeils() {
        let dark = DiscordTheme.sunset
        #expect(dark.readingVeil(vividness: 0) == 0.80)
        #expect(dark.sidebarVeil(vividness: 0) == 0.75)
        // `0.48 + 0.32·m` and `0.45 + 0.30·m` at the editor's most vivid, m = 0.3.
        #expect(abs(dark.readingVeil(vividness: 1) - 0.576) < 1e-12)
        #expect(abs(dark.sidebarVeil(vividness: 1) - 0.54) < 1e-12)
        // A light theme's own: 85 % and 70 % of white, thinned the light way.
        let light = DiscordTheme.hanami
        #expect(light.readingVeil(vividness: 0) == 0.85)
        #expect(light.sidebarVeil(vividness: 0) == 0.70)
        #expect(abs(light.readingVeil(vividness: 1) - 0.85 * 0.72) < 1e-12)
        #expect(abs(light.sidebarVeil(vividness: 1) - 0.504) < 1e-12)
    }

    @Test("Every accent reads on the brightest ground it can land on, calm to vivid")
    func accentsStayLegible() {
        for preset in ThemePreset.allCases where !preset.followsSystemAccent {
            for step in 0...4 {
                let vividness = Double(step) / 4
                let seed = preset.seed.at(vividness: vividness)
                let accent = preset.colors(vividness: vividness).accent!
                #expect(InkContrast.ratio(accent, seed.inkCeiling) >= InkContrast.textMinimum - 1e-9,
                        "\(preset.title) at \(vividness)")
            }
        }
    }

    @Test("A colour that already reads is left exactly alone")
    func passingInkIsUntouched() {
        let ground: UInt32 = 0x0A_0A_0C
        for ink: UInt32 in [0xFF_FF_FF, 0xF1_C4_0F, 0x57_F2_87, 0xEB_45_9E] {
            #expect(InkContrast.legible(ink, on: ground) == ink)
        }
    }

    @Test("A colour that fails is moved away from the ground, and keeps its hue")
    func failingInkIsLifted() {
        let navy: UInt32 = 0x1F_3B_73
        // On a dark ground it lightens…
        let onDark = InkContrast.legible(navy, on: 0x1E_1A_2E)
        #expect(InkContrast.ratio(onDark, 0x1E_1A_2E) >= InkContrast.textMinimum)
        #expect(Oklch(packedRGB: onDark).lightness > Oklch(packedRGB: navy).lightness)
        #expect(abs(Oklch(packedRGB: onDark).hue - Oklch(packedRGB: navy).hue) < 3)
        // …and a pale one on a light ground darkens.
        let butter: UInt32 = 0xF7_E3_8B
        let onLight = InkContrast.legible(butter, on: 0xF2_F0_EA)
        #expect(InkContrast.ratio(onLight, 0xF2_F0_EA) >= InkContrast.textMinimum)
        #expect(Oklch(packedRGB: onLight).lightness < Oklch(packedRGB: butter).lightness)
    }
}

/// SplitMix64 — deterministic, so a failure in the shuffle's band reproduces.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
