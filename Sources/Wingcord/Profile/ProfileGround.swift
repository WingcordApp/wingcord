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

    /// Discord's "Apply theme to other users' profiles"
    /// (`syncProfileThemeWithUserTheme`): every themed profile in the reader's
    /// own light or dark (`101928`), its modal ground mixed for that room, and
    /// the heavier overlay Discord keeps for it (`920601`).
    private var followsReader: Bool { AppSettings.shared.appliesThemeToProfiles }

    /// Discord's `PROFILE_GRADIENT_OVERLAY`: black or white at 60 % — and at
    /// 80 % (`…_SYNCED_WITH_USER_THEME`) for a profile in the reader's room.
    private var overlay: Double { followsReader ? 0.8 : 0.6 }

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
    /// **An unthemed card follows the app too** — dark in a dark room, light in
    /// a light one. It used to answer `true` outright, on the grounds that every
    /// theme this app shipped was dark; the first light theme made every
    /// profile without colours of its own a white card with white type on it.
    var isDark: Bool {
        guard let pair, !followsAppTheme, !followsReader else { return Self.appIsDark }
        return ProfileThemeColors.isDark(pair.primary)
    }

    /// The app's own room — the theme's, which the window's appearance follows.
    /// Read through `ThemeAccess`, so a card evaluating it is redrawn when the
    /// theme changes.
    private static var appIsDark: Bool { ThemeAccess.colors.appearance == .dark }

    /// **What a profile with no colours of its own is drawn in: the house's
    /// neutral room, never the app's theme.** Discord paints an unthemed card
    /// on its own base surfaces, and a reader's green or sunset theme spread
    /// over a stranger's plain profile reads as the stranger having chosen it
    /// (Alex, 2026-10-07: "on blank profiles that dont have nitro, the app's
    /// theme gets applied which discord doesnt do"). True Black's ladder in a
    /// dark room and Porcelain's in a light one — the two rooms "Sync with
    /// computer" resolves to.
    private var neutral: ThemeColors { isDark ? .trueBlack : .porcelain }

    /// An unthemed card's own fill. See `neutral`.
    var neutralSurface: Color { Color(hex: neutral.surface) }
    /// A step above it — a ring, a plate, a card on the card.
    var neutralRaised: Color { Color(hex: neutral.surfaceRaised) }

    /// Whether a surface painting this ground needs **dark** ink on it.
    ///
    /// One environment value is the whole ink fix, because every `Ink` in this
    /// app is a hierarchical style — a light card needs `.colorScheme(.light)`
    /// rather than a light variant of every label, divider and control in the
    /// profile. It is also what the system's own controls read.
    var wantsDarkInk: Bool { !isDark }

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
        guard let pair else { return Color(hex: neutral.canvas) }
        return Color(hex: ProfileThemeColors.veiled(pair.primary, dark: isDark, alpha: overlay))
    }

    /// And at its foot — the secondary under the same overlay.
    var bodyFoot: Color {
        guard let pair else { return Color(hex: neutral.canvas) }
        return Color(hex: ProfileThemeColors.veiled(pair.secondary, dark: isDark, alpha: overlay))
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
        guard let pair else { return Color(hex: neutral.canvas) }
        let base = ProfileThemeColors.modalBackground(
            primary: pair.primary,
            secondary: pair.secondary,
            forcedDark: followsReader ? Self.appIsDark : nil
        )
        return Color(hex: ProfileThemeColors.modalRamp(over: base, dark: isDark, fraction: 0.2))
    }

    /// What that base starts at, before it settles into `modalBase`.
    var modalHead: Color {
        guard let pair else { return Color(hex: neutral.canvas) }
        let base = ProfileThemeColors.modalBackground(
            primary: pair.primary,
            secondary: pair.secondary,
            forcedDark: followsReader ? Self.appIsDark : nil
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
        guard let pair else { return AnyShapeStyle(Self.neutralRim) }
        return AnyShapeStyle(LinearGradient(
            colors: [Color(hex: pair.primary), Color(hex: pair.secondary)],
            startPoint: .top,
            endPoint: .bottom
        ))
    }

    /// The hairline round an unthemed card: light in a dark room, shade in a
    /// light one.
    private static let neutralRim = Color.relative(dark: 0.10, light: 0.10)

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

    /// A card sitting on this ground — an activity, a widget, the games strip,
    /// a row that answers to the pointer.
    ///
    /// **Discord's `--user-profile-overlay-background`**, the surface its
    /// activity and widget cards are built on: `--opacity-16` — a cool grey,
    /// hsl(240 4% 61%), at 16 % — on a dark profile, and white at 24 % on a
    /// light one. Translucent, so the person's own colour runs through it.
    ///
    /// **This was black at 45 %**, Discord's `PROFILE_GRADIENT_SECTION_BOX` —
    /// which is the status bubble's token, not a card's, and which on a dark
    /// theme drew every activity card as a black slab.
    ///
    /// Not glass: the card's ground is opaque paint with nothing behind it to
    /// refract (§4 rule 3).
    var panelFill: AnyShapeStyle {
        guard pair != nil else { return AnyShapeStyle(neutralRaised) }
        return AnyShapeStyle(wantsDarkInk ? Self.overlayLight : Self.overlayDark)
    }

    /// `--opacity-16`: 151,151,159 at 41/255.
    private static let overlayDark = Color(red: 151 / 255, green: 151 / 255, blue: 159 / 255)
        .opacity(41 / 255)
    /// `--opacity-white-24`: white at 61/255.
    private static let overlayLight = Color.white.opacity(61 / 255)

    /// The edge a card on this ground wears. **Only on a light profile**, as
    /// Discord draws it (`--border-muted`): on a dark one the overlay is
    /// already lighter than its ground, and an edge adds a line nobody needs.
    var panelEdge: Color? {
        wantsDarkInk ? Color.black.opacity(0.08) : nil
    }

    /// The custom status bubble's plate.
    ///
    /// **Translucent, over whatever is actually behind it.** This is
    /// `PROFILE_GRADIENT_SECTION_BOX` as Discord's own token table declares it —
    /// `BLACK` at 45 % on its dark themes, `WHITE` at 45 % on its light one —
    /// and the client resolves it to an eight-digit hex and lets the profile
    /// show through. Nothing is composited down.
    ///
    /// **This used to be flattened against the body colour, and that is what
    /// made it wrong.** The reasoning was that 45 % of somebody's banner coming
    /// through a speech bubble reads as a bug — but Discord accepts exactly
    /// that, and flattening produced a bubble derived from the *primary* theme
    /// colour, which is not what is behind the bubble at all. On a profile whose
    /// primary is bright pink the bubble came out bright pink; Discord's, over
    /// the same profile's pale banner, measured `#EFFEFF`.
    ///
    /// Both of Alex's measurements are consistent with this and with nothing
    /// derivable from the theme colours alone: `#EFFEFF` is 45 % white over a
    /// near-white banner region, and `#262421` is 45 % black over a dark warm
    /// grey one. That the backdrop is the *artwork* rather than a theme colour
    /// is the whole finding — a derivation from `theme_colors` cannot produce
    /// either number, which is why every attempt to fit one has missed.
    ///
    /// **Near-white on a light profile, near-black on a dark one, and opaque.**
    ///
    /// Three things had to be true at once and each was wrong on its own:
    ///
    ///  - **The colour is the theme's, not the person's.** Deriving it from the
    ///    `primary` gave a bright-pink bubble on a bright-pink profile, where
    ///    Discord's over the same account measured `#EFFEFF` — near-white with a
    ///    trace of cyan. `PROFILE_GRADIENT_SECTION_BOX` is `WHITE` on a light
    ///    theme and `BLACK` on a dark one, and neither is a hue.
    ///  - **It is opaque.** The token carries an opacity, but the client
    ///    resolves it with `.resolve(theme).hex()` and a six-digit hex has no
    ///    alpha — the 45 % is applied against the theme's own background and the
    ///    *result* is painted. Left translucent, a bubble on a pale banner had
    ///    the artwork legible straight through the words.
    ///  - **It still carries a trace of the person.** `modalBackground` is
    ///    exactly that value — Discord's own `v2` base, a near-white or
    ///    near-black card holding the pair's hue — so the plate is the token
    ///    laid over it rather than over the saturated body.
    ///
    /// **The 0.9 is fitted to one measurement**, and that is stated rather than
    /// hidden: it lands on `#F2F0FE` against Discord's `#EFFEFF` for the one
    /// profile whose theme colours and rendered bubble are both in hand. A
    /// second pair — any account's `theme_colors` beside a sampled bubble —
    /// would settle whether the constant is right or whether the relationship
    /// is something else that happens to pass through this point.
    var statusBubbleFill: Color {
        guard let pair else { return neutralSurface }
        let base = ProfileThemeColors.modalBackground(
            primary: pair.primary,
            secondary: pair.secondary,
            forcedDark: followsAppTheme || followsReader ? Self.appIsDark : nil
        )
        return Color(hex: ProfileThemeColors.veiled(base, dark: isDark, alpha: 0.9))
    }

    /// The ink on the custom-status bubble.
    ///
    /// **It follows the bubble's own plate, not the card's body.** The plate is
    /// near-white on a light profile and near-black on a dark one — see
    /// `statusBubbleFill` — so a fixed white was legible on exactly half of
    /// them. It was fixed for a reason that has since stopped being true: the
    /// bubble used to be translucent over arbitrary banner artwork, where
    /// vibrancy resolves against a picture nobody chose. It is an opaque themed
    /// plate now, and an opaque plate has a knowable contrast.
    var statusBubbleInk: Color {
        pair == nil ? InkColor.primary : (isDark ? .white : .black)
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
        let seed = accentColorValue.map { Color(hex: $0) } ?? neutralRaised
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
            // What this card's flyouts wear: see `profileFlyoutAppearance()`.
            .environment(\.profileFlyoutScheme, ground.wantsDarkInk ? .light : .dark)
    }

    @ViewBuilder
    private var fill: some View {
        if !paints {
            EmptyView()
        } else if ground == .neutral {
            // **One opaque fill**, the neutral room's `surface` rather than its
            // `canvas` so the card is one step off the transcript it floats
            // over; the rest of the separation is the rim above and the shadow
            // the surface casts. Never the app theme's — see `neutralSurface`.
            ground.neutralSurface.clipShape(.rect(cornerRadius: corner, style: .continuous))
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
