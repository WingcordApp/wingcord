import SwiftUI
import WingcordCore

/// The card that appears beside a clicked avatar or name.
///
/// **The card's ground is the person's own theme, and everything drawn on it is
/// achromatic.** That is this app's colour rule applied to a profile rather than
/// an exception to it: colour comes from user content — avatars, banners, role
/// colours — and the chrome stays neutral. A profile is the one surface that is
/// *entirely* someone's content, so it is the one surface that is entirely
/// their colour.
///
/// Three sources feed that ground, in order, and all three only ever arrive
/// from `GET /users/{id}/profile`:
///
///   1. `themeColorValues` — a PAIR, drawn as a gradient. Collapsing the pair to
///      its first colour is how a purple-to-blue profile comes out flat purple.
///   2. `accentColorValue` — the older single swatch, blended toward the
///      surface so it grounds the card instead of flooding it.
///   3. Nothing, for the majority who have never themed themselves. They get
///      `Palette.surface`, and the card has to look deliberate for them too —
///      which is why the layout never depends on colour being present.
///
/// **There are no action buttons.** A filled accent button and a bordered one
/// sitting on someone's own palette is two more colours competing with the only
/// ones that mean anything here, and they were the loudest objects on a surface
/// whose whole job is to show a person. The full profile is still reachable —
/// **the avatar is the target** — it just is not a chrome slab any more.
struct MiniProfileCard: View {
    var profile: ProfilePresentation
    var openFullProfile: () -> Void
    /// What a click on an emoji in this person's prose does. Nil leaves them
    /// inert pictures, which is the honest answer on a surface with no route to
    /// ask about one.
    var openEmoji: ((EmojiRef) -> Void)?

    /// The emoji whose card is open, if any. One popover per surface rather
    /// than one per picture in somebody's prose.
    @State private var inspectedEmoji: EmojiRef?
    /// How wide the card is laid out.
    ///
    /// A parameter rather than a constant because the same card is the popover
    /// beside a message *and* the column beside a direct message. Two copies of
    /// this view would be two places for a badge row, a role chip or a status
    /// bubble to drift.
    var width: CGFloat = 320
    /// Whether this is a floating card or a column that fills its pane.
    ///
    /// **The two are not the same object with a different width.** A popover is
    /// a card: it has corners, a shadow, and it ends where its content does. A
    /// sidebar is a *region*: its ground runs the height of the pane, and a
    /// rounded card floating at the top of an empty column with a shadow under
    /// it reads as something that failed to load the rest of itself.
    var form: Form = .card

    enum Form: Equatable {
        case card
        case column
    }

    @Environment(\.motion) private var motion
    /// **One height, banner or no banner.**
    ///
    /// The no-banner case used to be 64pt, which is less than the avatar's own
    /// 80 — so the avatar hung most of the way outside its own plate and the
    /// card read as two mismatched pieces. Every profile now reserves the same
    /// block, and what fills it (artwork, or the accent) is a paint-time
    /// difference rather than a layout one.
    private var bannerHeight: CGFloat { 108 }
    /// How far the avatar hangs below the banner.
    private var avatarDrop: CGFloat { Metrics.avatarProfile / 2 - 6 }

    private var ground: ProfileGround { ProfileGround(themeColorValues: profile.themeColorValues) }

    /// What a section has to lay out inside. One definition, because the badge
    /// flyout has to know it in order not to reach past the card's edge.
    private var contentWidth: CGFloat { width - Spacing.margin * 2 }

    /// The display name is **not** tinted by role, and that is a correction.
    ///
    /// Checked against Discord for the same member: their top coloured role is
    /// a yellow "Admin", and Discord draws the name in the profile's own
    /// treatment rather than in yellow. Colouring it by role also says the same
    /// thing twice — the role chips are directly beneath, each with its own
    /// swatch — and a saturated name over a themed ground is the pairing most
    /// likely to be unreadable, because neither colour was chosen with the
    /// other in mind.
    private var nameStyle: AnyShapeStyle { AnyShapeStyle(InkColor.primary) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            banner
            identity
            if !profile.isLoading { detail }

            if profile.isLoading {
                ProfileSkeleton(contentWidth: contentWidth)
            } else if let bio = profile.bio, !bio.isEmpty {
                section("About Me") {
                    // **Markdown, not a plain string.** A bio is the one place
                    // in the app where people write `<:emoji:id>` and `<t:…>` by
                    // hand, and a `Text` renders both as literal angle brackets.
                    ProseText(
                        markdown: bio,
                        font: .system(.caption),
                        color: InkColor.secondary,
                        emojiSide: 16,
                        onEmoji: openEmoji ?? { inspectedEmoji = $0 }
                    )
                }
            }
            if !profile.isLoading, !profile.roles.isEmpty {
                section("Roles") { RoleChipFlow(roles: profile.roles) }
            }
        }
        // **Pinned on the VStack itself, not only on whatever hosts the card.**
        // A `.frame` on a `ScrollView` sets the viewport; it does not stop the
        // CONTENT reporting a larger width. Constraining the stack constrains
        // the proposal every child is offered, so no future child can move the
        // column again.
        .frame(width: width)
        // **A column draws no ground of its own.** Its pane paints one that runs
        // the full height — see `DirectMessageProfilePane` — because a ground
        // that stops where the content stops leaves the lower half of the
        // sidebar showing the transcript's black through it, which is what a
        // rounded card floating at the top of an empty column actually was.
        .modifier(ProfileGroundFill(ground: ground, corner: corner, paints: form == .card))
        .clipShape(.rect(cornerRadius: corner, style: .continuous))
        .overlay {
            if form == .card {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(ground.borderStyle, lineWidth: ground.borderWidth)
            }
        }
        // The effect is drawn OVER the finished card and clipped to it — its
        // layers are authored at `zIndex` 100+, above everything. `allowsHitTesting`
        // is off at the view level as well as in the host, so a composition
        // covering the whole card cannot swallow a click meant for it.
        .overlay {
            if let effect = profile.effect {
                ProfileEffectView(effect: effect, width: width)
                    .allowsHitTesting(false)
                    .accessibilityLabel(Text(effect.accessibilityLabel ?? effect.title))
            }
        }
        .clipShape(.rect(cornerRadius: corner, style: .continuous))
        // A column casts no shadow: it is not floating over anything.
        .shadow(color: .black.opacity(form == .card ? 0.45 : 0), radius: 28, y: 10)
        // The card for an emoji somebody put in their bio. A nested popover,
        // one per surface — see `ExpressionInfoPopover`.
        .presentsExpressionInfo(for: $inspectedEmoji)
    }

    /// A card has corners; a column is a region of the window and has none.
    private var corner: CGFloat { form == .card ? Radius.card : 0 }

    private var banner: some View {
        ZStack(alignment: .bottomLeading) {
            // **The artwork is an overlay on a zero-content ground, never a
            // sibling in the stack**, and this card had the bug the full
            // profile was already fixed for.
            //
            // An aspect-**filled** `RemoteImage` reports the IMAGE's size to
            // layout, not the box's. In a popover that is invisible — the
            // popover sizes to its content, so a card that asks to be 900 wide
            // simply gets a wider popover nobody notices. Put the same card in a
            // `ScrollView` column and the trap fires: a vertical scroll view
            // answers a too-wide child by CENTRING it and clipping both sides,
            // which sliced the first letter off the name, off `ABOUT ME`, and
            // off the avatar.
            //
            // `Color.clear` accepts whatever width it is offered, so a filling
            // picture contributes no width anywhere.
            Color.clear
                .background { bannerPlate }
                .overlay {
                    if let bannerURL = profile.bannerURL {
                        // The still underneath, the animated layer over it. A
                        // user banner with an `a_` hash is served as a GIF and
                        // drifts; one without is a single frame and never
                        // reaches the animated path at all.
                        ZStack {
                            RemoteImage(url: bannerURL, side: width, bucket: .artwork) {
                                Color.clear
                            }
                            .aspectRatio(contentMode: .fill)

                            // Only when it can animate — the extension says so,
                            // so a still banner never pays for a second fetch, a
                            // multi-frame decode and a coordinator to learn it
                            // has one frame. The budget is the banner's, not a
                            // decoration's: a frame here is around half a
                            // megabyte, and the 6 MB default would buy nine.
                            if CDN.canAnimate(bannerURL) {
                                AnimatedDecoration(
                                    url: bannerURL,
                                    side: width,
                                    gravity: .resizeAspectFill,
                                    byteBudget: 12 * 1024 * 1024
                                )
                            }
                        }
                    }
                }
                .frame(height: bannerHeight)
                .clipped()
            // The avatar's cut-out. See `ProfileAvatar`: the gap around the
            // avatar is a hole in this artwork, so it shows the card's own
            // ground rather than a stroke of flat black painted on top.
            .mask(alignment: .bottomLeading) {
                ProfileAvatar.bannerMask(drop: avatarDrop)
            }

            ProfileAvatar(
                profile: profile,
                drop: avatarDrop,
                dotSide: 16,
                openFullProfile: openFullProfile
            )

            if hasCustomStatus {
                // The cluster places itself from the avatar's drop — see
                // `CustomStatusBubble`. The banner, the avatar and the bubble
                // are one arrangement, and a hand-tuned offset here would be
                // right on one of the two profile surfaces at most.
                CustomStatusBubble(
                    text: profile.customStatus,
                    emoji: profile.customStatusEmoji,
                    avatarDrop: avatarDrop,
                    cardWidth: width
                )
            }
        }
        // **The avatar's drop AND its decoration's overhang.** A decoration is
        // drawn outside the avatar's bounds and contributes no layout size, so
        // reserving the drop alone put the display name under a ring of clouds.
        .padding(.bottom, avatarDrop + ProfileAvatar.decorationOverhang)
    }

    private var hasCustomStatus: Bool {
        profile.customStatusEmoji != nil || profile.customStatus?.isEmpty == false
    }

    /// What stands behind the banner while the artwork loads, and instead of it
    /// when there is none.
    ///
    /// **This is where `accent_color` belongs, and the only place it does.**
    /// Discord derives it from the banner, so it is exactly right as a stand-in
    /// for one — a person with no banner image gets their accent as a solid
    /// strip, which is what Discord draws too — and exactly wrong as a tint for
    /// the body underneath.
    private var bannerPlate: some View {
        let seed = ground.plateSeed(accentColorValue: profile.accentColorValue)
        return LinearGradient(
            colors: [seed, seed.opacity(0.6)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            // **The marks sit beside the NAME.** A clan tag and the APP mark are
            // both worn as part of how someone is addressed — the member list
            // draws them against the name for the same reason — and hanging
            // them off the handle underneath separates a person from the thing
            // they chose to be identified by.
            HStack(spacing: Spacing.tight) {
                Text(profile.displayName)
                    .font(.system(.title2, weight: .bold))
                    .foregroundStyle(nameStyle)
                    .lineLimit(1)
                if let tag = profile.guildTag {
                    GuildTagChip(tag: tag)
                }
                if profile.isBot {
                    TagChip(text: "APP")
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: Spacing.tight) {
                Text(profile.handle)
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.secondary)
                if let pronouns = profile.pronouns, !pronouns.isEmpty {
                    // Separated by a bullet rather than put on its own line:
                    // it is part of how someone is addressed, not a fact about
                    // them, and Discord sets it inline for the same reason.
                    Text("•").foregroundStyle(InkColor.tertiary)
                    Text(pronouns)
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.system(.caption))

            // The nickname is an extra line, never a replacement: a nickname
            // that silently stands in for someone's real name makes them
            // unfindable in search and in a mention.
            if let nickname = profile.nickname, nickname != profile.displayName {
                Text("Known here as \(nickname)")
                    .font(.system(.caption2))
                    .foregroundStyle(InkColor.tertiary)
            }

            if !profile.badges.isEmpty {
                BadgeRow(badges: profile.badges)
                    .padding(.top, 2)
            }

            if let subtitle = profile.activity?.rowSubtitle {
                Label(subtitle, systemImage: "gamecontroller.fill")
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Spacing.margin)
        // A deliberate gap under the avatar rather than the name starting where
        // the picture stops. The clearance above is arithmetic — what the
        // artwork occupies — and this is the breathing room on top of it.
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.snug)
    }

    /// The one line the profile route pays for that is not a badge.
    ///
    /// **Nitro and the pre-2023 name used to be rows here and are not any
    /// more.** Both are facts Discord publishes as badges, and a card that
    /// states them in text under the mutual-servers line says the same thing
    /// twice on any account whose badge row already carries them. They live on
    /// their badges now, where a reader looks for them: hovering the Nitro crest
    /// gives the "since" date, hovering the legacy crest gives the old name.
    ///
    /// What is left is the mutual servers, and that is a *destination* rather
    /// than a statement — which is why it is the only one that stays.
    @ViewBuilder
    private var detail: some View {
        if !profile.mutualServers.isEmpty {
            MutualServersRow(servers: profile.mutualServers)
                .padding(.horizontal, Spacing.margin)
                .padding(.bottom, Spacing.snug)
        }

        if !profile.connections.isEmpty {
            section("Connections") {
                FlowLayout(spacing: Spacing.tight) {
                    ForEach(profile.connections) { connection in
                        ConnectionChip(connection: connection)
                    }
                }
            }
        }
    }

    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(title.uppercased())
                .font(Typeface.sectionHeader)
                .foregroundStyle(InkColor.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.snug)
    }
}
