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
            // **Reorderable only in an edit** (decision 21). The container's
            // `isEnabled` alone didn't stop macOS 27 from lifting a card for a
            // reader who can't edit (Alex, Image 11): it only refused the drop,
            // so the card flew back. Outside an edit the cards aren't
            // reorderable at all. Editing is Manage Server only.
            if isEditing {
                ForEach(widgets) { widget in
                    card(widget)
                }
                .reorderable(collectionID: column)
            } else {
                ForEach(widgets) { widget in
                    card(widget)
                }
            }
            if isEditing {
                ServerHubAddSlot(column: column, index: widgets.count, isColumnEmpty: widgets.isEmpty)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(motion.standard, value: widgets.map(\.id))
    }

    private func card(_ widget: ServerHubPresentation.Widget) -> some View {
        ServerHubCard(widget: widget, isEditing: isEditing, isWide: isWide)
            .transition(.asymmetric(
                insertion: .scale(scale: 0.96).combined(with: .opacity),
                removal: .scale(scale: 0.94).combined(with: .opacity)
            ))
    }
}
