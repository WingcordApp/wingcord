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
    /// Opens the full profile — on a tab, when a stack's peek asks for the one
    /// its cards continue on.
    var openFullProfile: (ProfileTab?) -> Void
    /// What a click on an emoji in this person's prose does. Nil leaves them
    /// inert pictures, which is the honest answer on a surface with no route to
    /// ask about one.
    var openEmoji: ((EmojiRef) -> Void)?
    /// What a click on a link in this person's prose does. Nil draws links as
    /// accent text and takes no clicks, which is what a surface with no opener
    /// can honestly offer — `INVARIANTS.md` §5.5.
    var openLink: ((String) -> Void)?
    /// Their widgets as the popout stacks them, empty where they have no board.
    ///
    /// Resolved by the presenter for the same reason the full profile's board
    /// is: joining the widgets to their games, templates and identities is a
    /// table lookup per card, and doing it in this body would redo it on every
    /// hover anywhere on the card.
    var widgetPreviews: [WidgetPreview] = []

    /// The emoji whose card is open, if any. One popover per surface rather
    /// than one per picture in somebody's prose.
    @State private var inspectedEmoji: EmojiRef?
    /// Whether the person menu is open.
    @State private var isMenuOpen = false
    /// The pointer on the name or the handle, which underline together.
    @State private var isHoveringName = false
    /// Which list the reader's own action block is showing.
    ///
    /// **Held here rather than in the block**, because the status bubble at the
    /// top of the card is the other thing that opens the editor: clicking what
    /// you wrote is how you change it.
    @State private var ownSurface: OwnProfileSurface = .root
    /// The prompt an empty bubble carries, chosen once per card.
    ///
    /// **Not per body evaluation.** A body runs on every hover, and a prompt
    /// that changed under the pointer would read as a card that cannot make up
    /// its mind — see `CustomStatusPrompt`.
    @State private var ownStatusPrompt = CustomStatusPrompt.prompt(
        seed: Int.random(in: 0..<1000)
    )
    /// Whether the still under the moving banner has been taken away.
    @State private var bannerIsPlaying = false
    /// Whether the pointer is over the card, which fades the profile effect
    /// back so the name and banner under it can be read.
    @State private var isEffectFaded = false
    /// Whether the reader said yes to "Show Profile?" on this card.
    ///
    /// **Per card, as Discord's is** — its `useState` lives and dies with the
    /// popout, so the next card opened on a blocked person warns again.
    @State private var isWarningPassed = false
    /// How wide the card is laid out.
    ///
    /// A parameter rather than a constant because the same card is the popover
    /// beside a message *and* the column beside a direct message. Two copies of
    /// this view would be two places for a badge row, a role chip or a status
    /// bubble to drift.
    var width: CGFloat = 320
    /// The tallest the card may stand — the window's height, less the
    /// placement's margins. Past it the card scrolls inside its own rounded
    /// edge rather than running off the bottom of the window. Nil where the
    /// host already scrolls it (the DM column).
    var maxHeight: CGFloat?
    /// Whether this is a floating card or a column that fills its pane.
    ///
    /// **The two are not the same object with a different width.** A popover is
    /// a card: it has corners, a shadow, and it ends where its content does. A
    /// sidebar is a *region*: its ground runs the height of the pane, and a
    /// rounded card floating at the top of an empty column with a shadow under
    /// it reads as something that failed to load the rest of itself.
    var form: Form = .card
    /// The controls the reader's own card carries, from the now bar.
    ///
    /// **Nil on every other card in the app**, which is what keeps this out of
    /// their bodies: a profile opened from a message is somebody else's, and
    /// there is nothing on it to edit. See `OwnProfilePanel`.
    var ownActions: OwnProfileActions?
    /// Whether the profile effect plays over the card. Off only where the card
    /// is measured and never shown — an effect is the largest decode the app
    /// makes and changes nothing about the card's size.
    var showsEffect = true
    /// Whether the banner and the emoji in the bio move.
    ///
    /// **The DM column passes its hover.** It stays on screen for as long as
    /// the conversation does, and a banner looping beside somebody reading is
    /// motion nobody is looking at — Discord's sidebar plays both only while
    /// the pointer is on it (`animateOnHoverOrFocusOnly`, `r1`). Its avatar and
    /// decoration are not gated, and neither are they here. A card opened by a
    /// click is being looked at, so it always plays.
    var animates = true

    enum Form: Equatable {
        case card
        case column
        /// Inside a message — Discord's user profile embed (module `273147`):
        /// who they are, whom the reader shares with them, and the way to
        /// the full profile. Nothing they wrote about themselves.
        case embed
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
        if let warning = shownWarning {
            warningCard(warning)
        } else {
            profileCard
        }
    }

    /// The warning this card opens behind — see `AppModel.profileWarning`.
    private var shownWarning: ProfileWarning? {
        guard !profile.isSelf, !isWarningPassed else { return nil }
        return model.profileWarning(for: profile.userID)
    }

    /// "Show Profile?" on the person's own ground, in the card's frame.
    private func warningCard(_ warning: ProfileWarning) -> some View {
        let warningForm: ProfileWarningView.Form = switch form {
        case .card: .card
        case .column: .column
        case .embed: .embed
        }
        return ProfileWarningView(
            warning: warning,
            name: profile.displayName,
            avatarURL: profile.avatarURL,
            monogram: profile.monogram,
            form: warningForm,
            width: width,
            reveal: { isWarningPassed = true },
            skip: {
                isWarningPassed = true
                model.skipIgnoredProfileWarning()
            }
        )
        .frame(width: width)
        .modifier(ScrollsPastHeight(maxHeight: maxHeight))
        .modifier(ProfileGroundFill(ground: ground, corner: corner, paints: form != .column))
        .clipShape(.rect(cornerRadius: corner, style: .continuous))
        .overlay {
            if form != .column {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(ground.borderStyle, lineWidth: ground.borderWidth)
            }
        }
        .shadow(color: .black.opacity(form == .card ? 0.45 : 0), radius: 28, x: 0, y: 10)
    }

    @ViewBuilder
    private var profileCard: some View {
        // Read once: the shadow and the frame's staples take the same value.
        let frameShadow = frameShadowOpacity
        VStack(alignment: .leading, spacing: 0) {
            // Above the banner, which is where Discord puts it — the first
            // thing on the card rather than a mark inside it.
            if profile.isProfilePrivate { PrivateProfileBanner() }
            banner
            identity
            if profile.isPartlyUnavailable, !profile.isLoading {
                PartialProfileNotice(retry: nil)
                    .padding(.horizontal, Spacing.margin)
                    .padding(.bottom, Spacing.snug)
            }
            if !profile.isLoading { detail }

            if form == .embed {
                if profile.isLoading { ProfileSkeleton(contentWidth: contentWidth) }
                if !profile.isSystem { viewProfileButton }
            } else {
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
                            onLink: openLink,
                            animates: animates
                        )
                    }
                }
                // **Between the bio and the activities**, which is where Discord
                // puts them and where they belong regardless: the bio is what
                // someone says about themselves, and the widgets are what else
                // they chose to show.
                if !profile.isLoading {
                    ProfileWidgetStack(
                        previews: widgetPreviews,
                        ground: ground,
                        width: contentWidth,
                        isColumn: form == .column,
                        openBoard: { openFullProfile(.board) }
                    )
                    // A personal widget's pictures are addressed by its owner.
                    .environment(\.widgetOwner, profile.userID)
                    .padding(.horizontal, Spacing.margin)
                    .padding(.bottom, widgetPreviews.isEmpty ? 0 : Spacing.snug)
                }
                // **Above the roles**: what somebody is doing now belongs with
                // what they chose to show, not with what a server says about
                // them.
                activityStack
                let roleEditing = profile.showsMainProfile
                    ? nil
                    : profile.guild.flatMap { model.roleEditing(for: profile.userID, in: $0.id) }
                if !profile.isLoading, !profile.roles.isEmpty || roleEditing?.addable.isEmpty == false {
                    section("Roles") {
                        // **Two rows, then a count.** A card is a summary that opens
                        // beside a row; somebody holding forty-six roles would
                        // otherwise open a card taller than the window, and the
                        // roles are not why anybody clicked. The full profile shows
                        // all of them.
                        RoleChipFlow(
                            roles: profile.roles,
                            maximumRows: form == .card ? 2 : nil,
                            width: contentWidth,
                            editing: roleEditing
                        )
                    }
                }
                if !profile.isLoading {
                    connections
                    // Streamer Mode's personal information: the reader's notes.
                    if !profile.isSelf, !StreamerMode.shared.hidesPersonalInformation {
                        ProfileNoteField(
                            userID: profile.userID,
                            note: profile.note,
                            width: contentWidth
                        )
                        .padding(.horizontal, Spacing.margin)
                        .padding(.bottom, Spacing.snug)
                    }
                }
                // **Last, under everything the card says about the person.** These
                // act on the profile above them, and a block of commands between the
                // bio and the roles would read as part of what the profile says.
                if let ownActions {
                    OwnProfileActionBlock(actions: ownActions, surface: $ownSurface)
                        // Set Status… opens the card on the editor, without
                        // the swap's animation — `ProfileRequest.ownSurface`.
                        .onChange(of: ownActions.startsOn, initial: true) { _, start in
                            guard start != .root else { return }
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { ownSurface = start }
                        }
                }
            }
        }
        // **Pinned on the VStack itself, not only on whatever hosts the card.**
        // A `.frame` on a `ScrollView` sets the viewport; it does not stop the
        // CONTENT reporting a larger width. Constraining the stack constrains
        // the proposal every child is offered, so no future child can move the
        // column again.
        .frame(width: width)
        .modifier(ScrollsPastHeight(maxHeight: maxHeight))
        // **A column draws no ground of its own.** Its pane paints one that runs
        // the full height — see `DirectMessageProfilePane` — because a ground
        // that stops where the content stops leaves the lower half of the
        // sidebar showing the transcript's black through it, which is what a
        // rounded card floating at the top of an empty column actually was.
        .modifier(ProfileGroundFill(
            ground: ground,
            corner: corner,
            paints: form != .column,
            form: .card(topHold: Self.bannerHeight)
        ))
        .clipShape(.rect(cornerRadius: corner, style: .continuous))
        .overlay {
            if form != .column {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(ground.borderStyle, lineWidth: ground.borderWidth)
            }
        }
        // The effect is drawn OVER the finished card and clipped to it — its
        // layers are authored at `zIndex` 100+, above everything. `allowsHitTesting`
        // is off at the view level as well as in the host, so a composition
        // covering the whole card cannot swallow a click meant for it.
        .overlay {
            if showsEffect, let effect = profile.effect {
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
            if !profile.isSelf, model.offersProfileMenu(for: profile.userID) {
                UserMenuButton(isOpen: $isMenuOpen)
                    .padding(Spacing.base)
                    .presentsUserMenu(
                        for: profile.userID,
                        inGuild: profile.guild?.id,
                        profileOptions: .init(
                            // **The card's own item, and its only one.** The
                            // full profile omits it, being already there — and
                            // this card omits *View Main Profile*, which Discord
                            // offers only from the full one. A popout is a
                            // glance; swapping which of two profiles it is
                            // showing, in place, with no room to say which, is a
                            // control that leaves the reader unsure what they
                            // are looking at.
                            opensFullProfile: true
                        ),
                        onProfileOption: { option in
                            switch option {
                            // **The host's own opener, never the store's.** A
                            // card in a popover raises its request, the DM
                            // column has no request to raise and opens one —
                            // only the host knows which, and asking the store
                            // to raise "the open card" from the column did
                            // nothing at all.
                            case .fullProfile: openFullProfile(nil)
                            // Not offered here — see the options above. Written
                            // out rather than defaulted, so a case added later
                            // is a compile error rather than a silent no-op.
                            case .mainProfile, .perServerProfile: break
                            }
                        },
                        isPresented: $isMenuOpen
                    )
            }
        }
        .clipShape(.rect(cornerRadius: corner, style: .continuous))
        // A column casts no shadow: it is not floating over anything. A card
        // wearing a frame casts Discord's in place of its own — see
        // `FrameShadow`. One modifier either way, so the frame landing after
        // the card changes its values and not its identity.
        .shadow(
            color: .black.opacity(form == .card ? frameShadow ?? 0.45 : 0),
            radius: frameShadow == nil ? 28 : FrameShadow.radius,
            x: frameShadow == nil ? 0 : FrameShadow.offset,
            y: frameShadow == nil ? 10 : FrameShadow.offset
        )
        // **In a column the frame hangs on the pane, not here.** The column's
        // card is the pane's rounded box, which runs to the foot of the window;
        // this view is only what scrolls inside it, and artwork hung off it
        // would scroll away with the bio — see `DirectMessageProfilePane`.
        //
        // After the shadow, deliberately. Applied before it, the overhanging
        // artwork would be shadowed too — a drop shadow under a rose hanging in
        // free space, cast by nothing; the staples throw their own instead.
        .profileFrame(
            form == .column ? nil : profile.frame,
            cardWidth: width,
            shadowOpacity: frameShadow
        )
        // The card for an emoji somebody put in their bio. A nested popover,
        // one per surface — see `ExpressionInfoPopover`.
        .presentsExpressionInfo(for: $inspectedEmoji)
    }

    /// A card has corners; a column is a region of the window and has none.
    private var corner: CGFloat { form == .column ? 0 : Radius.card }

    /// How dark the shadows of a floating card that wears a frame are, and
    /// nil for every other card — the one case Discord gives a frame shadows
    /// of its own. See `FrameShadow`.
    ///
    /// The theme is read only on that path, so an unframed card registers no
    /// dependency on it.
    private var frameShadowOpacity: Double? {
        guard form == .card, let frame = profile.frame, !frame.isEmpty else { return nil }
        return FrameShadow.opacity(in: ThemeStore.shared.colors)
    }

    /// Discord's one button on the embed: the full profile, across the foot. A
    /// standard bordered button, like Open Server on a server's card.
    private var viewProfileButton: some View {
        Button { openFullProfile(nil) } label: {
            Text("View Profile")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(.horizontal, Spacing.margin)
        .padding(.top, Spacing.tight)
        .padding(.bottom, Spacing.margin)
    }

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
                            // See `bannerFilm` for why the latch is read
                            // beside a question the state cannot answer.
                            .opacity(bannerIsPlaying && bannerFilm != nil ? 0 : 1)

                            // Only when it can animate — the extension says so,
                            // so a still banner never pays for a second fetch, a
                            // multi-frame decode and a coordinator to learn it
                            // has one frame — and only while `animates`.
                            //
                            // **Every frame, at the source's resolution** — see
                            // `AnimatedDecoration`, which streams a loop this
                            // size rather than sampling it to fit a budget.
                            if let film = bannerFilm {
                                AnimatedDecoration(
                                    url: film,
                                    side: width,
                                    gravity: .resizeAspectFill,
                                    onPlayback: { playing in
                                        guard bannerIsPlaying != playing else { return }
                                        bannerIsPlaying = playing
                                    }
                                )
                            }
                        }
                    }
                }
                .frame(height: Self.bannerHeight)
                .clipped()
                // **The still comes back whenever the film over it goes** — a
                // banner that changed, and in the DM column the pointer
                // leaving. The filmstrip reports playback from its load and
                // never from a view update, so it has nothing to say on its way
                // out: it is simply gone, and a latch left set is a bare plate
                // where somebody's banner was. Watched here rather than inside
                // the artwork, which is not there to watch a banner removed.
                .onChange(of: bannerFilm) {
                    if bannerIsPlaying { bannerIsPlaying = false }
                }
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
                openFullProfile: { openFullProfile(nil) }
            )
            .allowsHitTesting(!profile.isSystem)

            // **On the reader's own card the bubble is ALWAYS there, and it is
            // a button.** Clicking what you wrote is how you change it — which
            // is Discord's arrangement, and what a separate "Set a Custom
            // Status" row in the menu below was standing in for. An empty one
            // carries a prompt and a plus, so a card with no status still says
            // where a status goes.
            //
            // The cluster places itself from the avatar's drop — see
            // `CustomStatusBubble`. The banner, the avatar and the bubble are
            // one arrangement, and a hand-tuned offset here would be right on
            // one of the two profile surfaces at most.
            if ownActions != nil {
                Button { ownSurface = .customStatus } label: {
                    CustomStatusBubble(
                        text: profile.customStatus,
                        emoji: profile.customStatusEmoji,
                        placeholder: hasCustomStatus ? nil : ownStatusPrompt,
                        avatarDrop: avatarDrop,
                        cardWidth: width,
                        fill: ground.statusBubbleFill,
                        ink: ground.statusBubbleInk
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    Text(hasCustomStatus ? "Edit your custom status" : "Set a custom status")
                )
            } else if hasCustomStatus {
                CustomStatusBubble(
                    text: profile.customStatus,
                    emoji: profile.customStatusEmoji,
                    avatarDrop: avatarDrop,
                    cardWidth: width,
                    fill: ground.statusBubbleFill,
                    ink: ground.statusBubbleInk,
                    answer: model.statusAnswering(for: profile),
                    isSelectable: true
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

    /// The banner's moving form while it is up, and nil while it is not: a
    /// banner with frames to play, on a card allowed to play them.
    ///
    /// **One value decides the film, the still over it and the latch
    /// between them.** Read beside `bannerIsPlaying`, it is what stops that
    /// latch sticking: only the film clears the latch, and a filmstrip that is
    /// dismantled reports nothing on its way out — so without this the still
    /// stays at zero over a film that is no longer there and the card draws a
    /// bare plate where somebody's banner was. `AvatarView` carries the same
    /// pair, for the same defect.
    private var bannerFilm: URL? {
        guard animates, let url = profile.bannerURL, CDN.canAnimate(url) else { return nil }
        return url
    }

    /// The widest the display name may come out, after the marks worn beside
    /// it have taken theirs.
    ///
    /// **The tag chip no longer takes any**, because it is no longer beside the
    /// name — see `identity`. Only the APP mark is, and only on a bot, whose
    /// name is one that Discord chose rather than a person's.
    ///
    /// A floor, so a card whose marks are wider than its content still gives
    /// the name something to wrap into rather than a negative width.
    private var nameWidth: CGFloat {
        max(80, contentWidth - (profile.nameTag.map { TagChip.width($0) + Spacing.tight } ?? 0))
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            // **The marks sit beside the NAME.** A clan tag and the APP mark are
            // both worn as part of how someone is addressed — the member list
            // draws them against the name for the same reason — and hanging
            // them off the handle underneath separates a person from the thing
            // they chose to be identified by.
            // **The name has the row to itself, and it wraps.**
            //
            // The tag chip used to sit beside it, which is what the member list
            // does — and on a long name the two could not both fit. The width
            // reserved for the chip made the name truncate sooner, and the chip
            // still landed on the letters, because a styled name is a drawn view
            // that reported its whole measured width whatever it was told.
            //
            // Discord's own popout wraps the name to two lines and moves the tag
            // down to the head of the badge row. That is the arrangement here:
            // a tag is a thing somebody wears, and the badges are the row of
            // things somebody wears.
            HStack(spacing: Spacing.tight) {
                // **The name and the handle open the full profile**, and
                // underline together under the pointer — Discord's
                // `.clickable:hover .displayName.noStyles` and
                // `.userTagUsername`.
                Button { openFullProfile(nil) } label: {
                    StyledDisplayName(
                        text: profile.displayName,
                        style: profile.displayNameStyle,
                        textStyle: .title2,
                        weight: .bold,
                        // `heading-lg/bold`, read out of Discord's own
                        // stylesheet. `.title2` is 17 on macOS, which is what
                        // this was and which is visibly small beside the real
                        // thing.
                        pointSize: 20,
                        // **The card's own width, stated.** A styled name is a
                        // drawn view, so a `.lineLimit` at the call site reaches
                        // nothing — the ceiling is what makes it wrap at all.
                        maximumWidth: nameWidth,
                        maximumLines: 2,
                        underlined: isHoveringName
                    )
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .onHover { isHoveringName = $0 }
                .nameCopyMenu(displayName: profile.displayName, handle: profile.handle)
                // Discord's own account has no full profile behind its name.
                .allowsHitTesting(!profile.isSystem)
                if let tag = profile.nameTag {
                    TagChip(text: tag)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: Spacing.tight) {
                Button { openFullProfile(nil) } label: {
                    Text(profile.handle)
                        .font(.system(.caption))
                        .foregroundStyle(InkColor.secondary)
                        .underline(isHoveringName)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .onHover { isHoveringName = $0 }
                .nameCopyMenu(displayName: profile.displayName, handle: profile.handle)
                // Discord's own account has no full profile behind its name.
                .allowsHitTesting(!profile.isSystem)
                if let pronouns = profile.pronouns, !pronouns.isEmpty {
                    // Separated by a bullet rather than put on its own line:
                    // it is part of how someone is addressed, not a fact about
                    // them, and Discord sets it inline for the same reason.
                    Text("•").foregroundStyle(InkColor.tertiary)
                    Text(pronouns)
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
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
                    .textSelection(.enabled)
            }

            // The tag leads the row, then the badges — Discord's own order,
            // and the reason this is one row rather than a tag row above a
            // badge row: they are the same kind of thing and a divide between
            // them would be a line the popout does not have.
            if profile.guildTag != nil || !profile.badges.isEmpty {
                HStack(spacing: Spacing.tight) {
                    if let tag = profile.guildTag {
                        GuildTagChip(tag: tag)
                    }
                    if !profile.badges.isEmpty {
                        BadgeRow(badges: profile.badges, premiumSince: profile.premiumSince, userID: profile.userID)
                    }
                    Spacer(minLength: 0)
                }
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
        if !profile.mutualServers.isEmpty || !profile.mutualFriends.isEmpty {
            MutualsRow(
                servers: profile.mutualServers,
                friends: profile.mutualFriends,
                openServer: { model.openMutualServer($0) }
            )
                .padding(.horizontal, Spacing.margin)
                .padding(.bottom, Spacing.snug)
        }
    }

    /// What they are doing, as Discord's popout stacks it (module `646986`):
    /// every activity in `ActivityOrder`, then the call they are in. The first
    /// is drawn whole, the edge of the next shows beneath it, and the rest are
    /// one press away on the full profile's Activity tab.
    ///
    /// **A custom status is not a card** — it is the bubble on the banner.
    ///
    /// **No recent activity here, and that is deliberate.** A card is a summary
    /// that opens beside a row; twenty inventory entries would make it taller
    /// than the window, and they are what the Activity tab is for.
    @ViewBuilder
    private var activityStack: some View {
        if !profile.isLoading {
            // Discord's cards in its order — the live activities, then the
            // call — and no call on a profile its owner made private.
            let stream = model.profileStream(for: profile.userID, inGuild: profile.guild?.id)
            // A stream stands for the call it is in — Discord draws no voice
            // card beside one.
            let voice = profile.isProfilePrivate || stream != nil
                ? nil
                : model.profileVoice(for: profile.userID, inGuild: profile.guild?.id)
            let cards = (stream == nil ? 0 : 1) + profile.activities.count + (voice == nil ? 0 : 1)
            if cards > 0 {
                ProfileCardStack(
                    hasMore: cards > 1,
                    ground: ground,
                    expand: { openFullProfile(.activity) }
                ) {
                    if let stream {
                        ProfileStreamCard(
                            stream: stream,
                            form: .card,
                            ground: ground,
                            watch: { model.watchStream(from: stream) },
                            join: { model.joinVoice(from: stream) },
                            openGuild: { model.openGuild($0) },
                            viewAllActivity: form == .card ? { openFullProfile(.activity) } : nil
                        )
                    } else if let first = profile.activities.first {
                        CurrentActivityCard(
                            activity: first,
                            buttonURLs: profile.activityButtonURLs,
                            storeOffers: profile.activityStoreOffers,
                            ground: ground,
                            openGame: openGame(for: first),
                            applicationIconURL: model.applicationIconURL(
                                first.applicationID, side: Metrics.avatarProfile
                            ),
                            isOwn: profile.isSelf,
                            listenAlong: model.listenAlongOffer(for: profile.userID, activity: first)
                        )
                    } else if let voice {
                        ProfileVoiceCard(
                            voice: voice,
                            form: .card,
                            ground: ground,
                            open: { model.openVoice(from: voice) },
                            openGuild: { model.openGuild($0) },
                            setStatus: {
                                // Discord's popout steps aside for the modal;
                                // the column stays where it is.
                                if form == .card { model.profileRequest = nil }
                                model.editVoiceStatus(in: voice.channelID)
                            },
                            // The popout's one menu item; Discord's column
                            // offers none.
                            viewAllActivity: form == .card ? { openFullProfile(.activity) } : nil
                        )
                    }
                }
                .padding(.horizontal, Spacing.margin)
                .padding(.bottom, Spacing.snug)
            }
        }
    }

    /// **Only for a game.** A Spotify session and a custom status have no page
    /// behind them, and a title that looks pressable and opens nothing is the
    /// inert control `INVARIANTS.md` §5.5 forbids.
    private func openGame(for activity: Activity) -> (() -> Void)? {
        guard activity.kind == .playing else { return nil }
        return model.gameProfileOpener(for: activity.applicationID)
    }

    /// The accounts they have linked.
    ///
    /// **Below the roles, not above the bio.** Connections are a footer: they
    /// are where somebody goes *after* reading who this person is, and putting
    /// them between the mutual servers and the bio pushed the one line the card
    /// exists for below the fold on anybody with four linked accounts.
    @ViewBuilder
    private var connections: some View {
        // The reader's own connected accounts are Streamer Mode's personal
        // information.
        if !profile.connections.isEmpty,
           !(profile.isSelf && StreamerMode.shared.hidesPersonalInformation) {
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

/// Lets a card taller than its window scroll inside itself.
///
/// **Its own height until it reaches the cap**, and the cap after that: the
/// frame asks the scroll view for its ideal height — its content's — and holds
/// it to the cap, which is what keeps a short card exactly as it was.
///
/// **No scroller unless the content is past the cap.** Opening a card flashed
/// one for a second over a card that fits; measured against the cap rather
/// than the viewport, nothing in the card's arrival can raise it — and
/// Discord's popout, whose scroller is invisible at rest, shows none either.
private struct ScrollsPastHeight: ViewModifier {
    var maxHeight: CGFloat?

    @State private var contentHeight: CGFloat = 0

    func body(content: Content) -> some View {
        if let maxHeight {
            ScrollView(.vertical) {
                content
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(contentHeight > maxHeight ? .automatic : .never)
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            content
        }
    }
}
