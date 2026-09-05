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
/// `docs/PROFILE-DESIGN-SPEC.md` §0.
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

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isMenuOpen = false

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
                banner
                identity
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
        .modifier(ProfileGroundFill(ground: ground, corner: 0))
        .overlay(alignment: .bottom) { footDock }
        .overlay(alignment: .trailing) {
            Rectangle().fill(.white.opacity(0.10)).frame(width: 1)
        }
        // The effect plays over the finished panel and is clipped to it. Its
        // layers are authored at `zIndex` 100+ — above everything — and it must
        // not swallow a click meant for the controls underneath.
        .overlay {
            if let effect = profile.effect {
                ProfileEffectView(effect: effect, width: Self.width)
                    .allowsHitTesting(false)
                    .accessibilityLabel(Text(effect.accessibilityLabel ?? effect.title))
            }
        }
        .clipped()
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
                // The handoff's fade: the artwork dissolves into the rail rather
                // than ending in a line, which is what keeps the banner and the
                // body reading as one surface.
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.3),
                            .init(color: Palette.canvas.opacity(0.55), location: 0.78),
                            .init(color: Palette.canvas.opacity(0.9), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .frame(height: Self.bannerHeight)
                .clipped()
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

            if hasCustomStatus {
                CustomStatusBubble(
                    text: profile.customStatus,
                    emoji: profile.customStatusEmoji,
                    avatarDrop: Self.avatarDrop,
                    cardWidth: Self.width,
                    avatarSide: Self.avatarSide,
                    margin: Self.gutter
                )
            }
        }
        // The drop AND the decoration's overhang: a decoration is drawn outside
        // the avatar's bounds and contributes no layout size, so reserving the
        // drop alone puts the name under a ring of clouds.
        .padding(.bottom, Self.avatarDrop + ProfileAvatar.decorationOverhang(side: Self.avatarSide))
    }

    @ViewBuilder
    private var bannerArtwork: some View {
        if let url = profile.bannerURL {
            ZStack {
                RemoteImage(url: url, side: Self.width, bucket: .artwork) { Color.clear }
                    .aspectRatio(contentMode: .fill)
                // Only where the hash says it can move, so a still banner never
                // pays for a second fetch and a multi-frame decode. The budget
                // is a banner's — around half a megabyte a frame — not a
                // decoration's, whose default would buy nine of them.
                if CDN.canAnimate(url) {
                    AnimatedDecoration(
                        url: url,
                        side: Self.width,
                        gravity: .resizeAspectFill,
                        byteBudget: 12 * 1024 * 1024
                    )
                }
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
                StyledDisplayName(
                    text: profile.displayName,
                    style: profile.displayNameStyle,
                    textStyle: .largeTitle,
                    weight: .bold
                )
                .lineLimit(1)
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
                if let tag = profile.guildTag { GuildTagChip(tag: tag) }
                // A label, never a filter — the route still hands over the
                // mutual servers the reader can see for themselves.
                if profile.isProfilePrivate {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(InkColor.tertiary)
                        .help("This profile is private")
                        .accessibilityLabel(Text("Private profile"))
                }
                if !profile.badges.isEmpty { BadgeRow(badges: profile.badges) }
                Spacer(minLength: 0)
            }
            // A row of eleven badges beside a guild tag and a handle is wider
            // than the column, and the row is the part that gives.
            .fixedSize(horizontal: false, vertical: true)

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
                    symbolName: "sparkles"
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
        if !profile.connections.isEmpty {
            section("Connections", topGap: 24) {
                ConnectionDock(connections: profile.connections)
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
                    colors: [.clear, Palette.canvas.opacity(0.78)],
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
            .modifier(NeutralFriendGlass(isPlain: ground.accentPair == nil))
            .accessibilityLabel(Text(title))
        }
    }

    /// **Always a LIGHT ramp of the person's hue, never the raw colour.** The
    /// handoff's pill runs `oklch(0.9 …)` to `oklch(0.78 …)` — two tints of the
    /// theme, both light — and sets the label in near-black. Dropping the raw
    /// swatch in as the lower stop is what put dark text on a navy pill: half
    /// the themes people choose are dark, and a fill whose contrast depends on
    /// somebody else's taste is a label that is unreadable for some of them.
    private var friendFill: AnyShapeStyle {
        guard let pair = ground.accentPair else { return AnyShapeStyle(Color.clear) }
        return AnyShapeStyle(LinearGradient(
            colors: [
                pair.primary.mix(with: .white, by: 0.72),
                pair.primary.mix(with: .white, by: 0.42),
            ],
            startPoint: .top,
            endPoint: .bottom
        ))
    }

    /// Near-black on a lit pill, the hierarchy on a clear one. A destructive
    /// action keeps its own colour either way — dropping a friend is the one
    /// thing on this bar that cannot be taken back.
    private var friendLabelStyle: AnyShapeStyle {
        if profile.relationship.friendActionIsDestructive {
            return AnyShapeStyle(Palette.destructive)
        }
        return ground.accentPair == nil
            ? AnyShapeStyle(InkColor.primary)
            : AnyShapeStyle(Color.black.opacity(0.82))
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
        } else if moment.symbolName == BrandMark.discord {
            ConnectionMark(service: BrandMark.discord, side: 13)
        } else if let symbolName = moment.symbolName {
            Image(systemName: symbolName)
                .font(.system(size: 9))
                .foregroundStyle(InkColor.tertiary)
                .frame(width: 13, height: 13)
        }
    }
}
