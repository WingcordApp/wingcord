import SwiftUI

/// Every keyboard shortcut the app defines, in one table.
///
/// **The single source of truth is the menu, not this list** — a shortcut that
/// exists here and nowhere else would be a lie printed in a settings window, and
/// a pane of those is worse than no pane. So the rule is: nothing goes in this
/// table that is not bound in `WingcordCommands` or handled by a key press on a
/// real view, and the two are changed together.
///
/// It is a `let` array of value types rather than a builder, so the pane costs
/// one iteration over sixteen structs.
nonisolated struct SettingsShortcut: Identifiable, Sendable {
    var id: String { keys }
    /// Written the way the menu bar writes it, so the two match on screen.
    var keys: String
    var action: String

    /// The keys a view answers, which are not menu items and cannot be moved.
    ///
    /// **Everything that CAN be rebound left this table** — it is
    /// `AppShortcut` now, which the menu reads, so a row and the key it names
    /// cannot drift. What is left is the grammar of whatever has the keyboard:
    /// Return in a composer means send, and a client that let that be moved
    /// would have a text field whose meaning depends on a setting three panes
    /// away.
    static let fixed: [SettingsShortcut] = [
        .init(keys: "↑", action: "Reply to the newest message, in an empty composer"),
        .init(keys: "⏎", action: "Send"),
        .init(keys: "⇧⏎", action: "A new line without sending"),
        .init(keys: "⇥", action: "Accept the highlighted emoji, mention or command"),
        .init(keys: "↑ ↓", action: "Move through an open list"),
        .init(keys: "⎋", action: "Dismiss the open list, card or panel"),
        .init(keys: "⌫", action: "Take back the last answered option of a command"),
        .init(keys: "⌘F", action: "Search this server or conversation"),
        .init(keys: "⌘,", action: "Settings"),
        .init(keys: "⌘1–9", action: "Nth server"),
    ]
}
