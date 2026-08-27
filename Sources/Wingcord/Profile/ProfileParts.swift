import SwiftUI
import WingcordCore

// The pieces both profile surfaces are built from.
//
// **One definition each, shared by the card and the full profile**, because the
// two are the same person one click apart: a badge row that answers to the
// pointer in a popover and not in a sheet, or role chips with two different
// radii, is the kind of drift nobody notices until both are on screen together.
//
// They live here rather than inside either surface for the same reason
// `ProfilePresentation` does — the surface that happens to have been written
// first is not the owner of a shared component.

/// The row of account badges.
///
/// Discord's own artwork where the profile route named it, an SF Symbol where
/// only a flag bit was available.
///
/// **Hovering one opens a popover naming it**, rather than waiting out the
/// system tooltip delay. That delay is the whole reason a tooltip is the wrong
/// control here: a badge is an eighteen-point picture with no text anywhere near
/// it, so "what is that?" is the first question every one of them raises, and
/// answering it half a second later is answering it after the reader has given
/// up and moved on.
///
/// **A real popover, and it took two wrong answers to get here.** Drawn inside
/// the card it was bounded by the card: centred on its badge, a long label —
/// Discord writes some of these as whole sentences — started outside the leading
/// edge and was cut off there; anchored to the row instead, it stopped being cut
/// but had to truncate, which loses the end of the only sentence that says what
/// the badge is. A popover is not bounded by the card at all, so the label is
/// whole and where it belongs. One is presented at a time — `hovered` holds a
/// single id — so the row costs one popover, not one each.
struct BadgeRow: View {
    var badges: [ProfileBadge]

    @State private var hovered: ProfileBadge.ID?

    private static let side: CGFloat = 18

    var body: some View {
        // Wrapping, because a well-decorated account carries more of these than
        // a 320pt card has room for on one line, and a row that clips silently
        // drops badges the reader has no way to know existed.
        FlowLayout(spacing: Spacing.tight) {
            ForEach(badges) { badge in
                mark(badge)
                    .frame(width: Self.side, height: Self.side)
                    .contentShape(.rect)
                    .onHover { isInside in
                        // A `@State` write of an equal value still invalidates.
                        let next = isInside ? badge.id : (hovered == badge.id ? nil : hovered)
                        guard hovered != next else { return }
                        hovered = next
                    }
                    .popover(
                        isPresented: Binding(
                            get: { hovered == badge.id },
                            // Dismissal is owned by the pointer leaving, not by
                            // the popover: clearing here as well would fight
                            // `onHover` and flicker.
                            set: { if !$0, hovered == badge.id { hovered = nil } }
                        ),
                        arrowEdge: .top
                    ) {
                        BadgeFlyout(label: badge.label)
                    }
                    .accessibilityLabel(Text(badge.label))
            }
        }
    }

    @ViewBuilder
    private func mark(_ badge: ProfileBadge) -> some View {
        if let url = badge.iconURL {
            RemoteImage(url: url, side: Self.side) {
                symbol(badge)
            }
        } else {
            symbol(badge)
        }
    }

    private func symbol(_ badge: ProfileBadge) -> some View {
        Image(systemName: badge.symbolName)
            .font(.system(.caption))
            .foregroundStyle(InkColor.secondary)
    }
}

/// The label inside that popover.
///
/// **One line, whole.** Discord names some badges with a sentence, and now that
/// the label is in a window of its own there is nothing to wrap against and
/// nothing to truncate for — the popover sizes to the text.
struct BadgeFlyout: View {
    var label: String

    var body: some View {
        Text(label)
            .font(.system(.subheadline))
            .foregroundStyle(InkColor.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.base)
            // It is an answer about the thing under the pointer, so it must
            // never become the thing under the pointer.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The mutual-servers line, and the list it opens.
///
/// The count alone is a fact the reader then has to go and check somewhere else,
/// and the profile route already sent the answer — so the line is the way into
/// it rather than a statement beside it.
///
/// A `.popover` here rather than an in-card overlay, unlike the badge flyout:
/// this one is opened by a click, holds a scrolling list of arbitrary length,
/// and has to be dismissible. All four of those are things a popover already
/// does — outside-click, Escape, screen-edge avoidance, first responder — and
/// each is a thing a hand-placed overlay would have to grow by hand.
struct MutualServersRow: View {
    var servers: [MutualServer]

    @Environment(\.motion) private var motion
    @State private var isOpen = false
    @State private var isHovering = false

    private var label: String {
        servers.count == 1 ? "1 Mutual Server" : "\(servers.count) Mutual Servers"
    }

    var body: some View {
        Button { isOpen = true } label: {
            HStack(spacing: Spacing.base) {
                Image(systemName: "person.2.fill")
                    .font(.system(.caption2))
                    .foregroundStyle(InkColor.tertiary)
                    .frame(width: 14)
                Text(label)
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(InkColor.tertiary)
                    .opacity(isHovering || isOpen ? 1 : 0.45)
            }
            // The ground grows OUTWARD from the row rather than the row being
            // padded in and back out again: the symbol then still lines up with
            // the fact rows under it, which is the alignment a reader actually
            // sees. Inside the button's own label, so it is part of the control
            // rather than a background behind it — §4 rule 4.
            .background {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(Palette.hoverFill)
                    .opacity(isHovering || isOpen ? 1 : 0)
                    .padding(.horizontal, -5)
                    .padding(.vertical, -3)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .accessibilityLabel(Text(label))
        .accessibilityHint("Show the servers you share")
        .popover(isPresented: $isOpen, arrowEdge: .trailing) {
            MutualServersList(servers: servers)
                // The list carries the material; the popover must carry none,
                // or two are stacked and the result reads as frost.
                .presentationBackground(.clear)
        }
    }
}

/// The servers themselves.
///
/// Scrolls only once it has to: an account sharing three servers gets a panel
/// three rows tall, not a fixed pane with an empty half. The cap is what stops
/// an account sharing ninety from producing a panel taller than the display.
struct MutualServersList: View {
    var servers: [MutualServer]

    private static let rowHeight: CGFloat = 34
    private static let visibleRows = 8

    private var height: CGFloat {
        min(CGFloat(servers.count), CGFloat(Self.visibleRows)) * Self.rowHeight
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(servers) { server in
                    HStack(spacing: Spacing.base) {
                        RemoteImage(url: server.iconURL, side: Metrics.avatarRow) {
                            Text(server.monogram)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Ink.secondary)
                                .frame(width: Metrics.avatarRow, height: Metrics.avatarRow)
                                .background(Palette.surfaceRaised)
                        }
                        .frame(width: Metrics.avatarRow, height: Metrics.avatarRow)
                        .clipShape(.circle)

                        VStack(alignment: .leading, spacing: 0) {
                            Text(server.name)
                                .font(Typeface.rowTitle)
                                .foregroundStyle(Ink.primary)
                                .lineLimit(1)
                            // The nickname they carry there. Shown only where it
                            // exists, which is the only case it says anything.
                            if let nickname = server.nickname {
                                Text(nickname)
                                    .font(Typeface.rowSubtitle)
                                    .foregroundStyle(Ink.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: Self.rowHeight)
                    .padding(.horizontal, Spacing.snug)
                }
            }
            .padding(.vertical, Spacing.base)
        }
        .scrollIndicators(.never)
        .scrollDisabled(servers.count <= Self.visibleRows)
        .frame(width: 240, height: height + Spacing.base * 2)
    }
}

/// What the card shows while the detail fetch is still out.
///
/// **A skeleton rather than a stripped-down profile.** Everything below the
/// name — the bio, the roles, the badges — arrives from a request that is still
/// in flight when the card opens, so drawing the card without them says "this
/// person has nothing" and then visibly contradicts itself a moment later. Grey
/// bars say "not yet", which is the truth.
///
/// The bars do not shimmer. A shimmer is an animation running on every frame the
/// card is open, for a wait that is usually one round trip, and the spinner
/// already carries the "working" signal.
struct ProfileSkeleton: View {
    /// The width the bars are laid out against — the card's, less its margins.
    var contentWidth: CGFloat

    /// Deterministic fractions, so the block does not reshuffle on a repaint.
    private static let fractions: [CGFloat] = [0.55, 0.86, 0.34]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading profile…")
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(InkColor.tertiary)
            }

            VStack(alignment: .leading, spacing: Spacing.tight) {
                ForEach(Array(Self.fractions.enumerated()), id: \.offset) { _, fraction in
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: contentWidth * fraction, height: 9)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.snug)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading profile"))
    }
}

/// One linked account.
///
/// The service is named by a symbol where the system has a fitting one and by
/// its own name where it does not — an unknown service still has to be legible,
/// and Discord adds services faster than any hard-coded table keeps up with.
struct ConnectionChip: View {
    var connection: ConnectedAccount

    private var serviceName: String {
        BrandMark.mark(for: connection.service)?.name
            ?? connection.service.capitalized
    }

    var body: some View {
        HStack(spacing: 5) {
            ConnectionMark(service: connection.service, side: 15)
            Text(connection.name)
                .font(.system(.caption2))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
            if connection.isVerified {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Palette.affirmative)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .glassEffect(.clear, in: .rect(cornerRadius: 9))
        .help(serviceName)
        .accessibilityLabel(Text("\(serviceName), \(connection.name)"))
    }
}

/// A small uppercase chip — the APP mark.
///
/// **Tinted, and that is not a colour-rule exception.** The rule is that colour
/// carries meaning; this mark's whole job is to say *this account is not a
/// person*, which is the one thing on a profile a reader must not have to work
/// out. The transcript already draws it in the accent — a clear-glass version
/// here made the same mark read as a grey label on the surface where it matters
/// most, and made the two disagree one click apart.
///
/// The tint is in the material rather than a fill behind it, so it still lenses
/// the person's own ground: a fill under glass is what §4 rule 3 forbids.
struct TagChip: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .glassEffect(.regular.tint(Palette.accent), in: .rect(cornerRadius: 5))
    }
}

/// A clan tag, worn beside a name.
///
/// **The guild's badge and the letters, never the letters alone.** A tag IS the
/// pair on Discord — the badge is the half people recognise across servers — and
/// the member list already draws both. A profile that showed only the letters
/// was the same person wearing half a mark.
///
/// The badge is a tiny asset out of the same cache as every other picture, and
/// the chip reserves its slot whether or not it has landed, so the tag does not
/// reflow when it does.
///
/// **It opens the server behind it, in a popover of its own.** That is a nested
/// popover — this chip is drawn inside the profile card, which is itself one —
/// and it is the right control rather than a routed request: a card presented at
/// the window root would have to be anchored to a rect in the root's space, and
/// a view inside a popover has no such rect. Nested popovers were confirmed on
/// screen rather than assumed; see `HANDOFF.md`.
///
/// One chip per profile surface, so this is a presentation modifier on a leaf
/// and not on a list row — the rule it would otherwise break exists because a
/// popover written into a row is evaluated by every row.
struct GuildTagChip: View {
    var tag: GuildTag

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isOpen = false
    @State private var isHovering = false

    private static let badgeSide: CGFloat = 12

    var body: some View {
        Group {
            if let guildID = tag.guildID {
                Button {
                    isOpen = true
                    model.loadGuildProfile(guildID)
                } label: { chip }
                .buttonStyle(.plain)
                .onHover { hovering in
                    // A `@State` write of an equal value still invalidates.
                    guard isHovering != hovering else { return }
                    isHovering = hovering
                }
                .animation(motion.hover, value: isHovering)
                .accessibilityHint("Show this server")
                .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                    GuildProfileCard(
                        profile: model.guildProfilePresentation(of: guildID, tag: tag.text),
                        openGuild: { model.openGuild($0) }
                    )
                    // The card supplies its own ground, so the popover must
                    // supply none — two materials in series read as frost.
                    .presentationBackground(.clear)
                }
            } else {
                chip
            }
        }
        .accessibilityLabel(Text("Tag \(tag.text)"))
    }

    private var chip: some View {
        HStack(spacing: 3) {
            if let url = tag.badgeURL {
                RemoteImage(url: url, side: Self.badgeSide) { Color.clear }
                    .frame(width: Self.badgeSide, height: Self.badgeSide)
            }
            Text(tag.text)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
        }
        .padding(.leading, tag.badgeURL == nil ? 6 : 4)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .glassEffect(
            // Lit under the pointer rather than given a fill behind it: a fill
            // under glass is what stops a surface lensing (§4 rule 3).
            isHovering || isOpen ? .clear.tint(Palette.hoverFill) : .clear,
            in: .capsule
        )
        .contentShape(.capsule)
    }
}

/// Role chips that wrap.
///
/// A `Layout` rather than a `GeometryReader` and a computed row split: a layout
/// sees the proposal and can place its subviews in one pass, where the reader
/// needs a second pass and a state write to publish the width it measured — and
/// a state write during layout is a relayout.
struct RoleChipFlow: View {
    var roles: [ProfileRole]

    var body: some View {
        FlowLayout(spacing: Spacing.tight) {
            ForEach(roles) { role in
                HStack(spacing: 4) {
                    Circle()
                        .fill(role.colorValue.map { Color(hex: $0) } ?? Palette.presenceOffline)
                        .frame(width: 8, height: 8)
                    Text(role.name)
                        .font(.system(.caption2))
                        .foregroundStyle(InkColor.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                // Clear glass, because the ground behind it is the person's own
                // colour and a `.regular` material would blur it into grey.
                .glassEffect(.clear, in: .rect(cornerRadius: 7))
            }
        }
    }
}

/// Wraps its subviews onto as many rows as they need.
///
/// A `Layout` rather than a `GeometryReader` and a computed row split: a layout
/// sees the proposal and can place its subviews in one pass, where the reader
/// needs a second pass and a state write to publish the width it measured — and
/// a state write during layout is a relayout.
///
/// **Every subview is measured once, into the cache.** `sizeThatFits` and
/// `placeSubviews` both need every child's size, and asking a `Text` for one is
/// a text-measurement call — so the uncached version measured a fifty-role
/// profile a hundred times per layout pass, and again on every width change.
/// The `Layout` protocol's cache exists for exactly this and costs one array.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    struct Cache {
        var sizes: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var total = CGSize.zero

        for size in cache.sizes {
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                total.width = max(total.width, rowWidth)
                total.height += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth > 0 ? spacing + size.width : size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        total.width = max(total.width, rowWidth)
        total.height += rowHeight
        return total
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = cache.sizes[index]
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The avatar as a profile draws it: a **hole in the artwork**, not a ring on
/// top of it.
///
/// The ring it replaces was a 5pt stroke of `Palette.canvas` painted over the
/// banner, and on a dark banner that is a heavy black outline stuck to the
/// avatar — the presence dot carried a second one of its own. What Discord
/// draws, and what this draws now, is a hole: the artwork is masked away in a
/// disc around the avatar, so the gap shows the CARD'S OWN GROUND. On a themed
/// profile that is the theme's wash and on an unthemed one it is the glass, and
/// neither is a colour a stroke could have been given in advance.
///
/// **Masks rather than `destinationOut` blending, and that is load-bearing.**
/// The banner can be an `AnimatedDecoration`, which is an `NSView` hosting a
/// `CALayer`; a sibling drawn with a blend mode does not reliably composite
/// against an AppKit-backed layer, but a mask becomes that layer's own
/// `CALayer.mask` and always does.
///
/// The three placements below are written against the same four numbers — the
/// avatar's side, its drop, the leading margin and the gap — so the hole and the
/// thing it is a hole for cannot drift apart.
struct ProfileAvatar: View {
    var profile: ProfilePresentation
    /// How far the avatar hangs below the artwork.
    var drop: CGFloat
    var dotSide: CGFloat
    /// Nil where the avatar opens nothing — the full profile is already open.
    var openFullProfile: (() -> Void)?

    /// The gap the cut-out leaves around the avatar, per edge.
    static let ringGap: CGFloat = 5
    /// And around the presence dot.
    private static let dotGap: CGFloat = 3
    /// How far the dot is pulled inside the avatar's corner.
    private static let dotInset: CGFloat = 2

    private var side: CGFloat { Metrics.avatarProfile }

    /// The mask an artwork block takes so this avatar can sit in it.
    ///
    /// Bottom-leading, like the stack the avatar is placed in, and offset by the
    /// same drop — so the hole is wherever the avatar is, including after a
    /// metric changes.
    static func bannerMask(drop: CGFloat) -> some View {
        Rectangle()
            .overlay(alignment: .bottomLeading) {
                Circle()
                    .frame(
                        width: Metrics.avatarProfile + ringGap * 2,
                        height: Metrics.avatarProfile + ringGap * 2
                    )
                    .padding(.leading, Spacing.margin - ringGap)
                    .offset(y: drop + ringGap)
                    .blendMode(.destinationOut)
            }
            // The blend is contained here, where there is nothing but shapes.
            .compositingGroup()
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            avatar
                // The dot's own hole, taken out of the avatar. It lands below
                // the banner's lower edge, so what shows through it is the card
                // ground with no artwork in the way.
                .mask { dotMask }
                .padding(.leading, Spacing.margin)
                .offset(y: drop)

            PresenceDot(status: profile.status, side: dotSide, hasPlate: false)
                .frame(width: dotSide, height: dotSide)
                .padding(.leading, Spacing.margin + side - dotSide - Self.dotInset)
                .offset(y: drop - Self.dotInset)
        }
    }

    @ViewBuilder
    private var avatar: some View {
        let art = AvatarView(
            url: profile.avatarURL,
            monogram: profile.monogram,
            side: side,
            decorationURL: profile.decorationURL
        )
        if let openFullProfile {
            Button(action: openFullProfile) {
                art.contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(profile.displayName))
            .accessibilityHint("Open the full profile")
        } else {
            art
        }
    }

    /// How far a decoration is drawn outside the avatar's own bounds.
    ///
    /// **Static, and read by the surfaces that lay out around this.** A
    /// decoration is drawn at 1.2x *outside* the avatar's bounds and therefore
    /// contributes no size to layout at all — so a card that reserves the
    /// avatar's own height alone puts the next line under a ring of clouds. The
    /// number belongs to one place, and the places that must clear it read it.
    static let decorationOverhang: CGFloat =
        Metrics.avatarProfile * (Metrics.decorationScale - 1) / 2

    private var decorationOverhang: CGFloat { Self.decorationOverhang }

    private var dotMask: some View {
        // **The rectangle has to cover the DECORATION, not just the avatar.** A
        // mask is laid out in the masked view's own bounds, and a decoration is
        // authored as a frame AROUND the avatar and drawn at 1.2x outside them —
        // so a bounds-sized rectangle masked the overhang away and cut every
        // decorated avatar into a square, clouds and wings sliced off at the
        // corners. The negative padding pushes the rectangle out to the
        // decoration's own extent; the hole below still aligns to the avatar's
        // bounds, which is where the dot is.
        Rectangle()
            .padding(-decorationOverhang)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .frame(
                        width: dotSide + Self.dotGap * 2,
                        height: dotSide + Self.dotGap * 2
                    )
                    .offset(x: Self.dotGap - Self.dotInset, y: Self.dotGap - Self.dotInset)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
    }
}
