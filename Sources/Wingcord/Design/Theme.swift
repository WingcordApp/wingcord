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
//    The other nine themes and anything the reader builds are derived; this one
//    is a literal triple, and the tests pin it.
//
// THE RAMP IS THE INVARIANT. Every derived theme uses the same three Oklab
// lightness steps, so the separation between the reading surface, a card on it
// and a row inside that card is *identical* at every hue. That is the whole
// reason these read as one set: choosing a hue is a choice, never a retune.

/// One end of a theme's ground: a hue, and how much of it the ground carries.
///
/// Two of these make a theme. **The window is lit from above and the two stops
/// are the two ends of that light** — `head` is what is behind the toolbar, and
/// `foot` is what is behind the composer and down the whole sidebar. A theme
/// with one colour is a coloured rectangle; a theme with two is a room.
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

/// The numbers a theme is made of: two stops, one lightness, one accent.
///
/// A seed rather than a list of colours, for three reasons that all matter:
/// it is what the picker manipulates, it is what persists (six doubles instead
/// of a palette), and it is what guarantees a theme somebody built cannot be
/// structurally different from one that shipped.
///
/// **One lightness for both stops, and that is deliberate.** The gap between the
/// head and the foot is `ThemeColors.washRise` and it is fixed, because it is
/// the *window's* sense of depth rather than the theme's — a reader who could
/// set both ends independently could invert it, and an app lit from below reads
/// as broken rather than as themed. What the two stops choose is colour.
nonisolated struct ThemeSeed: Hashable, Sendable {
    /// Behind the toolbar — the darker end, and the theme's stated colour.
    var head: ThemeStop
    /// Behind the composer — the lit end, and the one the accent comes from.
    var foot: ThemeStop
    /// How bright the ground is overall, `0...1`.
    var light: Double
    /// Where the accent sits relative to the **head**, in turns of the wheel.
    /// `0` is that stop's own hue; `0.5` is its opposite.
    var accentTurn: Double

    init(head: ThemeStop, foot: ThemeStop, light: Double, accentTurn: Double = 0) {
        self.head = head
        self.foot = foot
        self.light = min(1, max(0, light))
        // Wrapped rather than clamped: a turn is circular, so −0.1 and 0.9 are
        // the same accent and clamping one of them to zero would silently
        // change the answer.
        self.accentTurn = accentTurn - (accentTurn.rounded(.down))
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
    }

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
        return depth * Self.maximumGroundChroma * (lightness / ground)
    }

    /// The ground behind the toolbar — the theme's stated colour, and the
    /// darker of its two ends.
    var canvas: Oklch {
        let lightness = groundLightness
        return Oklch(
            lightness: lightness,
            chroma: chroma(depth: head.depth, atLightness: lightness),
            hue: head.hue
        )
    }

    /// The ground behind the composer, and the lit end of the window.
    var canvasLit: Oklch {
        let lightness = groundLightness + ThemeColors.washRise
        return Oklch(
            lightness: lightness,
            chroma: chroma(depth: foot.depth, atLightness: lightness),
            hue: foot.hue
        )
    }

    /// Where a panel and a row inside it sit between the two stops.
    ///
    /// **Halfway, and it has to be.** A card is drawn at every height of the
    /// window — a settings card near the toolbar, an embed halfway down, a
    /// reaction chip beside the composer — so a card that belonged to one end
    /// would be visibly the wrong colour at the other. Taking the midpoint means
    /// it is a little wrong everywhere instead of very wrong somewhere, which is
    /// the trade every shared surface in a two-tone room makes.
    private var midStop: ThemeStop {
        ThemeStop(
            hue: Self.mixHue(foot.hue, head.hue, 0.5),
            depth: (foot.depth + head.depth) / 2
        )
    }

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

/// A theme after the arithmetic — what the app actually paints with.
///
/// **Packed integers, not `Color`s.** This value is read from the drawn canvases
/// off the main actor, through a lock, on a path that runs per row. A `Color` is
/// reference-counted, so a struct of a dozen of them costs a retain and a
/// release per field on every snapshot; a struct of `UInt32`s is a memcpy of
/// forty bytes and touches no allocator at all.
nonisolated struct ThemeColors: Hashable, Sendable {
    /// The reading surface. `Palette.canvas`.
    var canvas: UInt32
    /// The lit end of the ground, at the **foot** of the window.
    ///
    /// **The light is at the bottom, and that is measured rather than chosen.**
    /// Both of the clients this was checked against put the saturated end of a
    /// theme down where the composer is and let it fall away toward the toolbar,
    /// and it is the right way round for a reason that is about the window
    /// rather than about colour: the top of a chat window is chrome — a title, a
    /// row of controls — and the bottom is where somebody is actually typing. A
    /// gradient lit from the top puts its brightest region behind the least
    /// interesting part of the app.
    ///
    /// **Equal to `canvas` for the house theme, and only for it.** True Black is
    /// stated rather than derived precisely so the default appearance cannot
    /// drift, and a wash over it would be a change to that appearance rather
    /// than a theme. Everything else is washed, Graphite included — a lifted
    /// neutral is still a choice somebody made.
    var canvasLit: UInt32
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
    /// What the sidebar column — the guild rail *and* the channel list — is
    /// painted with, and how strongly.
    ///
    /// Zero opacity means the column is painted with **nothing at all**, which
    /// is `INVARIANTS.md` §1's rule and is what the house theme does. See
    /// `ThemeColors.railVeilOpacity`.
    var railVeil: UInt32
    var railVeilOpacity: Double

    /// Whether the ground carries a wash at all.
    var isWashed: Bool { canvasLit != canvas }

    /// The house palette, stated rather than derived. See the note at the top.
    static let trueBlack = ThemeColors(
        canvas: 0x0A_0A_0C,
        canvasLit: 0x0A_0A_0C,
        surface: 0x14_14_17,
        surfaceRaised: 0x1C_1C_20,
        accent: nil,
        railVeil: 0x14_14_17,
        railVeilOpacity: 0
    )

    init(
        canvas: UInt32,
        canvasLit: UInt32,
        surface: UInt32,
        surfaceRaised: UInt32,
        accent: UInt32?,
        railVeil: UInt32,
        railVeilOpacity: Double
    ) {
        self.canvas = canvas
        self.canvasLit = canvasLit
        self.surface = surface
        self.surfaceRaised = surfaceRaised
        self.accent = accent
        self.railVeil = railVeil
        self.railVeilOpacity = railVeilOpacity
    }

    /// Derived from a seed.
    ///
    /// Every colour in one pass, so the sixteen bisections the gamut fit costs
    /// happen once per theme change rather than once per read.
    init(_ seed: ThemeSeed, followsSystemAccent: Bool = false) {
        canvas = seed.canvas.packedRGB()
        canvasLit = seed.canvasLit.packedRGB()
        surface = seed.surface.packedRGB()
        surfaceRaised = seed.surfaceRaised.packedRGB()
        accent = followsSystemAccent ? nil : seed.accent.packedRGB()
        // **A derived theme always paints the sidebar**, and the colour is the
        // foot rather than the panel above it: the reading surface carries a
        // wash that lifts it, so the two columns then read the way a themed
        // window ought to — a lit page beside a darker column of contents.
        railVeil = canvas
        railVeilOpacity = Self.paintedRailOpacity
    }

    /// How much lighter the very top of the reading surface is than its foot.
    ///
    /// Half again a ramp step, which is a *lot* — and it is measured rather than
    /// chosen: the reference this was checked against runs L 0.175 at the foot
    /// of its window to 0.276 behind its toolbar, which is more than two steps.
    /// A wash any gentler than this is invisible on a window seven hundred
    /// points tall, which is exactly what the first attempt here was.
    ///
    /// **It is spent in the top half and flat below** — see `washMidpoint`. That
    /// is what lets it be this large without breaking the one thing the ramp
    /// guarantees: a card is a step above the ground it sits on, and a wash that
    /// carried a step and a half all the way down would swallow every embed in
    /// the transcript.
    static let washRise = ThemeSeed.surfaceStep * 1.5

    /// Where the wash has finished falling off, as a fraction of the reading
    /// surface's height.
    ///
    /// Above it the ground is lit; below it, flat. Fifty-five percent puts the
    /// whole of it in the region a scrolled transcript keeps *behind* its
    /// content — the toolbar's band, the first message or two — and leaves the
    /// composer's end of the window at the theme's stated colour.
    static let washMidpoint = 0.55

    /// How strongly a theme paints the sidebar column.
    ///
    /// **The one place this system knowingly breaks `INVARIANTS.md` §1**, and
    /// the exception is worth stating precisely. §1 says the sidebar column is
    /// painted with nothing, because AppKit paints it with behind-window
    /// vibrancy and that vibrancy *is* the bleed — the wallpaper and the
    /// menu-bar accent coming through the rail and the channel list. Painting it
    /// throws that away, and the app then has to hand-roll what it just covered
    /// up.
    ///
    /// **So the house theme still paints nothing, and every other theme paints.**
    /// That is the whole rule, and it is a rule about *consent* rather than about
    /// colour: the bleed is what Wingcord looks like until somebody says
    /// otherwise, and choosing a theme is saying otherwise. A first attempt here
    /// gated on the theme having a hue and veiled at a third, on the reasoning
    /// that a thin tint keeps the bleed *and* carries the colour. It does not —
    /// over behind-window vibrancy a third of a near-black is invisible, and the
    /// result was a themed transcript beside a sidebar that had plainly not
    /// heard about it.
    ///
    /// **Opaque, and the six percent that used to be left is a measured
    /// mistake.** Leaving a sliver of vibrancy through sounded like keeping a
    /// trace of the bleed. What it actually did was make the column's colour a
    /// function of the *wallpaper*: sampled on a bright sky, the sidebar read
    /// #02230D at the top of the window against the transcript's #011309 beside
    /// it — visibly lighter, and lighter by a different amount at every height,
    /// because the desktop is. The two columns share one field now precisely so
    /// they cannot disagree, and six percent of somebody's photograph is enough
    /// to make them.
    ///
    /// The bleed is the house theme's, and the house theme still has all of it.
    static let paintedRailOpacity = 1.0

    /// How much darker the sidebar column is than the page beside it.
    ///
    /// **The only difference left between the two columns**, now that they share
    /// one field. It used to be far more than this and by accident: the detail
    /// column carried a wash and the sidebar carried one flat fill, so the two
    /// were lit independently and met at a hard seam down the split view. A
    /// reader described the result as two tones rather than a theme, and they
    /// were right — it was two themes.
    ///
    /// Six percent of black over the shared field. Enough that a table of
    /// contents reads as one step behind the page, which is what every client
    /// that does this well draws; not enough to be a second colour.
    static let sidebarRecess = 0.06
}

// MARK: - The ten

/// A theme the app ships with.
///
/// **The raw values are the persistence format**, so they are stable and never
/// renamed: an entry written by an older build has to keep meaning the same
/// theme. A case removed later must leave its raw value retired rather than
/// reused.
enum ThemePreset: String, CaseIterable, Identifiable, Hashable, Sendable {
    case trueBlack
    case graphite
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
        case .ember:
            ThemeSeed(
                head: ThemeStop(hue: 32, depth: 0.62),
                foot: ThemeStop(hue: 68, depth: 0.80),
                light: 0.400
            )
        case .rosewood:
            ThemeSeed(
                head: ThemeStop(hue: 8, depth: 0.68),
                foot: ThemeStop(hue: 32, depth: 0.82),
                light: 0.395,
                accentTurn: 0.030
            )
        case .mulberry:
            ThemeSeed(
                head: ThemeStop(hue: 322, depth: 0.66),
                foot: ThemeStop(hue: 352, depth: 0.86),
                light: 0.425,
                accentTurn: 0.020
            )
        case .nebula:
            ThemeSeed(
                head: ThemeStop(hue: 282, depth: 0.70),
                foot: ThemeStop(hue: 318, depth: 0.88),
                light: 0.425,
                accentTurn: 0.015
            )
        case .nightfall:
            ThemeSeed(
                head: ThemeStop(hue: 258, depth: 0.72),
                foot: ThemeStop(hue: 292, depth: 0.92),
                light: 0.435,
                accentTurn: 0.015
            )
        case .deepSea:
            ThemeSeed(
                head: ThemeStop(hue: 258, depth: 0.68),
                foot: ThemeStop(hue: 232, depth: 0.90),
                light: 0.415,
                accentTurn: -0.030
            )
        case .lagoon:
            ThemeSeed(
                head: ThemeStop(hue: 212, depth: 0.66),
                foot: ThemeStop(hue: 186, depth: 0.84),
                light: 0.400
            )
        case .conifer:
            ThemeSeed(
                head: ThemeStop(hue: 166, depth: 0.62),
                foot: ThemeStop(hue: 138, depth: 0.80),
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
        case .trueBlack, .graphite: true
        default: false
        }
    }

    var colors: ThemeColors {
        // Stated, not derived — see the note at the top of this file.
        if self == .trueBlack { return .trueBlack }
        return ThemeColors(seed, followsSystemAccent: followsSystemAccent)
    }
}

// MARK: - What is selected

/// One of the ten, or the reader's own.
///
/// The custom seed lives **beside** the selection rather than inside it, so
/// stepping through the presets to compare them and coming back to Custom finds
/// the blend still there. A selection that carried its payload would lose the
/// reader's work every time they looked at something else.
enum ThemeChoice: Hashable, Sendable {
    case preset(ThemePreset)
    case custom

    var preset: ThemePreset? {
        if case .preset(let preset) = self { return preset }
        return nil
    }

    var isCustom: Bool { self == .custom }
}
