import CoreGraphics
import Foundation

/// The face a styled display name is set in.
///
/// **The raw values are Discord's font ids, and they are NOT the order the
/// picker shows.** The picker leads with gg sans and Tempo; the ids run in the
/// order the fonts shipped, and four of them — 2, 5, 9 and 11 — are unassigned.
/// Twelve faces across a 1-16 range is why this is an enum with holes rather
/// than an index into an array: a lookup by position draws the wrong face the
/// day Discord fills one in, and one that force-unwraps crashes on it.
///
/// Each case names a **PostScript** name rather than a family. Six of the files
/// carry the weight in their family string — `MuseoModerno SemiBold`,
/// `Orbitron SemiBold` — so family matching misbehaves, and Medieval's family is
/// `Néo-castel :-)`, non-ASCII with a smiley in it.
public enum DisplayNameFont: Int, Hashable, Sendable, Codable, CaseIterable {
    /// The app's own face. `font_id: 1` means "no custom font", not "bundle
    /// Discord's" — gg sans is licensed to Discord and is not ours to ship.
    case `default` = 1
    case sakura = 3
    case jellybean = 4
    case modern = 6
    case medieval = 7
    case eightBit = 8
    case vampyre = 10
    case tempo = 12
    case monkeyBars = 13
    case mainframe = 14
    case headbang = 15
    case journal = 16

    /// What the picker calls it, and what a hover tooltip says.
    ///
    /// Discord's own names, from their chooser. `default` is gg sans, which this
    /// app does not ship and does not name as though it did — see the case's own
    /// note.
    public var title: String {
        switch self {
        case .default: "Default"
        case .sakura: "Sakura"
        case .jellybean: "Jellybean"
        case .modern: "Modern"
        case .medieval: "Medieval"
        case .eightBit: "8-Bit"
        case .vampyre: "Vampyre"
        case .tempo: "Tempo"
        case .monkeyBars: "Monkey Bars"
        case .mainframe: "Mainframe"
        case .headbang: "Headbang"
        case .journal: "Journal"
        }
    }

    /// The PostScript name inside the bundled file. Nil for `.default`, which
    /// resolves to the system face.
    public var postScriptName: String? {
        switch self {
        case .default: nil
        case .sakura: "CherryBombOne-Regular"
        case .jellybean: "Chicle-Regular"
        case .modern: "MuseoModerno-Medium"
        case .medieval: "Neo-castel-:-"
        case .eightBit: "PixelifySans-Regular"
        case .vampyre: "Sinistre-Regular"
        case .tempo: "ZillaSlab-SemiBold"
        case .monkeyBars: "PlaypenSans-Bold"
        case .mainframe: "Orbitron-Bold"
        case .headbang: "NewRocker-Regular"
        case .journal: "Kalam-Bold"
        }
    }

    /// The file this face ships in, without its extension.
    ///
    /// Kept apart from `postScriptName` because they genuinely differ — the file
    /// is `Neo-castel`, the PostScript name is `Neo-castel-:-` — and because
    /// registration looks one up and lookup uses the other.
    public var fileName: String? {
        switch self {
        case .default: nil
        case .medieval: "Neo-castel"
        default: postScriptName
        }
    }

    /// Extra tracking Discord applies to this face, in ems.
    ///
    /// **Part of the design, not a nicety.** These are per-family corrections in
    /// Discord's own stylesheet; a name set without them reads as too tight in
    /// the display faces that carry one.
    public var letterSpacing: CGFloat {
        switch self {
        case .sakura: 0.04
        case .tempo, .mainframe: 0.03
        case .medieval, .eightBit: 0.02
        case .modern, .vampyre: 0.01
        case .default, .jellybean, .monkeyBars, .headbang, .journal: 0
        }
    }

    /// Whether this face sits a point low on a Core Text baseline.
    ///
    /// Discord nudges exactly these two by `translateY(-1px)` **under WebKit**,
    /// and leaves them alone under Blink. macOS is the same text stack Safari
    /// draws with, so the WebKit branch is the one that applies here — the
    /// correction is for how Core Text places these faces, not for a browser.
    public var liftsBaseline: Bool {
        switch self {
        case .sakura, .medieval: true
        default: false
        }
    }
}

/// The effect a styled display name is painted with.
///
/// **Raw values are Discord's own ids, and they are NOT the picker's order.**
/// This enum used to say they were — "1-indexed in the order the picker shows
/// them, which for effects is also the id order" — and that sentence was a
/// guess written as a fact. `id 6` is `GLOW`, which the picker does not offer;
/// Gummy is **8**. So every account whose Gummy arrived from Discord decoded as
/// id 6, missed the enum entirely and fell back to Solid: one flat colour, no
/// animation, for as long as this type has existed.
///
/// It was invisible from inside the app because the *editor* builds a style
/// locally and never round-trips the wire, so the picker's own preview animated
/// correctly while no real account ever did. Worse, saving Gummy wrote id 6 and
/// set the account's effect to Glow.
///
/// Read off Discord's own bundle — `[SOLID, GRADIENT, NEON, TOON, POP]` and
/// `[GUMMY, PRISM]` are the two groups the picker concatenates — and confirmed
/// against `docs.discord.food`'s table, which additionally documents
/// `1001…1004` as `TEST_1…TEST_4`, all of which fall back to Solid.
public enum DisplayNameEffect: Int, Hashable, Sendable, Codable, CaseIterable {
    case solid = 1
    case gradient = 2
    case neon = 3
    case toon = 4
    case pop = 5
    /// **Not offered by the picker, and it has to exist anyway.** Discord's
    /// documentation says it "falls back to gradient", and its own bundle
    /// groups it with Gradient when handing out preset palettes. An account
    /// wearing it is a real account; leaving the case out would flatten them to
    /// Solid the way Gummy was flattened.
    case glow = 6
    case prism = 7
    case gummy = 8

    /// What the picker calls it. Discord's own names.
    public var title: String {
        switch self {
        case .solid: "Solid"
        case .gradient: "Gradient"
        case .neon: "Neon"
        case .toon: "Toon"
        case .pop: "Pop"
        case .glow: "Glow"
        case .prism: "Prism"
        case .gummy: "Gummy"
        }
    }

    /// The effects a reader may choose, in Discord's own order.
    ///
    /// **Not `allCases`, and the difference is Glow.** Discord's picker
    /// concatenates two groups and Glow is in neither — it is a legacy id that
    /// still arrives on the wire. Offering it would let somebody select an
    /// effect Discord's own client cannot; leaving it out of the enum would
    /// flatten everyone already wearing it.
    public static let offered: [DisplayNameEffect] = [
        .solid, .gradient, .neon, .toon, .pop, .gummy, .prism,
    ]

    /// Whether this is painted as something else.
    ///
    /// Glow is the only one, and Discord's own renderer does the same: its
    /// preset-palette table groups `GRADIENT` and `GLOW` under one case.
    public var painted: DisplayNameEffect {
        self == .glow ? .gradient : self
    }

    /// How many colours this effect is chosen with, confirmed against the wells
    /// each picker draws.
    ///
    /// **Solid's answer is 1 and its payload may still be empty**, which is a
    /// real state rather than a malformed one — see `DisplayNameStyle.colors`.
    /// Everything else derives its whole palette from `colors[0]`.
    public var colorCount: Int {
        switch self {
        case .solid, .neon, .toon, .pop: 1
        case .gradient, .glow: 2
        case .gummy: 4
        case .prism: 5
        }
    }

    /// Whether this effect moves at all. Solid and Gradient are static, and
    /// knowing that up front is what lets the renderer skip building an
    /// animation it would only add and never run.
    public var isAnimated: Bool {
        switch self {
        // Glow is drawn as a gradient, so it stands as still as one.
        case .solid, .gradient, .glow: false
        case .neon, .toon, .pop, .gummy, .prism: true
        }
    }
}

/// How an account has chosen to have its display name drawn.
///
/// `user.display_name_styles` is `{font_id, effect_id, colors}`. All three parts
/// are independent: a font with no effect, an effect in the default face, or
/// both. **Nil is not the same as `.solid` with no colours** — nil means the
/// account set nothing and the name is drawn by the ordinary label.
public struct DisplayNameStyle: Hashable, Sendable, Codable {
    public let font: DisplayNameFont
    public let effect: DisplayNameEffect
    /// The chosen colours, as 24-bit RGB, in the order the picker holds them.
    ///
    /// **Empty is a real state and must not be filled in.** Discord's own save
    /// path writes `[]` when the effect is Solid and the chosen colour is the
    /// default, meaning "styled font, default colour". A renderer that requires
    /// `colors[0]` draws nothing at all for those accounts.
    public let colors: [UInt32]

    public init(font: DisplayNameFont, effect: DisplayNameEffect, colors: [UInt32]) {
        self.font = font
        self.effect = effect
        self.colors = colors
    }

    /// Whether there is anything here worth drawing differently.
    ///
    /// The default face with a Solid effect and no colours is what an account
    /// that has touched the picker and changed nothing looks like, and it is
    /// indistinguishable from having no style at all. Answering that here keeps
    /// every surface from having to know it.
    public var isPlain: Bool {
        font == .default && effect == .solid && colors.isEmpty
    }

    /// The palette every derived shade comes from, or nil when the account chose
    /// no colour. Resolved once by the caller and never inside a draw.
    public var palette: DisplayNamePalette? {
        colors.first.map(DisplayNamePalette.init(main:))
    }
}
