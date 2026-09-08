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

    static let groups: [(title: String, shortcuts: [SettingsShortcut])] = [
        ("Going somewhere", [
            .init(keys: "⌘K", action: "Quick switcher"),
            .init(keys: "⌥↑", action: "Previous channel"),
            .init(keys: "⌥↓", action: "Next channel"),
            .init(keys: "⌥⌘↑", action: "Previous server"),
            .init(keys: "⌥⌘↓", action: "Next server"),
            .init(keys: "⌘0", action: "Direct messages"),
            .init(keys: "⌘1–9", action: "Nth server"),
        ]),
        ("Writing", [
            .init(keys: "↑", action: "Reply to the newest message, in an empty composer"),
            .init(keys: "⏎", action: "Send"),
            .init(keys: "⇥", action: "Accept the highlighted emoji"),
            .init(keys: "⎋", action: "Dismiss the emoji list, or the open card"),
        ]),
        ("Windows", [
            .init(keys: "⌘,", action: "Settings"),
            .init(keys: "⌘W", action: "Close the window"),
            .init(keys: "⌘M", action: "Minimise"),
        ]),
        ("In this window", [
            .init(keys: "↑ ↓", action: "Move through the sections"),
            .init(keys: "⌘F", action: "Search the sections"),
        ]),
    ]
}
