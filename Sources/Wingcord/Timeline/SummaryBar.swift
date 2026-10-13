import SwiftUI
import WingcordCore

/// A channel's summaries, as three glass pills under the toolbar: the stretch
/// the reader is in, and the way to the ones either side.
///
/// **The named pill leads and the arrows trail** — the name where a line of
/// reading starts, the two steps where the toolbar's own controls sit. The
/// named pill opens every summary in a flyout; the arrows go a stretch back or
/// forward.
///
/// **In the scroll edge, not below it.** The container grows the rows' top
/// inset by `reservedHeight`, and AppKit's scroll pocket spans the whole inset
/// — so the pills float over softened rows the way the toolbar's items do,
/// where a bar below the edge would be glass over sharp text with the edge
/// ending at its top.
///
/// **It re-renders when the reader crosses a stretch, not when they scroll.**
/// The coordinator reports `SummaryPlace` only when it changes.
struct SummaryBar: View {
    var channelID: ChannelID
    /// Newest first — handed down by the container, which already read them to
    /// decide that the bar is shown.
    var summaries: [ChannelSummary]
    var scroll: TranscriptScrollState

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isListShown = false

    /// A step lighter than the composer's controls: this is a second row of
    /// chrome, not the place anybody types.
    static let pillHeight: CGFloat = 32
    /// What the bar takes from the top of the transcript.
    static let reservedHeight: CGFloat = pillHeight + Spacing.tight * 2

    var body: some View {
        let place = resolvedPlace
        let title = place.title(in: summaries)
        GlassEffectContainer(spacing: Spacing.tight) {
            HStack(spacing: Spacing.base) {
                topicPill(title: title, current: place.current)
                    .layoutPriority(1)
                Spacer(minLength: Spacing.base)
                step(to: place.older, glyph: "chevron.up", label: "Previous Summary")
                step(to: place.newer, glyph: "chevron.down", label: "Next Summary")
            }
            // Hit testing follows the pills, not the row: the gap between them
            // passes the pointer through to the transcript, and only the pills
            // cover it — `INVARIANTS.md` §2.9.
            .onHover(perform: scroll.pointer(overChrome:))
        }
        .padding(.horizontal, Spacing.margin)
        .frame(height: Self.reservedHeight)
        // A bar that goes while the pointer is on it — the toggle, or the last
        // summary going — hears no exit, and the latch would leave the canvas
        // covered.
        .onDisappear { scroll.pointer(overChrome: false) }
        .animation(motion.glassMorph, value: title)
    }

    /// The coordinator's answer, or the present's until it has given one —
    /// and never an index this list does not have, which a place reported
    /// for the channel before can hold for one frame.
    private var resolvedPlace: SummaryPlace {
        if let place = scroll.summaryPlace,
           [place.current, place.older, place.newer].allSatisfy({ $0.map(summaries.indices.contains) ?? true })
        {
            return place
        }
        return SummaryPlace(top: nil, bottom: nil, highlighted: nil, summaries: summaries)
    }

    private func topicPill(title: String, current: Int?) -> some View {
        Button { isListShown.toggle() } label: {
            HStack(spacing: Spacing.tight + Spacing.hair) {
                Image(systemName: "scroll")
                    .foregroundStyle(InkColor.solid.opacity(0.72))
                Text(title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(InkColor.solid.opacity(0.6))
                    .rotationEffect(.degrees(isListShown ? 180 : 0))
            }
            .foregroundStyle(InkColor.solid)
            .padding(.horizontal, Spacing.snug)
            .frame(height: Self.pillHeight)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // A control over the transcript: `.regular` glass, the HIG's default
        // for a control over content — `.clear` is for media.
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(motion.standard, value: isListShown)
        .help("All summaries")
        .accessibilityLabel(Text("Current summary"))
        .accessibilityValue(Text(title))
        .accessibilityHint(Text("Lists every summary in this channel"))
        // **A flyout off the pill that raised it**, in the popover's own glass —
        // §4.9: the content paints nothing. One control, evaluated once, so the
        // presentation belongs inline, the way the toolbar's pins do.
        .popover(isPresented: $isListShown, arrowEdge: .bottom) {
            SummaryList(
                channelID: channelID,
                summaries: summaries,
                currentID: current.map { summaries[$0].id }
            ) { summary in
                isListShown = false
                model.openSummary(summary, in: channelID)
            }
        }
    }

    /// One of the two arrows. With nowhere to go it dims and its glass stops
    /// answering the pointer — §5.5: a control that cannot work must not look
    /// like one that can.
    private func step(to target: Int?, glyph: String, label: String) -> some View {
        Button {
            guard let target, summaries.indices.contains(target) else { return }
            model.openSummary(summaries[target], in: channelID)
        } label: {
            Image(symbol: glyph)
                .font(Typeface.controlGlyph)
                .foregroundStyle(InkColor.solid.opacity(target == nil ? 0.35 : 1))
                .frame(width: Self.pillHeight, height: Self.pillHeight)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(target == nil ? .regular : .regular.interactive(), in: .circle)
        .disabled(target == nil)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}
