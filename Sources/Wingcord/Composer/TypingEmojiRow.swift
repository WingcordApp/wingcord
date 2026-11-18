import SwiftUI
import WingcordCore

/// A custom typing indicator's emoji, in place of the dots, moving the way the
/// typer chose — Pulse, Ring or Wave (docs/CLIPS-PRESENCE.md, D23).
///
/// **One emoji at a time, in turn**, as the dots do: a `PhaseAnimator` steps
/// through the slots and back to rest, so the row costs one phase change per
/// step rather than a clock of its own. It is only ever on screen while one
/// person types with an indicator of their own, in the channel open.
///
/// Reduce Motion keeps the emoji and stops the movement — and an animated
/// custom emoji's own film asks the same preference, inside `ExpressionGlyph`.
struct TypingEmojiRow: View {
    var style: TypingIndicatorStyle

    @Environment(\.motion) private var motion

    /// The glyph's side: the typing line's caption size, a little larger, as the
    /// symbol it replaces reads at that size.
    private static let side: CGFloat = 14

    var body: some View {
        if motion.reduceMotion || style.animation == .unspecified {
            row(active: nil)
        } else {
            // Every slot, then a beat of rest before it starts again.
            PhaseAnimator(Array(0...style.emojis.count)) { phase in
                row(active: phase < style.emojis.count ? phase : nil)
            } animation: { _ in
                .easeInOut(duration: 0.24)
            }
        }
    }

    private func row(active: Int?) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(style.emojis.enumerated()), id: \.offset) { index, emoji in
                ExpressionGlyph(emoji: emoji, side: Self.side, plays: true)
                    .frame(width: Self.side, height: Self.side)
                    .modifier(Motion(animation: style.animation, isActive: active == index))
            }
        }
        .accessibilityHidden(true)
    }

    /// One slot's step: Pulse swells it, Wave lifts it, Ring swings it like a
    /// bell.
    private struct Motion: ViewModifier {
        var animation: TypingIndicatorStyle.Animation
        var isActive: Bool

        func body(content: Content) -> some View {
            switch animation {
            case .pulse: content.scaleEffect(isActive ? 1.3 : 1)
            case .wave: content.offset(y: isActive ? -3 : 0)
            case .ring: content.rotationEffect(.degrees(isActive ? 18 : 0), anchor: .top)
            case .unspecified: content
            }
        }
    }
}
