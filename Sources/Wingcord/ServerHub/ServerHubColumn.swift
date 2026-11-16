import SwiftUI

/// One column of cards, and — while editing — the slot that adds to it.
struct ServerHubColumn: View {
    var widgets: [ServerHubPresentation.Widget]
    var column: Int
    var isEditing: Bool
    /// The main column with room to spare: an Image + Text card lays its picture
    /// beside its words rather than over them.
    var isWide: Bool

    @Environment(\.motion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            ForEach(widgets) { widget in
                ServerHubCard(widget: widget, isEditing: isEditing, isWide: isWide)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.96).combined(with: .opacity),
                        removal: .scale(scale: 0.94).combined(with: .opacity)
                    ))
            }
            .reorderable(collectionID: column)
            if isEditing {
                ServerHubAddSlot(column: column, index: widgets.count, isColumnEmpty: widgets.isEmpty)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(motion.standard, value: widgets.map(\.id))
    }
}
