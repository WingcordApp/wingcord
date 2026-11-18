import Foundation
import WingcordCore

// MARK: - A server's own theme
//
// What a server with the `GUILD_THEME` feature asks a member's window to look
// like while they are in it — read out of Discord's web bundle, not fitted to
// the red of one server's screenshot:
//
//  - **Its presets** (module `476931`): ten of them, **not** the reader's
//    twenty-two — Twilight, Plum, Fire, Gold Dust, Moss, Jade, Obsidian, Ocean,
//    Denim and Blurple — each two colours with a dark and a light version.
//  - **One colour expanded into two** (the same module's `kI`), for a server
//    that chose its own.
//  - **The generator** (module `153469`'s `dY`): the variables Discord's
//    `custom-client-theme` stylesheet rules (`419070`, `952007`) read — how
//    thick the veils are, how much of a base colour goes into every surface,
//    and the text tint.
//
// Every number is pinned by `ServerThemeTests` against Discord's own modules
// run in Node on its own chroma.js — which is how one of them was caught the
// wrong way round, see `baseAmount`.

/// A server's theme, resolved for the reader's room.
nonisolated struct ServerTheme: Equatable, Sendable {
    /// The gradient's two colours, first to last, spread evenly along the line.
    var stops: [UInt32]
    /// CSS degrees; see `GradientAxis`. A preset's is 0, which runs up.
    var angle: Double
    /// Discord's `base_mix`, `0...100`: how far the ground comes forward.
    var baseMix: Double
    /// The reader's room. A server theme has a version for each and never
    /// changes which one the reader is in.
    var room: ThemeAppearance

    /// Nil where the server's theme draws nothing — see `GuildTheme.resolved`.
    init?(_ theme: GuildTheme, room: ThemeAppearance) {
        switch theme.resolved {
        case .preset(let id)?:
            guard let preset = Self.presets[id] else { return nil }
            let version = room == .light ? preset.light : preset.dark
            stops = [version.from, version.to]
            angle = 0
            baseMix = version.baseMix
        case .custom(let color, let angle, let baseMix)?:
            stops = Self.expanded(color, room: room)
            self.angle = angle
            self.baseMix = baseMix
        case nil:
            return nil
        }
        self.room = room
    }

    /// A custom theme somebody shared — the same generator, fed from the share:
    /// its colours, angle and mix, **and its own room**, which Discord's
    /// Preview switches the window to (`tR` sets the base theme it carries).
    init(shared theme: SharedClientTheme) {
        stops = theme.gradientStops
        angle = theme.gradientAngle
        baseMix = theme.baseMix
        room = theme.isLight ? .light : .dark
    }

    // MARK: The generator, `dY`

    /// `100 − base_mix`: how far the theme stands back.
    private var standBack: Double { 100 - baseMix }

    /// `--custom-background-gradient-opacity-mix-amount`, **as the string
    /// Discord writes it**: `toFixed(2)`, so the veils are computed from the
    /// rounded value.
    var veilMix: Double { Self.twoPlaces((30 + 0.7 * standBack) / 100) }

    /// The veil over the page — Discord's chat surface under a
    /// `custom-client-theme`: `0.48 + 0.32·m` dark, and a light room's own
    /// `0.95·(0.6 + 0.4·m)`, whose 0.95 is the base the generator sets.
    ///
    /// In a dark room it never goes below `InkContrast.legibleVeil` for the
    /// server's colours: a server's bright pick does not get to wash out the
    /// reader's text (Alex, 2026-11-18).
    var pageVeil: Double {
        room == .light
            ? 0.95 * (0.6 + 0.4 * veilMix)
            : max(0.48 + 0.32 * veilMix, InkContrast.legibleVeil(over: stops))
    }

    /// The veil over the sidebar — Discord's channel list, `high`: `0.45 +
    /// 0.30·m` dark and `0.42 + 0.28·m` light. The rail's own lighter veil is
    /// not drawn, for `DiscordTheme.sidebarVeil`'s reason.
    var frameVeil: Double {
        room == .light
            ? 0.42 + 0.28 * veilMix
            : max(0.45 + 0.30 * veilMix, InkContrast.legibleVeil(over: stops))
    }

    /// How much of `baseColor` goes into every solid surface, in percent.
    ///
    /// **The dark room's is the larger one.** The generator branches on a
    /// helper (`M`, module `462887`) that answers *is dark* — true for Discord's
    /// three dark themes, `dark`, `darker` and `midnight` — so its first branch
    /// is the dark room's. Read without running, it was ported the other way
    /// round; run in Node it gives a dark Twilight 60 % and a light Jade 20 %.
    var baseAmount: Double {
        room == .light ? 30 - 0.2 * baseMix : 60 + 0.4 * standBack
    }

    /// The same, for the text tint — 30 % dark, 40 % light.
    var textAmount: Double { room == .light ? 40 : 30 }

    /// The colour every solid surface is mixed with: the darker stop at full
    /// saturation and 5 % lightness in a dark room, the lighter at 90 % in a
    /// light one.
    var baseColor: UInt32 {
        room == .light
            ? ChromaHSL.saturated(ends.lightest, lightness: 0.9)
            : ChromaHSL.saturated(ends.darkest, lightness: 0.05)
    }

    /// The colour mixed into text. **The darker stop in a dark room**, raised
    /// to between 90 and 100 % lightness — white at a `base_mix` of 100 —
    /// and the lighter one lowered to within 5 % of black in a light room.
    /// Neither is saturated first, unlike the preset tint.
    var textColor: UInt32 {
        room == .light
            ? ChromaHSL.settingLightness(ends.lightest, to: Self.twoPlaces(0.05 * standBack / 100))
            : ChromaHSL.settingLightness(ends.darkest, to: Self.twoPlaces((100 - 0.1 * standBack) / 100))
    }

    /// The colours the app paints with while this theme is on — Discord's own
    /// three rungs mixed with `baseColor`, as `DiscordTheme.colors` mixes them,
    /// at this theme's amount.
    var colors: ThemeColors {
        let base = Oklch(packedRGB: baseColor)
        let weight = Self.weight(baseAmount)
        func tinted(_ neutral: UInt32) -> UInt32 {
            Oklch(packedRGB: neutral).mixed(with: base, weight: weight).clippedRGB()
        }
        let rungs: (UInt32, UInt32, UInt32) = switch room {
        case .dark: (0x12_12_14, 0x1A_1A_1E, 0x20_20_24)
        case .light: (0xF3_F3_F4, 0xFB_FB_FB, 0xFF_FF_FF)
        }
        return ThemeColors(
            canvas: tinted(rungs.0),
            surface: tinted(rungs.1),
            surfaceRaised: tinted(rungs.2),
            accent: nil,
            appearance: room,
            textTint: textColor,
            textTintWeight: Self.weight(textAmount)
        )
    }

    /// `color-mix(in oklab, X 100%, tint N%)` as one weight on the tint — CSS
    /// normalises percentages that sum past a hundred. See
    /// `DiscordTheme.tintWeight`.
    static func weight(_ percent: Double) -> Double { percent / (100 + percent) }

    /// The stops by luminance, as the generator picks them: the **first**
    /// darkest and the first lightest, so two stops of one luminance are one
    /// colour twice.
    var ends: (darkest: UInt32, lightest: UInt32) {
        let luminances = stops.map(ChromaHSL.luminance)
        guard let low = luminances.min(), let high = luminances.max(),
              let darkest = luminances.firstIndex(of: low),
              let lightest = luminances.firstIndex(of: high)
        else { return (0, 0) }
        return (stops[darkest], stops[lightest])
    }

    /// JavaScript's `toFixed(2)`, read back as a number.
    private static func twoPlaces(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    // MARK: One colour, `kI`

    /// A server's own colour as the two stops of its gradient: brought into
    /// the room's range of lightness — 15 to 35 % dark, 55 to 75 % light, in
    /// proportion to where it sat between 15 and 75 — then a second stop 20 %
    /// darker in a dark room or lighter in a light one.
    static func expanded(_ color: UInt32, room: ThemeAppearance) -> [UInt32] {
        let (lowest, highest) = (15.0, 75.0)
        let range: (low: Double, high: Double) = room == .light ? (55, 75) : (15, 35)
        let tone = min(highest, max(lowest, 100 * ChromaHSL(color).lightness))
        let placed = ChromaHSL.settingLightness(
            color,
            to: (range.low + (tone - lowest) / (highest - lowest) * (range.high - range.low)) / 100
        )
        let step = room == .light ? 0.2 : -0.2
        let second = ChromaHSL.settingLightness(
            placed,
            to: min(1, max(0, ChromaHSL(placed).lightness + step))
        )
        return [placed, second]
    }

    // MARK: The presets

    /// One version of a preset: its two colours and its mix.
    struct Version: Sendable {
        var from: UInt32
        var to: UInt32
        var baseMix: Double
    }

    /// Each preset's name, by its id — Discord's own words for them
    /// (`976665`).
    static let presetNames: [Int: String] = [
        1: "Twilight", 2: "Plum", 3: "Fire", 4: "Gold Dust", 5: "Moss",
        6: "Jade", 7: "Obsidian", 8: "Ocean", 9: "Denim", 10: "Blurple",
    ]

    /// The order Discord's picker lays them out in (`476931`'s `E`), which is
    /// not the order of their ids. The first is what switching a theme on
    /// with nothing chosen selects (`Qy`).
    static let pickerOrder = [1, 9, 8, 10, 7, 2, 3, 4, 5, 6]

    /// A new custom theme's colour and intensity — Discord's `a0` and `BC`.
    static let defaultCustomColor: UInt32 = 0x58_65_F2
    static let defaultCustomBaseMix: Double = 74

    /// Discord's ten, by its own ids.
    static let presets: [Int: (dark: Version, light: Version)] = [
        1: (Version(from: 0x69_42_6A, to: 0x11_17_31, baseMix: 100),   // Twilight
            Version(from: 0xFA_9E_FF, to: 0x5A_7E_FE, baseMix: 100)),
        2: (Version(from: 0x8A_3F_7F, to: 0x2C_0D_25, baseMix: 100),   // Plum
            Version(from: 0xE8_93_FF, to: 0xFF_AD_DC, baseMix: 100)),
        3: (Version(from: 0x9B_2C_2C, to: 0x2A_0C_0C, baseMix: 50),    // Fire
            Version(from: 0xFF_EB_CA, to: 0xFF_89_89, baseMix: 50)),
        4: (Version(from: 0x6C_52_3D, to: 0x24_19_12, baseMix: 50),    // Gold Dust
            Version(from: 0xFF_E7_DA, to: 0xFF_D8_9B, baseMix: 50)),
        5: (Version(from: 0x58_69_4E, to: 0x22_2A_1C, baseMix: 50),    // Moss
            Version(from: 0xB7_D1_9F, to: 0xB1_DC_A4, baseMix: 50)),
        6: (Version(from: 0x29_70_71, to: 0x18_20_3F, baseMix: 50),    // Jade
            Version(from: 0xC5_F0_D2, to: 0x60_AD_B2, baseMix: 50)),
        7: (Version(from: 0x5E_4C_85, to: 0x1E_17_40, baseMix: 100),   // Obsidian
            Version(from: 0xB5_9D_F2, to: 0x8F_89_D2, baseMix: 100)),
        8: (Version(from: 0x24_5B_92, to: 0x14_1D_40, baseMix: 100),   // Ocean
            Version(from: 0x9A_DB_F7, to: 0x2D_3C_CA, baseMix: 100)),
        9: (Version(from: 0x53_59_AD, to: 0x12_12_38, baseMix: 100),   // Denim
            Version(from: 0xDB_DB_FF, to: 0x60_60_FF, baseMix: 100)),
        10: (Version(from: 0x53_3D_9E, to: 0x1A_10_35, baseMix: 100),  // Blurple
             Version(from: 0xC3_BF_FF, to: 0x81_6B_DC, baseMix: 100)),
    ]
}

/// The server theme in effect: whose, so the ground fades going into and out of
/// it, and what.
struct ActiveServerTheme: Equatable, Sendable {
    var guildID: GuildID
    var theme: GuildTheme
}
