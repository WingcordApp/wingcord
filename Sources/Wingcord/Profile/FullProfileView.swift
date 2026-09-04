import SwiftUI
import WingcordCore

/// The full profile: everything the card has, plus everything it had no room
/// for.
///
/// **Two columns, and the split is by kind rather than by length.** The left is
/// the person — their artwork, their name, their marks, the facts they wrote
/// about themselves. The right is *context*: what they are doing, and where the
/// two of you overlap. Stacking all of it into one scrolling column, which is
/// what this used to be, means the roles push the mutuals below the fold on a
/// well-decorated account and off the bottom entirely on a heavily-roled one.
///
/// It shares `ProfilePresentation` and `ProfileGround` with the card rather than
/// resolving or restyling its own. Two resolvers is how a nickname shows in one
/// surface and not the other; two grounds is how the same person comes out one
/// colour in a popover and another in a sheet, one click apart.
///
/// **Only tabs with something behind them exist.** Discord shows four and leaves
/// three of them saying "no". This client has no friend graph and no profile
/// board, so it does not draw the chrome for them — an empty tab is a promise
/// the app cannot keep, and the reader pays for it every time they click one.
struct FullProfileView: View {
    var profile: ProfilePresentation
    var openDirectMessage: (ChannelID) -> Void
    var openEmoji: ((EmojiRef) -> Void)?
    /// What a click on a link in this person's prose does. Nil draws links as
    /// accent text and takes no clicks, which is what a surface with no opener
    /// can honestly offer — `INVARIANTS.md` §5.5.
    var openLink: ((String) -> Void)?

    /// See `MiniProfileCard.inspectedEmoji`.
    @State private var inspectedEmoji: EmojiRef?
    var dismiss: () -> Void

    @Environment(\.motion) private var motion
    @Namespace private var tabUnderline
    @State private var tab: Tab = .activity

    private static let identityWidth: CGFloat = 360
    private static let contextWidth: CGFloat = 340
    private static let height: CGFloat = 560

    private var bannerHeight: CGFloat { 150 }
    /// What the identity column lays out inside — the badge flyout's ceiling.
    private var contentWidth: CGFloat { Self.identityWidth - Spacing.margin * 2 }
    private var avatarDrop: CGFloat { Metrics.avatarProfile / 2 }

    private var ground: ProfileGround {
        ProfileGround(themeColorValues: profile.themeColorValues, isDerived: profile.isThemeDerived)
    }

    /// The tabs this client can actually fill.
    private enum Tab: Hashable {
        case activity
        case mutuals

        var title: String { self == .activity ? "Activity" : "Mutual Servers" }
    }

    private var tabs: [Tab] {
        profile.mutualServers.isEmpty ? [.activity] : [.activity, .mutuals]
    }

    var body: some View {
        HStack(spacing: 0) {
            identityColumn
            contextColumn
        }
        .frame(width: Self.identityWidth + Self.contextWidth, height: Self.height)
        // **One ground under both columns, not one each.** The colour is the
        // person's, and a wash that stops at the divider says the right-hand
        // pane belongs to the app rather than to them — which is exactly how it
        // read: a themed identity column beside a slab of flat black. Washing
        // the whole sheet is what makes it one surface with a person's colour in
        // it, and the divider then separates two regions of that surface rather
        // than two unrelated panels.
        .modifier(ProfileGroundFill(ground: ground, corner: Radius.card))
        .overlay(alignment: .topTrailing) { closeButton }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(ground.borderStyle, lineWidth: ground.borderWidth)
        }
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 32, y: 12)
        // The frame, wrapping the IDENTITY COLUMN rather than the whole
        // surface.
        //
        // **Which box a frame belongs to is the person's card, not the window
        // holding it.** Measured against Discord's own rendering: the same
        // frame is half again as large in the full profile as in the popout,
        // and the ratio is the two identity measures — not the sheet's, which
        // is twice as wide. So the column is what it scales to, and because
        // that column is at the sheet's leading edge and runs its full height,
        // three of its four overflows fall outside the sheet.
        //
        // Written out here rather than through `profileFrame(_:cardWidth:)`
        // because the box it decorates is a REGION of this sheet rather than
        // the sheet itself, so the overlay has to be given that region's width
        // and pinned to the leading edge.
        .overlay(alignment: .leading) {
            if let frame = profile.frame, !frame.isEmpty {
                ProfileFrameView(
                    frame: frame,
                    cardWidth: Self.identityWidth,
                    order: .front
                )
                .frame(width: Self.identityWidth)
            }
        }
        // The sheet supplies no material of its own, so the corners drawn above
        // are the corners on screen rather than a rounded rect inside a square.
        .presentationBackground(.clear)
        // The card for an emoji somebody put in their bio. A nested popover,
        // one per surface — see `ExpressionInfoPopover`.
        .presentsExpressionInfo(for: $inspectedEmoji)
    }

    // MARK: The person

    /// Scrolls on its own, so a hundred roles never push the context pane's tabs
    /// off the bottom — the two columns are independent surfaces, and one shared
    /// scroll view would couple them.
    private var identityColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                banner
                identity
                facts
            }
            // **Pinned here, inside the scroll view, and not only outside it.**
            // A `.frame` on the `ScrollView` sets the viewport; it does not stop
            // the CONTENT reporting a larger width, and a vertical scroll view
            // answers a too-wide child by centring it and clipping both sides.
            // That is what shifted this whole column thirty points left and cut
            // the first letter off every heading in it.
            .frame(width: Self.identityWidth, alignment: .leading)
        }
        .scrollIndicators(.never)
        .softScrollEdgesVertical()
        .frame(width: Self.identityWidth)
        // Drawn over the finished column and clipped to it, above everything,
        // and takes no input — the same contract as on the card.
        .overlay {
            if let effect = profile.effect {
                ProfileEffectView(effect: effect, width: Self.identityWidth)
                    .allowsHitTesting(false)
                    .accessibilityLabel(Text(effect.accessibilityLabel ?? effect.title))
            }
        }
        .clipped()
        .overlay(alignment: .trailing) {
            // The seam between the two regions, in the person's own colour so it
            // belongs to the surface rather than being drawn across it.
            Rectangle()
                .fill(ground.borderStyle)
                .frame(width: 1)
                .opacity(0.5)
        }
    }

    private var banner: some View {
        ZStack(alignment: .bottomLeading) {
            // **The artwork is an overlay on a zero-content ground, never a
            // sibling in the stack.** A filling image reports the IMAGE's size
            // to the layout, so a stack holding one grows wider than its column
            // and takes everything laid out beside it with it. `Color.clear`
            // accepts whatever width it is offered, which keeps the geometry the
            // column's and leaves the picture purely decorative.
            Color.clear
                .background { bannerPlate }
                .overlay {
                    if let bannerURL = profile.bannerURL {
                        ZStack {
                            RemoteImage(
                                url: bannerURL,
                                side: Self.identityWidth,
                                bucket: .artwork
                            ) {
                                Color.clear
                            }
                            .aspectRatio(contentMode: .fill)

                            // See `MiniProfileCard.banner`: the extension is a
                            // complete answer about whether there is film to
                            // fetch, and a banner frame needs a banner's budget
                            // rather than a decoration's.
                            if CDN.canAnimate(bannerURL) {
                                AnimatedDecoration(
                                    url: bannerURL,
                                    side: Self.identityWidth,
                                    gravity: .resizeAspectFill,
                                    byteBudget: 12 * 1024 * 1024
                                )
                            }
                        }
                    }
                }
                .frame(height: bannerHeight)
                .clipped()
            // The avatar's cut-out — see `ProfileAvatar`.
            .mask(alignment: .bottomLeading) {
                ProfileAvatar.bannerMask(drop: avatarDrop)
            }

            // No target: this IS the full profile.
            ProfileAvatar(profile: profile, drop: avatarDrop, dotSide: 18)

            if hasCustomStatus {
                // The cluster places itself from the avatar's drop — see
                // `CustomStatusBubble`. The banner, the avatar and the bubble
                // are one arrangement, and a hand-tuned offset here would be
                // right on one of the two profile surfaces at most.
                CustomStatusBubble(
                    text: profile.customStatus,
                    emoji: profile.customStatusEmoji,
                    avatarDrop: avatarDrop,
                    cardWidth: Self.identityWidth
                )
            }
        }
        // The avatar's drop AND its decoration's overhang — see the card.
        .padding(.bottom, avatarDrop + ProfileAvatar.decorationOverhang)
    }

    private var hasCustomStatus: Bool {
        profile.customStatusEmoji != nil || profile.customStatus?.isEmpty == false
    }

    private var bannerPlate: some View {
        Rectangle().fill(ground.plateStyle(accentColorValue: profile.accentColorValue))
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.base) {
                StyledDisplayName(
                    text: profile.displayName,
                    style: profile.displayNameStyle,
                    textStyle: .title,
                    weight: .bold
                )
                // The marks are worn beside the name, the same as on the card
                // and the same as in the member list.
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
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.secondary)
                if let pronouns = profile.pronouns, !pronouns.isEmpty {
                    Text("•").foregroundStyle(InkColor.tertiary)
                    Text(pronouns)
                        .font(.system(.subheadline))
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(1)
                }
            }

            // An extra line, never a replacement: a nickname that silently
            // stands in for someone's real name makes them unfindable.
            if let nickname = profile.nickname, nickname != profile.displayName {
                Text("Known here as \(nickname)")
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.tertiary)
            }

            if !profile.badges.isEmpty {
                BadgeRow(badges: profile.badges)
                    .padding(.top, Spacing.tight)
            }

            if let channelID = profile.directMessageChannelID {
                Button("Message", systemImage: "bubble.left.fill") {
                    openDirectMessage(channelID)
                }
                .buttonStyle(.glassProminent)
                .padding(.top, Spacing.base)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.margin)
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.snug)
    }

    @ViewBuilder
    private var facts: some View {
        if profile.isLoading {
            ProfileSkeleton(contentWidth: contentWidth)
        }

        if let bio = profile.bio, !bio.isEmpty {
            section("About Me") {
                // Markdown, not a plain string — see the card.
                ProseText(
                    markdown: bio,
                    font: .system(.subheadline),
                    color: InkColor.secondary,
                    emojiSide: 18,
                    onEmoji: openEmoji ?? { inspectedEmoji = $0 },
                    onLink: openLink
                )
            }
        }

        section("Member Since") {
            VStack(alignment: .leading, spacing: Spacing.base) {
                // Derived from the snowflake rather than fetched: the id already
                // carries a millisecond timestamp.
                joinRow(title: "Discord", date: profile.accountCreated) {
                    // Discord's own mark rather than a stand-in symbol: this row
                    // names a service, and the other row beside it shows that
                    // server's real icon. One of the two being a sparkle made
                    // the pair read as a placeholder that had not loaded.
                    ConnectionMark(service: BrandMark.discord, side: 20)
                }
                // **Named, not just dated.** Two bare dates under one heading is
                // a puzzle; the server this profile was opened in is the answer
                // to half of it, and the app already has its icon resident.
                if let memberSince = profile.memberSince, let guild = profile.guild {
                    joinRow(title: guild.name, date: memberSince) { serverIcon(guild) }
                }
            }
        }

        if let tier = profile.premiumTier.label {
            section(tier) {
                Text(profile.premiumSince.map {
                    "Subscriber since \($0.formatted(.dateTime.month(.wide).year()))"
                } ?? "Subscriber")
                .font(.system(.subheadline))
                .foregroundStyle(InkColor.secondary)
            }
        }

        if let legacy = profile.legacyUsername {
            section("Originally") {
                Text(legacy)
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.secondary)
                    .textSelection(.enabled)
            }
        }

        if !profile.roles.isEmpty {
            section("Roles") { RoleChipFlow(roles: profile.roles) }
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

        // **The full profile shows every role**, where the card caps at two
        // rows and counts the rest: this is the page somebody opened *to see
        // them*, and it scrolls.
        if !profile.mutualFriends.isEmpty {
            section("Mutual Friends") {
                MutualFriendsRow(friends: profile.mutualFriends)
            }
        }

        if !profile.isSelf {
            ProfileNoteField(
                userID: profile.userID,
                note: profile.note,
                width: Self.identityWidth - Spacing.group * 2
            )
            .padding(.horizontal, Spacing.group)
            .padding(.bottom, Spacing.margin)
        }
    }

    private func joinRow(
        title: String,
        date: Date,
        @ViewBuilder icon: () -> some View
    ) -> some View {
        HStack(spacing: Spacing.base) {
            icon()
                .font(.system(.caption))
                .foregroundStyle(InkColor.tertiary)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.tertiary)
                    .lineLimit(1)
                Text(date, format: .dateTime.day().month(.abbreviated).year())
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.secondary)
            }
        }
    }

    private func serverIcon(_ server: MutualServer) -> some View {
        RemoteImage(url: server.iconURL, side: 20) {
            Text(server.monogram)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Ink.secondary)
                .frame(width: 20, height: 20)
                .background(Palette.surfaceRaised)
        }
        .frame(width: 20, height: 20)
        .clipShape(.circle)
    }

    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text(title.uppercased())
                .font(Typeface.sectionHeader)
                .foregroundStyle(InkColor.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.snug)
    }

    // MARK: The context

    private var contextColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if tabs.count > 1 { tabStrip }
            Group {
                switch tab {
                case .activity:
                    ActivityPane(profile: profile, ground: ground)
                case .mutuals:
                    MutualServersPane(servers: profile.mutualServers, ground: ground)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The pane swaps in place rather than cutting: the tab's underline
            // is already travelling, and a hard cut underneath it reads as two
            // unrelated screens.
            .transition(.opacity)
        }
        .frame(width: Self.contextWidth)
        .padding(.top, tabs.count > 1 ? Spacing.margin : Spacing.group)
        // Declared once, on the column, so the underline's travel and the pane's
        // cross-fade are one gesture rather than two that happen to overlap.
        .animation(motion.standard, value: tab)
    }

    /// The tabs.
    ///
    /// One underline in a shared namespace rather than one per tab fading in and
    /// out: the mark travels to the tab that was clicked, which is the whole of
    /// what a tab strip has to say.
    private var tabStrip: some View {
        HStack(spacing: Spacing.group) {
            ForEach(tabs, id: \.self) { candidate in
                TabButton(
                    title: candidate.title,
                    isSelected: tab == candidate,
                    accent: ground.accent,
                    namespace: tabUnderline
                ) {
                    // A `@State` write of an equal value still invalidates.
                    guard tab != candidate else { return }
                    tab = candidate
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.margin)
        // Room for the close button, which floats over this row's trailing end.
        .padding(.trailing, Metrics.control + Spacing.base)
        .padding(.bottom, Spacing.snug)
    }

    private var closeButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(InkColor.secondary)
                .frame(width: Metrics.control, height: Metrics.control)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .interactiveChrome(in: .circle)
        .padding(Spacing.snug)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel(Text("Close"))
    }
}

/// One tab, and the underline that travels between them.
///
/// **The mark is in the person's colour, not the app's.** These two tabs sit on
/// a surface washed in someone's own theme; a white underline on it is the one
/// piece of chrome that belongs to nobody, and it was the loudest thing in the
/// pane. An unthemed profile has no colour to lend, and there the underline
/// falls back to the app's own hierarchy rather than to a colour invented for
/// it.
private struct TabButton: View {
    var title: String
    var isSelected: Bool
    /// Nil on an unthemed profile.
    var accent: Color?
    var namespace: Namespace.ID
    var action: () -> Void

    private var mark: AnyShapeStyle {
        accent.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Ink.primary)
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.subheadline, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(
                    isSelected ? AnyShapeStyle(InkColor.primary) : AnyShapeStyle(Ink.secondary)
                )
                .padding(.bottom, 6)
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Capsule()
                            .fill(mark)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "underline", in: namespace)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// What they are doing, or an honest account of why there is nothing here.
private struct ActivityPane: View {
    var profile: ProfilePresentation
    var ground: ProfileGround

    var body: some View {
        if let activity = profile.activity {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                ActivityCard(activity: activity, ground: ground)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.margin)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ProfileEmptyState(
                symbol: "moon.zzz.fill",
                title: "Nothing right now",
                detail: "\(profile.displayName) isn't playing, listening to or "
                    + "streaming anything.",
                ground: ground
            )
        }
    }
}

/// One running activity.
private struct ActivityCard: View {
    var activity: Activity
    var ground: ProfileGround

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(.title3))
                .foregroundStyle(ground.accent ?? InkColor.secondary)
                .frame(width: 40, height: 40)
                .background(ground.panelFill, in: .rect(cornerRadius: Radius.row))

            VStack(alignment: .leading, spacing: 2) {
                Text(activity.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)
                if let details = activity.details, !details.isEmpty {
                    Text(details)
                        .font(.system(.caption))
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(2)
                }
                if let state = activity.state, !state.isEmpty {
                    Text(state)
                        .font(.system(.caption))
                        .foregroundStyle(InkColor.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A panel on the person's own ground, washed in their colour — not a
        // grey box dropped onto it. §4 rule 2: the ground under this is already
        // the lower surface, so this one is solid rather than a second glass.
        .background(ground.panelFill, in: .rect(cornerRadius: Radius.glass, style: .continuous))
    }
}

/// The servers you share, at full size.
private struct MutualServersPane: View {
    var servers: [MutualServer]
    var ground: ProfileGround

    private static let iconSide: CGFloat = 32

    @State private var hovered: GuildID?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(servers) { server in
                    row(server)
                }
            }
            .padding(.horizontal, Spacing.base)
            .padding(.bottom, Spacing.margin)
        }
        .scrollIndicators(.never)
        .softScrollEdgesVertical()
    }

    private func row(_ server: MutualServer) -> some View {
        HStack(spacing: Spacing.snug) {
            RemoteImage(url: server.iconURL, side: Self.iconSide) {
                Text(server.monogram)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: Self.iconSide, height: Self.iconSide)
                    .background(ground.panelFill)
            }
            .frame(width: Self.iconSide, height: Self.iconSide)
            .clipShape(.rect(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                Text(server.name)
                    .font(Typeface.rowTitle)
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)
                if let nickname = server.nickname {
                    Text(nickname)
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(InkColor.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(ground.panelFill)
                .opacity(hovered == server.id ? 1 : 0)
        }
        .contentShape(.rect(cornerRadius: Radius.row, style: .continuous))
        .onHover { hovering in
            let next = hovering ? server.id : (hovered == server.id ? nil : hovered)
            // A `@State` write of an equal value still invalidates.
            guard hovered != next else { return }
            hovered = next
        }
    }
}

/// A pane with nothing in it, saying so.
///
/// A sentence rather than a shrug: "no activity" and "they are not sharing one"
/// are the same picture and different facts, and the reader has no other way to
/// tell them apart.
private struct ProfileEmptyState: View {
    var symbol: String
    var title: String
    var detail: String
    var ground: ProfileGround

    var body: some View {
        VStack(spacing: Spacing.snug) {
            // The glyph sits in a disc of the person's own colour rather than
            // floating alone on the ground. An empty pane is still THEIR pane,
            // and a lone grey symbol in the middle of a large surface reads as
            // something that failed to load rather than as an answer.
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(ground.accent ?? InkColor.secondary)
                .frame(width: 64, height: 64)
                .background(ground.panelFill, in: .circle)

            Text(title)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)
            Text(detail)
                .font(.system(.caption))
                .foregroundStyle(InkColor.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.group)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
