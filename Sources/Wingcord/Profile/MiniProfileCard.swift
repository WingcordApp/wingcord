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
    /// What a click on a link in this person's prose does. Nil draws links as
    /// accent text and takes no clicks, which is what a surface with no opener
    /// can honestly offer — `INVARIANTS.md` §5.5.
    var openLink: ((String) -> Void)?
    /// The strip of game covers, or nil where they have arranged no board.
    ///
    /// Resolved by the presenter for the same reason the full profile's board
    /// is: joining the widgets to the games is a table lookup per cover, and
    /// doing it in this body would redo it on every hover anywhere on the card.
    var gameCollection: GameCollection?

    /// The emoji whose card is open, if any. One popover per surface rather
    /// than one per picture in somebody's prose.
    @State private var inspectedEmoji: EmojiRef?
    /// Whether the person menu is open.
    @State private var isMenuOpen = false
    /// Whether the still under the moving banner has been taken away.
    @State private var bannerIsPlaying = false
    /// Whether the pointer is over the card, which fades the profile effect
    /// back so the name and banner under it can be read.
    @State private var isEffectFaded = false
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

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    /// **One height, banner or no banner.**
    ///
    /// The no-banner case used to be 64pt, which is less than the avatar's own
    /// 80 — so the avatar hung most of the way outside its own plate and the
    /// card read as two mismatched pieces. Every profile now reserves the same
    /// block, and what fills it (artwork, or the accent) is a paint-time
    /// difference rather than a layout one.
    static let bannerHeight: CGFloat = 108
    /// How far the avatar hangs below the banner.
    private var avatarDrop: CGFloat { Metrics.avatarProfile / 2 - 6 }

    private var ground: ProfileGround {
        // **The column follows the APP's theme and the popout does not**, and
        // they are the same view — Discord's DM sidebar hands its own
        // `themeOverride` down while the popout beside it takes the person's.
        // See `ProfileGround.isDark`.
        ProfileGround(
            themeColorValues: profile.themeColorValues,
            followsAppTheme: form == .column
        )
    }

    /// What a section has to lay out inside. One definition, because the badge
    /// flyout has to know it in order not to reach past the card's edge.
    private var contentWidth: CGFloat { width - Spacing.margin * 2 }


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Above the banner, which is where Discord puts it — the first
            // thing on the card rather than a mark inside it.
            if profile.isProfilePrivate { PrivateProfileBanner() }
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
                        onEmoji: openEmoji ?? { inspectedEmoji = $0 },
                    onLink: openLink
                    )
                }
            }
            // **Between the bio and the roles**, which is where Discord puts it
            // and where it belongs regardless: the bio is what someone says
            // about themselves and the roles are what a server says about them,
            // so the games — which they also chose — sit with the first group.
            if !profile.isLoading, let gameCollection {
                GameCollectionRow(
                    collection: gameCollection,
                    ground: ground,
                    openBoard: openFullProfile
                )
                    .padding(.horizontal, Spacing.margin)
                    .padding(.bottom, Spacing.snug)
            }
            currentActivity
            if !profile.isLoading, !profile.roles.isEmpty {
                section("Roles") {
                    // **Two rows, then a count.** A card is a summary that opens
                    // beside a row; somebody holding forty-six roles would
                    // otherwise open a card taller than the window, and the
                    // roles are not why anybody clicked. The full profile shows
                    // all of them.
                    RoleChipFlow(
                        roles: profile.roles,
                        maximumRows: form == .card ? 2 : nil,
                        width: contentWidth
                    )
                }
            }
            if !profile.isLoading {
                connections
                if !profile.isSelf {
                    ProfileNoteField(
                        userID: profile.userID,
                        note: profile.note,
                        width: contentWidth
                    )
                    .padding(.horizontal, Spacing.margin)
                    .padding(.bottom, Spacing.snug)
                }
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
        .modifier(ProfileGroundFill(
            ground: ground,
            corner: corner,
            paints: form == .card,
            form: .card(topHold: Self.bannerHeight)
        ))
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
                    // Steps back under the pointer so the name and banner it is
                    // drawn over can be read — Discord's own `.hovered` rule.
                    .opacity(isEffectFaded ? ProfileEffectFade.hovered : 1)
                    .animation(ProfileEffectFade.animation, value: isEffectFaded)
            }
        }
        .onHover { isEffectFaded = $0 }
        // **The one control on the card, and it is a glyph rather than a
        // slab.** What this surface used to have was a filled accent button and
        // a bordered one sitting on somebody's own palette — two more colours
        // competing with the only ones that mean anything here. A quiet circle
        // in the corner is a different object: it names no action until it is
        // opened, so it cannot compete with the identity beside it.
        .overlay(alignment: .topTrailing) {
            if !profile.isSelf {
                UserMenuButton(isOpen: $isMenuOpen)
                    .padding(Spacing.base)
                    .presentsUserMenu(
                        for: profile.userID,
                        inGuild: profile.guild?.id,
                        profileOptions: .init(
                            // The card's own item. The full profile omits it,
                            // being already there.
                            opensFullProfile: true,
                            alternateName: profile.alternateName,
                            showsMainProfile: profile.showsMainProfile
                        ),
                        onProfileOption: { option in
                            switch option {
                            case .fullProfile: model.openFullProfile()
                            case .mainProfile: model.showMainProfile(true)
                            case .perServerProfile: model.showMainProfile(false)
                            }
                        },
                        isPresented: $isMenuOpen
                    )
            }
        }
        .clipShape(.rect(cornerRadius: corner, style: .continuous))
        // A column casts no shadow: it is not floating over anything.
        .shadow(color: .black.opacity(form == .card ? 0.45 : 0), radius: 28, y: 10)
        // **A frame wraps a card's CORNERS, so a column never gets one.** That
        // is the same distinction `Form` already draws and not a second one: a
        // card ends where its content does and has four edges to hang artwork
        // from, while a column is a region running the height of the pane whose
        // foot is the window's. There is no bottom edge there to anchor to, and
        // a garland pinned to the bottom of a sidebar is not what anybody
        // bought.
        //
        // After the shadow, deliberately. Applied before it, the overhanging
        // artwork would be shadowed too — a drop shadow under a rose hanging in
        // free space, cast by nothing.
        //
        // After the shadow, deliberately: applied before it, the artwork would
        // be shadowed along with the card.
        .profileFrame(form == .card ? profile.frame : nil, cardWidth: width)
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
                            // Gone once the film is up: two copies of one
                            // picture composited every frame buys nothing.
                            // See `bannerPlays` for why the latch is read
                            // beside a question the state cannot answer.
                            .opacity(bannerIsPlaying && bannerPlays ? 0 : 1)

                            // Only when it can animate — the extension says so,
                            // so a still banner never pays for a second fetch, a
                            // multi-frame decode and a coordinator to learn it
                            // has one frame.
                            //
                            // **The budget is the whole loop at the drawn
                            // size.** A hand-picked 12 MB bought twenty frames
                            // of a sixty-frame banner here, which is every third
                            // one — see `AnimatedImage.budget(forDrawn:)`, which
                            // is the arithmetic this comment used to describe.
                            if CDN.canAnimate(bannerURL) {
                                AnimatedDecoration(
                                    url: bannerURL,
                                    side: width,
                                    gravity: .resizeAspectFill,
                                    byteBudget: AnimatedImage.budget(
                                        forDrawn: CGSize(
                                            width: width,
                                            height: Self.bannerHeight
                                        )
                                    ),
                                    onPlayback: { playing in
                                        guard bannerIsPlaying != playing else { return }
                                        bannerIsPlaying = playing
                                    }
                                )
                            }
                        }
                        // A banner that changes has to put its still back while
                        // the new one resolves, or the strip is empty between.
                        .onChange(of: bannerURL) { bannerIsPlaying = false }
                    }
                }
                .frame(height: Self.bannerHeight)
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
                    cardWidth: width,
                    fill: ground.statusBubbleFill
                )
            }
        }
        // **The avatar's drop AND its decoration's overhang.** A decoration is
        // drawn outside the avatar's bounds and contributes no layout size, so
        // reserving the drop alone put the display name under a ring of clouds.
        .padding(.bottom, avatarDrop + ProfileAvatar.decorationOverhang())
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
        Rectangle().fill(ground.plateStyle(accentColorValue: profile.accentColorValue))
    }

    /// Whether there is a moving form to put up at all.
    ///
    /// **Read beside `bannerIsPlaying`, and it is what stops that latch
    /// sticking.** Only the film clears the latch, and a filmstrip that is
    /// dismantled reports nothing on its way out — so without this the still
    /// stays at zero over a film that is no longer there and the card draws a
    /// bare plate where somebody's banner was. `AvatarView` carries the same
    /// pair, for the same defect.
    private var bannerPlays: Bool {
        profile.bannerURL.map(CDN.canAnimate) ?? false
    }

    /// The widest the display name may come out, after the marks worn beside
    /// it have taken theirs.
    ///
    /// Measured rather than guessed: the chip's width is `MemberRowGeometry`'s
    /// own arithmetic, so the reservation here and the chip drawn there cannot
    /// disagree.
    private var nameWidth: CGFloat {
        var available = contentWidth
        if let tag = profile.guildTag {
            available -= MemberRowGeometry.tagChipWidth(
                textWidth: TimelineLayoutEngine.measure(tag.text, font: MemberRowGeometry.tagChipFont),
                hasBadge: tag.badgeURL != nil
            ) + Spacing.tight
        }
        if profile.isBot { available -= 34 + Spacing.tight }
        // A floor, so a card whose marks are wider than its content still gives
        // the name something to truncate into rather than a negative width.
        return max(80, available)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            // **The marks sit beside the NAME.** A clan tag and the APP mark are
            // both worn as part of how someone is addressed — the member list
            // draws them against the name for the same reason — and hanging
            // them off the handle underneath separates a person from the thing
            // they chose to be identified by.
            HStack(spacing: Spacing.tight) {
                StyledDisplayName(
                    text: profile.displayName,
                    style: profile.displayNameStyle,
                    textStyle: .title2,
                    weight: .bold,
                    // `heading-lg/bold`, read out of Discord's own stylesheet.
                    // `.title2` is 17 on macOS, which is what this was and which
                    // is visibly small beside the real thing.
                    pointSize: 20,
                    // **The card's own width, stated — the same fix the full
                    // profile already carries.** A styled name is a drawn view,
                    // so the `.lineLimit(1)` a `Text` would honour reaches
                    // nothing: it reported its whole measured width, the row
                    // grew to hold it, and the tag chip was laid down on top of
                    // the letters. Visible only on a long name, which is why it
                    // survived every short one.
                    maximumWidth: nameWidth
                )
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
                // **A label, never a filter.** The profile route says
                // `private: true` and still hands over the mutual servers the
                // reader can see for themselves; hiding them here would be
                // inventing a restriction the server did not make, and dropping
                // the flag would be losing something this person chose to say.
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
                BadgeRow(badges: profile.badges, premiumSince: profile.premiumSince)
                    .padding(.top, 2)
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

        if !profile.mutualFriends.isEmpty {
            MutualFriendsRow(friends: profile.mutualFriends)
                .padding(.horizontal, Spacing.margin)
                .padding(.bottom, Spacing.snug)
        }
    }

    /// What they are doing right now, drawn in full.
    ///
    /// **The whole rich presence, and it used to be one grey line.** The card
    /// said "Playing Counter-Strike 2 with Medal" in caption type under the
    /// badges, which threw away the game's art, the publisher's mark riding its
    /// corner, the two lines the app wrote, the clock and both of its buttons.
    /// Every one of those is on the wire and the card has room for them.
    ///
    /// **No recent activity here, and that is deliberate.** A card is a summary
    /// that opens beside a row; twenty inventory entries would make it taller
    /// than the window, and they are what the full profile's Activity tab is
    /// for. What somebody is doing *now* is the one thing on that tab worth
    /// answering before the reader has asked for it.
    @ViewBuilder
    private var currentActivity: some View {
        if !profile.isLoading, let activity = profile.activity, activity.kind != .custom {
            CurrentActivityCard(
                activity: activity,
                buttonURLs: profile.activityButtonURLs,
                storeOffers: profile.activityStoreOffers,
                ground: ground,
                openGame: openGame(for: activity),
                applicationIconURL: model.applicationIconURL(
                    activity.applicationID, side: Metrics.avatarProfile
                )
            )
            .padding(.horizontal, Spacing.margin)
            .padding(.bottom, Spacing.snug)
        }
    }

    /// **Only for a game.** A Spotify session and a custom status have no page
    /// behind them, and a title that looks pressable and opens nothing is the
    /// inert control `INVARIANTS.md` §5.5 forbids.
    private func openGame(for activity: Activity) -> (() -> Void)? {
        guard activity.kind == .playing, let id = activity.applicationID else { return nil }
        return { model.openGameProfile(id) }
    }

    /// The accounts they have linked.
    ///
    /// **Below the roles, not above the bio.** Connections are a footer: they
    /// are where somebody goes *after* reading who this person is, and putting
    /// them between the mutual servers and the bio pushed the one line the card
    /// exists for below the fold on anybody with four linked accounts.
    @ViewBuilder
    private var connections: some View {
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
