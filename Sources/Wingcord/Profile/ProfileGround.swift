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
/// So: themed profiles get their gradient; everyone else gets glass.
///
/// **Shared by the card and the full profile**, because the two are the same
/// person one click apart. Two copies of these opacities is how a profile comes
/// out one colour in a popover and another in a sheet, and the numbers below are
/// fitted rather than picked — see `ProfileGroundFill`.
enum ProfileGround: Equatable {
    /// The person themed themselves. Primary and secondary.
    case themed(Color, Color)
    /// No theme. The surface is a floating material like every other panel.
    case glass

    init(themeColorValues: [UInt32]) {
        if themeColorValues.count >= 2 {
            self = .themed(Color(hex: themeColorValues[0]), Color(hex: themeColorValues[1]))
        } else if let only = themeColorValues.first {
            // A single colour is still a deliberate theme, just a flat one.
            self = .themed(Color(hex: only), Color(hex: only))
        } else {
            self = .glass
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
        case .themed(let primary, let secondary):
            AnyShapeStyle(LinearGradient(
                colors: [primary.opacity(0.95), secondary.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            ))
        case .glass:
            AnyShapeStyle(Color.white.opacity(0.10))
        }
    }

    /// How heavy that edge is drawn. A themed rim is a light source and needs
    /// body; a neutral hairline is a separation and must stay a hairline.
    var borderWidth: CGFloat {
        switch self {
        case .themed: 1.5
        case .glass: 1
        }
    }

    /// The colour this surface lends to its own chrome — a selected tab, the
    /// underline that travels between them, a symbol that should belong to the
    /// person rather than to the app.
    ///
    /// **Nil is not a missing value, it is an answer**: an unthemed profile has
    /// no colour of its own, and the correct accent for it is the app's own
    /// hierarchy rather than a colour invented on its behalf. Every reader of
    /// this falls back to `Ink`, which is what the rest of the app uses.
    var accent: Color? {
        switch self {
        case .themed(let primary, _): primary
        case .glass: nil
        }
    }

    /// A grouped panel sitting on this ground — an activity card, a row that
    /// answers to the pointer.
    ///
    /// Not glass: the ground under it is already the lower surface, and §4's
    /// answer when two glass surfaces would stack is to make one of them solid.
    /// On a themed profile it takes a wash of the theme so the panel reads as
    /// part of the person's surface rather than as a grey box dropped onto it.
    var panelFill: AnyShapeStyle {
        switch self {
        case .themed(let primary, _):
            AnyShapeStyle(primary.opacity(0.16).blendMode(.plusLighter))
        case .glass:
            AnyShapeStyle(Palette.surfaceRaised)
        }
    }

    /// What stands behind a banner while the artwork loads, and instead of it
    /// when there is none.
    ///
    /// **This is where `accent_color` belongs, and the only place it does.**
    /// Discord derives it from the banner, so it is exactly right as a stand-in
    /// for one — a person with no banner image gets their accent as a solid
    /// strip, which is what Discord draws too — and exactly wrong as a tint for
    /// the body underneath.
    func plateSeed(accentColorValue: UInt32?) -> Color {
        switch self {
        case .themed(let primary, _): primary
        case .glass: accentColorValue.map { Color(hex: $0) } ?? Palette.surfaceRaised
        }
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
        case .glass:
            // No fill behind it — §4 rule 3. The material is the surface.
            content.glassEffect(.regular, in: .rect(cornerRadius: corner, style: .continuous))
        }
    }
}
