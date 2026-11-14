import SwiftUI

/// The toolbar row, drawn by a page whose own controls live on it: Discover's
/// pickers, Channels & Roles' tabs.
///
/// **The page draws it, because the page holds what's on it**, and `DetailHeader`
/// steps aside for these pages (`pageDrawsHeaderRow`). As the floating bar the page
/// already had, the bar and the scroll view's reservation can't disagree. It's the
/// same layout at the same height with the same margins as every other page's row,
/// so anything else on it stays put as pages change.
struct PageHeaderBar<Leading: View, Center: View, Trailing: View>: View {
    /// Whether the centre may drop to a row of its own when one row can't hold it.
    var wrapsCenter = false
    /// The trailing slot's widest, for deciding that. See `HeaderBarLayout`.
    var reservedTrailing: CGFloat = 0
    @ViewBuilder var leading: Leading
    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing

    @Environment(\.shellLayout) private var layout
    @Environment(\.motion) private var motion

    var body: some View {
        HeaderBarLayout(
            rowHeight: ShellMetrics.headerHeight,
            wrapsCenter: wrapsCenter,
            reservedTrailing: reservedTrailing
        ) {
            leading.layoutValue(key: HeaderSlotKey.self, value: .leading)
            center.layoutValue(key: HeaderSlotKey.self, value: .center)
            // The update arrow ends every page's row, as it ends the ordinary one
            // (docs/UPDATES.md D8), at the height of the search fields beside it.
            // It takes no room while there's no update.
            HStack(spacing: Spacing.base) {
                trailing
                UpdateToolbarButton()
                    .environment(\.headerControlSide, SearchField.height)
            }
            .layoutValue(key: HeaderSlotKey.self, value: .trailing)
        }
        .padding(.leading, (layout?.detailHeaderLeadingClearance ?? 0) + Spacing.snug)
        .padding(.trailing, Spacing.snug)
        .animation(motion.reposition, value: layout.map(ShellMotionKey.init))
        .dragsWindow()
    }
}
