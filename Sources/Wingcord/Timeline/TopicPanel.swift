import SwiftUI
import WingcordCore

/// An open topic's messages, on a card over the transcript.
///
/// **Discord's focus mode** (module `247933`): the transcript goes to where
/// the topic begins, and the topic — only its own messages, gathered from
/// wherever they fell among everybody else's — comes up over it. Put away, the
/// card leaves its marker above the first message, which is how it is found
/// again; Escape and a click outside put it away too.
///
/// **Clear glass over a dimmed transcript**, for the quick switcher's reason
/// and at its strength (`Palette.modalScrim`): a card of messages over a
/// column of messages is unreadable through clear glass alone, and frosting it
/// is the slab §4 exists to avoid.
struct TopicPanel: View {
    var channelID: ChannelID
    var topInset: CGFloat
    var bottomInset: CGFloat

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    var body: some View {
        let open = model.openTopic.flatMap { $0.channelID == channelID && $0.showsPanel ? $0 : nil }
        ZStack(alignment: .top) {
            if let open {
                Button(action: model.closeTopicPanel) {
                    Palette.modalScrim.contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Hide conversation"))
                .transition(.opacity)

                TopicPanelCard(topic: open.topic, channelID: channelID)
                    .padding(.top, topInset + Spacing.base)
                    .padding(.horizontal, Spacing.section)
                    .padding(.bottom, bottomInset + Spacing.base)
                    // Out of the marker's direction, and back into it.
                    .transition(.materialize(from: .top, blurring: false))
            }
        }
        // The transcript runs under the composer; the card stops above it,
        // measured from the same foot the content inset is.
        .ignoresSafeArea(.container, edges: .bottom)
        .animation(motion.panel, value: open?.topic.id)
    }
}

/// The card itself: the topic's name and summary, and its messages.
private struct TopicPanelCard: View {
    var topic: ConversationTopic
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @State private var presentation = PresentationRevision.shared
    /// Moves when a picture a card draws has landed — `PinnedMessagesPane`'s
    /// counter, for its reason.
    @State private var artworkGeneration: UInt64 = 0
    @State private var width: CGFloat = 0

    var body: some View {
        // Read at the top, so an arrival while the card is up invalidates it.
        let isLoaded = model.topicMessages[topic.id] != nil
        let cards = width > 0
            ? model.topicCards(for: topic.id, in: channelID, width: width)
            : []

        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(cards) { card in
                        MessageCardCanvas(
                            card: card,
                            presentationRevision: presentation.value,
                            artworkGeneration: artworkGeneration
                        )
                        // The layout's own height: placed once, never measured.
                        .frame(width: width, height: card.height)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(card.accessibilityLabel))
                    }
                }
                .padding(.bottom, Spacing.snug)
                .overlay {
                    if !isLoaded {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.top, Spacing.group)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .softScrollEdgesVertical()
            // **The width the cards are laid out against, derived once from
            // the one frame that knows it** — not measured per card.
            .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { newWidth in
                guard abs(width - newWidth) >= 1 else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { width = newWidth }
            }
        }
        .modalPanel(in: RoundedRectangle(cornerRadius: Radius.card))
        .task(id: cards.map(\.id)) {
            await MessageCardArtwork.prefetch(cards) { artworkGeneration &+= 1 }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(topic.title)
                    .font(.system(.headline))
                    .foregroundStyle(InkColor.primary)
                if let summary = topic.summary {
                    Text(summary)
                        .font(.system(.subheadline))
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button(action: model.closeTopicPanel) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(InkColor.solid)
                    .frame(width: Metrics.control, height: Metrics.control)
                    // A region inside the card's material, not a body of its
                    // own — glass on glass is §4's first rule.
                    .background(Circle().fill(Palette.hoverFill))
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Hide conversation")
            .accessibilityLabel(Text("Hide conversation"))
        }
        .padding(Spacing.margin)
    }
}
