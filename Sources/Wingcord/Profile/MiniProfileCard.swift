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

    @Environment(\.motion) private var motion

    private var width: CGFloat { 320 }
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
                    Text(bio)
                        .font(.system(.caption))
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !profile.isLoading, !profile.roles.isEmpty {
                section("Roles") { RoleChipFlow(roles: profile.roles) }
            }
        }
        .frame(width: width)
        .modifier(ProfileGroundFill(ground: ground, corner: Radius.card))
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(ground.borderStyle, lineWidth: ground.borderWidth)
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
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 28, y: 10)
    }

    private var banner: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let bannerURL = profile.bannerURL {
                    // The still underneath, the animated layer over it. A user
                    // banner with an `a_` hash is served as a GIF and drifts;
                    // one without is a single frame and never reaches the
                    // animated path at all.
                    ZStack {
                        RemoteImage(url: bannerURL, side: width, bucket: .artwork) {
                            bannerPlate
                        }
                        .aspectRatio(contentMode: .fill)

                        // Only when it can animate — the extension says so, so a
                        // still banner never pays for a second fetch, a
                        // multi-frame decode and a coordinator to learn it has
                        // one frame. The budget is the banner's, not a
                        // decoration's: a frame here is around half a megabyte,
                        // and the 6 MB default would buy about nine of them.
                        if CDN.canAnimate(bannerURL) {
                            AnimatedDecoration(
                                url: bannerURL,
                                side: width,
                                gravity: .resizeAspectFill,
                                byteBudget: 12 * 1024 * 1024
                            )
                        }
                    }
                } else {
                    bannerPlate
                }
            }
            .frame(height: bannerHeight)
            .frame(maxWidth: .infinity)
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
        }
        .padding(.bottom, avatarDrop)
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

            if let customStatus = profile.customStatus, !customStatus.isEmpty {
                Text(customStatus)
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.secondary)
                    .lineLimit(2)
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
