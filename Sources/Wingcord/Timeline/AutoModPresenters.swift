import SwiftUI
import WingcordCore

/// What AutoMod's cards can raise at the window root: Discord's
/// confirmation before a mention raid's restrictions are lifted.
struct AutoModCardPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.alert(
            "Remove Mention Raid Restrictions",
            isPresented: Binding(
                get: { model.mentionRaidRemoval != nil },
                set: { if !$0 { model.mentionRaidRemoval = nil } }
            )
        ) {
            Button("Confirm") { model.confirmMentionRaidRemoval() }
            Button("Cancel", role: .cancel) { model.mentionRaidRemoval = nil }
        } message: {
            Text("Are you sure you want to remove all message restrictions that were placed on this server due to "
                + "a suspected mention raid?")
        }
    }
}

extension View {
    /// Apply once, at the window root.
    func presentsAutoModCards() -> some View {
        modifier(AutoModCardPresenter())
    }
}

/// What a moderator did, over its mark on an AutoMod alert — Discord's
/// tooltip (`nQ`), drawn where the transcript cannot draw it.
///
/// **Composed over the drawn transcript, as the mark flyout is**, from a frame
/// the canvas publishes in the clip view's space. Over the mark, where
/// Discord's tooltips sit, and under it where the transcript ends too close
/// above. Its words are found when it shows, because they say how long ago.
struct AutoModActionTooltipOverlay: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var shown: AutoModActionHover?
    @State private var sentence: String?

    /// Between the tooltip and the mark it names.
    private static let gap: CGFloat = 6
    /// Room above the mark before it goes below instead.
    private static let headroom: CGFloat = 36

    var body: some View {
        // Read first, so the dependency is registered whether or not there is
        // anything to draw.
        let hover = model.autoModActionHover
        GeometryReader { proxy in
            if let shown, shown == hover, let sentence {
                let mark = shown.frame
                let above = mark.minY >= Self.headroom
                Color.clear
                    .frame(width: 0, height: 0)
                    .overlay(alignment: above ? .bottom : .top) {
                        Text(sentence)
                            .font(.system(.callout, weight: .medium))
                            .foregroundStyle(Ink.primary)
                            .padding(.horizontal, Spacing.base * 1.5)
                            .padding(.vertical, Spacing.base)
                            .glassEffect(
                                .regular,
                                in: .rect(cornerRadius: Radius.glass, style: .continuous)
                            )
                            .fixedSize()
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
            // Cleared before any wait: a tooltip for the mark the pointer just
            // left must not outlive it — `INVARIANTS.md` §5.
            if shown != nil, shown != hover { shown = nil }
            guard let hover else { return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            sentence = model.autoModActionSentence(hover.action, in: channelID)
            shown = hover
        }
    }
}
