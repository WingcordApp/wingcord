import SwiftUI
import WingcordCore

/// When a message was last changed, over the "(edited)" the pointer rests on —
/// Discord's tooltip on its `.edited`, the whole moment on the reader's clock.
///
/// **Composed over the drawn transcript, as the AutoMod tooltip is**, from a
/// frame the canvas publishes in the clip view's space. Over the marker, where
/// Discord's tooltips sit, and under it where the transcript ends too close
/// above. It takes no clicks: it is an answer about the thing under the
/// pointer.
struct EditedMarkTooltipOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var shown: EditedMarkHover?

    /// Between the tooltip and the marker it names.
    private static let gap: CGFloat = 6
    /// Room above the marker before it goes below instead.
    private static let headroom: CGFloat = 36

    var body: some View {
        // Read first, so the dependency is registered whether or not there is
        // anything to draw.
        let hover = model.editedMarkHover
        GeometryReader { proxy in
            if let shown, shown == hover {
                let mark = shown.frame
                let above = mark.minY >= Self.headroom
                let paneWidth = proxy.size.width
                Color.clear
                    .frame(width: 0, height: 0)
                    .overlay(alignment: above ? .bottom : .top) {
                        Text(PresentationRevision.shared.timeline.fullTimestampLabel(shown.editedAt))
                            .font(.system(.callout, weight: .medium))
                            .foregroundStyle(Ink.primary)
                            .padding(.horizontal, Spacing.base * 1.5)
                            .padding(.vertical, Spacing.base)
                            .glassEffect(
                                .regular,
                                in: .rect(cornerRadius: Radius.glass, style: .continuous)
                            )
                            .fixedSize()
                            // **Kept inside the transcript.** The marker ends
                            // the reader's own bubble, against the trailing
                            // edge, where a tooltip centred on it hangs half
                            // its width past the pane.
                            .alignmentGuide(HorizontalAlignment.center) { size in
                                let half = size.width / 2
                                let low = half + Spacing.snug
                                let high = max(low, paneWidth - half - Spacing.snug)
                                return half + mark.midX - min(max(mark.midX, low), high)
                            }
                            .offset(y: above ? -Self.gap : Self.gap)
                            .transition(.materialize(from: above ? .bottom : .top, blurring: false))
                    }
                    .position(
                        x: min(max(mark.midX, 0), proxy.size.width),
                        y: above ? mark.minY : mark.maxY
                    )
            }
        }
        .allowsHitTesting(false)
        .animation(motion.hover, value: shown)
        .task(id: hover) {
            // Cleared before any wait: a tooltip for the marker the pointer
            // just left must not outlive it — `INVARIANTS.md` §5.
            if shown != nil, shown != hover { shown = nil }
            guard let hover else { return }
            // Discord's `delay: 750` — a word a reader's pointer crosses a lot.
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            shown = hover
        }
    }
}
