import AppKit
import SwiftUI
import WingcordCore

/// Who reacted, in a flyout over the chip the pointer rests on — Discord's
/// reaction tooltip (`831688`'s `ex`).
///
/// **A popover, anchored to the chip**, as every flyout in this app is: the
/// system's glass and its arrow, with nothing painted on the content (§4.9).
/// The transcript is a drawn canvas that can host nothing, so the canvas
/// publishes the chip's frame in the clip view's space and this overlay, laid
/// over the same space, hangs the popover off it.
///
/// **It waits before it asks.** Discord's dwell: half a second over a plain
/// chip, three quarters over a super one, whose effect plays first. A pointer
/// crossing a row of chips asks nobody anything, and one that settles asks once.
///
/// **It can be reached, and it answers a click.** The card stays while the
/// pointer is on it — a moment's grace covers the gap between chip and card —
/// and the emoji and the sentence are one control that opens the list of
/// everybody who reacted, at this reaction: Discord's `x()`, which its
/// sentence's "N others" link and the rest of its card share.
///
/// **It never takes the chip's click** — see `ReactionFlyoutHost`.
struct ReactionTooltipOverlay: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @State private var shown: Shown?
    @State private var isOnCard = false
    @State private var dismissal: Task<Void, Never>?

    private struct Shown: Equatable {
        var hover: ReactionHover
        var content: ReactionTooltipContent
    }

    /// How long the pointer may be on neither the chip nor the card before
    /// the card goes. The badge flyout's grace, for its reason: the card is a
    /// window of its own, with an arrow's gap between it and the chip.
    private static let grace: Duration = .milliseconds(180)

    var body: some View {
        // Read first, so the dependency is registered whether or not there is
        // anything to show.
        let hover = model.reactionHover
        // The shown chip's count, so a change while the card is up — the
        // reader clicking the chip under it — rewrites the sentence.
        let count = shown.flatMap { count(of: $0.hover) }
        ReactionFlyoutHost(
            anchor: shown?.hover.chipFrame,
            root: shown.map { shown in
                ReactionFlyoutRoot(
                    model: model,
                    emoji: shown.hover.emoji,
                    content: shown.content,
                    hovering: { pointer(onCard: $0) },
                    openList: { openList(for: shown.hover) }
                )
            }
        )
        .allowsHitTesting(false)
        .task(id: hover) { await follow(hover) }
        .task(id: count) { await recount(count) }
        // A popover is a window of the app's own and outlives the app losing
        // focus — where the pointer can no longer be seen leaving the chip.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            close()
        }
    }

    // MARK: Following the pointer

    private func follow(_ hover: ReactionHover?) async {
        guard let hover else {
            // Off the chip: the card goes, unless the pointer is on its way
            // onto it.
            scheduleDismissal()
            return
        }
        dismissal?.cancel()
        if let shown, shown.hover.isSameChip(as: hover) {
            // Back on the chip the card is about, or the chip moved under it.
            if shown.hover != hover { self.shown?.hover = hover }
            return
        }
        // Another chip. The card for the last one goes now — `INVARIANTS.md`
        // §5: nothing outlives what it names — and this one waits its turn.
        if shown != nil { shown = nil }
        try? await Task.sleep(for: .milliseconds(hover.kind == .burst ? 750 : 500))
        guard !Task.isCancelled,
              let content = await model.reactionTooltip(for: hover, in: channelID),
              !Task.isCancelled
        else { return }
        shown = Shown(hover: hover, content: content)
    }

    private func pointer(onCard: Bool) {
        isOnCard = onCard
        if onCard {
            dismissal?.cancel()
        } else {
            scheduleDismissal()
        }
    }

    private func scheduleDismissal() {
        dismissal?.cancel()
        guard shown != nil else { return }
        dismissal = Task {
            try? await Task.sleep(for: Self.grace)
            guard !Task.isCancelled, !isOnCard else { return }
            if let hover = model.reactionHover, let shown, shown.hover.isSameChip(as: hover) { return }
            shown = nil
        }
    }

    private func close() {
        dismissal?.cancel()
        isOnCard = false
        shown = nil
    }

    // MARK: What it says

    private func count(of hover: ReactionHover) -> Int? {
        model.message(hover.messageID, in: channelID)?.reactions
            .first { $0.emoji.isSameReaction(as: hover.emoji) }?
            .count(of: hover.kind)
    }

    /// Rewrites the sentence for a count that moved, and takes the card away
    /// from a reaction that has gone.
    private func recount(_ count: Int?) async {
        guard let current = shown else { return }
        guard count != nil,
              let content = await model.reactionTooltip(for: current.hover, in: channelID)
        else {
            close()
            return
        }
        guard shown?.hover.isSameChip(as: current.hover) == true, shown?.content != content else { return }
        shown?.content = content
    }

    private func openList(for hover: ReactionHover) {
        close()
        model.openReactionsList(
            for: hover.messageID,
            in: channelID,
            selection: ReactionListing.Key(emoji: hover.emoji.reactionKey, kind: hover.kind)
        )
    }
}

private extension ReactionHover {
    /// The same chip, wherever it is drawn now.
    func isSameChip(as other: ReactionHover) -> Bool {
        messageID == other.messageID && kind == other.kind && emoji.isSameReaction(as: other.emoji)
    }
}

/// The popover the drawn transcript cannot host: one `NSPopover`, shown beside
/// a rect in this view's space.
///
/// **AppKit's popover, not SwiftUI's `.popover`, for its behaviour.** SwiftUI's
/// is transient, and a transient popover spends the next click anywhere
/// outside it on its own dismissal — `TenureBadgeFlyout` names the same trade.
/// Here that click lands on the chip under the card, which is the one thing a
/// reader resting on a reaction is about to press. `.applicationDefined` leaves
/// every click where it falls; the overlay decides when the card goes.
///
/// **And it hands the keyboard back.** A popover can make its own window key as
/// it opens, and a card that rose under the pointer must not take the
/// composer's typing with it.
private struct ReactionFlyoutHost: NSViewRepresentable {
    var anchor: CGRect?
    var root: ReactionFlyoutRoot?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        context.coordinator.update(anchor: anchor, root: root, in: view)
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        coordinator.close()
    }

    /// The overlay's own space, top-left origin like SwiftUI's, and never the
    /// target of a click.
    final class AnchorView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        private var popover: NSPopover?
        private var host: NSHostingController<ReactionFlyoutRoot>?

        func update(anchor: CGRect?, root: ReactionFlyoutRoot?, in view: NSView) {
            guard let anchor, let root, let window = view.window else {
                close()
                return
            }
            if let popover, let host, popover.isShown {
                host.rootView = root
                if popover.positioningRect != anchor { popover.positioningRect = anchor }
                return
            }
            let host = NSHostingController(rootView: root)
            host.sizingOptions = .preferredContentSize
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = true
            popover.contentViewController = host
            self.host = host
            self.popover = popover
            let wasKey = window.isKeyWindow
            // Above the chip, where Discord puts it; AppKit turns it round
            // when there is no room.
            popover.show(relativeTo: anchor, of: view, preferredEdge: .minY)
            if wasKey, !window.isKeyWindow { window.makeKey() }
        }

        func close() {
            popover?.performClose(nil)
            popover = nil
            host = nil
        }
    }
}

/// What the popover's window is handed. **A window of its own inherits
/// nothing**, so the store, the motion rules and the app's colour scheme are
/// restated here — the last for the reason `ProfileParts` gives: a flyout
/// escaping into its own window must say which scheme it is drawn against.
private struct ReactionFlyoutRoot: View {
    var model: AppModel
    var emoji: EmojiRef
    var content: ReactionTooltipContent
    var hovering: (Bool) -> Void
    var openList: () -> Void

    var body: some View {
        ReactionFlyoutCard(emoji: emoji, content: content, openList: openList)
            .onHover(perform: hovering)
            .environment(model)
            .resolvesMotion()
            .appColorScheme()
    }
}

/// The card: the emoji at Discord's jumbo size, the sentence, a super
/// reaction's note, and where a foreign emoji comes from.
private struct ReactionFlyoutCard: View {
    var emoji: EmojiRef
    var content: ReactionTooltipContent
    var openList: () -> Void

    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    /// Wide enough for three names and a count on two lines.
    private static let width: CGFloat = 280
    /// Discord's `jumbo`: 48 points.
    private static let emojiSide: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Button(action: openList) {
                HStack(spacing: Spacing.snug) {
                    ReactionEmoji(emoji: emoji, side: Self.emojiSide)
                    sentence
                        .font(.system(.subheadline))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                guard isHovering != hovering else { return }
                isHovering = hovering
            }
            .accessibilityLabel(Text(content.sentence.text))
            .accessibilityHint(Text("Shows everyone who reacted"))

            if let note = content.note {
                Text(note)
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.secondary)
            }

            if isForeign {
                ReactionEmojiDetails(emoji: emoji)
            }
        }
        .padding(Spacing.snug)
        .frame(width: Self.width)
    }

    /// The sentence, its count of the others in the link's colour —
    /// underlined while the card is under the pointer, because the whole of
    /// it is the link.
    private var sentence: Text {
        let lead = Text(content.sentence.lead).foregroundStyle(InkColor.primary)
        guard let others = content.sentence.others else { return lead }
        let link = Text(others)
            .foregroundStyle(Color(nsColor: .linkColor))
            .underline(isHovering)
        return Text("\(lead)\(link)")
    }

    /// Discord offers its details only for a custom emoji from a server the
    /// reader is not in (`eA` returns nothing for one they are).
    private var isForeign: Bool {
        guard let id = emoji.id else { return false }
        return !model.guildEmojis.contains { _, emojis in emojis.contains { $0.id == id } }
    }
}

/// "See emoji details": where a foreign emoji comes from, asked for only when
/// somebody wants to know — Discord's `eA`, over this app's own answer to the
/// question (`ExpressionInfoCard`'s sentence and source row).
private struct ReactionEmojiDetails: View {
    var emoji: EmojiRef

    @Environment(AppModel.self) private var model
    @State private var isExpanded = false

    private var request: ExpressionInfoRequest {
        ExpressionInfoRequest(subject: .emoji(emoji), anchor: .zero)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            if isExpanded {
                let info = model.expressionInfo(for: request)
                Rectangle().fill(Palette.selectionFill).frame(height: 1)
                Text(info.detail)
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let source = info.source {
                    ExpressionSourceRow(source: source, openGuild: { model.selectGuild($0) })
                        // The row brings its own margin for the card it was
                        // made for; this one already has its own.
                        .padding(.horizontal, -Spacing.margin)
                }
            } else {
                // Once open it stays open, as Discord's does: the toggle is
                // replaced by what it revealed.
                Button { isExpanded = true } label: {
                    HStack(spacing: Spacing.tight) {
                        Text("See emoji details")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.secondary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: isExpanded) {
            guard isExpanded else { return }
            await model.loadExpressionSourceIfNeeded(for: request)
        }
    }
}
