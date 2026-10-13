import SwiftUI
import WingcordCore

/// What a server's mark means, over the mark the pointer rests on in an invite
/// card — Discord's badge tooltip, drawn where the transcript cannot draw it.
///
/// **Composed over the drawn transcript, as the reaction tooltip is**, from a
/// frame the canvas publishes in the clip view's space: the card is painted,
/// this is one glass card at a time, and Core Graphics cannot draw glass.
///
/// **Under the mark, where Discord puts it** (`tooltipPosition: "bottom"`),
/// and over it only where the transcript ends too close below. It takes no
/// clicks: it is an answer about the thing under the pointer.
struct GuildMarkTooltipOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var shown: GuildMarkHover?

    /// Between the card and the mark it names.
    private static let gap: CGFloat = 6
    /// Room the card needs below the mark before it goes above instead — three
    /// lines and the boost strip.
    private static let footroom: CGFloat = 96

    var body: some View {
        // Read first, so the dependency is registered whether or not there is
        // anything to draw.
        let hover = model.markHover
        GeometryReader { proxy in
            if let shown, shown == hover {
                let mark = shown.frame
                let below = proxy.size.height - mark.maxY >= Self.footroom
                let half = GuildMarkFlyout.maxWidth / 2 + Spacing.snug
                let x = min(max(mark.midX, half), max(half, proxy.size.width - half))
                Color.clear
                    .frame(width: 0, height: 0)
                    .overlay(alignment: below ? .top : .bottom) {
                        GuildMarkFlyout(mark: shown.mark)
                            .clipShape(.rect(cornerRadius: Radius.glass, style: .continuous))
                            // A flyout over the transcript: regular glass, the
                            // default — `INVARIANTS.md` §4.
                            .glassEffect(
                                .regular,
                                in: .rect(cornerRadius: Radius.glass, style: .continuous)
                            )
                            .fixedSize()
                            .offset(y: below ? Self.gap : -Self.gap)
                            .transition(.materialize(from: below ? .top : .bottom, blurring: false))
                    }
                    .position(x: x, y: below ? mark.maxY : mark.minY)
            }
        }
        .allowsHitTesting(false)
        .animation(motion.hover, value: shown)
        .task(id: hover) {
            // Cleared before any wait: a card for the mark the pointer just left
            // must not outlive it — `INVARIANTS.md` §5.
            if shown != nil, shown != hover { shown = nil }
            guard let hover else { return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            shown = hover
        }
    }
}
