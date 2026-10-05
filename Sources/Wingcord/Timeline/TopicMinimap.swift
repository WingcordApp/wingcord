import SwiftUI
import WingcordCore

/// Which topics the minimap shows, and in which slot.
///
/// Discord's own arithmetic (module `247933`): seven slots, centred on the
/// topic the reader is in, clamped two from each end so an end of the list does
/// not leave slots empty in the middle — which is why the newest topic sits
/// low rather than centred — and faded at an end with more beyond it.
nonisolated struct TopicMinimapWindow: Equatable, Sendable {
    static let slots = 7

    struct Entry: Equatable, Sendable {
        /// Into the channel's topics.
        var index: Int
        /// Top to bottom, 0 ... 6.
        var slot: Int
    }

    var entries: [Entry]
    /// An end with more topics past it; its outermost bar is drawn fainter.
    var fadesTop: Bool
    var fadesBottom: Bool

    init(count: Int, current: Int) {
        guard count > 0 else {
            entries = []
            fadesTop = false
            fadesBottom = false
            return
        }
        let half = Self.slots / 2
        let low = min(2, count - 1)
        let high = max(low, count - 1 - 2)
        let center = min(max(current, low), high)
        entries = (-half...half).compactMap { offset in
            let index = center + offset
            return (0..<count).contains(index) ? Entry(index: index, slot: half + offset) : nil
        }
        fadesTop = center - half > 0
        fadesBottom = center + half < count - 1
    }
}

/// The channel's topics, as a minimap at the transcript's trailing edge.
///
/// **Short bars at rest, titles under the pointer** — Discord's arrangement,
/// in this app's glass. A bar's length follows its title's (`round(0.6 × n)`
/// points, 4 to 16) so the column is a silhouette of the list; hovering it opens
/// the titles on a clear plate, a title resting under the pointer brings up its
/// first messages in a flyout, and a click opens the topic.
///
/// **It re-renders when the reader crosses a topic, not when they scroll.** The
/// coordinator reports the reader's place (`TopicPlace`) only when it changes,
/// and everything else here is the pointer's own state.
struct TopicMinimap: View {
    var channelID: ChannelID
    var scroll: TranscriptScrollState

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isExpanded = false
    /// The title under the pointer.
    @State private var hovered: ConversationTopicID?
    /// The title whose flyout is up: the hovered one, once it has been rested
    /// on — `HoverFlyout`'s dwell, and its reason.
    @State private var previewing: ConversationTopic?
    @State private var dwell: Task<Void, Never>?

    /// The height of one title, expanded, and of one bar's step, at rest.
    static let titleRow: CGFloat = 28
    static let barRow: CGFloat = 14
    private static let dwellDuration = Duration.milliseconds(180)

    var body: some View {
        let topics = model.conversationTopics[channelID]?.topics ?? []
        if !topics.isEmpty {
            let openID = model.openTopic.flatMap { $0.channelID == channelID ? $0.topic.id : nil }
            let readerIndex = min(scroll.topicIndex ?? topics.count - 1, topics.count - 1)
            // Discord's order: the open topic, else the one being read, else
            // the newest.
            let current = openID.flatMap { id in topics.firstIndex { $0.id == id } } ?? readerIndex
            let window = TopicMinimapWindow(count: topics.count, current: current)
            let first = window.entries.first?.slot ?? 0

            VStack(alignment: .trailing, spacing: 0) {
                ForEach(window.entries, id: \.index) { entry in
                    let topic = topics[entry.index]
                    TopicMinimapRow(
                        topic: topic,
                        isExpanded: isExpanded,
                        emphasis: emphasis(of: topic.id, isCurrent: entry.index == current, openID: openID),
                        isFaint: (entry.slot == first && window.fadesTop)
                            || (entry == window.entries.last && window.fadesBottom),
                        // Above the reader's place, or at it, points up.
                        pointsDown: entry.index > readerIndex,
                        isOpen: topic.id == openID,
                        hover: { hover(topic, $0) },
                        open: { open(topic) }
                    )
                }
            }
            // The rows start at their first slot, so a list clamped at an end
            // keeps its bars where the full column would have them.
            .padding(.top, CGFloat(first) * (isExpanded ? Self.titleRow : Self.barRow))
            .padding(.vertical, Spacing.base)
            .padding(.horizontal, isExpanded ? Spacing.snug : Spacing.tight)
            // **Clear glass, and only while it holds titles.** At rest the bars
            // sit on the transcript like a scroller does; a plate under them
            // would be a panel standing in the reading column all day.
            .glassEffect(
                isExpanded ? .clear.tint(Palette.flyoutTint) : .identity,
                in: .rect(cornerRadius: Radius.glass)
            )
            .contentShape(.rect(cornerRadius: Radius.glass))
            .onHover(perform: setExpanded)
            // Gone under the pointer — the channel changed — hears no exit.
            .onDisappear { setExpanded(false) }
            .popover(
                item: $previewing,
                attachmentAnchor: .rect(.rect(anchor(for: previewing, in: window, first: first))),
                arrowEdge: .leading
            ) { topic in
                TopicPreviewFlyout(topic: topic, channelID: channelID)
            }
            .animation(motion.standard, value: isExpanded)
            .animation(motion.hover, value: hovered)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Topics"))
        }
    }

    private func emphasis(
        of id: ConversationTopicID,
        isCurrent: Bool,
        openID: ConversationTopicID?
    ) -> TopicMinimapRow.Emphasis {
        if id == openID || (openID == nil && isCurrent && !isExpanded) { return .current }
        if id == hovered { return .hovered }
        return hovered == nil ? .resting : .receded
    }

    /// Where the flyout points: the hovered title's own row.
    private func anchor(
        for topic: ConversationTopic?,
        in window: TopicMinimapWindow,
        first: Int
    ) -> CGRect {
        let position = window.entries.firstIndex { entry in
            model.conversationTopics[channelID]?.topics[entry.index].id == topic?.id
        } ?? 0
        return CGRect(
            x: 0,
            y: Spacing.base + CGFloat(first + position) * Self.titleRow,
            width: 1,
            height: Self.titleRow
        )
    }

    private func setExpanded(_ expanded: Bool) {
        scroll.pointer(overChrome: expanded)
        // A `@State` write of an equal value still invalidates — §2.
        if isExpanded != expanded { isExpanded = expanded }
        guard !expanded else { return }
        dwell?.cancel()
        dwell = nil
        if hovered != nil { hovered = nil }
        if previewing != nil { previewing = nil }
    }

    private func hover(_ topic: ConversationTopic, _ inside: Bool) {
        dwell?.cancel()
        guard inside, isExpanded else {
            if hovered == topic.id { hovered = nil }
            return
        }
        if hovered != topic.id { hovered = topic.id }
        // The open topic's flyout would show what its panel already shows.
        guard model.openTopic?.topic.id != topic.id else { return }
        dwell = Task {
            try? await Task.sleep(for: Self.dwellDuration)
            guard !Task.isCancelled else { return }
            previewing = topic
        }
    }

    private func open(_ topic: ConversationTopic) {
        dwell?.cancel()
        previewing = nil
        isExpanded = false
        model.openTopic(topic, in: channelID)
    }
}

/// One topic: a bar at rest, its title under the pointer.
private struct TopicMinimapRow: View {
    enum Emphasis {
        /// The topic the reader is in, or the open one.
        case current
        case hovered
        case resting
        /// Another title is under the pointer.
        case receded
    }

    var topic: ConversationTopic
    var isExpanded: Bool
    var emphasis: Emphasis
    /// The outermost bar at an end with more past it.
    var isFaint: Bool
    var pointsDown: Bool
    var isOpen: Bool
    var hover: (Bool) -> Void
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            ZStack(alignment: .trailing) {
                if isExpanded {
                    title
                        .transition(.opacity.combined(with: .scale(scale: 0.5, anchor: .trailing)))
                } else {
                    Capsule()
                        .fill(InkColor.solid.opacity(barOpacity))
                        .frame(width: barWidth, height: 2)
                        .transition(.opacity)
                }
            }
            .frame(height: isExpanded ? TopicMinimap.titleRow : TopicMinimap.barRow, alignment: .trailing)
            .frame(minWidth: 16, alignment: .trailing)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover(perform: hover)
        .accessibilityLabel(Text(topic.title))
        .accessibilityHint(Text(topic.summary ?? ""))
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }

    private var title: some View {
        HStack(spacing: Spacing.tight) {
            Text(topic.title)
                .font(emphasis == .current ? Typeface.rowTitleUnread : Typeface.rowTitle)
                .foregroundStyle(titleStyle)
                .lineLimit(1)
            if emphasis == .hovered {
                Image(symbol: pointsDown ? "arrow.down" : "arrow.up")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(InkColor.solid)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, isOpen ? Spacing.base : 0)
        .padding(.vertical, isOpen ? 3 : 0)
        // Discord's pill around the open topic's title: an outline, so it
        // reads as a place rather than as a second button.
        .overlay {
            if isOpen {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .strokeBorder(Palette.edgeStrong, lineWidth: 1)
            }
        }
    }

    /// `round(0.6 × characters)`, 4 to 16 points — Discord's own.
    private var barWidth: CGFloat {
        CGFloat(min(16, max(4, Int((0.6 * Double(topic.title.count)).rounded()))))
    }

    private var barOpacity: Double {
        if isFaint { return 0.2 }
        return emphasis == .current ? 0.85 : 0.4
    }

    private var titleStyle: Color {
        switch emphasis {
        case .current, .hovered: InkColor.primary
        case .resting: InkColor.secondary
        case .receded: InkColor.tertiary
        }
    }
}

/// A topic's first messages, in the flyout off its title.
///
/// **The transcript's own painter at flyout width** — the excerpt the inbox
/// draws — so a preview of a forward, an embed or a sticker is that, and not a
/// sentence standing in for it. The popover supplies the glass; this paints
/// nothing (`INVARIANTS.md` §4.9).
private struct TopicPreviewFlyout: View {
    var topic: ConversationTopic
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @State private var presentation = PresentationRevision.shared
    @State private var artworkGeneration: UInt64 = 0

    private static let width: CGFloat = 360
    /// Taller than this, the preview is cut and fades — it is a glimpse, and
    /// the panel is where a topic is read.
    private static let maximumHeight: CGFloat = 300
    private static var cardWidth: CGFloat { width - Spacing.snug * 2 }

    var body: some View {
        let card = model.topicPreviewCard(for: topic.id, in: channelID, width: Self.cardWidth)
        Group {
            if let card {
                MessageCardCanvas(
                    card: card,
                    presentationRevision: presentation.value,
                    artworkGeneration: artworkGeneration
                )
                .frame(width: Self.cardWidth, height: card.height)
                .frame(height: min(card.height, Self.maximumHeight), alignment: .top)
                .clipped()
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: card.height > Self.maximumHeight ? 0.8 : 1),
                            .init(color: card.height > Self.maximumHeight ? .clear : .black, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(card.accessibilityLabel))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: Self.cardWidth, height: 96)
            }
        }
        .padding(Spacing.snug)
        .task { model.previewTopic(topic, in: channelID) }
        .task(id: card?.id) {
            guard let card else { return }
            if await MessageCardArtwork.prefetch([card]) { artworkGeneration &+= 1 }
        }
    }
}
