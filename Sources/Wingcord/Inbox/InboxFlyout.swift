import SwiftUI
import WingcordCore

/// Everything waiting for the reader, behind one control.
///
/// **A popover off a real toolbar item**, which `INVARIANTS.md` §1 makes the one
/// place in this app a presentation may be attached inline: the item is chrome,
/// there is one of it, and it is not a row in a list. It is also the only way a
/// panel can point at the control that opened it.
///
/// Being a presentation is what lets the surfaces inside stay glass. A popover
/// paints its own backdrop behind the whole of its content — §1 again — and
/// that backdrop is the ground everything here lenses. The corollary is the
/// constraint that shapes the layout: **nothing may leave a transparent
/// margin**, because a hole in the content is where that backdrop stops reading
/// as a design choice and starts reading as a grey panel. The content fills the
/// popover edge to edge and the insets live *inside* it.
///
/// **The tab strip is `SegmentedPicker`, not Discord's underlined bar.** Discord
/// draws five labels with a moving rule beneath them; this app's vocabulary for
/// "these segments switch views" is the system's own capsule control, which
/// Clock and Podcasts use and which brings its own material and keyboard story.
/// Replicating the underline would be a travelling rule somebody has to animate
/// and a selection colour somebody has to pick — §1.
struct InboxFlyout: View {
    @Environment(AppModel.self) private var model
    @State private var presentation = PresentationRevision.shared
    /// Moves when a picture a card in here draws has landed.
    ///
    /// **Local, not `PresentationRevision`.** An avatar arriving in the flyout
    /// is a repaint of this panel; the app-wide counter would discard every
    /// laid-out row in every surface for it. See `PinnedMessagesPane`.
    @State private var artworkGeneration: UInt64 = 0

    /// Wide enough for the tab strip, which is what actually sets this.
    ///
    /// **Measured against the control, not chosen.** `SegmentedPicker` sizes each
    /// segment as its rendered label plus a fixed 40 points of air; the five
    /// titles here come to roughly 310 points of text, so the strip wants about
    /// 510 and the panel has to clear that plus its own 32 points of margin.
    /// At 520 it overflowed and the strip drew flush to both edges, which is
    /// what shipped.
    ///
    /// It comfortably clears the other constraint too: `Metrics.embedMaxWidth`
    /// is 432, and a card laid out narrower squeezes every embed in the list —
    /// which is most of what a bot posts and most of what an inbox holds.
    static let width: CGFloat = 580
    /// See the note on the frame below.
    private static let minimumHeight: CGFloat = 360
    private static let maximumHeight: CGFloat = 560
    /// What a `MessageCard` is laid out against: the panel, less the list's own
    /// margins and the group's.
    static var cardWidth: CGFloat { width - Spacing.snug * 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // The strip is hidden behind the friend-requests pane rather than
            // disabled: none of the five tabs is what is on screen, and a
            // segmented control with no live selection is a control that lies.
            if !model.inbox.isShowingFriendRequests {
                SegmentedPicker(
                    options: InboxTab.displayOrder.map { .init($0, $0.title) },
                    selection: Binding(
                        get: { model.inbox.tab },
                        set: { model.selectInboxTab($0) }
                    )
                )
                .padding(.horizontal, Spacing.margin)
                .padding(.bottom, Spacing.snug)
            }
            Divider().opacity(0.5)
            content
        }
        .frame(width: Self.width)
        // **A minimum, and it is what stops the popover opening as a sliver.**
        // AppKit sizes a popover from its content's *first* layout, and on that
        // pass nothing has been fetched — the panel is a header over a spinner.
        // The window is made that size and then grows as rows land, which reads
        // as the flyout being broken for its first second. `alignment: .top`
        // because a frame with a minimum taller than its content centres that
        // content, which would float the header in the middle of the box.
        .frame(
            minHeight: Self.minimumHeight,
            maxHeight: Self.maximumHeight,
            alignment: .top
        )
        // The popover supplies the material; a second one here would be glass
        // on glass — §4 rule 2.
        .presentationBackground(.clear)
        // **No animation on this container, and that is deliberate.** This
        // subtree sits on the popover's own material, and `INVARIANTS.md` §1.5
        // is explicit: a material inside a subtree an animation rasterises
        // offscreen has no backdrop to sample and paints an opaque black
        // rectangle for the length of the animation. `VoiceTile` shipped exactly
        // that bug with one `.animation` on the whole tile. It is also why the
        // groups below take a flat `Palette.groupedFill` rather than
        // `.structuralSurface()`.
        //
        // So the animations are scoped to the layers that actually read a value
        // and carry no material: the tab strip animates itself (it is
        // `NSSegmentedControl`), and the hover fills are animated on the rows.
        // Swapping the list is instant, which is the honest behaviour for a list
        // being replaced rather than moved.
    }

    // MARK: The bar

    private var header: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: model.inbox.isShowingFriendRequests ? "person.2" : "tray")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Ink.secondary)
                // The glyph is decoration beside a title that already says it.
                .accessibilityHidden(true)
            Text(model.inbox.isShowingFriendRequests ? "Friend Requests" : "Inbox")
                .font(.system(.headline))
                .foregroundStyle(Ink.primary)

            Spacer(minLength: Spacing.base)

            // **Only on Unreads, because it is the only list it can act on.**
            // `ack-bulk` moves read cursors; a mention, a bookmark or a queued
            // message has no read cursor to move, so offering it there would be
            // a control that does nothing.
            if !model.inbox.isShowingFriendRequests, model.inbox.tab == .unreads {
                Button {
                    model.markAllInboxRead()
                } label: {
                    Label("Mark All As Read", systemImage: "checkmark.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
                .help("Mark everything as read")
                .disabled(!model.canMarkAllInboxRead)
            }

            friendRequestsButton
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.top, Spacing.margin)
        .padding(.bottom, Spacing.snug)
    }

    /// The control that swaps the whole panel for the friend requests, and
    /// swaps it back.
    ///
    /// **One control, two states**, for the reason the call button is one: going
    /// to the requests and coming back are one bit resolved two ways, and a
    /// second button would leave a hole in the bar in whichever state is not
    /// showing.
    private var friendRequestsButton: some View {
        let showing = model.inbox.isShowingFriendRequests
        let count = model.incomingFriendRequestCount
        return Button {
            model.showFriendRequests(!showing)
        } label: {
            Label(
                showing ? "Back to the Inbox" : "View Friend Requests",
                systemImage: showing ? "chevron.backward" : "person.crop.circle.badge.plus"
            )
            .labelStyle(.iconOnly)
            // The count rides the control rather than sitting beside it: a
            // badge in the bar with no control under it is a number nobody can
            // act on.
            .overlay(alignment: .topTrailing) {
                if !showing, count > 0 {
                    CountBadge(count: count)
                        .offset(x: 7, y: -7)
                }
            }
        }
        .buttonStyle(.glass)
        .help(showing ? "Back to the inbox" : "View friend requests")
        // Spoken as one thing. Without this VoiceOver reads the label and then
        // the badge as two unrelated nodes.
        .accessibilityLabel(
            showing
                ? "Back to the inbox"
                : count > 0
                    ? "View friend requests, \(count) waiting"
                    : "View friend requests"
        )
    }

    // MARK: What is under it

    @ViewBuilder
    private var content: some View {
        if model.inbox.isShowingFriendRequests {
            // **No transition**, for the reason the container carries no
            // animation: an opacity transition is precisely the offscreen pass
            // that turns the list's materials black on the way out.
            FriendRequestsPane()
        } else {
            list
        }
    }

    @ViewBuilder
    private var list: some View {
        let tab = model.inbox.tab
        let groups = model.inboxGroups(width: Self.cardWidth)

        if let failure = model.inboxFailure(tab) {
            InboxNotice(
                symbolName: "exclamationmark.triangle",
                title: "That didn't load",
                message: failure,
                retry: { model.retryInboxTab(tab) }
            )
        } else if model.isInboxLoading(tab) {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.isEmpty {
            VStack(spacing: 0) {
                InboxEmptyState(tab: tab)
                limitBanner(tab)
            }
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: Spacing.snug) {
                        ForEach(groups) { group in
                            InboxGroupCard(
                                group: group,
                                tab: tab,
                                presentationRevision: presentation.value,
                                artworkGeneration: artworkGeneration
                            )
                        }
                    }
                    .padding(Spacing.snug)
                }
                .scrollBounceBehavior(.basedOnSize)
                .softScrollEdgesVertical()
                // **Under the scroll view, not inside it.** A cap is a fact
                // about the account rather than the last row of the list, and
                // one that scrolled away would be invisible exactly when the
                // list is long enough for somebody to wonder why they cannot
                // add another.
                limitBanner(tab)
            }
            // **The painters only peek**, so the pictures these cards draw have
            // to be asked for by somebody, and nothing else in the app asks for
            // an inbox row's avatar or embed artwork. One pass per set of
            // groups, behind the scroll gate like every other optional fetch.
            .task(id: groups.map(\.id)) {
                await prefetch(groups)
            }
        }
    }

    /// The line at the foot of a tab whose cap the account has reached.
    ///
    /// **Drawn only when the limit has actually been measured** — never as a
    /// standing advertisement. Discord shows free accounts a promotional
    /// version of this beside a single saved bookmark; that is a sales line
    /// rather than a fact about their account, and this app does not carry one.
    /// What it says instead is what is true: this list is full.
    @ViewBuilder
    private func limitBanner(_ tab: InboxTab) -> some View {
        if let notice = model.inboxLimitNotice(for: tab) {
            HStack(alignment: .top, spacing: Spacing.base) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.tertiary)
                    .accessibilityHidden(true)
                Text(notice)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.margin)
            .padding(.vertical, Spacing.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                Divider().opacity(0.4)
            }
        }
    }

    private func prefetch(_ groups: [InboxGroup]) async {
        let rows = groups.flatMap { $0.rows.compactMap(\.card) }.flatMap(\.messageRows)
        let requests = TimelineImageRequests.requests(
            for: rows,
            scale: 2,
            loadsArtwork: AppSettings.shared.loadsImagesAutomatically,
            playsAnimatedEmoji: AnimationClock.playsAnimatedEmoji
        )
        guard !requests.isEmpty else { return }
        await ScrollWorkGate.waitUntilInactive()
        guard !Task.isCancelled else { return }
        await withTaskGroup(of: Void.self) { group in
            for request in requests {
                group.addTask {
                    switch request.source {
                    case .still(let bucket):
                        _ = await ImageStore.shared.image(for: request.key, bucket: bucket)
                    case .film:
                        _ = await AnimatedImageStore.shared.image(
                            for: AnimatedImageStore.Key(
                                url: request.key.url,
                                maximumPixelSize: request.key.maximumPixelSize
                            )
                        )
                    }
                }
            }
        }
        guard !Task.isCancelled else { return }
        // One nudge for the batch: the cards peek the caches on their next
        // draw, and a repaint per picture would repaint the panel per avatar.
        artworkGeneration &+= 1
    }
}

/// A red count, as the rail and the channel list draw one.
struct CountBadge: View {
    var count: Int

    var body: some View {
        Text(count > 99 ? "99+" : String(count))
            .font(.system(size: 10, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.tight + 1)
            .padding(.vertical, 1)
            .frame(minWidth: 16)
            .background(Palette.unreadBadge, in: .capsule)
            // The number is spoken by whatever it is attached to.
            .accessibilityHidden(true)
    }
}

/// A centred notice that replaces the list — a refusal, with a way to try
/// again.
struct InboxNotice: View {
    var symbolName: String
    var title: String
    var message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: symbolName)
                .font(.system(size: 26))
                .foregroundStyle(Ink.tertiary)
            Text(title)
                .font(.system(.headline))
                .foregroundStyle(Ink.primary)
            Text(message)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(.glass)
                    .padding(.top, Spacing.tight)
            }
        }
        .padding(.horizontal, Spacing.group)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
