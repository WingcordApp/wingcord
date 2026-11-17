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
    /// Whose badges — the directory and the levelled cards need it (Phase 8).
    /// Nil on the preview surfaces, which draw the plain row.
    var userID: UserID? = nil
    /// The reader editing their own profile: the row ends in a pencil that
    /// opens "Customize your badges".
    var isEditing = false

    /// Discord's six (`988341`'s `a`), then "+N".
    private static let shownLimit = 6
    @State private var directoryBadge: Int?
    @State private var showsDirectory = false
    @State private var showsCustomizer = false
    /// Which page each flyout is on. **The directory and "Customize your
    /// badges" swap inside the one flyout** rather than one closing to open the
    /// other: the customizer's own flyout hangs off the pencil, which exists
    /// only while editing — so outside the editor "Customize Your Badges" opened
    /// nothing at all (Alex, 2026-10-22), and two popovers trading places in one
    /// turn is unreliable even where both anchors exist.
    @State private var rowPanel = BadgePanel.directory
    @State private var pencilPanel = BadgePanel.customize

    @Environment(AppModel.self) private var model
    /// Whose flyout is up.
    @State private var shown: ProfileBadge.ID?
    /// Where the pointer actually is. **Two latches, because the card sits
    /// directly above the badge**, and reaching it means leaving the mark that
    /// raised it. The plain one-line flyout never needed this because nothing in
    /// it was worth reaching.
    @State private var onBadge: ProfileBadge.ID?
    @State private var onCard: ProfileBadge.ID?
    @State private var dismissal: Task<Void, Never>?
    /// The panel waiting for a badge's card to finish going — see `present`.
    @State private var nextPanel: (() -> Void)?

    private static let side: CGFloat = 18

    var body: some View {
        // Wrapping, because a well-decorated account carries more of these than
        // a 320pt card has room for on one line, and a row that clips silently
        // drops badges the reader has no way to know existed.
        FlowLayout(spacing: Spacing.tight) {
            ForEach(badges.prefix(Self.shownLimit)) { badge in
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
                    .onTapGesture { openDirectory(on: badge, tenure: tenure) }
                    .onHover { inside in
                        if inside, let userID { model.loadBadgeCatalog(of: userID) }
                        pointer(badge.id, onCard: false, inside: inside)
                    }
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
                        // **One card, before the directory answers and after.**
                        // A line only where there's no person behind the row and
                        // nothing else to say.
                        Group {
                            if userID != nil || tenure != nil {
                                BadgeCard(
                                    badge: userID.flatMap { model.catalogBadge(forProfileBadge: badge.id, of: $0) },
                                    tenure: tenure,
                                    premiumSince: premiumSince,
                                    label: badge.label,
                                    iconURL: badge.iconURL
                                )
                                .onHover { pointer(badge.id, onCard: true, inside: $0) }
                            } else {
                                BadgeFlyout(label: badge.label)
                            }
                        }
                        // **The pointer owns this card, so a click does not.**
                        // A transient popover spends the first click outside it
                        // on closing itself, and the click never reaches what
                        // is under it — pressing a badge took two.
                        .interactiveDismissDisabled()
                        .onDisappear {
                            guard let panel = nextPanel else { return }
                            nextPanel = nil
                            panel()
                        }
                        // In the profile's room, glass and ink together.
                        .profileFlyoutAppearance()
                    }
                    .accessibilityLabel(Text(badge.label))
                    .accessibilityAddTraits(tenure == nil && userID == nil ? [] : .isButton)
            }
            if badges.count > Self.shownLimit {
                Button("+\(badges.count - Self.shownLimit)") {
                    guard userID != nil else { return }
                    directoryBadge = nil
                    rowPanel = .directory
                    present { showsDirectory = true }
                }
                .buttonStyle(.plain)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(InkColor.secondary)
                .frame(height: Self.side)
                .accessibilityLabel("\(badges.count - Self.shownLimit) more badges")
            }
            if isEditing, userID != nil {
                Button {
                    pencilPanel = .customize
                    present { showsCustomizer = true }
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: Self.side, height: Self.side)
                }
                .buttonStyle(.plain)
                .foregroundStyle(InkColor.secondary)
                .help("Customize your badges")
                .popover(isPresented: $showsCustomizer, arrowEdge: .bottom) {
                    if let userID { badgePanel($pencilPanel, userID: userID) }
                }
            }
        }
        .popover(isPresented: $showsDirectory, arrowEdge: .bottom) {
            if let userID { badgePanel($rowPanel, userID: userID) }
        }
        // **As the row appears, as Discord's does** (`useEffect` in its badge
        // list), so a card's first hover already has the moving artwork.
        .task(id: userID) {
            if let userID { model.loadBadgeCatalog(of: userID) }
        }
    }

    /// The directory or the customizer, switching in place.
    ///
    /// **In the profile's room**, as a badge's own card is. On the panel and not
    /// the row, whose "+N" and pencil sit on the card's own ground.
    private func badgePanel(_ panel: Binding<BadgePanel>, userID: UserID) -> some View {
        Group {
            switch panel.wrappedValue {
            case .directory:
                BadgeDirectory(userID: userID, initialBadgeID: directoryBadge) {
                    panel.wrappedValue = .customize
                }
            case .customize:
                BadgeCustomizer(userID: userID) {
                    panel.wrappedValue = .directory
                }
            }
        }
        .profileFlyoutAppearance()
    }

    /// Opens the directory on `badge` — or, with no person behind the row,
    /// Nitro's own sheet as before.
    private func openDirectory(on badge: ProfileBadge, tenure: PremiumTenure?) {
        guard let userID else {
            open(tenure)
            return
        }
        model.loadBadgeCatalog(of: userID)
        directoryBadge = BadgeKind.forProfileID(badge.id)?.rawValue
        rowPanel = .directory
        present { showsDirectory = true }
    }

    /// Puts up a panel, waiting for a badge's card to be gone if one is up.
    ///
    /// **A badge cannot be pressed without being hovered**, so its card is always
    /// up when it is pressed — and a popover asked for while another is closing
    /// is not presented, without a word. Pressing a badge took its card away and
    /// opened nothing; only "+N", which has no card, ever opened the directory.
    /// **Opened when the card has gone, not after a guess at how long that
    /// takes**: about 300 milliseconds here.
    private func present(_ panel: @escaping () -> Void) {
        guard shown != nil else {
            panel()
            return
        }
        nextPanel = panel
        dismiss()
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
        // **The directory has the floor.** A badge's flyout is a popover too,
        // and one raised from this window takes down the one already up — so
        // the pointer crossing a badge on its way into the directory closed
        // the directory under it (Alex's screenshot 33). While it, or the
        // customizer, is up, the row's marks raise nothing.
        guard !showsDirectory, !showsCustomizer, nextPanel == nil else {
            if shown != nil { dismiss() }
            return
        }
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
        // A levelled badge wears its current level's mark (Phase 8).
        if let userID, let url = model.catalogBadge(forProfileBadge: badge.id, of: userID)?.mark {
            BadgeArtwork(url: url, side: Self.side)
        } else if let url = badge.iconURL {
            RemoteImage(url: url, side: Self.side) {
                symbol(badge)
            }
        } else {
            symbol(badge)
        }
    }

    private func symbol(_ badge: ProfileBadge) -> some View {
        Image(symbol: badge.symbolName)
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

/// The servers two accounts share, opened from `MutualsRow`.
///
/// Scrolls only once it has to: an account sharing three servers gets a panel
/// three rows tall, not a fixed pane with an empty half. The cap is what stops
/// an account sharing ninety from producing a panel taller than the display.
struct MutualServersList: View {
    var servers: [MutualServer]
    /// A server pressed: go to it — Discord's row takes the reader there and
    /// closes the profile.
    var open: (GuildID) -> Void

    private static let rowHeight: CGFloat = 34
    private static let visibleRows = 8

    private var height: CGFloat {
        min(CGFloat(servers.count), CGFloat(Self.visibleRows)) * Self.rowHeight
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(servers) { server in
                    MutualServerRow(server: server, height: Self.rowHeight) { open(server.id) }
                }
            }
            .padding(.vertical, Spacing.base)
        }
        .scrollIndicators(.never)
        .scrollDisabled(servers.count <= Self.visibleRows)
        .frame(width: 240, height: height + Spacing.base * 2)
    }
}

/// One server in the list, which takes the reader there.
private struct MutualServerRow: View {
    var server: MutualServer
    var height: CGFloat
    var open: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
                    HStack(spacing: Spacing.base) {
                        // An animated icon plays here too, as Discord's does.
                        AnimatedPicture(url: server.iconURL, side: Metrics.avatarRow, contentMode: .fill) {
                            Text(server.monogram)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Ink.secondary)
                                .frame(width: Metrics.avatarRow, height: Metrics.avatarRow)
                                .background(Palette.surfaceRaised)
                        }
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
                    .frame(height: height)
                    .padding(.horizontal, Spacing.snug)
                    .background {
                        if isHovering {
                            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                                .fill(Palette.hoverFill)
                                .padding(.horizontal, Spacing.tight)
                        }
                    }
                    .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .help("Go to \(server.name)")
        .accessibilityLabel(Text(server.name))
        .accessibilityHint(Text("Opens the server"))
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
                        .fill(profileSkeletonLine)
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
                Image(symbol: affordance)
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(InkColor.tertiary)
                    .opacity(isHovering ? 1 : 0.5)
            }
            .padding(.leading, 4)
            .padding(.trailing, 7)
            .padding(.vertical, 3)
            .plainChip(in: .rect(cornerRadius: 9))
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

/// The two mutual counts, on one line, behind a cluster of the faces they name.
///
/// **Discord draws these as one row, not two.** The popout reads
/// "1 Mutual Friend · 8 Mutual Servers" with a stack of small pictures in front
/// of it; this app had them as two stacked rows with a symbol each, which is
/// twice the height for the same two facts and reads as a list of settings.
///
/// **The pictures are the FRIENDS' when there are any, and the servers' when
/// there are not.** That is Discord's rule and it is the right way round: a
/// face somebody recognises is worth more than a server icon they may not, and
/// the two counts are already written out beside it either way.
///
/// Each half keeps its own destination — the row is two buttons, not one — so a
/// reader who wants the servers does not have to go through the friends.
struct MutualsRow: View {
    var servers: [MutualServer]
    var friends: [MutualFriend]
    /// A shared server pressed in the list.
    var openServer: (GuildID) -> Void

    /// How many pictures the cluster shows before it stops.
    ///
    /// Three. The cluster is a hint at who, not a list of them; the list is one
    /// click away and the count beside it is exact.
    private static let clusterLimit = 3
    private static let iconSide: CGFloat = 16
    /// How far each picture sits from the one before it. Less than the side, so
    /// they overlap the way a stack of cards does.
    private static let step: CGFloat = 11
    /// The clearance bitten out of a picture for the one in front of it, so the
    /// two read as separate discs on any ground rather than merging.
    private static let clearance: CGFloat = 1.5

    var body: some View {
        HStack(spacing: Spacing.base) {
            cluster
            if !friends.isEmpty {
                MutualCountButton(
                    label: friends.count == 1
                        ? "1 Mutual Friend"
                        : "\(friends.count) Mutual Friends",
                    hint: "Show the people you both know"
                ) { MutualFriendsList(friends: friends) }
            }
            if !friends.isEmpty && !servers.isEmpty {
                Text("·").foregroundStyle(InkColor.tertiary).font(.system(.caption))
            }
            if !servers.isEmpty {
                MutualCountButton(
                    label: servers.count == 1
                        ? "1 Mutual Server"
                        : "\(servers.count) Mutual Servers",
                    hint: "Show the servers you share"
                ) { MutualServersList(servers: servers, open: openServer) }
            }
            Spacer(minLength: 0)
        }
    }

    /// The overlapping pictures.
    ///
    /// **Laid out by hand rather than by a negative-spacing `HStack`**, because
    /// each disc has to be notched for the one in FRONT of it — which means the
    /// one drawn first is on top, and a stack's z-order is the other way round.
    /// The width is stated so the row beside it lands where it should.
    @ViewBuilder
    private var cluster: some View {
        let count = min(friends.isEmpty ? servers.count : friends.count, Self.clusterLimit)
        if count > 0 {
            ZStack(alignment: .leading) {
                ForEach(0..<count, id: \.self) { index in
                    icon(at: index)
                        .frame(width: Self.iconSide, height: Self.iconSide)
                        // Bitten out for the next one along, which is the only
                        // way two discs read as two on a ground this view does
                        // not know the colour of. A ring drawn in a guessed
                        // colour is the alternative, and it is wrong on every
                        // theme but the one it was picked against.
                        .mask {
                            NotchedDisc(
                                notch: index + 1 < count ? Self.step : nil,
                                clearance: Self.clearance
                            )
                            .fill(style: FillStyle(eoFill: true))
                        }
                        .offset(x: CGFloat(index) * Self.step)
                        .zIndex(Double(-index))
                }
            }
            .frame(
                width: Self.iconSide + CGFloat(count - 1) * Self.step,
                height: Self.iconSide,
                alignment: .leading
            )
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func icon(at index: Int) -> some View {
        if friends.isEmpty {
            let server = servers[index]
            AvatarView(url: server.iconURL, monogram: server.monogram, side: Self.iconSide)
        } else {
            let friend = friends[index]
            AvatarView(
                url: friend.avatarURL(side: Self.iconSide),
                monogram: friend.monogram,
                side: Self.iconSide
            )
        }
    }
}

/// A disc with a bite taken out of its trailing side for the disc in front.
///
/// Filled even-odd: the second ellipse subtracts rather than adds. `nil` is the
/// last picture in a cluster, which has nothing in front of it.
nonisolated private struct NotchedDisc: Shape {
    var notch: CGFloat?
    var clearance: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(ellipseIn: rect)
        guard let notch else { return path }
        path.addEllipse(
            in: rect
                .offsetBy(dx: notch, dy: 0)
                .insetBy(dx: -clearance, dy: -clearance)
        )
        return path
    }
}

/// One half of the mutuals row: a count that opens its own list.
private struct MutualCountButton<List: View>: View {
    var label: String
    var hint: String
    @ViewBuilder var list: () -> List

    @Environment(\.motion) private var motion
    @State private var isOpen = false
    @State private var isHovering = false

    var body: some View {
        Button { isOpen = true } label: {
            Text(label)
                .font(.system(.caption))
                .foregroundStyle(isHovering || isOpen ? InkColor.primary : InkColor.secondary)
                .lineLimit(1)
                // The ground grows OUTWARD from the text rather than the text
                // being padded in and back out again, so the row's baseline is
                // where it would be without it — §4 rule 4, and the same trade
                // the rows this replaces already made.
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
        .accessibilityHint(hint)
        .popover(isPresented: $isOpen, arrowEdge: .trailing) {
            list()
                // The list carries the material; the popover must carry none,
                // or two are stacked and the result reads as frost.
                .presentationBackground(.clear)
                .profileFlyoutAppearance()
        }
    }
}

/// The people two accounts both know, opened from `MutualsRow`. Each carries
/// the server tag they wear.
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
        // No material of its own: in the popover the popover's glass is the
        // body, and in the profile it sits inside a slab that already has a
        // ground — glass on either would be a second surface. §4.9.
    }

    private func row(_ friend: MutualFriend) -> some View {
        HStack(spacing: Spacing.base) {
            AvatarView(
                url: friend.avatarURL(side: Metrics.avatarRow),
                monogram: friend.monogram,
                side: Metrics.avatarRow,
                // **Played here, where a roster of two hundred does not.** The
                // default is off because a long list of GIF faces is dozens of
                // filmstrips resident and dozens of layers rewritten every tick
                // for pictures nobody is looking at. This list is a handful of
                // people, opened deliberately, and it is short enough to scroll
                // in one glance — the same trade the profile card makes.
                animates: true
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
                .plainChip(in: .rect(cornerRadius: 6))
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
/// **The accent, and that is not a colour-rule exception.** The rule is that
/// colour carries meaning; this mark's whole job is to say *this account is not
/// a person*, which is the one thing on a profile a reader must not have to
/// work out. The transcript draws it in the accent too, so the two agree.
struct TagChip: View {
    var text: String

    /// What the chip takes beside a name, so the name can leave it room.
    static func width(_ text: String) -> CGFloat {
        (TimelineLayoutEngine.measure(text, font: AppBadge.font) + 12).rounded(.up)
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Palette.accent, in: .rect(cornerRadius: 5))
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
    @Environment(\.profileWearsTheme) private var profileWearsTheme
    @State private var isOpen = false
    @State private var isHovering = false

    private static let badgeSide: CGFloat = 12

    /// What the tag rides on, **Discord's own rule** (`guildTagPill`, `956495`):
    ///
    /// ```css
    /// .guildTagPill { background: var(--background-mod-subtle);
    ///                 border: 1px solid var(--border-muted) }
    /// .guildTagPill:hover { background-color: var(--background-mod-strong) }
    /// .custom-user-profile-theme.theme-light .guildTagPill { background: var(--opacity-white-24) }
    /// .custom-user-profile-theme.theme-light .guildTagPill:hover { background-color: var(--opacity-white-40) }
    /// ```
    ///
    /// This was an opaque `#91919b` carrying white letters, taken from one sample,
    /// and it was a grey lump on a pale card (Alex's image 52). The dark side is as
    /// it was.
    private var plate: Color {
        let isRaised = isHovering || isOpen
        guard colorScheme == .light else { return .white.opacity(isRaised ? 0.28 : 0.16) }
        return ProfileLightPlate.fill(wearsTheme: profileWearsTheme, isRaised: isRaised)
    }

    /// `--border-muted`: most of what a pill this pale has to separate it from the
    /// card. A fifth on the light side, and next to nothing on the dark.
    private var edge: Color {
        ProfileLightPlate.mod.opacity(colorScheme == .light ? 0.2 : 0.04)
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
                        profile: model.guildProfilePresentation(
                            of: guildID,
                            tag: tag.text,
                            badgeURL: tag.badgeURL
                        ),
                        openGuild: { model.openGuild($0) },
                        openGame: {
                            isOpen = false
                            model.openGameProfile($0)
                        },
                        enterGuild: {
                            isOpen = false
                            model.enterGuild($0)
                        }
                    )
                    // The card supplies its own ground, so the popover must
                    // supply none — two materials in series read as frost.
                    .presentationBackground(.clear)
                    // In the profile's room, as its other flyouts are.
                    .profileFlyoutAppearance()
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
                // The card's own ink, Discord's `text-default`: the plate is
                // see-through now, so what it's on decides what reads on it.
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
        }
        .padding(.leading, tag.badgeURL == nil ? 6 : 4)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .background(plate, in: .capsule)
        .overlay { Capsule().strokeBorder(edge, lineWidth: 1) }
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
    /// The × on each role the reader may take off and the + after them —
    /// nil for everybody without Manage Roles, and on every surface that only
    /// shows.
    var editing: RoleEditing?

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

    /// Whether the reader has opened the flow out.
    ///
    /// **State on the flow, not a parameter.** It is the flow's own control that
    /// sets it, it means nothing to anybody else, and a card that carried it
    /// would have to reset it when the profile changed.
    @State private var isExpanded = false
    @Environment(\.motion) private var motion

    private var visibleCount: Int {
        guard let maximumRows, width > 0, !isExpanded else { return roles.count }
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
                RoleChip(role: role, size: size, remove: removal(of: role))
            }
            // **The count is a button, and so is the arrow that puts it back.**
            // `+8` used to be a label: a card holding forty-six roles said so
            // and offered no way to read them, which is a control that names a
            // thing it will not show you. Discord opens the flow in place and
            // collapses it with a `<` in the same slot.
            if shown < roles.count {
                RoleOverflowChip(count: roles.count - shown) {
                    isExpanded = true
                }
            } else if isExpanded, maximumRows != nil {
                RoleCollapseChip { isExpanded = false }
            }
            if let editing, !editing.addable.isEmpty {
                RoleAddChip(roles: editing.addable, showsLabel: roles.isEmpty, size: size, add: editing.add)
            }
        }
        .animation(motion.standard, value: isExpanded)
        // A new person is a new set of roles, and an expansion the reader made
        // for somebody else is not a decision about them.
        .onChange(of: roles) { isExpanded = false }
    }

    private func removal(of role: ProfileRole) -> (() -> Void)? {
        guard let editing, editing.removable.contains(role.id) else { return nil }
        return { editing.remove(role.id) }
    }
}

/// One role, as a chip.
///
/// **Where the reader may take it off, the dot becomes a × under the
/// pointer** — Discord's own arrangement (`f935efd0`), which keeps a list of
/// forty roles from carrying forty buttons nobody asked to see. VoiceOver gets
/// the same act as a named action, because a control that exists only under a
/// hovering pointer does not exist for it.
struct RoleChip: View {
    var role: ProfileRole
    var size: RoleChipFlow.Size
    /// Takes the role off. Nil where the reader cannot.
    var remove: (() -> Void)?

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        // **The enhanced role style, which a boosted server buys.** Discord
        // paints the name with `linear-gradient(to right, c1, c2, c1)` clipped
        // to the glyphs, and gives the dot the same stops. Every field it needs
        // has been on `Role` since the role editor was written and nothing has
        // ever drawn it.
        let stops = role.gradientStops
        let showsRemove = remove != nil && isHovering
        HStack(spacing: RoleChipFit.dotGap) {
            ZStack {
                Group {
                    if let stops {
                        Circle().fill(LinearGradient(
                            colors: stops, startPoint: .leading, endPoint: .trailing
                        ))
                    } else {
                        Circle().fill(role.colorValue.map { Color(hex: $0) } ?? Palette.presenceOffline)
                    }
                }
                .opacity(showsRemove ? 0 : 1)
                if showsRemove, let remove {
                    Button(action: remove) {
                        Image(systemName: "xmark")
                            .font(.system(size: size.dotSide, weight: .heavy))
                            .foregroundStyle(InkColor.primary)
                    }
                    .buttonStyle(.plain)
                    // The glyph is the dot's size; the target is not.
                    .contentShape(.rect.inset(by: -4))
                    .help("Remove Role")
                    .transition(.opacity)
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
        // A plain chip: a role is content, never glass. See `PlainChipBackground`.
        .modifier(RoleChipGround(size: size))
        .onHover { hovering in
            guard remove != nil, isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if let remove {
                Button("Remove role \(role.name)", action: remove)
            }
        }
    }
}

/// The + after somebody's roles — Discord's "Add role" (`$` in `f935efd0`),
/// spelled out when they hold none, opening the roles the reader could give.
struct RoleAddChip: View {
    var roles: [ProfileRole]
    var showsLabel: Bool
    var size: RoleChipFlow.Size
    var add: (RoleID) -> Void

    @State private var isPicking = false

    var body: some View {
        Button { isPicking = true } label: {
            HStack(spacing: RoleChipFit.dotGap) {
                Image(systemName: "plus")
                    .font(.system(size: size.dotSide + 1, weight: .bold))
                if showsLabel {
                    Text("Add role").font(size.font)
                }
            }
            .foregroundStyle(InkColor.secondary)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .modifier(RoleChipGround(size: size))
        .help("Add role")
        .accessibilityLabel(Text("Add role"))
        .popover(isPresented: $isPicking, arrowEdge: .bottom) {
            RolePickerList(roles: roles) { roleID in
                isPicking = false
                add(roleID)
            }
            .profileFlyoutAppearance()
        }
    }
}

/// Discord's role picker (`465738`): a field that filters as it is typed,
/// over the roles on offer, each with its dot. Picking one is the act.
struct RolePickerList: View {
    var roles: [ProfileRole]
    var pick: (RoleID) -> Void

    @State private var query = ""
    @FocusState private var isFocused: Bool

    private var matches: [ProfileRole] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return roles }
        return roles.filter { $0.name.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Role", text: $query)
                .textFieldStyle(.plain)
                .font(.system(.subheadline))
                .focused($isFocused)
                .onSubmit {
                    if let first = matches.first { pick(first.id) }
                }
                .padding(.horizontal, Spacing.snug)
                .frame(height: FlyoutMetrics.rowHeight)
                .accessibilityLabel(Text("Add Role"))
            FlyoutDivider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(matches) { role in
                        FlyoutRow(
                            title: role.name,
                            dotColor: role.colorValue.map { Color(hex: $0) } ?? Palette.presenceOffline
                        ) { pick(role.id) }
                    }
                }
                .padding(.bottom, Spacing.tight)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: FlyoutMetrics.listHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Spacing.tight)
        .frame(width: 240)
        .onAppear { isFocused = true }
    }
}

/// "Private Profile", in the card's top-left corner, across from its ⋯.
///
/// **A label, never a filter.** The route says `private: true` and still hands
/// over the mutual servers the reader can see for themselves; hiding them would
/// be inventing a restriction the server did not make.
///
/// **Clear glass with no press response**: the material of the ⋯ it sits across
/// from, without the part that says it can be pressed. It used to be a strip of
/// its own above the banner, which pushed the whole card down (Alex, 2026-11-04).
struct PrivateProfilePill: View {
    /// The ⋯'s 30 on the card and the column. A little more on the full profile.
    var height: CGFloat = 30

    private var isLarge: Bool { height > 30 }

    var body: some View {
        HStack(spacing: Spacing.tight + Spacing.hair) {
            Image(systemName: "lock.fill")
                .font(.system(size: isLarge ? 12 : 11, weight: .semibold))
            Text("Private Profile")
                .font(.system(size: isLarge ? 13 : 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(InkColor.primary)
        .padding(.horizontal, isLarge ? 14 : 12)
        .frame(height: height)
        .fixedSize()
        .chromeOverMedia()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("This profile is private"))
    }
}

/// Discord's warning when the profile route refused (`559506`): "Unable to
/// load parts of profile" — and, on the full profile, its Retry.
struct PartialProfileNotice: View {
    /// Asks again. Nil on the card, which offers none.
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.presenceIdle)
                .accessibilityHidden(true)
            Text("Unable to load parts of profile")
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(InkColor.primary)
            Spacer(minLength: Spacing.base)
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
        .background(Palette.presenceIdle.opacity(0.12), in: .rect(cornerRadius: Radius.row, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .strokeBorder(Palette.presenceIdle.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The chip that stands for the roles a capped flow could not show.
struct RoleOverflowChip: View {
    var count: Int
    /// What pressing it does. **Nil where there is nothing to open** — the
    /// chip is also drawn on surfaces that have no room to expand into, and a
    /// pressable one there would be the inert control §5.5 forbids.
    var expand: (() -> Void)?

    var body: some View {
        let label = Text("+\(count)")
            .font(.system(.caption2, weight: .medium))
            .foregroundStyle(InkColor.secondary)
            // A count that ticks must not change width as it does.
            .monospacedDigit()

        Group {
            if let expand {
                Button(action: expand) { label.contentShape(.rect) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Show \(count) more roles"))
            } else {
                label
            }
        }
        .padding(.horizontal, RoleChipFit.horizontalPadding)
        .padding(.vertical, 3)
        .plainChip(in: .rect(cornerRadius: 7))
    }
}

/// The chip that puts an opened role flow back.
///
/// **A `<` in the slot the `+N` came out of**, which is Discord's own
/// arrangement and the reason it is a separate type rather than the overflow
/// chip with a flag: the two say opposite things and share only a shape.
struct RoleCollapseChip: View {
    var collapse: () -> Void

    var body: some View {
        Button(action: collapse) {
            Image(systemName: "chevron.left")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(InkColor.secondary)
                // The same box a `+N` occupies, so the row does not reflow as
                // the last chip swaps for this one.
                .frame(minWidth: 14)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, RoleChipFit.horizontalPadding)
        .padding(.vertical, 3)
        .plainChip(in: .rect(cornerRadius: 7))
        .accessibilityLabel(Text("Show fewer roles"))
    }
}

/// A role chip's ground: a rounded rect at the compact size, a capsule
/// otherwise. One modifier rather than a branch at each call site, so a chip
/// that changes size does not change identity.
private struct RoleChipGround: ViewModifier {
    var size: RoleChipFlow.Size

    func body(content: Content) -> some View {
        if size == .compact {
            content.plainChip(in: .rect(cornerRadius: 7))
        } else {
            content.plainChip(in: .capsule)
        }
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
            if x > bounds.minX {
                if x + spacing + size.width > bounds.maxX {
                    x = bounds.minX
                    y += rowHeight + spacing
                    rowHeight = 0
                } else {
                    x += spacing
                }
            }
            // Proposed the size it was measured at, which for an over-wide
            // child is the container's width rather than its own ideal — the
            // proposal is what makes it wrap instead of running off the edge.
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width
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
                .mask {
                    // No hole where there is no dot: an app that never
                    // connects shows its whole face.
                    if profile.status == .unknown { Rectangle() } else { dotMask }
                }
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
            decorationURL: profile.decorationURL,
            // **Both profile surfaces, always.** This is the one face the reader
            // opened a card to look at; the roster's hover gate is about a
            // column of them, and there is no column here.
            animates: true
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

/// Relative fills on a profile card, resolved by the card's own scheme — light
/// on a dark card, shade on a light one. They were plain white, which was
/// invisible on every light-themed profile before an unthemed card could be
/// light too.
private let profileSkeletonLine = Color.relative(dark: 0.08, light: 0.07)

/// The badge flyout's two pages.
private enum BadgePanel {
    case directory
    case customize
}
