import Foundation

/// The two columns of a Server Hub, and every way an edit changes them.
///
/// **Discord's own arithmetic** (`754674`): column 1 is the side column and
/// anything else is the main one; each column runs by `order`; and after every
/// change the positions are written back as plain column and index, so a save
/// never carries a gap or a duplicate.
public enum GuildSpaceLayout {
    public static let mainColumn = 0
    public static let sideColumn = 1

    /// The main column, then the side column, each in order.
    public static func columns(_ widgets: [GuildSpaceWidget]) -> [[GuildSpaceWidget]] {
        let ordered = widgets.sorted { $0.position.order < $1.position.order }
        return [
            ordered.filter { $0.position.column != sideColumn },
            ordered.filter { $0.position.column == sideColumn },
        ]
    }

    /// Every widget at its column's index — the shape a save sends.
    public static func normalized(_ widgets: [GuildSpaceWidget]) -> [GuildSpaceWidget] {
        flattened(columns(widgets))
    }

    /// Puts a widget into a column at an index, clamped to the column.
    public static func inserting(
        _ widget: GuildSpaceWidget,
        into widgets: [GuildSpaceWidget],
        column: Int,
        index: Int
    ) -> [GuildSpaceWidget] {
        var columns = columns(widgets.filter { $0.id != widget.id })
        let target = column == sideColumn ? 1 : 0
        columns[target].insert(widget, at: max(0, min(index, columns[target].count)))
        return flattened(columns)
    }

    /// Moves a widget to a column at an index. Nil when it isn't there.
    public static func moving(
        _ id: String,
        in widgets: [GuildSpaceWidget],
        toColumn column: Int,
        index: Int
    ) -> [GuildSpaceWidget]? {
        guard let widget = widgets.first(where: { $0.id == id }) else { return nil }
        return inserting(widget, into: widgets, column: column, index: index)
    }

    public static func removing(_ id: String, from widgets: [GuildSpaceWidget]) -> [GuildSpaceWidget] {
        normalized(widgets.filter { $0.id != id })
    }

    /// Discord's starting layout for a new hub (`855823`'s `Ac`): the
    /// leaderboard above the whiteboard in the main column, popular games beside
    /// them — each only where the catalog offers it.
    public static let starterKinds: [[GuildSpaceWidgetKind]] = [
        [.leaderboard, .whiteboard],
        [.popularGames],
    ]

    private static func flattened(_ columns: [[GuildSpaceWidget]]) -> [GuildSpaceWidget] {
        columns.enumerated().flatMap { column, widgets in
            widgets.enumerated().map { order, widget in
                var placed = widget
                placed.position = .init(column: column, order: order)
                return placed
            }
        }
    }
}
