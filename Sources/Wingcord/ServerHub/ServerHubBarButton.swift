import SwiftUI

/// A worded control on the toolbar row: a glass capsule at the search field's
/// height, as the Members page's Prune is. The prominent one carries the
/// accent in its glass (`emphasisChrome`'s tint), not as a painted fill.
struct ServerHubBarButton: View {
    var title: String
    var systemImage: String?
    var isProminent = false
    var isWorking = false
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.tight) {
                if isWorking {
                    ProgressView()
                        .controlSize(.mini)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
            }
            // White only on the tinted glass; untinted (disabled), the row's ink.
            .foregroundStyle(isProminent && isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.primary))
            .fixedSize()
            .padding(.horizontal, Spacing.margin)
            .frame(height: SearchField.height)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .glassEffect(glass, in: .capsule)
        .accessibilityLabel(Text(title))
    }

    private var glass: Glass {
        isProminent && isEnabled
            ? .regular.tint(Palette.accent.opacity(0.7)).interactive()
            : .regular.interactive()
    }
}
