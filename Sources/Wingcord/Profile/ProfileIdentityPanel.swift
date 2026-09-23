import SwiftUI
import WingcordCore

/// The left column of the full profile: who this is, in a portrait card.
///
/// **Fixed 360 wide, and the width is the reason the column exists.** A profile
/// frame and a profile effect are aspect-locked artwork authored for a card of
/// roughly 340 × 430 — measured on three live accounts — and there is no way to
/// place a composition that shape on a 1,400-point landscape surface. Discord's
/// left column is that shape *because their cosmetics are*, and any client that
/// sells the same cosmetics inherits the constraint. See
/// `HANDOFF.md`'s "The profile stage" has the three measurements.
///
/// **Every number below is the design handoff's, scaled once.** The sheet was
/// drawn at 1,280 points with a 452-point rail; this one is 1,040 with a
/// 360-point rail, so the factor is 0.797 and it is applied to the artwork
/// height, the avatar, the margins, the dock and the gaps rather than to each of
/// them by eye. `Metrics` names the two that other views also have to agree
/// with; the rest are private here because nothing else lays out against them.
struct ProfileIdentityPanel: View {
    var profile: ProfilePresentation
    var ground: ProfileGround
    var openEmoji: (EmojiRef) -> Void
    var openLink: ((String) -> Void)?
    /// Non-nil while the reader is editing their own profile — see
    /// `ProfileSheet`. The name, the pronouns, the bio and the tag become fields
    /// in place; the cosmetics stay in the rail, which is where a grid of
    /// artwork belongs.
    var editor: ProfileEditor?
    /// The servers whose tag the reader could wear.
    var tagOptions: [ServerTagOption] = []
    var present: ((ProfileEditPicker) -> Void)?

    @Environment(AppModel.self) private var model

    /// What this account and this server permit — see `ProfileEditCapability`.
    /// `.account` outside an edit, where nothing is being gated anyway.
    private var capability: ProfileEditCapability {
        model.profileEditCapability(for: editor?.scope ?? .account)
    }
    @Environment(\.motion) private var motion
    @State private var isMenuOpen = false
    /// Whether the still under the moving banner has been taken away. See
    /// `bannerArtwork`.
    @State private var bannerIsPlaying = false
    /// Whether the pointer is over the card. Two things read it: the profile
    /// effect fades back so the name and banner under it can be read, and the
    /// edit pencils appear — both of which are "get out of the way of the thing
    /// being looked at" answered on the same signal.
    @State private var isHovered = false

    /// The card a frame and an effect are authored for. 452 ÷ 1,280 of the
    /// design's sheet, which is the same third of ours.
    static let width: CGFloat = 360
    /// The banner strip: 264 in the handoff, full-bleed, and a plate in the
    /// person's own colour where there is no artwork — which is most accounts.
    private static let bannerHeight: CGFloat = 210
    /// 148 in the handoff. Overlaps the banner and hangs below it.
    private static let avatarSide: CGFloat = 118
    private static let avatarDrop: CGFloat = 56
    /// 34 in the handoff. The rail's own gutter, and wider than the app's usual
    /// margin because this column is a card rather than a list.
    private static let gutter: CGFloat = 26
    /// What the floating dock and its scrim occupy at the foot. The handoff
    /// reserves 150 for it, which is what stops the mockup's own defect — an
    /// Add Friend button drawn over the Connections row underneath it.
    private static let dockClearance: CGFloat = 118

    private var contentWidth: CGFloat { Self.width - Self.gutter * 2 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Above the banner, which is where Discord puts it.
                if profile.isProfilePrivate { PrivateProfileBanner() }
                banner
                identity
                bioSection
                statusRow
                memberSince
                roles
                connections
                note
            }
            .padding(.bottom, Self.dockClearance)
            // **Pinned on the stack itself, not only on the scroll view.** A
            // `.frame` on a `ScrollView` sets the viewport; it does not stop the
            // CONTENT reporting a larger width — and a vertical scroll view
            // answers a too-wide child by CENTRING it and clipping both sides,
            // which is how a badge row or a long role chip shoves the whole
            // column sideways and eats the trailing gutter. Constraining the
            // stack constrains the proposal every child is offered, so no future
            // child can move the column again. The card next door learned this
            // the same way — see `MiniProfileCard`.
            .frame(width: Self.width)
        }
        .scrollIndicators(.never)
        .frame(width: Self.width)
        // The panel paints the person's own ground — their chosen theme pair, or
        // the pair quantised out of their artwork. The content column beside it
        // is lit by `AmbientArtwork` instead: two different jobs, and the reason
        // this one is opaque is §1, a surface carrying prose is a reading
        // surface.
        // **No white veil over it, and the handoff has one.** Its rail is a
        // translucent panel on a dark sheet, so a five-per-cent wash reads as
        // light catching the glass; this one is opaque paint already fitted
        // against Discord's own card, and the same wash there just makes a
        // themed profile paler than the colours it was given.
        .modifier(ProfileGroundFill(
            ground: ground,
            corner: 0,
            form: .card(topHold: Self.bannerHeight)
        ))
        .overlay(alignment: .bottom) { footDock }
        .overlay(alignment: .trailing) {
            Rectangle().fill(identityPanelEdge).frame(width: 1)
        }
        // The effect plays over the finished panel and is clipped to it. Its
        // layers are authored at `zIndex` 100+ — above everything — and it must
        // not swallow a click meant for the controls underneath.
        .overlay {
            if let effect = profile.effect {
                ProfileEffectView(effect: effect, width: Self.width)
                    .allowsHitTesting(false)
                    .accessibilityLabel(Text(effect.accessibilityLabel ?? effect.title))
                    .opacity(isHovered ? ProfileEffectFade.hovered : 1)
                    .animation(ProfileEffectFade.animation, value: isHovered)
            }
        }
        .onHover { isHovered = $0 }
        .clipped()
    }

    /// The pencil over the avatar.
    ///
    /// **A menu rather than a jump to the picker**, because the avatar carries
    /// two cosmetics — the picture and the ring around it — and a click cannot
    /// know which is meant. Removing either is offered here too: Discord puts
    /// both removals in this menu and nowhere else, and the picker is the wrong
    /// place for "take it off".
    @ViewBuilder
    private var avatarEditMenu: some View {
        if let editor {
            EditOverlayButton(isVisible: isHovered) {
                Button("Change Avatar") { present?(.avatar) }
                Button("Change Avatar Decoration") { present?(.decoration) }
                Divider()
                Button("Remove Avatar", role: .destructive) { editor.avatar = .removed }
                // Only offered where there is one to take off.
                if editor.avatarDecorationSKU != nil {
                    Button("Remove Avatar Decoration", role: .destructive) {
                        editor.avatarDecorationSKU = nil
                        editor.decorationAsset = nil
                    }
                }
            }
            .padding(.leading, Self.gutter + Self.avatarSide - 34)
            .padding(.top, Self.bannerHeight - Self.avatarDrop)
        }
    }

    /// The pencil over the banner.
    ///
    /// The frame is deliberately absent: nothing captured names the field that
    /// sets one, so a menu item for it would open a grid whose Apply could not
    /// be written — `INVARIANTS.md` §5.5. See `ProfileEditRail.sections`.
    @ViewBuilder
    private var bannerEditMenu: some View {
        if editor != nil {
            EditOverlayButton(isVisible: isHovered) {
                Button("Change Profile Effect") { present?(.effect) }
            }
            .padding(Spacing.snug)
        }
    }

    /// The bio.
    ///
    /// **This column never drew one**, which was a gap rather than a decision —
    /// the small card shows it and the full profile did not, so the longest
    /// thing somebody writes about themselves was the one thing the big surface
    /// left out. Editing made it impossible to ignore.
    @ViewBuilder
    private var bioSection: some View {
        if let editor {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("Bio")
                    .font(Typeface.sectionHeader)
                    .foregroundStyle(InkColor.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.9)
                // **A per-server bio is a Nitro field; an account's is not.**
                // `PATCH /guilds/{id}/members/@me` marks `bio` premium and
                // `PATCH /users/@me/profile` does not — so the same control is
                // gated in one scope and free in the other.
                let allowed = editor.scope.guildID == nil
                    ? capability.canEditBio
                    : capability.canEditGuildBio
                EditableBioField(
                    text: Binding(get: { editor.bio }, set: { editor.bio = $0 })
                )
                .disabled(!allowed)
                .opacity(allowed ? 1 : 0.45)
                if !allowed {
                    Text(ProfileEditCapability.nitroNote)
                        .font(.system(.caption))
                        .foregroundStyle(InkColor.tertiary)
                }
            }
            .padding(.horizontal, Self.gutter)
            .padding(.top, Spacing.margin)
        } else if let bio = profile.bio, !bio.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("Bio")
                    .font(Typeface.sectionHeader)
                    .foregroundStyle(InkColor.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.9)
                ProseText(
                    markdown: bio,
                    font: .system(.subheadline),
                    color: InkColor.primary,
                    onEmoji: openEmoji,
                    onLink: openLink
                )
            }
            .padding(.horizontal, Self.gutter)
            .padding(.top, Spacing.margin)
        }
    }

    // MARK: Artwork

    private var banner: some View {
        ZStack(alignment: .bottomLeading) {
            // `Color.clear` under the picture, never the picture as a sibling:
            // an aspect-filled `RemoteImage` reports the IMAGE's size upward,
            // and a stack holding one sets this column's width to the banner's.
            Color.clear
                .background {
                    Rectangle().fill(ground.plateStyle(accentColorValue: profile.accentColorValue))
                }
                .overlay { bannerArtwork }
                // The handoff's fade: the artwork dissolves into the body rather
                // than ending in a line, which is what keeps the banner and the
                // body reading as one surface.
                //
                // **Only where there IS artwork.** A person with no banner gets
                // a flat plate of their primary colour, and a colour block has
                // nothing to dissolve — fading one into the body just erases
                // it. Measured against Discord's own card for an account whose
                // pair is `#89867d` / `#d5d4d3`: its plate is that colour flat,
                // edge to edge, ending in a hard line against the body. Ours
                // was washing out to within a few units of the body and the
                // banner had effectively disappeared.
                .overlay {
                    if profile.bannerURL != nil {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.3),
                                .init(color: ground.bodyHead.opacity(0.55), location: 0.78),
                                .init(color: ground.bodyHead.opacity(0.9), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
                .frame(height: Self.bannerHeight)
                .clipped()
                .overlay(alignment: .topTrailing) { bannerEditMenu }
                // The avatar's cut-out is a HOLE in the artwork, not a stroke
                // painted over it — so what shows in the gap is the panel's own
                // ground under any theme. See `ProfileAvatar`.
                .mask(alignment: .bottomLeading) {
                    ProfileAvatar.bannerMask(
                        side: Self.avatarSide,
                        drop: Self.avatarDrop,
                        leading: Self.gutter
                    )
                }

            ProfileAvatar(
                profile: profile,
                drop: Self.avatarDrop,
                dotSide: 26,
                side: Self.avatarSide,
                leading: Self.gutter
            )
            .overlay(alignment: .topLeading) { avatarEditMenu }

            if hasCustomStatus {
                CustomStatusBubble(
                    text: profile.customStatus,
                    emoji: profile.customStatusEmoji,
                    avatarDrop: Self.avatarDrop,
                    cardWidth: Self.width,
                    avatarSide: Self.avatarSide,
                    margin: Self.gutter,
                    fill: ground.statusBubbleFill,
                    ink: ground.statusBubbleInk,
                    answer: model.statusAnswering(for: profile)
                )
            }
        }
        // The drop AND the decoration's overhang: a decoration is drawn outside
        // the avatar's bounds and contributes no layout size, so reserving the
        // drop alone puts the name under a ring of clouds.
        .padding(.bottom, Self.avatarDrop + ProfileAvatar.decorationOverhang(side: Self.avatarSide))
    }

    /// Whether there is a moving form to put up at all — the extension says
    /// so, and nothing else here can.
    ///
    /// **Read beside the latch below, and the second half is not redundant.**
    /// `bannerIsPlaying` is `@State` and only the film can clear it: a
    /// filmstrip that is dismantled reports nothing on the way out
    /// (`AnimatedDecoration.tearDown` bumps its generation precisely so a
    /// report in flight is dropped), so the latch stays true, the still stays
    /// at zero, and the strip draws its plate and the body's fade over
    /// nothing — **a banner that is simply gone.** Asking whether there is a
    /// film at all cannot get stuck. `AvatarView` keeps the same pair of
    /// guards, for the same defect.
    private var bannerPlays: Bool {
        profile.bannerURL.map(CDN.canAnimate) ?? false
    }

    @ViewBuilder
    private var bannerArtwork: some View {
        if let url = profile.bannerURL {
            ZStack {
                RemoteImage(url: url, side: Self.width, bucket: .artwork) { Color.clear }
                    .aspectRatio(contentMode: .fill)
                    // Taken away once the film is up: two copies of the same
                    // picture composited every frame buys nothing, and the
                    // still is only here to fill the box while the strip
                    // decodes. See `bannerPlays` for the second half.
                    .opacity(bannerIsPlaying && bannerPlays ? 0 : 1)
                // Only where the hash says it can move, so a still banner never
                // pays for a second fetch and a multi-frame decode.
                //
                // **The budget is the whole loop at the size it is drawn**, not
                // a number chosen by hand: a banner is around half a megabyte a
                // frame here, so the 12 MB this used to ask for bought twenty
                // frames of a sixty-frame asset — every third one, which is
                // what made it stutter. `AnimatedImage.budget(forDrawn:)` is
                // that arithmetic in one place.
                if CDN.canAnimate(url) {
                    AnimatedDecoration(
                        url: url,
                        side: Self.width,
                        gravity: .resizeAspectFill,
                        byteBudget: AnimatedImage.budget(
                            forDrawn: CGSize(width: Self.width, height: Self.bannerHeight)
                        ),
                        onPlayback: { playing in
                            guard bannerIsPlaying != playing else { return }
                            bannerIsPlaying = playing
                        }
                    )
                }
            }
            // A banner that changes has to put its still back while the new one
            // resolves, or the strip is empty in between.
            .onChange(of: url) { bannerIsPlaying = false }
            // The latch is the one thing on this card that can hide artwork
            // that is present, and it does it silently — so its transitions are
            // on the record. Gated on the trace sink and cold: a banner reports
            // twice in its life.
            .onChange(of: bannerIsPlaying) { _, playing in
                DiagnosticLog.trace(
                    "profile",
                    "banner latch \(playing) plays=\(bannerPlays) \(url.lastPathComponent)"
                )
            }
        }
    }

    private var hasCustomStatus: Bool {
        profile.customStatusEmoji != nil || profile.customStatus?.isEmpty == false
    }

    // MARK: Who

    private var identity: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                if let editor {
                    // **In a server this field is the NICKNAME**, and the server
                    // decides whether it may be typed at all: `nick` is the one
                    // profile field gated by a permission rather than by a
                    // subscription — `CHANGE_NICKNAME` on
                    // `PATCH /guilds/{id}/members/@me`. A server that withholds
                    // it refuses the write, and the refusal arrives after every
                    // other edit in the sheet has already been saved.
                    let nameAllowed = editor.scope.guildID == nil
                        || capability.canEditNickname
                    VStack(alignment: .leading, spacing: 2) {
                        // **The field the scope saves**: the account's display
                        // name, or this server's nickname. Binding the display
                        // name here in a server wrote nothing — `saveGuild`
                        // sends `nick` — so a typed nickname was silently lost.
                        EditableDisplayName(
                            text: editor.scope.guildID == nil
                                ? Binding(
                                    get: { editor.displayName },
                                    set: { editor.displayName = $0 }
                                )
                                : Binding(
                                    get: { editor.nickname },
                                    set: { editor.nickname = $0 }
                                ),
                            // Discord's own placeholder for a nickname is the
                            // name it would fall back to.
                            placeholder: editor.scope.guildID == nil
                                ? profile.handle
                                : editor.accountName,
                            style: profile.displayNameStyle,
                            editStyle: { present?(.displayNameStyle) }
                        )
                        .disabled(!nameAllowed)
                        .opacity(nameAllowed ? 1 : 0.45)
                        if !nameAllowed {
                            Text(ProfileEditCapability.nicknameNote)
                                .font(.system(.caption))
                                .foregroundStyle(InkColor.tertiary)
                        }
                    }
                } else {
                    StyledDisplayName(
                        text: profile.displayName,
                        style: profile.displayNameStyle,
                        textStyle: .largeTitle,
                        weight: .semibold,
                        // `heading-xl/semibold`, read out of Discord's own
                        // stylesheet. `.largeTitle` is 26 on macOS, two points
                        // over — and the weight was bold where Discord sets 600.
                        pointSize: 24,
                        // **The panel's own width, stated.** A styled name is
                        // a drawn view and a `.lineLimit` at the call site
                        // reaches only the plain branch — so without a ceiling a
                        // long name reported its whole measured width and took
                        // the card out of the window with it, and with one it
                        // truncated where Discord wraps.
                        maximumWidth: contentWidth - (profile.isBot ? 44 : 0),
                        maximumLines: 2
                    )
                }
                if profile.isBot { TagChip(text: "APP") }
                Spacer(minLength: 0)
            }

            HStack(spacing: Spacing.base) {
                Text(profile.handle)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(InkColor.secondary)
                    .lineLimit(1)
                if let pronouns = profile.pronouns, !pronouns.isEmpty {
                    Text("·").foregroundStyle(InkColor.tertiary)
                    Text(pronouns)
                        .font(.system(.subheadline))
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(1)
                }
                if let editor {
                    ServerTagChooser(
                        options: tagOptions,
                        selection: Binding(
                            get: { editor.primaryGuildID },
                            set: { editor.primaryGuildID = $0 }
                        )
                    )
                } else if let tag = profile.guildTag {
                    GuildTagChip(tag: tag)
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)

            // **The badges are their own row**, which is where Discord puts
            // them. They used to share the handle's: eleven badges beside a
            // tag chip and a handle is wider than the column, and the handle is
            // what gave — it truncated to "someramdomguyykal…" on a name whose
            // owner had six badges, while the badges themselves wrapped onto a
            // second line anyway. Splitting them costs nothing and the handle
            // fits.
            if !profile.badges.isEmpty {
                BadgeRow(badges: profile.badges, premiumSince: profile.premiumSince)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // A nickname is an extra line, never a replacement: one that
            // silently stands in for somebody's real name makes them
            // unfindable in search and in a mention.
            if let nickname = profile.nickname, nickname != profile.displayName {
                Text("Known here as \(nickname)")
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.tertiary)
            }
        }
        .padding(.horizontal, Self.gutter)
        .padding(.top, 14)
    }

    /// The presence, as the handoff's own capsule row.
    ///
    /// **The dot and the words, and nothing on the right-hand end.** The mockup
    /// puts "4h 12m" there and there is no such number: a presence has no
    /// duration anywhere in the API, and a client that draws one is drawing a
    /// figure that is always wrong. What is real is the state itself, and it
    /// earns the row on its own.
    private var statusRow: some View {
        HStack(spacing: Spacing.base) {
            PresenceDot(status: profile.status, side: 7, hasPlate: false)
            Text(profile.status.label)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(InkColor.primary)
            Spacer(minLength: 0)
            if profile.isBot {
                Text("APP")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(InkColor.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.clear.tint(Palette.flyoutTint), in: .rect(cornerRadius: 13))
        .padding(.horizontal, Self.gutter)
        .padding(.top, 16)
        .accessibilityElement(children: .combine)
    }

    // MARK: The sections

    /// The one idea from the mockup worth keeping outright: two dates at the
    /// ends of a rule, which reads as a life where two label/value rows read as
    /// a form.
    private var memberSince: some View {
        section("Member Since", topGap: 22) {
            ProfileDateSpan(moments: moments, pair: ground.accentPair)
        }
    }

    /// The dated facts this profile actually carries, oldest first.
    ///
    /// **Three at most, and the span draws the two ends.** Account created is
    /// always there; joining this server is there in a guild and absent in a
    /// direct message; Nitro is there for a subscriber. Drawing the extremes
    /// rather than a fixed pair is what keeps the line meaningful in a DM,
    /// where there is no server date to be the far end.
    private var moments: [ProfileDateSpan.Moment] {
        var moments = [
            ProfileDateSpan.Moment(
                date: profile.accountCreated,
                label: "Discord",
                symbolName: BrandMark.discord
            ),
        ]
        if let premium = profile.premiumSince {
            moments.append(
                ProfileDateSpan.Moment(
                    date: premium,
                    label: profile.premiumTier.label ?? "Nitro",
                    // Discord's own mark rather than `sparkles`. An SF Symbol
                    // standing in for a brand reads as decoration beside the
                    // two real marks on the same line.
                    symbolName: BrandMark.nitro
                )
            )
        }
        if let joined = profile.memberSince, let guild = profile.guild {
            moments.append(
                ProfileDateSpan.Moment(date: joined, label: guild.name, iconURL: guild.iconURL)
            )
        }
        return moments.sorted { $0.date < $1.date }
    }

    @ViewBuilder
    private var roles: some View {
        if !profile.roles.isEmpty {
            section("Roles", topGap: 22) {
                RoleChipFlow(
                    roles: profile.roles,
                    maximumRows: nil,
                    width: contentWidth,
                    size: .comfortable
                )
            }
        }
    }

    @ViewBuilder
    private var connections: some View {
        // **The section appears while editing even with nothing in it**, because
        // that is where "Add Connection" lives — a reader with no connections is
        // exactly the one who needs the control.
        if !profile.connections.isEmpty || editor != nil {
            section("Connections", topGap: 24) {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    if !profile.connections.isEmpty {
                        ConnectionDock(connections: profile.connections)
                    }
                    if editor != nil {
                        Button {
                            present?(.connection)
                        } label: {
                            Label("Add Connection", systemImage: "plus")
                                .font(.system(.subheadline))
                                .foregroundStyle(InkColor.secondary)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var note: some View {
        if !profile.isSelf {
            section("Note", topGap: 22, aside: "only visible to you") {
                ProfileNoteField(
                    userID: profile.userID,
                    note: profile.note,
                    width: contentWidth,
                    showsLabel: false,
                    form: .panel
                )
            }
        }
    }

    /// A small-caps heading and what sits under it.
    ///
    /// **Small caps everywhere here, which reverses an earlier call.** The
    /// argument against them was that five shouting labels down a column read
    /// as a settings pane — true of labels set in the *body* face, which is
    /// what the old surface had. At 11 points, semibold, tracked and at
    /// forty-per-cent white they are not labels competing with the content, they
    /// are the rules between its sections, and the handoff is right that the
    /// column needs them.
    private func section(
        _ title: String,
        topGap: CGFloat,
        aside: String? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Text(title)
                    .font(Typeface.sectionHeader)
                    .foregroundStyle(InkColor.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.9)
                if let aside {
                    Text(aside)
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.quaternary)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.gutter)
        .padding(.top, topGap)
    }

    // MARK: The foot

    /// The verbs, as one floating dock over the foot of the rail.
    ///
    /// **It floats, and the list above reserves room for it.** In the handoff
    /// this dock is absolutely positioned and the scrolling body carries 150
    /// points of bottom padding to clear it — which is the fix for the mockup's
    /// own visible defect, an Add Friend button drawn across the Connections row
    /// underneath. Reserving nothing and floating anyway is what produced that
    /// screenshot; `dockClearance` is the reservation.
    @ViewBuilder
    private var footDock: some View {
        if !profile.isSelf {
            ZStack(alignment: .bottom) {
                // The ramp the dock sits in, so content scrolling under it
                // fades out rather than being cut by its edge.
                LinearGradient(
                    colors: [.clear, ground.bodyFoot.opacity(0.78)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: Self.dockClearance)
                .allowsHitTesting(false)

                HStack(spacing: Spacing.base) {
                    friendButton
                    // **Always drawn, never gated on an existing DM.** Opening
                    // one is `POST /users/@me/channels`, it is idempotent, and
                    // it is what this control has always meant — see
                    // `AppModel.messagePerson`.
                    circle("Message", "envelope.fill") {
                        model.messagePerson(profile.userID)
                    }
                    circle("More actions", "ellipsis") { isMenuOpen.toggle() }
                        .presentsUserMenu(
                            for: profile.userID,
                            inGuild: profile.guild?.id,
                            profileOptions: .init(
                                alternateName: profile.alternateName,
                                showsMainProfile: profile.showsMainProfile
                            ),
                            onProfileOption: { option in
                                switch option {
                                case .fullProfile: break
                                case .mainProfile: model.showMainProfile(true)
                                case .perServerProfile: model.showMainProfile(false)
                                }
                            },
                            isPresented: $isMenuOpen
                        )
                }
                .padding(6)
                .glassEffect(.clear.tint(Palette.flyoutTint), in: .capsule)
                .padding(.horizontal, Self.gutter)
                .padding(.bottom, 20)
            }
        }
    }

    /// Add Friend, Accept, Cancel or Remove — one control, because they are one
    /// route and one slot. Which of the four it is comes from the relationship
    /// itself; a second copy of that decision here is how two surfaces end up
    /// disagreeing about whether somebody is a friend.
    ///
    /// **Tinted with the person's own colour, and only where they have one.**
    /// The handoff fills it with the theme's primary and sets the label in near
    /// black. That is the app's colour rule rather than an exception to it —
    /// colour on a profile comes from the person — and an account with no theme
    /// gets the same pill in plain glass rather than an accent invented for
    /// them.
    @ViewBuilder
    private var friendButton: some View {
        if let title = profile.relationship.friendActionTitle {
            Button { model.toggleFriend(with: profile.userID) } label: {
                HStack(spacing: 7) {
                    Image(systemName: profile.relationship.friendActionSymbol)
                        .font(.system(size: 12, weight: .semibold))
                    Text(title)
                        .font(.system(.subheadline, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(friendLabelStyle)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.profileDockControl)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .disabled(profile.isRelationshipBusy)
            .background(friendFill, in: .capsule)
            .modifier(NeutralFriendGlass(
                isPlain: ground.accentPair == nil
                    || profile.relationship.friendActionIsDestructive
            ))
            .accessibilityLabel(Text(title))
        }
    }

    /// **Discord's own `--profile-gradient-button-color`**, which is the
    /// person's primary darkened until its contrast against white lands in
    /// `7...10` — see `ProfileThemeColors.buttonFill`. Measured off its window
    /// at `#35332C` for a grey profile and `#005287` for a cyan one.
    ///
    /// It replaced a light ramp of the same hue, and the reason is that a card
    /// can now be near-white: a pale tint of somebody's colour is a perfectly
    /// good pill on a dark card and disappears completely on a light one, which
    /// is half of all Nitro accounts with no theme of their own. A fill defined
    /// by its contrast works on both, which is the whole point of defining it
    /// that way.
    ///
    /// **A destructive action keeps the plain pill.** Remove Friend is the one
    /// thing on this bar that cannot be taken back, so it says so in its own
    /// colour rather than wearing the person's — and a red label on a solid
    /// theme-coloured fill is exactly the unreadable pair this is avoiding.
    private var friendFill: AnyShapeStyle {
        guard !profile.relationship.friendActionIsDestructive, let fill = ground.buttonFill else {
            return AnyShapeStyle(Color.clear)
        }
        return AnyShapeStyle(fill)
    }

    /// White on a lit pill, the hierarchy on a clear one — and the lit pill was
    /// chosen for exactly that contrast.
    private var friendLabelStyle: AnyShapeStyle {
        if profile.relationship.friendActionIsDestructive {
            return AnyShapeStyle(Palette.destructive)
        }
        return ground.buttonFill == nil
            ? AnyShapeStyle(InkColor.primary)
            : AnyShapeStyle(Color.white)
    }

    private func circle(
        _ label: String,
        _ symbolName: String,
        _ perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(InkColor.primary)
                .frame(width: Metrics.profileDockControl, height: Metrics.profileDockControl)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .interactiveChromeOverMedia(in: .circle)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

/// Glass for the friend pill on a profile with no colours of its own.
///
/// **A modifier with a branch rather than an `if` at the call site**, because
/// the two arms are different view types and branching in the panel's own
/// builder would give the button two identities — so a theme arriving a moment
/// after the sheet opened would POP rather than change material. The colours
/// land while the sheet is already on screen, so that is the common case.
private struct NeutralFriendGlass: ViewModifier {
    var isPlain: Bool

    func body(content: Content) -> some View {
        if isPlain {
            content.interactiveChromeOverMedia()
        } else {
            content
        }
    }
}

/// The linked accounts, as the handoff's magnifying dock.
///
/// **Marks in a row, and one of them named at a time.** A list of rows is what
/// the column had and it is right on a card; at 360 points beside a name in
/// 26-point type it is six grey lines where the design wants a shelf. The marks
/// carry the recognition — nobody reads "Steam", they see the cog — and the
/// account under the pointer is the one spelled out, with the facts that service
/// published beside it.
///
/// **No "+" tile.** The handoff has one and it is not real: adding a connection
/// is the reader's own settings, not something that can be done on somebody
/// else's profile.
private struct ConnectionDock: View {
    var connections: [ConnectedAccount]

    @Environment(\.openURL) private var openURL
    @Environment(\.motion) private var motion
    @State private var hovered: ConnectedAccount.ID?

    private static let tile: CGFloat = 37

    /// The one that is spelled out: whichever is under the pointer, else the
    /// first. **Never nil** — an empty caption column would leave the dock
    /// looking like it had failed to load half of itself.
    private var named: ConnectedAccount? {
        connections.first { $0.id == hovered } ?? connections.first
    }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                ForEach(connections.prefix(4)) { connection in
                    tile(connection)
                }
            }
            Spacer(minLength: Spacing.base)
            if let named {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(named.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(InkColor.primary)
                            .lineLimit(1)
                        if named.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.affirmative)
                        }
                    }
                    Text(caption(named))
                        .font(.system(size: 11))
                        .foregroundStyle(InkColor.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 150, alignment: .trailing)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.clear.tint(Palette.flyoutTint), in: .rect(cornerRadius: 18))
        .animation(motion.hover, value: hovered)
    }

    private func tile(_ connection: ConnectedAccount) -> some View {
        Button { open(connection) } label: {
            ConnectionMark(service: connection.service, side: Self.tile)
                .frame(width: Self.tile, height: Self.tile)
                .contentShape(.rect(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        // The dock's own magnification: the mark under the pointer lifts and
        // grows, which is what makes a row of icons read as a shelf rather than
        // as a toolbar.
        .scaleEffect(hovered == connection.id ? 1.16 : 1, anchor: .bottom)
        .offset(y: hovered == connection.id ? -5 : 0)
        .zIndex(hovered == connection.id ? 1 : 0)
        .onHover { hovering in
            let next = hovering ? connection.id : nil
            guard hovered != next else { return }
            hovered = next
        }
        .help(connection.profileURL == nil ? "Copy \(connection.name)" : "Open \(connection.name)")
        .accessibilityLabel(Text(connection.name))
    }

    /// The service, and up to two of the facts it published about the account.
    private func caption(_ connection: ConnectedAccount) -> String {
        let service = BrandMark.mark(for: connection.service)?.name
            ?? connection.service.capitalized
        let facts = connection.facts.prefix(2).map(Self.describe)
        return ([service] + facts).joined(separator: " · ")
    }

    private static func describe(_ fact: ConnectionFact) -> String {
        switch fact.content {
        case .since(let date):
            "since \(date.formatted(.dateTime.year()))"
        case .count(let value, let noun):
            "\(value.formatted(.number)) \(noun)"
        case .flag(let label):
            label
        }
    }

    private func open(_ connection: ConnectedAccount) {
        if let url = connection.profileURL {
            openURL(url)
        } else {
            AppModel.copy(connection.name)
        }
    }
}

/// Two dates at the ends of a rule.
///
/// **A span, not a table.** Two label/value rows say the same thing and read as
/// a form; two dates at the ends of a line read as a life. The rule is drawn in
/// the person's own two colours, so the panel has one accent rather than a grey
/// hairline dropped onto it.
///
/// A profile with one dated fact — a bot in a direct message — draws that fact
/// alone rather than a line to nowhere.
struct ProfileDateSpan: View {
    var moments: [Moment]

    struct Moment: Hashable {
        var date: Date
        /// What the date is about: "Discord", the server's name, "Nitro".
        var label: String
        var iconURL: URL?
        var symbolName: String?
    }

    /// The theme's two colours, so the rule belongs to the person. Nil falls
    /// back to a neutral rule, which is what an unthemed profile should get.
    var pair: (primary: Color, secondary: Color)?

    var body: some View {
        if let first = moments.first {
            HStack(alignment: .center, spacing: Spacing.snug) {
                end(first, alignment: .leading)
                if let last = moments.last, last != first {
                    rule
                    end(last, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Two points tall with a rounded cap, and it takes the slack: the two ends
    /// are flexible and equal, and this sits between them. Sized any other way
    /// the far date is pushed past the panel's edge and clipped, which is what
    /// a fixed-size pair of ends did.
    private var rule: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        (pair?.primary ?? .white).opacity(0.85),
                        (pair?.secondary ?? .white).opacity(0.45),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 2)
            // **Flexible, at the same priority as the two ends.** Given a lower
            // one it is laid out last, out of whatever the ends left — and two
            // ends that each accept an infinite width leave nothing, so the rule
            // came out as a sixteen-point dash floating between two dates.
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
    }

    private func end(_ moment: Moment, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(moment.date, format: .dateTime.month(.abbreviated).day().year())
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
            HStack(spacing: 4) {
                marker(moment)
                Text(moment.label)
                    .font(.system(size: 11))
                    .foregroundStyle(InkColor.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: alignment == .leading ? .leading : .trailing
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func marker(_ moment: Moment) -> some View {
        if let url = moment.iconURL {
            RemoteImage(url: url, side: 13) { Circle().fill(Palette.surfaceRaised) }
                .frame(width: 13, height: 13)
                .clipShape(.circle)
        } else if let symbolName = moment.symbolName,
                  let mark = BrandMark.mark(for: symbolName) {
            // Discord's and Nitro's own outlines. Named through the table so a
            // third one costs an entry rather than a branch.
            //
            // **Bare, in the brand's own colour — not the plate the connection
            // dock draws.** There the colour has to be the ground, because four
            // of those brands are black and a black glyph on a near-black card
            // is an empty square. Here it is a mark on a line of dates beside
            // two dates and a server's round icon, and a filled tile among them
            // reads as a button. Discord draws them bare too.
            //
            // A brand too dark to be ink still gets the plate, so a mark added
            // to this line later cannot be the one that comes out invisible —
            // the rule is the colour's own luminance rather than an exception
            // for the two that happen to be here today.
            if BrandMark.readsAsInk(mark.tint) {
                BrandGlyph(service: symbolName)
                    .fill(Color(hex: mark.tint))
                    .frame(width: 13, height: 13)
            } else {
                ConnectionMark(service: symbolName, side: 13)
            }
        } else if let symbolName = moment.symbolName {
            Image(systemName: symbolName)
                .font(.system(size: 9))
                .foregroundStyle(InkColor.tertiary)
                .frame(width: 13, height: 13)
        }
    }
}

/// The rule down the identity panel's trailing edge, resolved by the panel's
/// own scheme.
private let identityPanelEdge = Color.relative(dark: 0.10, light: 0.10)
