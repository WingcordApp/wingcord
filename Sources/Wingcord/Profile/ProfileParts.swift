import AppKit
import CoreText
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
    /// When this account's subscription started, for the one badge that says
    /// so. Nil where the profile route has not answered, and on the two preview
    /// surfaces that draw a badge row without a live account behind it.
    var premiumSince: Date?

    @Environment(AppModel.self) private var model
    /// Whose flyout is up.
    @State private var shown: ProfileBadge.ID?
    /// Where the pointer actually is. **Two latches, because the card sits
    /// directly above the badge** — a tenure badge's flyout is a 240-point
    /// object a reader is meant to click, and reaching it means leaving the
    /// mark that raised it. The plain one-line flyout never needed this because
    /// nothing in it was worth reaching.
    @State private var onBadge: ProfileBadge.ID?
    @State private var onCard: ProfileBadge.ID?
    @State private var dismissal: Task<Void, Never>?

    private static let side: CGFloat = 18

    var body: some View {
        // Wrapping, because a well-decorated account carries more of these than
        // a 320pt card has room for on one line, and a row that clips silently
        // drops badges the reader has no way to know existed.
        FlowLayout(spacing: Spacing.tight) {
            ForEach(badges) { badge in
                let tenure = PremiumTenure.named(badge.id)
                mark(badge)
                    .frame(width: Self.side, height: Self.side)
                    // **Discord's own `drop-shadow(0 0 5px …)` in the tier's
                    // colour**, and only while the pointer is on it. A badge
                    // that glows all the time is decoration; one that glows
                    // under the pointer is telling the reader it answers.
                    .shadow(
                        color: tenure.map { Color(hex: $0.glow) } ?? .clear,
                        radius: shown == badge.id ? 5 : 0
                    )
                    .contentShape(.rect)
                    // Only a tenure badge opens anything. Everything else on
                    // this row is a label, and a mark that looks pressable and
                    // does nothing is the inert control `INVARIANTS.md` §5.5
                    // forbids.
                    .onTapGesture { open(tenure) }
                    .onHover { pointer(badge.id, onCard: false, inside: $0) }
                    .popover(
                        isPresented: Binding(
                            get: { shown == badge.id },
                            // Dismissal is owned by the pointer leaving, not by
                            // the popover: clearing here as well would fight
                            // `onHover` and flicker. A real dismissal — Escape,
                            // the window resigning — still lands here.
                            set: { if !$0, shown == badge.id { dismiss() } }
                        ),
                        arrowEdge: .top
                    ) {
                        // **A tenure badge gets a card, everything else a
                        // line.** That is Discord's own split rather than a
                        // preference: it is the only badge it says more than a
                        // sentence about, and the only one that opens a page.
                        if let tenure {
                            TenureBadgeFlyout(
                                tenure: tenure,
                                premiumSince: premiumSince,
                                open: { open(tenure) },
                                hovering: { pointer(badge.id, onCard: true, inside: $0) }
                            )
                        } else {
                            BadgeFlyout(label: badge.label)
                        }
                    }
                    // **A presentation paints the APP's material, not the
                    // card's**, and it inherits the card's environment on the
                    // way out — so a flyout raised from a light profile came up
                    // on this app's near-black popover with the card's dark ink
                    // on it, unreadable. Anything that escapes a themed surface
                    // into a window of its own has to restate the scheme it is
                    // actually drawn against.
                    .environment(\.colorScheme, .dark)
                    .accessibilityLabel(Text(badge.label))
                    .accessibilityAddTraits(tenure == nil ? [] : .isButton)
            }
        }
    }

    /// Where the pointer is, from either surface, and what that means for the
    /// flyout.
    ///
    /// **The grace period is what makes the card reachable at all.** The card is
    /// a separate window with an arrow between it and the badge, so for the
    /// frames the pointer spends crossing it is over neither — and dismissing on
    /// the first `false` takes the card away from under the hand reaching for
    /// it. Cancelled the moment either surface reports the pointer back, so a
    /// reader who keeps moving never sees the delay.
    private func pointer(_ id: ProfileBadge.ID, onCard isCard: Bool, inside: Bool) {
        if isCard {
            onCard = inside ? id : (onCard == id ? nil : onCard)
        } else {
            onBadge = inside ? id : (onBadge == id ? nil : onBadge)
        }
        dismissal?.cancel()
        dismissal = nil
        if let next = onBadge ?? onCard {
            // A `@State` write of an equal value still invalidates.
            if shown != next { shown = next }
            return
        }
        dismissal = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, onBadge == nil, onCard == nil else { return }
            shown = nil
        }
    }

    private func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        onBadge = nil
        onCard = nil
        shown = nil
    }

    /// Raises the tier's page, and takes the flyout down on the way.
    ///
    /// Leaving the card up over a full-window page would be a hover answer
    /// floating above the page it just opened.
    private func open(_ tenure: PremiumTenure?) {
        guard let tenure else { return }
        dismiss()
        model.tenureBadgeRequest = TenureBadgeRequest(
            tenure: tenure,
            premiumSince: premiumSince
        )
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
                // And the app's ink with it — see the badge flyout above.
                .environment(\.colorScheme, .dark)
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

    @Environment(\.openURL) private var openURL
    @Environment(\.motion) private var motion
    @State private var isHovering = false
    /// Shown for a beat after a copy, because the pasteboard gives no feedback
    /// of its own and a chip that does nothing visible reads as a dead control.
    @State private var didCopy = false
    @State private var copyReset: Task<Void, Never>?

    /// Where it goes, or nil for a service with no public page.
    private var url: URL? { connection.profileURL }

    var body: some View {
        Button(action: act) {
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
                // **The affordance says which of two things pressing it does.**
                // Half these services have no address a client can build — a
                // PlayStation tag, a BattleTag, a Riot ID — and a chip that
                // looked like a link and opened nothing is the inert control
                // §5.5 is about. An arrow means "this leaves the app"; a
                // document means "this goes on the pasteboard".
                Image(systemName: affordance)
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(InkColor.tertiary)
                    .opacity(isHovering ? 1 : 0.5)
            }
            .padding(.leading, 4)
            .padding(.trailing, 7)
            .padding(.vertical, 3)
            .glassEffect(.clear, in: .rect(cornerRadius: 9))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .animation(motion.standard, value: didCopy)
        .help(helpText)
        .accessibilityLabel(Text("\(serviceName), \(connection.name)"))
        .accessibilityHint(url == nil ? "Copy the name" : "Open in your browser")
        .onDisappear { copyReset?.cancel() }
    }

    private var affordance: String {
        if didCopy { return "checkmark" }
        return url == nil ? "doc.on.doc" : "arrow.up.forward"
    }

    private var helpText: String {
        if didCopy { return "Copied" }
        return url == nil ? "Copy \(serviceName) name" : "Open on \(serviceName)"
    }

    private func act() {
        if let url {
            openURL(url)
            return
        }
        AppModel.copy(connection.name)
        didCopy = true
        // A cancelled task rather than a timer: the chip can be torn down with
        // the card at any point, and a timer outlives what it was drawn for.
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}

/// The people both accounts know.
///
/// The same control the mutual-servers row is, and deliberately: they answer
/// the same shape of question one line apart, and two arrangements for one
/// shape is two places for the chevron to drift.
struct MutualFriendsRow: View {
    var friends: [MutualFriend]

    @Environment(\.motion) private var motion
    @State private var isOpen = false
    @State private var isHovering = false

    private var label: String {
        friends.count == 1 ? "1 Mutual Friend" : "\(friends.count) Mutual Friends"
    }

    var body: some View {
        Button { isOpen = true } label: {
            HStack(spacing: Spacing.base) {
                Image(systemName: "person.crop.circle.badge.checkmark")
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
        .accessibilityHint("Show the people you both know")
        .popover(isPresented: $isOpen, arrowEdge: .trailing) {
            MutualFriendsList(friends: friends)
                .presentationBackground(.clear)
                .environment(\.colorScheme, .dark)
        }
    }
}

/// The friends themselves, each with the server tag they wear.
struct MutualFriendsList: View {
    var friends: [MutualFriend]

    @Environment(AppModel.self) private var model

    private static let rowHeight: CGFloat = 34
    private static let visibleRows = 8
    private static let width: CGFloat = 250
    private static let badgeSide: CGFloat = 11

    private var height: CGFloat {
        min(CGFloat(friends.count), CGFloat(Self.visibleRows)) * Self.rowHeight
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(friends) { friend in
                    Button {
                        // Opens their card in place of this one. The anchor is
                        // zero because a popover row has no rect in the window
                        // root's space — the presenter centres what it cannot
                        // place, which is the honest answer here.
                        model.openProfile(friend.id, anchor: .zero, depth: .full)
                    } label: {
                        row(friend)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, Spacing.tight)
        }
        .frame(width: Self.width, height: height + Spacing.tight * 2)
        .scrollBounceBehavior(.basedOnSize)
        .glassEffect(.clear.tint(Palette.flyoutTint), in: .rect(cornerRadius: Radius.glass))
    }

    private func row(_ friend: MutualFriend) -> some View {
        HStack(spacing: Spacing.base) {
            AvatarView(
                url: friend.avatarHash.flatMap {
                    CDN.avatar(userID: friend.id, hash: $0, side: Metrics.avatarRow)
                },
                monogram: friend.monogram,
                side: Metrics.avatarRow
            )
            Text(friend.name)
                .font(Typeface.rowTitle)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            // The server tag they wear. Drawn here rather than resolved from
            // the store, because the reader is very often in none of the
            // servers a mutual friend is in — see `MutualFriend.tag`.
            if let tag = friend.tag {
                HStack(spacing: 3) {
                    if let guildID = friend.tagGuildID, let hash = friend.tagBadgeHash,
                       let url = CDN.guildTagBadge(guildID: guildID, hash: hash)
                    {
                        RemoteImage(url: url, side: Self.badgeSide) { Color.clear }
                            .frame(width: Self.badgeSide, height: Self.badgeSide)
                    }
                    Text(tag)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .glassEffect(.clear, in: .rect(cornerRadius: 6))
                .accessibilityLabel(Text("Tag \(tag)"))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.snug)
        .frame(height: Self.rowHeight)
        .contentShape(.rect)
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
    /// The card's, not the window's — a themed profile flips it.
    @Environment(\.colorScheme) private var colorScheme
    @State private var isOpen = false
    @State private var isHovering = false

    private static let badgeSide: CGFloat = 12

    /// What the tag rides on.
    ///
    /// **A neutral plate, not a wash of the card**, and that is measured rather
    /// than reasoned: on a profile whose ground is `#e2ca9c` Discord draws the
    /// chip at `#91919b` — a blue-grey with no trace of the gold under it, so it
    /// is an opaque surface token rather than black at some opacity over the
    /// person's colour, which would have kept the hue.
    ///
    /// On a dark card the app's own hover fill is already that plate, so only
    /// the light side needs the constant. One sample, and it is labelled as one.
    private var plate: Color {
        let base = colorScheme == .light ? Color(hex: 0x91_91_9B) : Color.white.opacity(0.16)
        return isHovering || isOpen ? base.opacity(colorScheme == .light ? 0.85 : 0.28) : base
    }

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
                        openGuild: { model.openGuild($0) },
                        enterGuild: { model.enterGuild($0) }
                    )
                    // The card supplies its own ground, so the popover must
                    // supply none — two materials in series read as frost.
                    .presentationBackground(.clear)
                    // A server's card is the app's own surface, not the
                    // person's — see the badge flyout above.
                    .environment(\.colorScheme, .dark)
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
                // **Always white, whatever the card under it is doing.** The
                // tag is a server's mark rather than the person's ink, and it
                // rides a plate chosen to carry white — so it does not follow
                // `colorScheme` the way everything else on a themed card does.
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.leading, tag.badgeURL == nil ? 6 : 4)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .background(plate, in: .capsule)
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
    /// How many rows the flow may take before the rest become a count.
    ///
    /// **Nil on the full profile and two on the card**, which is the reference's
    /// own split and the right one: a card is a summary that opens beside a row
    /// and must not grow taller than the window on somebody holding forty-six
    /// roles, while the full profile is the page you opened *to see them*.
    var maximumRows: Int?
    /// What the flow has to fit in. The card's is a constant it already owns,
    /// so this is handed down rather than measured — a `GeometryReader` here
    /// would cost a pass and publish a number that outlives the card.
    var width: CGFloat = 0
    /// How much room a chip gets.
    ///
    /// **The card and the identity panel are two sizes, not two designs.** A
    /// popover 320 wide holding two rows of chips wants them small; a 360-point
    /// panel under a 26-point name wants the handoff's own capsule — 13-point
    /// label, nine-point dot, a full round. One shape, one number.
    var size: Size = .compact

    enum Size: Equatable {
        case compact
        case comfortable

        var font: Font {
            switch self {
            case .compact: .system(.caption2)
            case .comfortable: .system(.subheadline, weight: .medium)
            }
        }

        var dotSide: CGFloat {
            switch self {
            case .compact: RoleChipFit.dotSide
            case .comfortable: 9
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .compact: RoleChipFit.horizontalPadding
            case .comfortable: 12
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .compact: 3
            case .comfortable: 6
            }
        }
    }

    private var visibleCount: Int {
        guard let maximumRows, width > 0 else { return roles.count }
        return RoleChipFit.visibleCount(
            names: roles.map(\.name),
            total: roles.count,
            width: width,
            rows: maximumRows
        )
    }

    var body: some View {
        let shown = visibleCount
        FlowLayout(spacing: Spacing.tight) {
            ForEach(roles.prefix(shown)) { role in
                chip(role)
            }
            if shown < roles.count {
                RoleOverflowChip(count: roles.count - shown)
            }
        }
    }

    private func chip(_ role: ProfileRole) -> some View {
        // **The enhanced role style, which a boosted server buys.** Discord
        // paints the name with `linear-gradient(to right, c1, c2, c1)` clipped
        // to the glyphs, and gives the dot the same stops. Every field it needs
        // has been on `Role` since the role editor was written and nothing has
        // ever drawn it.
        let stops = role.gradientStops
        return HStack(spacing: RoleChipFit.dotGap) {
            Group {
                if let stops {
                    Circle().fill(LinearGradient(
                        colors: stops, startPoint: .leading, endPoint: .trailing
                    ))
                } else {
                    Circle().fill(role.colorValue.map { Color(hex: $0) } ?? Palette.presenceOffline)
                }
            }
            .frame(width: size.dotSide, height: size.dotSide)

            Text(role.name)
                .font(size.font)
                .foregroundStyle(stops.map {
                    AnyShapeStyle(LinearGradient(
                        colors: $0, startPoint: .leading, endPoint: .trailing
                    ))
                } ?? AnyShapeStyle(InkColor.primary))
                .lineLimit(1)

            // **A role's own mark, and it goes AFTER the name** — the dot says
            // which colour the role is, the mark says which role it is, and
            // Discord orders them that way. A server sets an uploaded icon or a
            // unicode emoji, never both.
            if let url = role.iconURL {
                RemoteImage(url: url, side: size.dotSide + 4) { Color.clear }
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.dotSide + 4, height: size.dotSide + 4)
            } else if let emoji = role.unicodeEmoji {
                Text(emoji).font(size.font)
            }
        }
        .padding(.horizontal, size.horizontalPadding)
        .padding(.vertical, size.verticalPadding)
        // Clear glass, because the ground behind it is the person's own
        // colour and a `.regular` material would blur it into grey.
        .glassEffect(
            .clear.tint(Palette.flyoutTint),
            in: size == .compact ? AnyShape(.rect(cornerRadius: 7)) : AnyShape(.capsule)
        )
    }
}

/// "Private Profile", across the head of the card.
///
/// **A nine-point lock beside the handle is not a label, it is a speck.** That
/// is what this replaced, and a reader who has not been told what it means will
/// never find out — the badge row beside it is full of small marks that all
/// look like decoration. Discord gives the fact a strip of its own above the
/// banner, glyph and words together, and it is the first thing on the card.
///
/// **A label, never a filter.** The route says `private: true` and still hands
/// over the mutual servers the reader can see for themselves; hiding them would
/// be inventing a restriction the server did not make.
struct PrivateProfileBanner: View {
    var body: some View {
        HStack(spacing: Spacing.tight) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
            Text("Private Profile")
                .font(.system(.subheadline, weight: .semibold))
        }
        .foregroundStyle(InkColor.primary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.base)
        // Over the person's own ground rather than a grey plate, so the strip
        // belongs to the card instead of sitting on it.
        .background(.white.opacity(0.10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("This profile is private"))
    }
}

/// The chip that stands for the roles a capped flow could not show.
struct RoleOverflowChip: View {
    var count: Int

    var body: some View {
        Text("+\(count)")
            .font(.system(.caption2, weight: .medium))
            .foregroundStyle(InkColor.secondary)
            // A count that ticks must not change width as it does.
            .monospacedDigit()
            .padding(.horizontal, RoleChipFit.horizontalPadding)
            .padding(.vertical, 3)
            .glassEffect(.clear, in: .rect(cornerRadius: 7))
    }
}

/// How many role chips fit in a capped flow.
///
/// **Solved before the layout runs, not by it.** A `Layout` knows exactly which
/// subviews fit — it has every size and the proposal — and cannot change the
/// one that says `+43`, because the number depends on how many it decided to
/// drop. Doing the arithmetic here means the label and the placement come from
/// the same answer.
///
/// **A pure function over strings and one width**, so every awkward case — one
/// role wider than the card, a cap of zero, an overflow chip that does not
/// itself fit — is checkable without running the app. The measurement it needs
/// is a `CTLine` per role, which is microseconds for the fifty a heavy profile
/// carries and happens when a card opens rather than per frame.
enum RoleChipFit {
    static let dotSide: CGFloat = 8
    static let dotGap: CGFloat = 4
    static let horizontalPadding: CGFloat = 7
    static let spacing = Spacing.tight

    /// The greatest number of chips that leaves room for the `+N` standing for
    /// the rest, inside `rows` rows of `width`.
    static func visibleCount(
        names: [String],
        total: Int,
        width: CGFloat,
        rows: Int
    ) -> Int {
        guard rows > 0, width > 0 else { return 0 }
        let widths = names.map(chipWidth)
        if fits(widths, width: width, rows: rows) { return names.count }

        // Monotonic in `shown` — dropping a chip can never need more rows — so
        // the largest that fits is a binary search rather than a walk.
        var low = 0
        var high = names.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            var candidate = Array(widths.prefix(middle))
            candidate.append(overflowWidth(total - middle))
            if fits(candidate, width: width, rows: rows) {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// Whether these widths wrap into at most `rows` rows.
    private static func fits(_ widths: [CGFloat], width: CGFloat, rows: Int) -> Bool {
        var used = 1
        var x: CGFloat = 0
        for itemWidth in widths {
            if x > 0, x + spacing + itemWidth > width {
                used += 1
                if used > rows { return false }
                x = itemWidth
            } else {
                x += x > 0 ? spacing + itemWidth : itemWidth
            }
        }
        return used <= rows
    }

    static func chipWidth(of name: String) -> CGFloat {
        dotSide + dotGap + measure(name, font: chipFont) + horizontalPadding * 2
    }

    static func overflowWidth(_ count: Int) -> CGFloat {
        measure("+\(count)", font: overflowFont) + horizontalPadding * 2
    }

    /// The faces the two chips are set in.
    ///
    /// `preferredFont(forTextStyle:)` rather than a fixed size, so the split
    /// follows the reader's own text size the way the chips themselves do.
    private static var chipFont: NSFont { .preferredFont(forTextStyle: .caption2) }
    private static var overflowFont: NSFont {
        NSFont.systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .medium
        )
    }

    private static func measure(_ string: String, font: NSFont) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: [.font: font])
        )
        return ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
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
///
/// **A subview wider than the row is re-measured AT the row's width, and the
/// flow never reports wider than it was proposed.** Both halves are one fix and
/// it is the whole of a defect that survived several sessions: a bio containing
/// a long URL, or a sentence of Chinese with no spaces anywhere in it, is one
/// unbreakable segment whose ideal width is six hundred points. Reported
/// upward, that made the profile card's content wider than the card — so the
/// card was laid out around a box it did not have, drifted left, and left a
/// blank strip down its right-hand side. Measured at the width it is actually
/// getting, the same `Text` wraps by character and the row simply becomes
/// taller, which is what a long word in a narrow column is supposed to do.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    struct Cache {
        /// What each subview wants, measured once.
        var ideal: [CGSize]
        /// What each subview gets at `resolvedWidth`. Equal to `ideal` for
        /// everything that fits, which is nearly everything.
        var sizes: [CGSize]
        /// The container width `sizes` was solved for. `nan` until the first
        /// proposal, so the first `sizeThatFits` always resolves.
        var resolvedWidth: CGFloat = .nan
    }

    func makeCache(subviews: Subviews) -> Cache {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        return Cache(ideal: ideal, sizes: ideal)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        cache.sizes = cache.ideal
        cache.resolvedWidth = .nan
    }

    /// Re-measures anything too wide for the container, once per width.
    ///
    /// Guarded on the width having changed *and* on something actually being
    /// too wide, so the common case — every chip narrower than the column —
    /// costs one comparison per subview and no measurement at all.
    private func resolve(_ cache: inout Cache, subviews: Subviews, width: CGFloat) {
        guard cache.resolvedWidth != width else { return }
        cache.resolvedWidth = width
        guard width.isFinite, cache.ideal.contains(where: { $0.width > width }) else {
            cache.sizes = cache.ideal
            return
        }
        cache.sizes = zip(subviews, cache.ideal).map { subview, ideal in
            guard ideal.width > width else { return ideal }
            return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        resolve(&cache, subviews: subviews, width: width)

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
        // **Never wider than the proposal.** A subview that still overflows
        // after being re-measured — a single glyph in a column narrower than
        // one — must cost this flow's *parent* nothing: the child clips, and
        // the column keeps the width it was given.
        if width.isFinite { total.width = min(total.width, width) }
        return total
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        resolve(&cache, subviews: subviews, width: bounds.width)

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
            // Proposed the size it was measured at, which for an over-wide
            // child is the container's width rather than its own ideal — the
            // proposal is what makes it wrap instead of running off the edge.
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
    /// **A parameter, because the two surfaces are two sizes.** The card is 320
    /// wide and the full profile's identity panel is 360, and an avatar that
    /// looked right on the first is small on the second. Every number below —
    /// the cut-out, the dot's corner, the decoration's overhang — is written
    /// against this one, so the hole and the thing it is a hole for cannot
    /// drift apart at either size.
    var side: CGFloat = Metrics.avatarProfile
    /// The rail's own gutter. **A parameter for the same reason the side is
    /// one**: the card's margin is 16 and the identity panel's is 26, and the
    /// hole in the artwork has to land where the avatar does under both.
    var leading: CGFloat = Spacing.margin

    /// The gap the cut-out leaves around the avatar, per edge.
    static let ringGap: CGFloat = 5
    /// And around the presence dot.
    private static let dotGap: CGFloat = 3
    /// How far the dot is pulled inside the avatar's corner.
    private static let dotInset: CGFloat = 2

    /// The mask an artwork block takes so this avatar can sit in it.
    ///
    /// Bottom-leading, like the stack the avatar is placed in, and offset by the
    /// same drop — so the hole is wherever the avatar is, including after a
    /// metric changes.
    static func bannerMask(
        side: CGFloat = Metrics.avatarProfile,
        drop: CGFloat,
        leading: CGFloat = Spacing.margin
    ) -> some View {
        Rectangle()
            .overlay(alignment: .bottomLeading) {
                Circle()
                    .frame(width: side + ringGap * 2, height: side + ringGap * 2)
                    .padding(.leading, leading - ringGap)
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
                .padding(.leading, leading)
                .offset(y: drop)

            PresenceDot(status: profile.status, side: dotSide, hasPlate: false)
                .frame(width: dotSide, height: dotSide)
                .padding(.leading, leading + side - dotSide - Self.dotInset)
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
    static func decorationOverhang(side: CGFloat = Metrics.avatarProfile) -> CGFloat {
        side * (Metrics.decorationScale - 1) / 2
    }

    private var decorationOverhang: CGFloat { Self.decorationOverhang(side: side) }

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
