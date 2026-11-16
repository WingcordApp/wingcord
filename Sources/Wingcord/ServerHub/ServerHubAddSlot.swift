import SwiftUI

/// The end of a column while editing: where a new widget goes. A dashed place,
/// not a card — it is room, not content.
struct ServerHubAddSlot: View {
    var column: Int
    var index: Int
    var isColumnEmpty: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: ServerHubMetrics.cardRadius) }

    var body: some View {
        Button(action: add) {
            VStack(spacing: Spacing.tight) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text(isColumnEmpty ? "Add widgets to this column" : "Add Widget")
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(Ink.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: isColumnEmpty ? 140 : 72)
            .background(isHovering ? Palette.hoverFill : .clear, in: shape)
            .overlay {
                shape.strokeBorder(Ink.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .accessibilityLabel(Text(column == 1 ? "Add Widget to the side column" : "Add Widget to the main column"))
    }

    private func add() {
        model.serverHub.sheet = .addWidget(column: column, index: index)
    }
}
