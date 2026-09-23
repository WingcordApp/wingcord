import SwiftUI
import WingcordCore

/// Who reacted, over the chip the pointer rests on.
///
/// **Composed over the drawn transcript, as the hover pill is**, from a frame
/// the canvas publishes in the clip view's space — the rows are painted, this
/// is one glass card at a time, and Core Graphics cannot draw glass.
///
/// **It waits before it asks.** Discord's dwell: half a second over a plain
/// chip, three quarters over a super one, whose effect plays first. A pointer
/// crossing a row of chips asks nobody anything, and one that settles asks once.
///
/// **It takes no clicks.** Discord's tooltip carries a link to the full list of
/// reactors and a button to add a super reaction; this client has no list to
/// open, and the chip under the card is that button already. A card nothing
/// on can be pressed must not stand between the pointer and the chip.
struct ReactionTooltipOverlay: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var shown: Shown?

    private struct Shown: Equatable {
        var hover: ReactionHover
        var content: ReactionTooltipContent
    }

    /// Wide enough for three names and a count on two lines, and fixed, so the
    /// card can be kept inside the transcript without being measured first.
    private static let width: CGFloat = 240
    /// Between the card and the chip it names.
    private static let gap: CGFloat = 8
    /// Room a card needs above its chip before it goes below instead — two
    /// lines and a note, at the card's own padding.
    private static let headroom: CGFloat = 96

    var body: some View {
        // Read first, so the dependency is registered whether or not there is
        // anything to draw.
        let hover = model.reactionHover
        GeometryReader { proxy in
            if let shown, shown.hover == hover {
                let chip = shown.hover.chipFrame
                let above = chip.minY >= Self.headroom
                let half = Self.width / 2 + Spacing.snug
                let x = min(max(chip.midX, half), max(half, proxy.size.width - half))
                Color.clear
                    .frame(width: 0, height: 0)
                    .overlay(alignment: above ? .bottom : .top) {
                        ReactionTooltipCard(emoji: shown.hover.emoji, content: shown.content)
                            .frame(width: Self.width)
                            .offset(y: above ? -Self.gap : Self.gap)
                            .transition(.materialize(from: above ? .bottom : .top, blurring: false))
                    }
                    .position(x: x, y: above ? chip.minY : chip.maxY)
            }
        }
        .allowsHitTesting(false)
        .animation(motion.hover, value: shown)
        .task(id: hover) {
            // Cleared before any wait: a card for the chip the pointer just
            // left must not outlive it — `INVARIANTS.md` §5.
            if shown != nil, shown?.hover != hover { shown = nil }
            guard let hover else { return }
            try? await Task.sleep(for: .milliseconds(hover.kind == .burst ? 750 : 500))
            guard !Task.isCancelled,
                  let content = await model.reactionTooltip(for: hover, in: channelID),
                  !Task.isCancelled
            else { return }
            shown = Shown(hover: hover, content: content)
        }
    }
}

/// The card itself: the emoji, the sentence, and a super reaction's note.
private struct ReactionTooltipCard: View {
    var emoji: EmojiRef
    var content: ReactionTooltipContent

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            glyph
                .frame(width: Self.glyphSide, height: Self.glyphSide)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.sentence)
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.primary)
                if let note = content.note {
                    Text(note)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.snug)
        // A flyout over the transcript is over media — `INVARIANTS.md` §4.
        .glassEffect(
            .clear.tint(Palette.flyoutTint),
            in: .rect(cornerRadius: Radius.glass, style: .continuous)
        )
    }

    private static let glyphSide: CGFloat = 32

    @ViewBuilder
    private var glyph: some View {
        if let id = emoji.id {
            RemoteImage(
                url: CDN.emoji(id: id, animated: false, side: Self.glyphSide),
                side: Self.glyphSide
            ) { Color.clear }
        } else {
            Text(emoji.name).font(.system(size: 26))
        }
    }
}
