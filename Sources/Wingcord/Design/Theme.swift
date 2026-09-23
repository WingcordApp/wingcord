import Foundation

// MARK: - What a theme is, and what it deliberately is not
//
// `Tokens.swift` used to open with "one theme: True Black. There is deliberately
// no theme system." This is the second decision that note asked for, and it is
// scoped so that the first one survives it:
//
//  - **A theme colours the GROUND and the accent. Nothing else.** The reading
//    surface, the panels on it, the rows inside those panels, and the one
//    colour the app spends on a primary control. Presence dots, unread badges,
//    role colours, avatars and every other pixel that came from a person are
//    untouched — they mean something, and a theme that recoloured them would be
//    editing content rather than chrome.
//  - **The relative fills stay relative.** A hover is still white at 7%, a
//    selection still white at 15%. They are the surface *plus light*, which is
//    the only definition that survives the system glass-intensity setting,
//    Reduce Transparency, and a wallpaper showing through the sidebar column.
//    Baking a theme colour into them would break all three.
//  - **True Black is stated, not derived.** It is the app's measured house
//    palette and the default, so it must come out bit-for-bit as it always has.
//    Porcelain, the light room, is stated too: the ramp below is built for a
//    dark ground and cannot reach a light one. The other nine themes and
//    anything the reader builds are derived; those two are literal triples, and
//    the tests pin them.
//
// THE RAMP IS THE INVARIANT. Every derived theme uses the same three Oklab
// lightness steps, so the separation between the reading surface, a card on it
// and a row inside that card is *identical* at every hue. That is the whole
// reason these read as one set: choosing a hue is a choice, never a retune.

/// One end of a theme's ground: a hue, and how much of it the ground carries.
///
/// Two of these make a theme. **They are the two ends of the window's light** —
/// `head` is the dark top-leading corner, behind the toolbar, and `foot` the lit
/// bottom-trailing one, behind the composer. A theme with one colour is a
/// coloured rectangle; a theme with two is a room.
nonisolated struct ThemeStop: Hashable, Sendable {
    /// Oklab hue in degrees, wrapped into `0..<360`.
    var hue: Double
    /// How much colour this end carries, `0...1`. Zero is a true grey.
    var depth: Double

    init(hue: Double, depth: Double) {
        self.hue = ThemeSeed.wrap(hue)
        self.depth = min(1, max(0, depth))
    }
}

/// The numbers a theme is made of: two to five stops, one lightness, one
/// accent, one angle.
///
/// A seed rather than a list of colours, for three reasons that all matter:
/// it is what the picker manipulates, it is what persists (a handful of doubles
/// instead of a palette), and it is what guarantees a theme somebody built
/// cannot be structurally different from one that shipped.
///
/// **One lightness for both stops, and that is deliberate.** The gap between the
/// head and the foot is `washRise` and it is fixed, because it is
/// the *window's* sense of depth rather than the theme's — a reader who could
/// set both ends independently could invert it, and an app lit from below reads
/// as broken rather than as themed. What the two stops choose is colour.
nonisolated struct ThemeSeed: Hashable, Sendable {
    /// Behind the toolbar — the darker end, and the theme's stated colour.
    var head: ThemeStop
    /// The colours the walk passes through between the two ends, in order:
    /// none to `maximumMiddle`, so a theme is two to five colours. Evenly
    /// spaced along the line, the way the ends are.
    var middle: [ThemeStop]
    /// Behind the composer — the lit end, and the one the accent comes from.
    var foot: ThemeStop
    /// How bright the ground is overall, `0...1`.
    var light: Double
    /// Where the accent sits relative to the **foot**, in turns of the wheel.
    /// `0` is that stop's own hue; `0.5` is its opposite.
    var accentTurn: Double
    /// The line the field runs along, in CSS degrees. `fieldAngle` for every
    /// preset; the reader's own blend may turn it.
    var angle: Double
    /// How far the reader has asked the ground to come forward, `0...1`: more
    /// colour, more light, a stronger glow. See `vividLift`.
    ///
    /// **The reader's, not the seed's** — it is one setting applied to
    /// whichever theme is on — so it is not part of `storageValue`, and the
    /// store sets it on every seed it resolves.
    var vividness = 0.0

    init(
        head: ThemeStop,
        middle: [ThemeStop] = [],
        foot: ThemeStop,
        light: Double,
        accentTurn: Double = 0,
        angle: Double = ThemeSeed.fieldAngle
    ) {
        self.head = head
        self.middle = Array(middle.prefix(Self.maximumMiddle))
        self.foot = foot
        self.light = min(1, max(0, light))
        // Wrapped rather than clamped: a turn is circular, so −0.1 and 0.9 are
        // the same accent and clamping one of them to zero would silently
        // change the answer.
        self.accentTurn = accentTurn - (accentTurn.rounded(.down))
        self.angle = Self.wrap(angle)
    }

    /// Five colours at most: a walk with more turns than that in a window's
    /// width is a rainbow, not a room.
    static let maximumMiddle = 3

    /// Every stop in walk order, head first.
    var anchors: [ThemeStop] { [head] + middle + [foot] }

    /// Replaces the stop at `index` in walk order.
    mutating func setAnchor(_ index: Int, to stop: ThemeStop) {
        if index == 0 {
            head = stop
        } else if index == middle.count + 1 {
            foot = stop
        } else if middle.indices.contains(index - 1) {
            middle[index - 1] = stop
        }
    }

    /// Where the stop at `index` sits along the line, `0...1`.
    func position(ofAnchor index: Int) -> Double {
        Double(index) / Double(middle.count + 1)
    }

    /// The same seed with every clamp and wrap applied again — for a value a
    /// caller mutated in place, which bypasses the initialisers.
    var normalized: ThemeSeed {
        var seed = ThemeSeed(
            head: ThemeStop(hue: head.hue, depth: head.depth),
            middle: middle.map { ThemeStop(hue: $0.hue, depth: $0.depth) },
            foot: ThemeStop(hue: foot.hue, depth: foot.depth),
            light: light,
            accentTurn: accentTurn,
            angle: angle
        )
        seed.vividness = min(1, max(0, vividness))
        return seed
    }

    /// This seed at the reader's vividness.
    func at(vividness: Double) -> ThemeSeed {
        var seed = self
        seed.vividness = min(1, max(0, vividness))
        return seed
    }

    /// The one-colour form, for a theme whose two ends are the same hue.
    init(hue: Double, depth: Double, light: Double, accentTurn: Double = 0) {
        self.init(
            head: ThemeStop(hue: hue, depth: depth),
            foot: ThemeStop(hue: hue, depth: depth),
            light: light,
            accentTurn: accentTurn
        )
    }

    static func wrap(_ hue: Double) -> Double {
        let wrapped = hue.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    /// Interpolates between two hues **the short way round**.
    ///
    /// Lerping the raw degrees is the bug this exists to prevent: 350 and 10 are
    /// twenty degrees apart, and the naïve midpoint of them is 180 — which is
    /// cyan, on the far side of the wheel from either end. A theme built out of
    /// a red head and a red foot would come out with cyan cards in it.
    static func mixHue(_ from: Double, _ to: Double, _ t: Double) -> Double {
        var delta = wrap(to) - wrap(from)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return wrap(wrap(from) + delta * t)
    }

    // MARK: The ramp
    //
    // Read off the house palette rather than invented: #0A0A0C, #141417 and
    // #1C1C20 sit at Oklab L 0.1457, 0.1926 and 0.2282. Those two gaps ARE the
    // app's sense of depth, and every derived theme reuses them exactly.

    /// The reading surface's lightness at `light`.
    ///
    /// The range stops well short of the middle on purpose. This is a dark app —
    /// its glass, its ink hierarchy and its drawn transcript are all tuned
    /// against a dark ground — and a "theme" that walked the canvas to mid-grey
    /// would not be a theme, it would be a half-finished light mode. 0.25 is a
    /// lifted graphite and is as far as the vocabulary goes.
    static let darkestGround = 0.100
    static let lightestGround = 0.250

    /// The gap from the reading surface to a panel on it, and to a row inside
    /// that panel.
    static let surfaceStep = 0.0469
    static let raisedStep = 0.0825

    /// The most colour a ground may carry at full depth.
    ///
    /// Measured against a reference rather than chosen: a themed client's violet
    /// ground reads Oklab C 0.035 at the foot of its window and 0.071 at the
    /// top, at L 0.175 and 0.276. Since chroma here scales with the ramp, 0.060
    /// at the ground reaches almost exactly that pair at full depth — which is
    /// as far as this vocabulary goes. Past it the canvas stops being a dark
    /// surface with a cast and starts being a coloured panel, at which point the
    /// transcript is read over a hue and every role colour on it shifts.
    static let maximumGroundChroma = 0.060

    /// Where an accent sits. Bright enough to be a control on a dark ground,
    /// colourful enough to be the one saturated thing in the chrome.
    static let accentLightness = 0.740
    static let accentChroma = 0.160

    var groundLightness: Double {
        Self.darkestGround + light * (Self.lightestGround - Self.darkestGround)
            + vividness * Self.vividLift
    }

    // MARK: Vividness
    //
    // The ramp above is the calm end of the range, and it stays the default.
    // Vividness walks the whole ramp forward from there toward the brighter,
    // more colourful grounds a reference client ships — L 0.25–0.36 at chroma
    // near 0.08 — without changing a single one of its steps: a card is still a
    // card's height above the ground at every setting.

    /// How far the whole ramp is lifted at full vividness: about a ramp step.
    static let vividLift = 0.050

    /// How much more colour the ground may carry at full vividness.
    static let vividChroma = 0.035

    /// The corner light's strength, calm to vivid.
    var glowStrength: Double { 0.28 + vividness * 0.12 }

    /// Chroma for a stop at a given step of the ramp.
    ///
    /// **It grows with lightness, and the house palette is why.** #0A0A0C,
    /// #141417 and #1C1C20 carry chroma 0.0043, 0.0060 and 0.0077 — a lighter
    /// step of the same surface holds proportionally more colour, because that
    /// is what happens when a near-black is lifted rather than repainted. A ramp
    /// with one flat chroma reads as three unrelated colours stacked.
    func chroma(depth: Double, atLightness lightness: Double) -> Double {
        let ground = groundLightness
        guard ground > 0 else { return 0 }
        let ceiling = Self.maximumGroundChroma + vividness * Self.vividChroma
        return depth * ceiling * (lightness / ground)
    }

    /// The brightest ground on the page a line of coloured type can land on:
    /// the lit end, with the corner light at full strength over it.
    ///
    /// Conservative on purpose. The light peaks in one corner, but a name in
    /// the roster sits exactly there, and a colour checked against anywhere
    /// dimmer would fail in the one place the reader is looking.
    var inkCeiling: UInt32 {
        InkContrast.composite(glow.packedRGB(), over: canvasLit.packedRGB(), opacity: glowStrength)
    }

    /// How much lighter the foot of the window is than its head.
    ///
    /// Half again a ramp step, which is a *lot* — and it is measured rather than
    /// chosen: the reference this was checked against runs L 0.175 at one end
    /// of its window to 0.276 at the other, which is more than two steps. A wash
    /// any gentler than this is invisible on a window seven hundred points tall,
    /// which is exactly what the first attempt here was.
    ///
    /// **The light is at the foot, and that is measured rather than chosen.**
    /// Both of the clients this was checked against put the saturated, lit end
    /// of a theme down where the composer is: the top of a chat window is
    /// chrome, and the bottom is where somebody is actually typing.
    static let washRise = surfaceStep * 1.5

    /// The ground in the window's top-leading corner — the theme's stated
    /// colour, and the darker of its two ends. `Palette.canvas`.
    var canvas: Oklch { field(at: 0) }

    /// The ground in the window's bottom-trailing corner, behind the composer:
    /// the lit end.
    var canvasLit: Oklch { field(at: 1) }

    // MARK: The field

    /// The angle every house theme's field is laid at — CSS degrees, clockwise
    /// from "to top". See `GradientAxis`.
    ///
    /// **A diagonal that is still mostly a fall.** The head sits in the window's
    /// top-leading corner and the foot in its bottom-trailing one, behind the
    /// composer, where the light has always been; the lean is what lets a hue
    /// travel *across* the window instead of stacking in bands. One angle for
    /// all of them, for the ramp's reason: choosing a hue is a choice, never a
    /// retune.
    static let fieldAngle = 150.0

    /// A point on the walk from the head to the foot, `t` of the way along it.
    ///
    /// **Walked in Oklch, and that is what lets the two ends sit far apart.** A
    /// straight line through RGB between two hues a quarter of the wheel apart
    /// passes through grey in the middle — the seam that used to hold every
    /// theme's ends within fifty degrees of each other. Here the hue turns the
    /// short way round and depth and lightness move in straight lines, so the
    /// middle of the walk is the hue between the ends at the same colourfulness.
    func field(at t: Double) -> Oklch {
        let lightness = groundLightness + Self.washRise * t
        let stop = stop(at: t)
        return Oklch(
            lightness: lightness,
            chroma: chroma(depth: stop.depth, atLightness: lightness),
            hue: stop.hue
        )
    }

    /// The hue and depth `t` of the way along the walk, through every stop.
    ///
    /// **Stop to stop, each leg the short way round.** Lightness is not a stop's
    /// to choose — it rises across the whole line by `washRise` — so this is
    /// only the colour, and `field(at:)` lights it.
    func stop(at t: Double) -> ThemeStop {
        let anchors = anchors
        let legs = Double(anchors.count - 1)
        let along = min(1, max(0, t)) * legs
        let leg = min(Int(along), anchors.count - 2)
        let from = anchors[leg]
        let to = anchors[leg + 1]
        let u = along - Double(leg)
        return ThemeStop(
            hue: Self.mixHue(from.hue, to.hue, u),
            depth: from.depth + (to.depth - from.depth) * u
        )
    }

    /// The same point in the **frame** — the sidebar column.
    ///
    /// **The frame carries the colour, and the page stays calm.** That is
    /// Discord's arrangement, read out of its stylesheet: its channel list shows
    /// a quarter of the gradient where its chat shows a fifth. The page is where
    /// the reading happens, so it keeps the ramp's quiet ground; the column of
    /// contents beside it is where a theme can afford to be seen. It replaces a
    /// recess that ran the other way — six percent of black — and made the one
    /// region nobody reads for long the darkest part of the room.
    func frame(at t: Double) -> Oklch {
        let page = field(at: t)
        return Oklch(
            lightness: page.lightness + Self.frameLift,
            chroma: page.chroma * Self.frameChroma,
            hue: page.hue
        )
    }

    /// How much lighter the frame is than the page beside it: under half a ramp
    /// step, so the two read as one room lit unevenly rather than as two grounds.
    static let frameLift = 0.022

    /// How much more colour the frame carries than the page.
    static let frameChroma = 1.35

    /// The light in the window's bottom-trailing corner: the foot's hue, lifted
    /// well clear of the ground and carrying more colour than it.
    ///
    /// A picture of light rather than a second colour, so it takes the foot's
    /// depth too — Graphite's is a grey glow, and a theme with a faint foot has
    /// a faint light.
    var glow: Oklch {
        let lit = canvasLit
        return Oklch(
            lightness: lit.lightness + Self.glowRise,
            chroma: foot.depth * Self.glowChroma,
            hue: lit.hue
        )
    }

    static let glowRise = 0.20
    static let glowChroma = 0.14

    /// Where a panel and a row inside it sit along the walk.
    ///
    /// **Halfway, and it has to be.** A card is drawn at every height of the
    /// window — a settings card near the toolbar, an embed halfway down, a
    /// reaction chip beside the composer — so a card that belonged to one end
    /// would be visibly the wrong colour at the other. Taking the midpoint means
    /// it is a little wrong everywhere instead of very wrong somewhere, which is
    /// the trade every shared surface in a many-toned room makes.
    private var midStop: ThemeStop { stop(at: 0.5) }

    var surface: Oklch {
        let lightness = groundLightness + Self.surfaceStep
        let stop = midStop
        return Oklch(
            lightness: lightness,
            chroma: chroma(depth: stop.depth, atLightness: lightness),
            hue: stop.hue
        )
    }

    var surfaceRaised: Oklch {
        let lightness = groundLightness + Self.raisedStep
        let stop = midStop
        return Oklch(
            lightness: lightness,
            chroma: chroma(depth: stop.depth, atLightness: lightness),
            hue: stop.hue
        )
    }

    /// Derived from the **foot**, because that is the end the eye reads as the
    /// theme's colour: it is the lit one, and it is what the composer and the
    /// now bar — the two places the accent is actually spent — are sitting on.
    var accent: Oklch {
        Oklch(
            lightness: Self.accentLightness,
            chroma: Self.accentChroma,
            hue: Self.wrap(foot.hue + accentTurn * 360)
        )
    }
}

// MARK: - The resolved colours

/// A theme after the arithmetic — the colours the app paints *things* with.
///
/// What the window's ground is made of is `ThemeGround`, resolved beside this
/// and read only by the SwiftUI views that draw it.
///
/// **Packed integers, not `Color`s.** This value is read from the drawn canvases
/// off the main actor, through a lock, on a path that runs per row. A `Color` is
/// reference-counted, so a struct of a dozen of them costs a retain and a
/// release per field on every snapshot; a struct of `UInt32`s is a memcpy and
/// touches no allocator at all.
nonisolated struct ThemeColors: Hashable, Sendable {
    /// The reading surface as one flat colour — for what has to sit *on* the
    /// ground and match it: a ring cut around an avatar, a sheet's backing.
    /// `Palette.canvas`.
    var canvas: UInt32
    /// Structural, non-floating surfaces. `Palette.surface`.
    var surface: UInt32
    /// A grouped row inside a structural surface. `Palette.surfaceRaised`.
    var surfaceRaised: UInt32
    /// The single accent, or nil to follow the accent colour the reader chose in
    /// System Settings.
    ///
    /// **Nil is a real value and it is the default.** The house theme spends its
    /// accent on primary buttons, the send arrow and focus rings, and tracking
    /// the system's means those agree with every other app on the Mac. A theme
    /// that states a hue is opting out of that deliberately, which is the point
    /// of choosing one.
    var accent: UInt32?
    /// Whether this is a dark room or a light one. The window's appearance
    /// follows it — see `ThemeStore.apply` — and so does every relative fill.
    var appearance: ThemeAppearance
    /// A colour mixed into the transcript's text, or nil for none: Discord's
    /// slight text tint, which only its themes carry. See
    /// `MessageTextStyle.current`.
    var textTint: UInt32?

    /// The house palette, stated rather than derived. See the note at the top.
    static let trueBlack = ThemeColors(
        canvas: 0x0A_0A_0C,
        surface: 0x14_14_17,
        surfaceRaised: 0x1C_1C_20,
        accent: nil
    )

    /// The house's light room, stated for True Black's reason: the seed's ramp
    /// is built for a dark ground, and a light one is a different ladder, not
    /// the same one turned over. The steps run *up* — a card is brighter than
    /// the page it sits on, and a row brighter again — because on a light
    /// ground that is what "in front" looks like.
    static let porcelain = ThemeColors(
        canvas: 0xF4_F3_F0,
        surface: 0xFA_F9_F7,
        surfaceRaised: 0xFF_FF_FF,
        accent: nil,
        appearance: .light
    )

    init(
        canvas: UInt32,
        surface: UInt32,
        surfaceRaised: UInt32,
        accent: UInt32?,
        appearance: ThemeAppearance = .dark,
        textTint: UInt32? = nil
    ) {
        self.canvas = canvas
        self.surface = surface
        self.surfaceRaised = surfaceRaised
        self.accent = accent
        self.appearance = appearance
        self.textTint = textTint
    }

    /// Derived from a seed.
    ///
    /// Every colour in one pass, so the sixteen bisections the gamut fit costs
    /// happen once per theme change rather than once per read.
    init(_ seed: ThemeSeed, followsSystemAccent: Bool = false) {
        canvas = seed.canvas.packedRGB()
        surface = seed.surface.packedRGB()
        surfaceRaised = seed.surfaceRaised.packedRGB()
        // **Checked against the brightest ground it can land on.** The accent
        // is spent on links and on the glyphs of the controls it marks, so it
        // is ink first; on the calm ramp it clears the bar with room to spare,
        // and it is the vivid end of the range that moves it.
        accent = followsSystemAccent
            ? nil
            : InkContrast.legible(seed.accent.packedRGB(), on: seed.inkCeiling)
        appearance = .dark
        textTint = nil
    }
}

/// A dark room or a light one.
nonisolated enum ThemeAppearance: Hashable, Sendable {
    case dark
    case light
}

// MARK: - The presets

/// A theme the app ships with.
///
/// **The raw values are the persistence format**, so they are stable and never
/// renamed: an entry written by an older build has to keep meaning the same
/// theme. A case removed later must leave its raw value retired rather than
/// reused.
enum ThemePreset: String, CaseIterable, Identifiable, Hashable, Sendable {
    case trueBlack
    case graphite
    case porcelain
    case ember
    case rosewood
    case mulberry
    case nebula
    case nightfall
    case deepSea
    case lagoon
    case conifer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trueBlack: "True Black"
        case .graphite: "Graphite"
        case .porcelain: "Porcelain"
        case .ember: "Ember"
        case .rosewood: "Rosewood"
        case .mulberry: "Mulberry"
        case .nebula: "Nebula"
        case .nightfall: "Nightfall"
        case .deepSea: "Deep Sea"
        case .lagoon: "Lagoon"
        case .conifer: "Conifer"
        }
    }

    /// One line, said the way the settings catalog says its own — what the
    /// theme *is*, never a restatement of its name.
    var summary: String {
        switch self {
        case .trueBlack: "The house palette. Near-black, and no colour at all."
        case .graphite: "The same room with the lights up. Neutral, and a step lighter."
        case .porcelain: "A light room. Warm white, glazed, and the system's accent."
        case .ember: "Banked coals. Warm ground, amber on top."
        case .rosewood: "Dark grain and a rust accent."
        case .mulberry: "Wine in a dark glass."
        case .nebula: "Violet dust, lit from inside."
        case .nightfall: "The last blue before it goes."
        case .deepSea: "Deep water, and the light that reaches it."
        case .lagoon: "Shallow water over pale sand."
        case .conifer: "Pine at dusk, with a mint edge."
        }
    }

    /// Where the theme sits in the picker's field, and what it derives from.
    ///
    /// True Black carries a seed even though its colours are stated: opening
    /// Plumage from it has to put the bead *somewhere*, and the honest place is
    /// the house palette's own measured hue and lightness rather than an
    /// arbitrary origin. Its cool cast is real — #0A0A0C is not a grey, it is a
    /// near-black with 0.004 of chroma at 286°.
    var seed: ThemeSeed {
        switch self {
        case .trueBlack:
            ThemeSeed(hue: 286, depth: 0.086, light: 0.305)
        case .graphite:
            ThemeSeed(hue: 286, depth: 0.075, light: 0.560)
        case .porcelain:
            // Stated, like True Black — see `ThemeColors.porcelain`. The seed is
            // where Plumage would put its beads if opened from here: the
            // porcelain's own warm cast, at the brightest the dark ramp allows.
            ThemeSeed(hue: 80, depth: 0.10, light: 1)
        // **Each keeps its old centre and spreads out from it.** The ends used to
        // sit 24 to 36 degrees apart, which is what a straight line through RGB
        // could survive; walked in Oklch they can sit 67 to 80 apart, which is
        // what makes the window read as a room with light moving through it. No
        // foot lands in 70–100°: olive at this lightness is a dirty grey at any
        // depth — see `PlumageShuffle.hueBands`.
        case .ember:
            // Crimson coals under amber.
            ThemeSeed(
                head: ThemeStop(hue: 358, depth: 0.72),
                foot: ThemeStop(hue: 68, depth: 0.88),
                light: 0.400
            )
        case .rosewood:
            // Plum grain to rust.
            ThemeSeed(
                head: ThemeStop(hue: 320, depth: 0.74),
                foot: ThemeStop(hue: 30, depth: 0.86),
                light: 0.395,
                accentTurn: 0.030
            )
        case .mulberry:
            // Purple to wine.
            ThemeSeed(
                head: ThemeStop(hue: 290, depth: 0.74),
                foot: ThemeStop(hue: 358, depth: 0.90),
                light: 0.425,
                accentTurn: 0.020
            )
        case .nebula:
            // Blue-violet dust to a magenta light.
            ThemeSeed(
                head: ThemeStop(hue: 255, depth: 0.76),
                foot: ThemeStop(hue: 335, depth: 0.92),
                light: 0.425,
                accentTurn: 0.015
            )
        case .nightfall:
            // Dusk blue to violet.
            ThemeSeed(
                head: ThemeStop(hue: 222, depth: 0.76),
                foot: ThemeStop(hue: 300, depth: 0.94),
                light: 0.435,
                accentTurn: 0.015
            )
        case .deepSea:
            // Abyssal indigo up to the teal the light reaches.
            ThemeSeed(
                head: ThemeStop(hue: 280, depth: 0.74),
                foot: ThemeStop(hue: 200, depth: 0.92),
                light: 0.415,
                accentTurn: -0.030
            )
        case .lagoon:
            // Lagoon blue to shallow turquoise.
            ThemeSeed(
                head: ThemeStop(hue: 235, depth: 0.72),
                foot: ThemeStop(hue: 165, depth: 0.88),
                light: 0.400
            )
        case .conifer:
            // Dusky teal to pine.
            ThemeSeed(
                head: ThemeStop(hue: 195, depth: 0.70),
                foot: ThemeStop(hue: 128, depth: 0.86),
                light: 0.395,
                accentTurn: -0.020
            )
        }
    }

    /// The two achromatic themes keep the reader's own accent colour.
    ///
    /// There is no hue in either of them for an accent to belong to, so deriving
    /// one would be inventing a colour the theme does not contain — and the
    /// system accent is the better answer anyway: it agrees with every other app
    /// on the Mac and it tracks Increase Contrast.
    var followsSystemAccent: Bool {
        switch self {
        case .trueBlack, .graphite, .porcelain: true
        default: false
        }
    }

    var colors: ThemeColors { colors(vividness: 0) }

    /// At the reader's vividness. **True Black ignores it**: stated, not
    /// derived — see the note at the top of this file — and a house palette
    /// that drifted with a slider would not be one.
    func colors(vividness: Double) -> ThemeColors {
        switch self {
        case .trueBlack: .trueBlack
        case .porcelain: .porcelain
        default: ThemeColors(seed.at(vividness: vividness), followsSystemAccent: followsSystemAccent)
        }
    }

    /// The two whose colours are written down rather than derived.
    var isStated: Bool { self == .trueBlack || self == .porcelain }
}

// MARK: - What is selected

/// One of the presets, one of Discord's, or the reader's own.
///
/// The custom seed lives **beside** the selection rather than inside it, so
/// stepping through the presets to compare them and coming back to Custom finds
/// the blend still there. A selection that carried its payload would lose the
/// reader's work every time they looked at something else.
enum ThemeChoice: Hashable, Sendable {
    case preset(ThemePreset)
    case discord(DiscordTheme)
    case custom

    var preset: ThemePreset? {
        if case .preset(let preset) = self { return preset }
        return nil
    }

    var isCustom: Bool { self == .custom }
}
