import SwiftUI
import WingcordCore

/// A channel's summaries, on the toolbar row: the stretch the reader is in at its leading
/// end, and the steps to the ones either side at its trailing end, with the channel's tools.
///
/// **On the row, not a second one under it.** They were three pills floating over the top
/// of the transcript, which cost the rows a band of their own and put chrome over the
/// words where the toolbar had room to spare. The pill reads like the title beside it and
/// the steps like the toolbar's other groups.
///
/// **It re-renders when the reader crosses a stretch, not when they scroll.** The
/// coordinator reports `SummaryPlace` only when it changes, and the main transcript hands
/// its scroll state to the model for these to read: `AppModel.summaryScroll`.
struct SummaryToolbarPill: View {
    var channelID: ChannelID
    /// Newest first.
    var summaries: [ChannelSummary]
    var scroll: TranscriptScrollState

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @Environment(\.headerControlSide) private var rowSide
    @State private var isListShown = false

    /// How far its own title may run, and how short it's cut before it's dropped.
    static let fullTitleWidth: CGFloat = 160
    static let shortTitleWidth: CGFloat = 80

    var body: some View {
        let place = SummaryPlace.resolved(scroll.summaryPlace, in: summaries)
        let title = place.title(in: summaries)
        Button { isListShown.toggle() } label: {
            // **It gives way before the channel's title does** (`HeaderBarLayout`): its
            // title in full, then cut short, then the glyph and the chevron alone.
            ViewThatFits(in: .horizontal) {
                label(title, upTo: Self.fullTitleWidth)
                label(title, upTo: Self.shortTitleWidth)
                label(nil, upTo: 0)
            }
            .frame(height: rowSide)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // The title capsule's own glass, so the two read as one family on the row.
        .glassEffect(.regular.interactive(), in: .capsule)
        .fixedSize(horizontal: false, vertical: true)
        .animation(motion.standard, value: isListShown)
        .animation(motion.glassMorph, value: title)
        .help("All summaries")
        .accessibilityLabel(Text("Current summary"))
        .accessibilityValue(Text(title))
        .accessibilityHint(Text("Lists every summary in this channel"))
        // **A flyout off the pill that raised it**, in the popover's own glass: §4.9,
        // the content paints nothing.
        .popover(isPresented: $isListShown, arrowEdge: .bottom) {
            SummaryList(
                channelID: channelID,
                summaries: summaries,
                currentID: place.current.map { summaries[$0].id }
            ) { summary in
                isListShown = false
                model.openSummary(summary, in: channelID)
            }
        }
    }

    /// One width of it: at its own size, so the pill hugs whichever fits.
    private func label(_ title: String?, upTo width: CGFloat) -> some View {
        HStack(spacing: Spacing.tight + Spacing.hair) {
            Image(systemName: "scroll")
                .foregroundStyle(InkColor.solid.opacity(0.72))
            if let title {
                Text(title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.interpolate)
                    .frame(maxWidth: width, alignment: .leading)
            }
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(InkColor.solid.opacity(0.6))
                .rotationEffect(.degrees(isListShown ? 180 : 0))
        }
        .foregroundStyle(InkColor.solid)
        .padding(.horizontal, Spacing.snug)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The two steps, a stretch back and a stretch on, as one of the toolbar's groups.
///
/// With nowhere to go a step dims and does nothing — §5.5: a control that cannot work must
/// not look like one that can.
struct SummaryToolbarSteps: View {
    var channelID: ChannelID
    var summaries: [ChannelSummary]
    var scroll: TranscriptScrollState

    @Environment(AppModel.self) private var model

    var body: some View {
        let place = SummaryPlace.resolved(scroll.summaryPlace, in: summaries)
        HeaderControlGroup {
            step(to: place.older, glyph: "chevron.up", label: "Previous Summary")
            step(to: place.newer, glyph: "chevron.down", label: "Next Summary")
        }
    }

    private func step(to target: Int?, glyph: String, label: String) -> some View {
        HeaderGroupButton(systemImage: glyph, label: label) {
            guard let target, summaries.indices.contains(target) else { return }
            model.openSummary(summaries[target], in: channelID)
        }
        .opacity(target == nil ? 0.35 : 1)
        .disabled(target == nil)
    }
}

extension SummaryPlace {
    /// The coordinator's answer, or the present's until it has given one, and never an
    /// index this list doesn't have, which a place reported for the channel before can
    /// hold for one frame.
    static func resolved(_ place: SummaryPlace?, in summaries: [ChannelSummary]) -> SummaryPlace {
        if let place,
           [place.current, place.older, place.newer].allSatisfy({ $0.map(summaries.indices.contains) ?? true })
        {
            return place
        }
        return SummaryPlace(top: nil, bottom: nil, highlighted: nil, summaries: summaries)
    }
}
