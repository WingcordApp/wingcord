import AppKit
import SwiftUI

/// What a profile surface is made of.
///
/// **One themed case, and there used to be two.** A pair the person chose and a
/// pair quantised out of their artwork were drawn differently here for a whole
/// session, on a measurement that turned out to be a coincidence: Discord rims
/// a derived card at `#D8D7D6` where that person's colour is `#8C8981`, which is
/// that colour two thirds of the way into white — and is also, exactly, the
/// SECOND swatch of their palette. There was never a rule; there was one
/// account whose two numbers happened to agree. Discord's own client cannot
/// tell the two apart either: `getPreviewThemeColors() ?? quantised` is one
/// value by the time anything draws it. See `ProfileThemeColors`.
///
/// **A profile carries its own light or dark theme, decided by the PRIMARY
/// colour alone**, and that is independent of the app's. A cat photographed on a
/// white sofa quantises to `#8C8981` / `#D8D7D6`, and Discord draws that account
/// as a near-white card with dark text in a dark client. Somebody who picked a
/// navy gets a near-black one. The same palette produces the same card in every
/// surface — popout, sidebar and full profile — so there is no "the card has a
/// colour here and IS the colour there": there is one treatment for a card and
/// a second for the full profile's own base, and both are in `ProfileThemeColors`.
///
/// **Both are opaque, and the unthemed one used not to be.** It was
/// `.glassEffect(.regular)` on the belief that a card supplies its own material
/// and the presentation behind it supplies none. The second half was false — a
/// popover and a sheet each paint a backdrop, and the card's glass had been
/// compositing over it all along, which is why it read as a solid mid-grey panel
/// rather than as the near-transparent material it actually was.
///
/// A profile card carries prose — a bio, roles, dates — so §1's rule wins over
/// §4's: **a reading surface is opaque.** It is also cheaper, because a
/// card-sized `.glassEffect` is a sampled backdrop blur recomputed for every
/// frame the transcript scrolls behind it.
enum ProfileGround: Equatable {
    /// The person's pair — chosen by them, or quantised out of their artwork.
    /// Packed 24-bit sRGB, because every derivation below is arithmetic and a
    /// `Color` cannot be asked for its channels without a bridge.
    /// - Parameter followsAppTheme: whether this surface takes the APP's theme
    ///   instead of the profile's. See `isDark`.
    case themed(primary: UInt32, secondary: UInt32, followsAppTheme: Bool)
    /// No pair at all. A plain structural ground, like every other panel in the
    /// app — and the right answer rather than a colour invented on somebody's
    /// behalf.
    case neutral

    /// - Parameter followsAppTheme: true on the surfaces that stay dark
    ///   whatever the person's colours are — see `isDark`.
    init(themeColorValues: [UInt32], followsAppTheme: Bool = false) {
        guard let first = themeColorValues.first else {
            self = .neutral
            return
        }
        // A single colour is still a theme, just a flat one.
        self = .themed(
            primary: first,
            secondary: themeColorValues.count >= 2 ? themeColorValues[1] : first,
            followsAppTheme: followsAppTheme
        )
    }

    /// The pair, or nil where there is none.
    ///
    /// **Nil is an answer, not a missing value**: an unthemed profile has no
    /// colours of its own, and the correct treatment is the app's own neutral.
    private var pair: (primary: UInt32, secondary: UInt32)? {
        switch self {
        case .themed(let primary, let secondary, _): (primary, secondary)
        case .neutral: nil
        }
    }

    /// Whether this surface takes the app's theme rather than the profile's.
    private var followsAppTheme: Bool {
        if case .themed(_, _, let follows) = self { return follows }
        return true
    }

    /// Whether this surface draws itself dark.
    ///
    /// **Discord decides this per SURFACE, not once per person**, and measuring
    /// three of them is the only way it was ever going to be found. The full
    /// profile and the popout take the *profile's* own theme — `themeFromColor`
    /// on the primary, so a pale palette gives a near-white card in a dark
    /// client. The **DM sidebar does not**: it hands
    /// `useProfileThemeStyle` a `themeOverride` of the app's theme, so it stays
    /// dark for the same account whose modal beside it is white.
    ///
    /// Measured on Discord's own sidebar for two accounts, and the overlay is
    /// still the 0.6 one rather than the 0.8 that `forceUserTheme` would have
    /// brought with it — which is how the two mechanisms are told apart:
    ///
    /// ```
    /// robinresting  #8c8981 / #d8d7d6   predicted 56,55,52 → 86,86,86
    ///                                      measured 57,56,54 → 85,85,84
    /// spiwal          #07adea / #4f003b   predicted  3,69,94 → 32, 0,24
    ///                                      measured 15,66,90 → 32, 6,28   (P3)
    /// ```
    ///
    /// An unthemed card follows the app too, which is dark at every preset this
    /// app ships.
    var isDark: Bool {
        guard let pair, !followsAppTheme else { return true }
        return ProfileThemeColors.isDark(pair.primary)
    }

    /// Whether a surface painting this ground needs **dark** ink on it.
    ///
    /// One environment value is the whole ink fix, because every `Ink` in this
    /// app is a hierarchical style — a light card needs `.colorScheme(.light)`
    /// rather than a light variant of every label, divider and control in the
    /// profile. It is also what the system's own controls read.
    var wantsDarkInk: Bool { pair != nil && !isDark }

    // MARK: The card

    /// A card's body at its head — the colour held under the banner.
    ///
    /// The person's primary under Discord's overlay: **black at 60 % on a dark
    /// profile, white at 60 % on a light one**. Also what the banner's fade has
    /// to dissolve into, which is why it is a property rather than a private
    /// number inside the fill: the body's ramp, the banner's fade and the foot
    /// dock's scrim are one surface, and three private copies of the arithmetic
    /// is how each stays individually defensible while the result is wrong (§2).
    var bodyHead: Color {
        guard let pair else { return Palette.canvas }
        return Color(hex: ProfileThemeColors.veiled(pair.primary, dark: isDark))
    }

    /// And at its foot — the secondary under the same overlay.
    var bodyFoot: Color {
        guard let pair else { return Palette.canvas }
        return Color(hex: ProfileThemeColors.veiled(pair.secondary, dark: isDark))
    }

    // MARK: The full profile

    /// The full profile's own base — everything the identity card does not
    /// cover.
    ///
    /// **A different colour from the card's, and that is not a stylistic
    /// split.** Discord's modal paints a clamped Lab midpoint of the pair
    /// rather than the pair itself, so the page around the identity card is a
    /// quiet near-white or near-black carrying the person's hue while the card
    /// beside it carries their actual colours. Drawing the card's own ramp
    /// across both is what made this client's full profile one flat slab of
    /// somebody's theme.
    var modalBase: Color {
        guard let pair else { return Palette.canvas }
        let base = ProfileThemeColors.modalBackground(
            primary: pair.primary,
            secondary: pair.secondary
        )
        return Color(hex: ProfileThemeColors.modalRamp(over: base, dark: isDark, fraction: 0.2))
    }

    /// What that base starts at, before it settles into `modalBase`.
    var modalHead: Color {
        guard let pair else { return Palette.canvas }
        let base = ProfileThemeColors.modalBackground(
            primary: pair.primary,
            secondary: pair.secondary
        )
        return Color(hex: ProfileThemeColors.modalRamp(over: base, dark: isDark, fraction: 0.8))
    }

    /// How far the modal's ramp runs before it is flat. **Absolute, not a
    /// fraction** — Discord's stop is `300px`, so a taller window gets more
    /// flat colour rather than a longer fade.
    static let modalRampHeight: CGFloat = 300

    // MARK: Chrome

    /// The card's edge.
    ///
    /// **The RAW pair, at full strength.** It is Discord's outer element
    /// showing through its inner's padding — the one part of the card the 60 %
    /// overlay never reaches, which is why a rim reads so much more saturated
    /// than the body it surrounds. The opacities this replaced were fitted
    /// against a body that was drawn wrong.
    ///
    /// White is still wrong here: a white rim on a saturated ground reads as a
    /// sticker cut out and pasted down. Over glass there is no theme to borrow
    /// from, so it keeps the neutral hairline every other floating surface uses.
    var borderStyle: AnyShapeStyle {
        guard let pair else { return AnyShapeStyle(Color.white.opacity(0.10)) }
        return AnyShapeStyle(LinearGradient(
            colors: [Color(hex: pair.primary), Color(hex: pair.secondary)],
            startPoint: .top,
            endPoint: .bottom
        ))
    }

    /// How heavy that edge is drawn. A themed rim is a light source and needs
    /// body; a neutral hairline is a separation and must stay a hairline.
    var borderWidth: CGFloat { pair == nil ? 1 : 1.5 }

    /// The two colours this ground lends a ramp — the date span's rule, the
    /// friend pill's fill.
    var accentPair: (primary: Color, secondary: Color)? {
        guard let pair else { return nil }
        return (Color(hex: pair.primary), Color(hex: pair.secondary))
    }

    /// The colour this surface lends its own chrome — a selected tab, the
    /// underline that travels between them, a symbol that should belong to the
    /// person rather than to the app.
    var accent: Color? { pair.map { Color(hex: $0.primary) } }

    /// The same colour, safe to set **text** in.
    ///
    /// **A wash colour and an ink colour are not the same value, and which way
    /// to move depends on the card.** On a dark card the primary is floored and
    /// desaturated into a pastel; on a light one the same treatment would make
    /// it invisible, so it takes `buttonFill` instead — the person's colour
    /// darkened until it carries against white, which is the same question.
    ///
    /// **Not a contrast *calculation*** on the dark side: a WCAG ratio against
    /// a gradient that runs two ways under a card is a number with no single
    /// answer, and a floor is honest about being a floor.
    var inkAccent: Color? {
        guard let pair else { return nil }
        return wantsDarkInk
            ? Color(hex: ProfileThemeColors.buttonFill(pair.primary))
            : Color(hex: pair.primary).liftedForInk()
    }

    /// The fill of a primary control on this card — Discord's
    /// `--profile-gradient-button-color`.
    ///
    /// The person's primary darkened until its contrast against white lands in
    /// `7...10`, so white text on it is legible whatever they chose. Measured
    /// off Discord for two accounts and reproduced within a unit on both:
    /// `#35332C` for a grey profile, `#005287` for a cyan one.
    var buttonFill: Color? {
        pair.map { Color(hex: ProfileThemeColors.buttonFill($0.primary)) }
    }

    /// And the fill of a secondary one beside it — `--control-secondary-*`,
    /// which is white at 72 % on a light card and at 8 % on a dark one.
    var secondaryControlFill: Color {
        wantsDarkInk ? .white.opacity(0.72) : .white.opacity(0.08)
    }

    /// A grouped panel sitting on this ground — an activity card, a row that
    /// answers to the pointer.
    ///
    /// Discord's `PROFILE_GRADIENT_SECTION_BOX`: black at 45 % on a dark card,
    /// white at 45 % on a light one. Not glass — the ground under it is already
    /// the lower surface, and §4's answer when two glass surfaces would stack is
    /// to make one of them solid.
    var panelFill: AnyShapeStyle {
        guard pair != nil else { return AnyShapeStyle(Palette.surfaceRaised) }
        return AnyShapeStyle(wantsDarkInk
            ? Color.white.opacity(0.45)
            : Color.black.opacity(0.45))
    }

    /// The custom status bubble's plate.
    ///
    /// **Themed, and OPAQUE, and only one of those is measured.** The polarity
    /// and the strength are Discord's `PROFILE_GRADIENT_SECTION_BOX` — black at
    /// 45 % on a dark card, white at 45 % on a light one — which is the same
    /// token every other panel on a profile takes and which `panelFill` already
    /// carries. What is *not* from a capture is compositing it down to an opaque
    /// colour instead of leaving it translucent: no capture in hand shows this
    /// bubble on a themed profile, and the bubble is the one panel that sits
    /// over the BANNER, which is arbitrary artwork. Forty-five per cent of
    /// somebody's photograph coming through a speech bubble reads as a bug
    /// rather than as material, and it reads worst while the bubble expands
    /// under the pointer and the picture moves inside it.
    ///
    /// So the fill is that token resolved against the body it sits on, which
    /// keeps the hue relationship Discord has and takes the picture out of it.
    /// An unthemed card keeps the app's own surface.
    var statusBubbleFill: Color {
        guard let pair else { return Palette.surface }
        let body = ProfileThemeColors.veiled(pair.primary, dark: isDark)
        return Color(hex: ProfileThemeColors.veiled(body, dark: isDark, alpha: 0.45))
    }

    /// What stands behind a banner while the artwork loads, and instead of it
    /// when there is none.
    ///
    /// **Flat, and the primary UNVEILED.** Discord paints the raw primary
    /// across the banner's whole slot — measured at `139,137,129` on an account
    /// with no banner, edge to edge, identical in light and dark mode. Fading
    /// it throws that agreement away: sampled anywhere but the first corner a
    /// gradient read `120,119,113` against Discord's `139,137,129`.
    ///
    /// **`accent_color` is where the gradient belongs, and the only place it
    /// does.** Discord derives it from the banner, so it is exactly right as a
    /// stand-in for one — and exactly wrong as a tint for the body underneath.
    ///
    /// One function rather than a seed each surface builds a gradient from,
    /// because both surfaces drew that gradient and only one of them would have
    /// been fixed.
    func plateStyle(accentColorValue: UInt32?) -> AnyShapeStyle {
        if let pair { return AnyShapeStyle(Color(hex: pair.primary)) }
        let seed = accentColorValue.map { Color(hex: $0) } ?? Palette.surfaceRaised
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
    /// Which of Discord's two treatments this surface takes.
    ///
    /// **Two surfaces, not two preferences.** Every card — the popout, the DM
    /// sidebar, the full profile's identity column — is the pair under one
    /// overlay. The full profile's *page* is the clamped midpoint with a ramp
    /// of its own. This client had a single treatment and used it for both,
    /// which is why a light profile came out a brown slab and a blue one came
    /// out royal blue.
    enum Form: Equatable {
        /// A card. `topHold` is its banner's height: Discord holds the head
        /// colour down to the foot of the banner and only ramps below it, which
        /// is `linear-gradient(start, start var(--banner-height), end)`.
        case card(topHold: CGFloat)
        /// The full profile's page.
        case page
    }

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
    var form: Form = .card(topHold: 0)

    func body(content: Content) -> some View {
        content
            .background { fill }
            .environment(\.colorScheme, ground.wantsDarkInk ? .light : .dark)
    }

    @ViewBuilder
    private var fill: some View {
        if !paints {
            EmptyView()
        } else if ground == .neutral {
            // **One opaque fill.** `surface` rather than `canvas` so the card is
            // one step off the transcript it floats over; the rest of the
            // separation is the rim above and the shadow the surface casts.
            Palette.surface.clipShape(.rect(cornerRadius: corner, style: .continuous))
        } else {
            switch form {
            case .card(let topHold):
                VStack(spacing: 0) {
                    ground.bodyHead.frame(height: topHold)
                    LinearGradient(
                        colors: [ground.bodyHead, ground.bodyFoot],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            case .page:
                // The ramp is 300 points from the top and the rest is flat, so
                // the base is the ramp's FOOT and the gradient is an overlay on
                // it. Stating it the other way round leaves a seam wherever the
                // page is taller than the ramp, which is every window.
                ground.modalBase
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [ground.modalHead, ground.modalBase],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: ProfileGround.modalRampHeight)
                    }
            }
        }
    }
}
