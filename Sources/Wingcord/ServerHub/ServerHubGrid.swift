import SwiftUI

/// The two columns: Discord's main column and its narrower side column, which
/// stack — main over side — where the window can't hold both.
///
/// **One layout, switched, not two trees** (`AnyLayout`): a card keeps its
/// identity, and so its state, as the window narrows past the point.
///
/// **Reordering is the system's** (`reorderable(collectionID:)` on each column,
/// one `reorderContainer` around both): a card dragged in an edit lands in
/// either column, and the difference comes back as the column and the card it
/// lands before — `AppModel.applyServerHubReorder`.
struct ServerHubGrid: View {
    var presentation: ServerHubPresentation

    @Environment(AppModel.self) private var model
    @State private var isWide = true

    var body: some View {
        let layout = isWide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.group))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.group))
        layout {
            ServerHubColumn(
                widgets: presentation.columns.first ?? [],
                column: 0,
                isEditing: presentation.isEditing,
                isWide: isWide
            )
            ServerHubColumn(
                widgets: presentation.columns.dropFirst().first ?? [],
                column: 1,
                isEditing: presentation.isEditing,
                isWide: false
            )
            .frame(width: isWide ? ServerHubMetrics.sideColumnWidth : nil)
        }
        .reorderContainer(
            for: ServerHubPresentation.Widget.self,
            in: Int.self,
            isEnabled: presentation.isEditing,
            move: reorder
        )
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width >= ServerHubMetrics.twoColumnMinimum
        } action: { wide in
            isWide = wide
        }
    }

    private func reorder(_ difference: ReorderDifference<String, Int>) {
        model.applyServerHubReorder(difference)
    }
}
