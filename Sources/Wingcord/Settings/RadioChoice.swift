import SwiftUI

/// One radio choice, with an optional paragraph under it — Content Visibility,
/// the kind of channel on the create sheet, a ban's reason, a prune's window.
/// Discord draws all of these as one radio group control (`144228`).
struct RadioChoice: View {
    var title: String
    var detail: String? = nil
    var isSelected: Bool
    var choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: Spacing.snug) {
                Image(symbol: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.tertiary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(Ink.primary)
                    if let detail {
                        Text(detail)
                            .font(.system(.caption))
                            .foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
