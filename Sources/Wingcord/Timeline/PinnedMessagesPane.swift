import SwiftUI
import WingcordCore

/// What a channel has pinned.
///
/// **A popover off a real toolbar item**, which is the one place in this app a
/// presentation may be attached inline: the item is chrome, there is one of it,
/// and it is not a row in a list. A control in a hand-laid band would sample the
/// transcript behind it rather than the toolbar's material — `INVARIANTS.md` §1.
///
/// **Each pin is the real message, drawn by the transcript's own painter.** It
/// used to be a name, a time and one line of `excerpt(of:)` — which is a
/// sentence for a message made of words and *nothing at all* for a forward, an
/// embed, a video, a poll or a file. Those are most of what people pin, so the
/// pane was blank exactly where it mattered. `MessageCard` is the transcript at
/// 300 points wide; anything the channel can draw, this draws.
///
/// Each row still goes somewhere: clicking one scrolls the transcript to it and
/// lights it, which is the whole reason anybody opens this.
struct PinnedMessagesPane: View {
    var channelID: ChannelID
    /// The inspector column's width when the pane is one of its tabs
    /// (REDESIGN.md R11); nil for the popover off the header's pin.
    var columnWidth: CGFloat? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var presentation = PresentationRevision.shared
    /// Moves when a picture a card draws has landed. Local, because a pinned
    /// avatar arriving is a repaint of this pane and not of every laid-out row
    /// in the app — which is what `PresentationRevision` would be.
    @State private var artworkGeneration: UInt64 = 0

    /// Wider than a hover card, because it holds real messages: an embed is
    /// laid out against `Metrics.embedMaxWidth` and a pane narrower than that
    /// squeezes every card in the channel.
    private static let width: CGFloat = 400
    private static let maximumHeight: CGFloat = 520
    /// See the note on the frame below.
    private static let minimumHeight: CGFloat = 260
    /// What a card is laid out against: the pane less the list's own margins.
    static var cardWidth: CGFloat { cardWidth(in: width) }

    static func cardWidth(in paneWidth: CGFloat) -> CGFloat {
        paneWidth - Spacing.snug * 2 - Spacing.base * 2
    }

    private var paneWidth: CGFloat { columnWidth ?? Self.width }

    var body: some View {
        // Read at the top rather than inside the branches, so an arrival while
        // the pane is open invalidates this body — a read that happens only on
        // one branch is a dependency only that branch registers.
        let pinned = model.pinnedMessages[channelID]
        let isLoading = model.pinsLoading.contains(channelID)
        let failure = model.pinsFailure[channelID]
        let cards = model.pinnedCards(in: channelID, width: Self.cardWidth(in: paneWidth))

        VStack(alignment: .leading, spacing: 0) {
            // A column's tab already says what it is.
            if columnWidth == nil {
                Text("Pinned messages")
                    .font(.system(.headline))
                    .foregroundStyle(Ink.primary)
                    .padding(.horizontal, Spacing.margin)
                    .padding(.top, Spacing.margin)
                    .padding(.bottom, Spacing.snug)
            }

            if let failure {
                notice(failure, symbolName: "exclamationmark.triangle")
            } else if let pinned, pinned.isEmpty {
                notice(
                    "Nothing is pinned here yet. Pin a message from its menu and it will show up.",
                    symbolName: "pin.slash"
                )
            } else if pinned != nil {
                list(cards)
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.group)
            }
        }
        .frame(width: paneWidth)
        // **A minimum, and it is what stops the popover opening as a sliver.**
        // AppKit sizes a popover from its content's *first* layout, and on that
        // pass the pins have not been fetched — the pane is a title over a
        // spinner, about forty points tall. The window is made that size and
        // then grows as the rows land, which reads as the flyout being broken
        // for the first second of its life. Reserving the height up front means
        // the first measurement is already the right one.
        // **`alignment: .top`, or the reservation centres what it
        // reserved for.** A frame with a minimum taller than its content
        // centres that content by default, so the title and its notice
        // floated in the middle of the box with empty space above and
        // below. The floor exists to stop the popover opening as a
        // sliver; the alignment is what keeps the content where a
        // header belongs.
        .frame(
            minHeight: columnWidth == nil ? Self.minimumHeight : nil,
            maxHeight: columnWidth == nil ? Self.maximumHeight : .infinity,
            alignment: .top
        )
        .animation(motion.standard, value: cards.count)
        // The popover supplies the material; this must not add a second.
        .presentationBackground(.clear)
        // **The painter only peeks**, so the pictures these cards draw have to
        // be asked for by somebody — and nothing else in the app asks for a
        // pinned message's attachments. One pass per set of cards, behind the
        // scroll gate like every other optional fetch.
        .task(id: cards.map(\.id)) {
            await prefetch(cards)
        }
        // A column asks for the pins itself; the popover's button already did.
        .task(id: columnWidth == nil ? nil : channelID) {
            if columnWidth != nil { model.sessionController.loadPins(in: channelID) }
        }
    }

    private func notice(_ text: String, symbolName: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            Image(symbol: symbolName)
                .font(.system(size: 13))
                .foregroundStyle(Ink.tertiary)
            Text(text)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.margin)
    }

    private func list(_ cards: [MessageCard]) -> some View {
        ScrollView {
            LazyVStack(spacing: Spacing.tight) {
                ForEach(cards) { card in
                    PinnedRow(
                        card: card,
                        cardWidth: Self.cardWidth(in: paneWidth),
                        presentationRevision: presentation.value,
                        artworkGeneration: artworkGeneration,
                        canUnpin: model.actions(for: card.id, in: channelID).contains(.unpin),
                        open: {
                            model.openPinsChannelID = nil
                            model.sessionController.jumpToMessage(card.id, in: channelID)
                        },
                        unpin: { model.togglePin(of: card.id, in: channelID) }
                    )
                }
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.bottom, Spacing.snug)
        }
        .scrollBounceBehavior(.basedOnSize)
        .softScrollEdgesVertical()
    }

    private func prefetch(_ cards: [MessageCard]) async {
        // One nudge for the batch: the cards peek the caches on their next
        // draw, and a repaint per picture would repaint the pane per avatar.
        if await MessageCardArtwork.prefetch(cards) { artworkGeneration &+= 1 }
    }
}

/// One pinned message, and the two things it can do.
private struct PinnedRow: View {
    var card: MessageCard
    var cardWidth: CGFloat
    var presentationRevision: UInt64
    var artworkGeneration: UInt64
    var canUnpin: Bool
    var open: () -> Void
    var unpin: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            MessageCardCanvas(
                card: card,
                presentationRevision: presentationRevision,
                artworkGeneration: artworkGeneration
            )
                // The height is the layout's, so the row is placed once. A
                // measured height here would cost a second layout pass per
                // card and would settle visibly on the first frame.
                .frame(width: cardWidth, height: card.height)
                .padding(Spacing.base)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .fill(isHovered ? Palette.hoverFill : .clear)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            // Revealed on hover, and it is a plain control rather than a glass
            // one: §4 rule 4 — a hover-revealed glass element inside a container
            // is drawn by the container regardless of the opacity on the wrapper
            // holding it, so every row's would appear at once.
            if canUnpin, isHovered {
                Button(action: unpin) {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.black.opacity(0.45)))
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .padding(Spacing.tight)
                .help("Unpin")
                .accessibilityLabel(Text("Unpin message"))
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            guard hovering != isHovered else { return }
            isHovered = hovering
        }
        .animation(motion.fadeQuick, value: isHovered)
        // One node with a plain label, exactly as a transcript row carries —
        // the canvas below draws no views for the platform to walk.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(card.accessibilityLabel))
    }
}
