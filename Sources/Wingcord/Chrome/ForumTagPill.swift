import SwiftUI
import WingcordCore

/// A tag to put on a new post: a glass pill, big enough to be the choice it
/// is — its emoji, its name, and a check once it's on, lit in the accent.
struct ForumTagPill: View {
    var tag: ForumTag
    var isOn: Bool

    var body: some View {
        HStack(spacing: Spacing.base) {
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .transition(.scale.combined(with: .opacity))
            }
            if let emoji = tag.emoji {
                ExpressionGlyph(emoji: emoji, side: 18)
            }
            Text(tag.name)
                .font(.system(.callout, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(Ink.primary))
        .padding(.horizontal, Spacing.snug + 2)
        .frame(height: 34)
        .contentShape(.capsule)
        .glassEffect(
            isOn ? .regular.tint(Palette.accent.opacity(0.75)).interactive() : .regular.interactive(),
            in: .capsule
        )
    }
}
