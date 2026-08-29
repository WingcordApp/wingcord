import SwiftUI

/// What a profile surface is made of.
///
/// **Only a real `theme_colors` pair tints the body.** This used to fall back to
/// `accent_color`, and that is wrong in the exact case it fires most: Discord
/// derives an account's accent from its banner, so a person with a red banner
/// and no theme got a card flooded red — banner colour bleeding into a surface
/// that should have stayed neutral. Discord's own client keeps the banner red
/// and the body a plain material, and that is correct behaviour rather than a
/// stylistic preference: the banner is artwork the person chose, the accent is a
/// number derived from it, and only the theme is a decision they made about the
/// card.
///
/// So: themed profiles get their gradient; everyone else gets a neutral ground.
///
/// **Both are opaque, and the unthemed one used not to be.** It was
/// `.glassEffect(.regular)` on the belief that a card supplies its own material
/// and the presentation behind it supplies none. The second half was false — a
/// popover and a sheet each paint a backdrop, and the card's glass had been
/// compositing over it all along, which is why it read as a solid mid-grey panel
/// rather than as the near-transparent material it actually was. Presenting the
/// card as a layer in the window took that backdrop away and the transcript
/// began reading straight through somebody's roles.
///
/// A profile card carries prose — a bio, roles, dates — so §1's rule wins over
/// §4's: **a reading surface is opaque.** It is also cheaper, because a
/// card-sized `.glassEffect` is a sampled backdrop blur recomputed for every
/// frame the transcript scrolls behind it.
///
/// **Shared by the card and the full profile**, because the two are the same
/// person one click apart. Two copies of these opacities is how a profile comes
/// out one colour in a popover and another in a sheet, and the numbers below are
/// fitted rather than picked — see `ProfileGroundFill`.
enum ProfileGround: Equatable {
    /// The person themed themselves. Primary and secondary.
    case themed(Color, Color)
    /// No theme. A plain structural ground, like every other panel in the app.
    case neutral
    /// No theme of their own, so one was quantised out of their artwork.
    ///
    /// **One colour, not a pair, and that is the whole reason this is its own
    /// case.** A chosen theme is two colours somebody picked to sit together; a
    /// derived one is the first two boxes a median cut happened to produce, and
    /// the second of those is very often the near-black *behind* the subject —
    /// a photograph's background. Fed into the themed gradient as its foot, that
    /// swatch inverts it: the surface gathers toward black where it should
    /// gather toward colour, and the card comes out darker at the bottom than at
    /// the top. Measured, before this case existed: 28 to 22 down the card,
    /// where Discord runs 56 to 86.
    ///
    /// So the derived ground is a wash of the PRIMARY at two strengths, and the
    /// second swatch is not drawn at all.
    case derived(Color)

    /// - Parameter isDerived: whether these colours were quantised out of the
    ///   person's artwork rather than chosen by them. The two are drawn
    ///   differently and cannot be told apart from the values alone.
    init(themeColorValues: [UInt32], isDerived: Bool = false) {
        guard let first = themeColorValues.first else {
            self = .neutral
            return
        }
        if isDerived {
            self = .derived(Color(hex: first))
        } else if themeColorValues.count >= 2 {
            self = .themed(Color(hex: first), Color(hex: themeColorValues[1]))
        } else {
            // A single colour is still a deliberate theme, just a flat one.
            self = .themed(Color(hex: first), Color(hex: first))
        }
    }

    /// The card's edge.
    ///
    /// **A lit rim in the person's own colours, not a hairline.** In the theme's
    /// primary at 55% over a near-black body it resolved to something barely
    /// separable from the shadow behind it, so the card had no edge at all: it
    /// read as a dark shape fading into a dark window rather than as an object
    /// lying on top of one.
    ///
    /// So it is a *gradient*, running the same way the body's wash does —
    /// primary at the head, secondary at the foot — which is what makes the rim
    /// and the fill read as one surface lit from one direction rather than as a
    /// border drawn around a fill. It is nearly opaque, because an edge is the
    /// one part of a card that is allowed to be the brightest thing in it.
    ///
    /// White is still wrong here, and for the original reason: a white rim on a
    /// saturated ground reads as a sticker cut out and pasted down. Over glass
    /// there is no theme to borrow from, so it keeps the neutral hairline every
    /// other floating surface in the app uses.
    var borderStyle: AnyShapeStyle {
        switch self {
        case .neutral:
            AnyShapeStyle(Color.white.opacity(0.10))
        case .derived(let primary):
            // **Measured, and a third of the way is the whole answer.** Discord
            // rims a derived card at #D8D7D6 where that person's colour is
            // 139,137,129 — which is that colour mixed one third into white,
            // predicting 216,215,213 against the 216,215,214 on screen. All
            // three channels, within a unit.
            //
            // A rim this light on a dark card looks wrong written down and is
            // right on screen, for the reason the themed rim already gives: an
            // edge is the one part of a card allowed to be the brightest thing
            // in it.
            AnyShapeStyle(primary.mix(with: .white, by: 0.667))
        case .themed(let primary, let secondary):
            AnyShapeStyle(LinearGradient(
                colors: [primary.opacity(0.95), secondary.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            ))
        }
    }

    /// The two colours this ground lends its chrome, or nil where it has none.
    ///
    /// **A derived ground answers with its one colour twice.** Everything below
    /// the body fill — the rim, the accent, a panel's wash — wants "the
    /// person's colour" rather than a gradient's two ends, and collapsing the
    /// distinction here is what keeps those treatments from growing a third
    /// branch each.
    private var pair: (primary: Color, secondary: Color)? {
        switch self {
        case .themed(let primary, let secondary): (primary, secondary)
        case .derived(let primary): (primary, primary)
        case .neutral: nil
        }
    }

    /// How heavy that edge is drawn. A themed rim is a light source and needs
    /// body; a neutral hairline is a separation and must stay a hairline.
    var borderWidth: CGFloat { pair == nil ? 1 : 1.5 }

    /// The colour this surface lends to its own chrome — a selected tab, the
    /// underline that travels between them, a symbol that should belong to the
    /// person rather than to the app.
    ///
    /// **Nil is not a missing value, it is an answer**: an unthemed profile has
    /// no colour of its own, and the correct accent for it is the app's own
    /// hierarchy rather than a colour invented on its behalf. Every reader of
    /// this falls back to `Ink`, which is what the rest of the app uses.
    var accent: Color? { pair?.primary }

    /// A grouped panel sitting on this ground — an activity card, a row that
    /// answers to the pointer.
    ///
    /// Not glass: the ground under it is already the lower surface, and §4's
    /// answer when two glass surfaces would stack is to make one of them solid.
    /// On a themed profile it takes a wash of the theme so the panel reads as
    /// part of the person's surface rather than as a grey box dropped onto it.
    var panelFill: AnyShapeStyle {
        guard let pair else { return AnyShapeStyle(Palette.surfaceRaised) }
        return AnyShapeStyle(pair.primary.opacity(0.16).blendMode(.plusLighter))
    }

    /// What stands behind a banner while the artwork loads, and instead of it
    /// when there is none.
    ///
    /// **This is where `accent_color` belongs, and the only place it does.**
    /// Discord derives it from the banner, so it is exactly right as a stand-in
    /// for one — a person with no banner image gets their accent as a solid
    /// strip, which is what Discord draws too — and exactly wrong as a tint for
    /// the body underneath.
    /// What stands behind a banner while the artwork loads, and instead of one
    /// when there is none.
    ///
    /// **Flat for a derived ground, a gradient for everything else**, and that
    /// is not a stylistic split. A derived colour IS what Discord paints in the
    /// banner's slot — measured at 139,137,129 on an account with no banner,
    /// flat across its whole width and identical in light and dark mode, and
    /// this client quantises the same avatar to within three units of it. Fading
    /// it across the strip throws that agreement away: sampled anywhere but the
    /// first corner it read 120,119,113 against Discord's 139,137,129.
    ///
    /// The gradient stays where it earns its place — over `accent_color`, which
    /// is a stand-in for artwork rather than a measured answer.
    ///
    /// One function rather than a seed each surface builds a gradient from,
    /// because both surfaces drew that gradient and only one of them would have
    /// been fixed.
    func plateStyle(accentColorValue: UInt32?) -> AnyShapeStyle {
        if case .derived(let primary) = self { return AnyShapeStyle(primary) }
        let seed = pair?.primary
            ?? accentColorValue.map { Color(hex: $0) }
            ?? Palette.surfaceRaised
        return AnyShapeStyle(LinearGradient(
            colors: [seed, seed.opacity(0.6)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ))
    }
}

/// Paints a profile surface's body.
///
/// A `ViewModifier` with a `switch` rather than an `if` at the call site: the
/// two branches produce different view types, and branching in the surface's own
/// builder would give it two identities — so a profile whose theme arrives a
/// moment after the card opens would POP rather than change material. The fetch
/// that fills these colours in lands while the popover is already on screen, so
/// that is the common case, not the edge one.
struct ProfileGroundFill: ViewModifier {
    var ground: ProfileGround
    var corner: CGFloat
    /// Whether this surface paints a ground at all.
    ///
    /// **False where the ground belongs to the pane around it** — the profile
    /// column beside a direct message, whose colour has to run the full height
    /// of the window rather than stopping where the content does. A flag rather
    /// than a case on `ProfileGround`, because "nothing" is a fact about the
    /// *surface*, not a kind of ground: a column and a card can carry the same
    /// person's theme and only one of them paints it.
    ///
    /// Constant for the life of a surface, so the branch below never changes a
    /// view's identity.
    var paints: Bool = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if !paints {
            content
        } else {
            fill(content)
        }
    }

    @ViewBuilder
    private func fill(_ content: Content) -> some View {
        switch ground {
        case .themed(let primary, let secondary):
            // Solid, not glass, and deliberately: a theme is a GRADIENT and
            // `.glassEffect`'s tint takes one colour, so a themed surface
            // rendered as glass loses half the person's palette. It is also the
            // lower surface here — the chips on it are the glass — and §4's
            // answer when two glass surfaces would stack is to make the lower
            // one solid.
            //
            // **A theme colour is a WASH over the reading surface, not the
            // surface itself.** Drawn at full strength the card came out a flat
            // bright magenta while Discord's own stayed almost black with the
            // colour only readable in it — the difference between a card that
            // has a colour and a card that IS one. The base stays `canvas`, the
            // app's near-black, and the theme is laid over it thinly.
            //
            // The ramp runs dark-to-coloured downward, matching Discord: the
            // region just under the banner is the quietest part of the surface
            // because the banner above it is already carrying the artwork, and
            // the colour gathers toward the foot where nothing competes.
            //
            // The two opacities are fitted, not picked. Against a bright violet
            // theme they resolve to #2B1032 at the top and #511648 at the foot
            // — relative luminance 24 and 35 — where Discord's own card for the
            // same member samples at 26 and 34. The values they replaced
            // resolved to 77 and 98, which is the whole of "washed out".
            content.background {
                LinearGradient(
                    colors: [primary.opacity(0.18), secondary.opacity(0.32)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .background(Palette.canvas)
            }
        case .derived(let primary):
            // **Fitted against Discord's own DARK mode, which is the only fair
            // reference for a dark app.** Measured on an account whose derived
            // colour is 139,137,129: Discord runs its card body from 56,56,52
            // at the head to 86,86,85 at the foot. Over this app's canvas at
            // 10,10,12 those are that colour at 0.357 and 0.589 — so these two
            // numbers are a solved equation rather than a preference, and the
            // result lands within two units of Discord on every channel.
            //
            // The direction matters as much as the strength. Colour GATHERS
            // downward here, where the pair the themed case is given would have
            // run the other way — see `ProfileGround.derived`.
            content.background {
                LinearGradient(
                    colors: [primary.opacity(0.36), primary.opacity(0.59)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .background(Palette.canvas)
            }
        case .neutral:
            // **One opaque fill, and the same base the themed case sits on.**
            // A themed card is `canvas` with a thin wash over it; an unthemed
            // one is that base with no wash, which is what keeps the two reading
            // as the same object with and without somebody's colours in it.
            //
            // `surface` rather than `canvas` so the card is one step off the
            // transcript it floats over; the rest of the separation is the rim
            // above and the shadow the surface already casts.
            content.background(
                Palette.surface,
                in: .rect(cornerRadius: corner, style: .continuous)
            )
        }
    }
}
