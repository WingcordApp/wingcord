import SwiftUI

/// One choice in a grid of them — a font, an effect, a typing indicator's
/// movement or word: a plate, the choice drawn on it, an accent edge on the
/// one chosen.
struct ChoiceTile<Content: View>: View {
    var isSelected: Bool
    var select: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.motion) private var motion

    var body: some View {
        Button(action: select) {
            content()
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(Palette.skeletonPlate)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                }
                .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(motion.hover, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
