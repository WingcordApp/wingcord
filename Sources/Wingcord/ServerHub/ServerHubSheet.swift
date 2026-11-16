import WingcordCore

/// The one sheet a Server Hub can have open.
enum ServerHubSheet: Hashable, Identifiable, Sendable {
    /// Add Widget, and where in which column the pick goes.
    case addWidget(column: Int, index: Int)
    /// A leaderboard, full size.
    case leaderboard(widgetID: String)
    /// An Image + Text widget's words and picture.
    case imageText(widgetID: String)
    /// Who may draw on the whiteboard.
    case whiteboardAccess(widgetID: String)

    var id: Self { self }
}
