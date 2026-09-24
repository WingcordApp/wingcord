import Foundation
import SwiftUI

// MARK: - Discord's own themes
//
// The gradient themes Discord's client ships, read out of its web bundle rather
// than fitted to screenshots of them. Four pieces of that bundle make a theme,
// and each is reproduced here from the source, not from a picture:
//
//  - **The preset table** (module `385803`): each theme's colour tokens, the
//    position of each stop along the gradient, the angle, and whether it sits
//    on Discord's light or dark base. Discord paints it as a plain CSS
//    `linear-gradient(<angle>deg, <hex> <stop>%, …)` (module `644235`).
//  - **The colour tokens**: one hex per `BG_GRADIENT_*` name, defined once.
//  - **The veils** (stylesheet `419070`): nothing in Discord's window sits on
//    the gradient bare. Every surface is the gradient pinned to the window and
//    seen through a flat veil — black over a dark theme (the chat at 80 %, the
//    channel list at 75 %), white over a light one (85 % and 70 %).
//  - **The surface tint** (module `345815`): a colour derived from the two ends
//    of the gradient, mixed at 50 % into every solid surface token — cards,
//    code blocks, popouts — with `color-mix(in oklab, …)`.
//
// **A light theme is a light window**, in Discord and here: choosing one turns
// the whole app to its light appearance — see `ThemeStore.pinAppearance`.

/// One of Discord's gradient themes, exactly as its client defines it.
///
/// **The raw values are the persistence format**, so they are stable and never
/// renamed — the same rule, for the same reason, as `ThemePreset`'s.
///
/// **The cases are in Discord's own order**, which is the order its picker lists
/// them in: the light presets, the dark ones, then Blurple Twilight, which
/// Discord keeps in a separate list of its own and appends.
nonisolated enum DiscordTheme: String, CaseIterable, Identifiable, Hashable, Sendable {
    case mintApple
    case citrusSherbert
    case retroRaincloud
    case hanami
    case sunrise
    case cottonCandy
    case lofiVibes
    case desertKhaki
    case sunset
    case chromaGlow
    case forest
    case crimsonMoon
    case midnightBlurple
    case mars
    case dusk
    case underTheSea
    case retroStorm
    case neonNights
    case strawberryLemonade
    case aurora
    case sepia
    case blurpleTwilight

    var id: String { rawValue }

    /// Discord's en-US strings, verbatim.
    var title: String {
        switch self {
        case .mintApple: "Mint Apple"
        case .citrusSherbert: "Citrus Sherbert"
        case .retroRaincloud: "Retro Raincloud"
        case .hanami: "Hanami"
        case .sunrise: "Sunrise"
        case .cottonCandy: "Cotton Candy"
        case .lofiVibes: "LoFi Vibes"
        case .desertKhaki: "Desert Khaki"
        case .sunset: "Sunset"
        case .chromaGlow: "Chroma Glow"
        case .forest: "Forest"
        case .crimsonMoon: "Crimson Moon"
        case .midnightBlurple: "Midnight Blurple"
        case .mars: "Mars"
        case .dusk: "Dusk"
        case .underTheSea: "Under the Sea"
        case .retroStorm: "Retro Storm"
        case .neonNights: "Neon Nights"
        case .strawberryLemonade: "Strawberry Lemonade"
        case .aurora: "Aurora"
        case .sepia: "Sepia"
        case .blurpleTwilight: "Blurple Twilight"
        }
    }

    /// Which of Discord's bases the theme sits on — and so which room the
    /// window turns into when it is chosen.
    var base: ThemeAppearance {
        switch self {
        case .mintApple, .citrusSherbert, .retroRaincloud, .hanami,
             .sunrise, .cottonCandy, .lofiVibes, .desertKhaki: .light
        default: .dark
        }
    }

    // MARK: The gradient

    /// One colour at one point along the gradient line.
    nonisolated struct Stop: Hashable, Sendable {
        /// 24-bit sRGB.
        var color: UInt32
        /// Along the gradient line, `0...1` — Discord's percentage over a hundred.
        var location: Double
    }

    /// The gradient's stops, first to last.
    ///
    /// Retro Storm repeats a colour at two positions on purpose: that is a
    /// plateau of flat colour in the middle of the band, and it is Discord's.
    var stops: [Stop] {
        switch self {
        case .mintApple:
            [
                Stop(color: 0x56_B6_9F, location: 0.0615), Stop(color: 0x63_BC_61, location: 0.487),
                Stop(color: 0x9E_CA_67, location: 0.9307),
            ]
        case .citrusSherbert:
            [Stop(color: 0xF3_B3_36, location: 0.311), Stop(color: 0xEE_85_58, location: 0.6709)]
        case .retroRaincloud:
            [
                Stop(color: 0x3A_7C_A1, location: 0.0564), Stop(color: 0x7F_7E_B9, location: 0.2638),
                Stop(color: 0x7F_7E_B9, location: 0.4992), Stop(color: 0x3A_7C_A1, location: 0.7312),
            ]
        case .hanami:
            [
                Stop(color: 0xEF_AA_B3, location: 0.0356), Stop(color: 0xEF_D6_96, location: 0.3549),
                Stop(color: 0xA6_DA_A2, location: 0.6878),
            ]
        case .sunrise:
            [
                Stop(color: 0x9F_41_75, location: 0.0862), Stop(color: 0xC4_90_64, location: 0.4807),
                Stop(color: 0xA6_95_3D, location: 0.7604),
            ]
        case .cottonCandy:
            [Stop(color: 0xF4_AB_B8, location: 0.085), Stop(color: 0xB1_C2_FC, location: 0.9428)]
        case .lofiVibes:
            [
                Stop(color: 0xA4_C0_F7, location: 0.0708), Stop(color: 0xA9_E4_E8, location: 0.3494),
                Stop(color: 0xB0_E2_B8, location: 0.6512), Stop(color: 0xCF_DF_A2, location: 0.9623),
            ]
        case .desertKhaki:
            [
                Stop(color: 0xE7_DB_D0, location: 0.1292), Stop(color: 0xDF_D0_B2, location: 0.3292),
                Stop(color: 0xE0_D6_A3, location: 0.5211),
            ]
        case .sunset:
            [Stop(color: 0x48_28_8C, location: 0.2757), Stop(color: 0xDB_7F_4B, location: 0.7125)]
        case .chromaGlow:
            [
                Stop(color: 0x0E_B5_BF, location: 0.0394), Stop(color: 0x4C_0C_E0, location: 0.261),
                Stop(color: 0xA3_08_A7, location: 0.3982), Stop(color: 0x9A_53_FF, location: 0.5689),
                Stop(color: 0x21_8B_E0, location: 0.7645),
            ]
        case .forest:
            [
                Stop(color: 0x14_22_15, location: 0.112), Stop(color: 0x2D_4D_39, location: 0.2993),
                Stop(color: 0x45_4C_32, location: 0.4864), Stop(color: 0x5A_7C_58, location: 0.6785),
                Stop(color: 0xA9_8E_4B, location: 0.8354),
            ]
        case .crimsonMoon:
            [Stop(color: 0x95_09_09, location: 0.1617), Stop(color: 0x00_00_00, location: 0.72)]
        case .midnightBlurple:
            [Stop(color: 0x53_48_CA, location: 0.1121), Stop(color: 0x14_07_30, location: 0.6192)]
        case .mars:
            [Stop(color: 0x89_52_40, location: 0.1461), Stop(color: 0x8F_43_43, location: 0.7462)]
        case .dusk:
            [Stop(color: 0x66_50_69, location: 0.1284), Stop(color: 0x91_A3_D1, location: 0.8599)]
        case .underTheSea:
            [
                Stop(color: 0x64_79_62, location: 0.0191), Stop(color: 0x58_85_75, location: 0.4899),
                Stop(color: 0x6A_84_82, location: 0.9635),
            ]
        case .retroStorm:
            [
                Stop(color: 0x3A_7C_A1, location: 0.0564), Stop(color: 0x58_57_9A, location: 0.2638),
                Stop(color: 0x58_57_9A, location: 0.4992), Stop(color: 0x3A_7C_A1, location: 0.7312),
            ]
        case .neonNights:
            [
                Stop(color: 0x01_A8_9E, location: 0), Stop(color: 0x7D_60_BA, location: 0.5),
                Stop(color: 0xB4_38_98, location: 1),
            ]
        case .strawberryLemonade:
            [
                Stop(color: 0xAF_1A_6C, location: 0.1879), Stop(color: 0xC2_6B_20, location: 0.4976),
                Stop(color: 0xE7_A5_25, location: 0.8072),
            ]
        case .aurora:
            [
                Stop(color: 0x06_20_53, location: 0.1039), Stop(color: 0x19_1F_BB, location: 0.2687),
                Stop(color: 0x13_92_9A, location: 0.4831), Stop(color: 0x21_85_73, location: 0.6498),
                Stop(color: 0x05_1A_81, location: 0.925),
            ]
        case .sepia:
            [Stop(color: 0x85_76_64, location: 0.1414), Stop(color: 0x5B_44_21, location: 0.6035)]
        case .blurpleTwilight:
            [Stop(color: 0x2C_3F_E7, location: 0.1118), Stop(color: 0x26_1D_83, location: 0.6454)]
        }
    }

    /// The CSS angle: degrees clockwise from "to top", so 180 runs top to foot.
    /// See `GradientAxis`.
    var angle: Double {
        switch self {
        case .mintApple: 180
        case .citrusSherbert: 180
        case .retroRaincloud: 148.71
        case .hanami: 38.08
        case .sunrise: 154.19
        case .cottonCandy: 180.14
        case .lofiVibes: 179.52
        case .desertKhaki: 38.99
        case .sunset: 141.68
        case .chromaGlow: 128.92
        case .forest: 162.27
        case .crimsonMoon: 64.92
        case .midnightBlurple: 48.17
        case .mars: 170.82
        case .dusk: 180
        case .underTheSea: 179.14
        case .retroStorm: 148.71
        case .neonNights: 180
        case .strawberryLemonade: 161.03
        case .aurora: 239.16
        case .sepia: 69.98
        case .blurpleTwilight: 47.61
        }
    }

    /// The stops as a SwiftUI gradient, built once per theme for the life of the
    /// process: the window's ground asks for it on every layout pass of a live
    /// resize.
    ///
    /// The table is built from `allCases`, so the lookup cannot miss.
    var gradient: Gradient { Self.gradients[self]! }

    private static let gradients: [DiscordTheme: Gradient] = Dictionary(
        uniqueKeysWithValues: allCases.map { theme in
            (theme, Gradient(stops: theme.stops.map {
                Gradient.Stop(color: Color(hex: $0.color), location: $0.location)
            }))
        }
    )

    // MARK: The veils

    /// How much black Discord lays over the gradient under its chat — and under
    /// its member list, which uses the same surface.
    ///
    /// **80 % is the preset's, and vividness thins it the way Discord's own
    /// theme editor does.** Discord's custom themes run the same veils through
    /// a mix amount `m`: the chat's is `0.48 + 0.32·m` and a channel list's
    /// `0.45 + 0.30·m`, with `m = 1` giving exactly the presets' 80 % and 75 %
    /// and the editor's most vivid setting giving `m = 0.3`. Vividness here is
    /// that range, re-expressed so zero lands on the preset's own number
    /// exactly.
    ///
    /// **A light theme's veil is white, and its numbers are its own**: 85 % under
    /// the chat, thinned as Discord's light custom themes thin it,
    /// `0.85·(0.6 + 0.4·m)`.
    func readingVeil(vividness: Double) -> Double {
        switch base {
        case .dark: Self.veil(from: 0.80, to: 0.48 + 0.32 * 0.3, vividness: vividness)
        case .light: Self.veil(from: 0.85, to: 0.85 * (0.6 + 0.4 * 0.3), vividness: vividness)
        }
    }

    /// How much black Discord lays over the gradient under a server's channel
    /// list.
    ///
    /// **One value for the whole sidebar column, and it is the channel list's.**
    /// Discord gives its server rail the app frame's 70 % and the list beside it
    /// 75 %; this app paints the rail and the list as one field, and the list is
    /// most of that field.
    ///
    /// A light theme's channel list sits under 70 % of white, thinned as
    /// `0.42 + 0.28·m`.
    func sidebarVeil(vividness: Double) -> Double {
        switch base {
        case .dark: Self.veil(from: 0.75, to: 0.45 + 0.30 * 0.3, vividness: vividness)
        case .light: Self.veil(from: 0.70, to: 0.42 + 0.28 * 0.3, vividness: vividness)
        }
    }

    private static func veil(from preset: Double, to mostVivid: Double, vividness: Double) -> Double {
        preset - (preset - mostVivid) * min(1, max(0, vividness))
    }

    // MARK: The solid surfaces

    /// The colours the app paints with under this theme.
    ///
    /// **Each flat surface is Discord's own token, tinted exactly as Discord
    /// tints it**: its dark palette's three lowest rungs, `#121214`, `#1A1A1E`
    /// and `#202024`, each mixed with `surfaceTint` by `color-mix(in oklab, N
    /// 100%, tint 50%)`. Those are the tokens Discord paints its code blocks,
    /// attachment frames and embed cards with, rung for rung the same ladder as
    /// this app's canvas, surface and raised row.
    ///
    /// **No accent of its own.** Discord keeps its brand colour whichever theme
    /// is on — a theme recolours the room, never the controls — and the
    /// equivalent here is the reader's system accent, which is what the house
    /// theme spends.
    ///
    /// A light theme takes its own base's rungs — `#F3F3F4`, `#FBFBFB` and
    /// `#FFFFFF` — because Discord's light palette has the two lowest rungs
    /// equal, and a raised row indistinguishable from its surface is not a rung.
    ///
    /// **Packed the way a browser packs them**: clipped, not fitted. See
    /// `Oklch.clippedRGB`.
    var colors: ThemeColors {
        let tint = Oklch(packedRGB: surfaceTint)
        func tinted(_ neutral: UInt32) -> UInt32 {
            Oklch(packedRGB: neutral).mixed(with: tint, weight: Self.tintWeight).clippedRGB()
        }
        let rungs: (UInt32, UInt32, UInt32) = switch base {
        case .dark: (0x12_12_14, 0x1A_1A_1E, 0x20_20_24)
        case .light: (0xF3_F3_F4, 0xFB_FB_FB, 0xFF_FF_FF)
        }
        return ThemeColors(
            canvas: tinted(rungs.0),
            surface: tinted(rungs.1),
            surfaceRaised: tinted(rungs.2),
            accent: nil,
            appearance: base,
            textTint: textTint
        )
    }

    /// `color-mix(in oklab, N 100%, tint 50%)` as one weight on the tint.
    ///
    /// The two percentages sum past a hundred, so CSS normalises them: the tint
    /// is fifty parts in a hundred and fifty. It is a third of the mix, not half
    /// — reading the declaration as "50 %" is the natural mistake.
    static let tintWeight = 50.0 / (100 + 50)

    /// The colour Discord tints every solid surface with under this theme.
    ///
    /// Module `345815`, line for line: take the gradient's first and last stops,
    /// keep the one with the lower luminance, and take its hue at full
    /// saturation and five percent lightness. A grey — or a hue of exactly zero,
    /// which chroma.js cannot tell from "no hue" — gives way to the lighter end.
    /// That clause is live rather than defensive: Crimson Moon's far end is pure
    /// black, and its tint comes from its red.
    ///
    /// **Both adjustments go through a whole byte**, because the library Discord
    /// computes this with rounds every conversion back from HSL: saturating
    /// Sunset's `#48288C` lands on `#3A00B4`, whose hue is 259.33° rather than
    /// 259.20°, and the lightness is then set on *that*.
    ///
    /// **A light theme takes the other end**: the *lighter* stop, at full
    /// saturation and ninety percent lightness — the same function, Discord's
    /// other branch.
    var surfaceTint: UInt32 {
        let (lighter, darker) = ends
        switch base {
        case .dark: return ChromaHSL.saturated(darker, lightness: 0.05)
        case .light: return ChromaHSL.saturated(lighter, lightness: 0.9)
        }
    }

    /// The colour Discord mixes into every line of text under this theme.
    ///
    /// Module `345815`'s other output: the *lighter* end over a dark theme, the
    /// darker over a light one, at full saturation — then lightened to 95 %
    /// (or darkened to 15 %) unless the saturated hue is blue to violet,
    /// 200°–300°, where the eye reads a pale tint as white and Discord settles
    /// for 80 % (or 25 %) so the hue survives. The hue is read *after* the
    /// saturation step, off the rounded colour, as chroma.js reads it.
    var textTint: UInt32 {
        let (lighter, darker) = ends
        var saturated = ChromaHSL(base == .dark ? lighter : darker)
        saturated.saturation = 1
        var tint = ChromaHSL(saturated.packed)
        let blueToViolet = tint.hue >= 200 && tint.hue <= 300
        tint.lightness = switch base {
        case .dark: blueToViolet ? 0.8 : 0.95
        case .light: blueToViolet ? 0.25 : 0.15
        }
        return tint.packed
    }

    /// `--custom-theme-text-color-amount: 38%` as one weight on the tint: 38
    /// parts in 138, for `tintWeight`'s reason.
    static let textTintWeight = 38.0 / (100 + 38)

    /// The gradient's two ends by luminance, with Discord's one substitution
    /// made: a darker end with no usable hue gives way to the lighter.
    private var ends: (lighter: UInt32, darker: UInt32) {
        let stops = stops
        guard let first = stops.first?.color, let last = stops.last?.color else { return (0, 0) }
        let (lighter, darker) = ChromaHSL.luminance(first) > ChromaHSL.luminance(last)
            ? (first, last)
            : (last, first)
        let darkerHue = ChromaHSL(darker).hue
        return (lighter, darkerHue.isNaN || darkerHue == 0 ? lighter : darker)
    }
}

// MARK: - HSL, the way the source computes it

/// HSL exactly as chroma.js 2.4 computes it, because that is what Discord's
/// derivation runs on and two of its habits change the answer.
///
/// - **A grey has no hue**, rather than a hue of zero: `NaN`, which fails every
///   comparison it meets. Carried through as `NaN` here for the same reason.
/// - **Converting back rounds every channel to a whole byte**, so a colour that
///   goes through two adjustments carries the first one's rounding into the
///   second. See `DiscordTheme.surfaceTint`.
nonisolated struct ChromaHSL {
    /// Degrees in `0..<360`, or `NaN` for a grey.
    var hue: Double
    var saturation: Double
    var lightness: Double

    init(_ packed: UInt32) {
        let red = Double((packed >> 16) & 0xFF) / 255
        let green = Double((packed >> 8) & 0xFF) / 255
        let blue = Double(packed & 0xFF) / 255
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        lightness = (high + low) / 2
        guard high != low else {
            hue = .nan
            saturation = 0
            return
        }
        let delta = high - low
        saturation = lightness < 0.5 ? delta / (high + low) : delta / (2 - high - low)
        var degrees = if red == high {
            (green - blue) / delta
        } else if green == high {
            2 + (blue - red) / delta
        } else {
            4 + (red - green) / delta
        }
        degrees *= 60
        hue = degrees < 0 ? degrees + 360 : degrees
    }

    /// Relative luminance, as chroma.js computes it — with WCAG 2.0's `0.03928`
    /// knee rather than sRGB's `0.04045`. It only ever decides which of two
    /// colours is darker, and it decides it the way Discord's copy does.
    static func luminance(_ packed: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((packed >> shift) & 0xFF) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    /// `chroma(color).set("hsl.l", lightness)`: one step, rounded to whole
    /// bytes as chroma.js rounds it.
    static func settingLightness(_ packed: UInt32, to lightness: Double) -> UInt32 {
        var color = ChromaHSL(packed)
        color.lightness = lightness
        return color.packed
    }

    /// `chroma(color).set("hsl.s", 1).set("hsl.l", lightness)`: two steps, and
    /// the first one's rounding carries into the second — see
    /// `DiscordTheme.surfaceTint`.
    static func saturated(_ packed: UInt32, lightness: Double) -> UInt32 {
        var color = ChromaHSL(packed)
        color.saturation = 1
        return settingLightness(color.packed, to: lightness)
    }

    /// Back to 24-bit sRGB, rounding each channel the way chroma.js does.
    var packed: UInt32 {
        let channels: [Double]
        if saturation == 0 {
            channels = [lightness, lightness, lightness]
        } else {
            let upper = lightness < 0.5
                ? lightness * (1 + saturation)
                : lightness + saturation - lightness * saturation
            let lower = 2 * lightness - upper
            let turn = hue / 360
            channels = [turn + 1.0 / 3, turn, turn - 1.0 / 3].map { raw in
                var position = raw
                if position < 0 { position += 1 }
                if position > 1 { position -= 1 }
                if 6 * position < 1 { return lower + (upper - lower) * 6 * position }
                if 2 * position < 1 { return upper }
                if 3 * position < 2 { return lower + (upper - lower) * (2.0 / 3 - position) * 6 }
                return lower
            }
        }
        return channels.reduce(0) { packed, channel in
            packed << 8 | UInt32(min(255, max(0, (channel * 255).rounded())))
        }
    }
}
