import SwiftUI

// MARK: - The settings window
//
// A standard window (DESIGN-NOTES decision 16): the system's split view, a
// sidebar list of the sections with its search field, and the selected pane
// beside it under the window's own toolbar — the shape of the system's own
// Settings app.
//
// The HIG's settings rules, and where each one is kept:
//
//   - opened from the App menu with ⌘, — `WingcordCommands`;
//   - "Update the window's title to reflect the currently visible pane" — the
//     detail pane's `navigationTitle`;
//   - "Dim a settings window's minimize and maximize buttons" — minimize and
//     full screen are off below. The window still resizes, because the panes
//     are scrolling pages of very different lengths rather than panes the
//     window can fit itself to;
//   - "Restore the most recently viewed pane" — `SettingsWindow.lastSection`.
//
// **A sidebar rather than the HIG's usual toolbar of panes**, because there are
// twenty of them: a toolbar holds seven or eight before it overflows, and the
// system's own Settings app moved to a sidebar for the same reason.

struct SettingsView: View {
    @State private var history: SettingsHistory
    @State private var query = ""

    init() {
        _history = State(initialValue: SettingsHistory(SettingsWindow.lastSection))
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: sectionBinding, query: $query)
                .navigationSplitViewColumnWidth(
                    min: SettingsMetrics.sidebarMinWidth,
                    ideal: SettingsMetrics.sidebarWidth,
                    max: SettingsMetrics.sidebarMaxWidth
                )
        } detail: {
            SettingsDetailPane(history: history)
        }
        .environment(\.settingsNavigate, SettingsNavigate { history.go(to: $0) })
        .frame(
            minWidth: SettingsMetrics.minWidth,
            minHeight: SettingsMetrics.minHeight
        )
        .windowMinimizeBehavior(.disabled)
        .windowFullScreenBehavior(.disabled)
        // A caller that asked for a page gets it — when the window appears, and
        // when it is asked again while already open.
        .onAppear { takePendingSection() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindow.didRequestSection)) { _ in
            takePendingSection()
        }
        .onChange(of: history.current) { _, section in
            SettingsWindow.lastSection = section
        }
    }

    /// Moves to the page an outside caller asked for, if one did.
    ///
    /// Through the history, so the back button can undo it — the same rule the
    /// sidebar follows.
    private func takePendingSection() {
        guard let section = SettingsWindow.takePendingSection() else { return }
        history.go(to: section)
    }

    /// The sidebar writes through the history rather than to a stored section,
    /// so a click on a row is a move the back button can undo.
    private var sectionBinding: Binding<SettingsSection?> {
        Binding(
            get: { history.current },
            set: { section in
                if let section { history.go(to: section) }
            }
        )
    }
}

// MARK: - The detail pane

/// The pane is ONE view type and always has been — §1. Every section is a case
/// inside it, never a branch in the caller, so macOS never re-resolves the
/// column split on a selection change.
private struct SettingsDetailPane: View {
    var history: SettingsHistory

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.motion) private var motion

    private var section: SettingsSection { history.current }

    var body: some View {
        ScrollView(.vertical) {
            SettingsPaneContent(section: section)
                .padding(SettingsMetrics.cardInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle(section.title)
        .toolbar {
            // Back and forward, where the system's own Settings and the Finder
            // keep them, with the Finder's keys.
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.left", action: history.goBack)
                    .disabled(!history.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward", systemImage: "chevron.right", action: history.goForward)
                    .disabled(!history.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
            }
            if let action = SettingsPaneAction(section: section) {
                ToolbarItem(placement: .primaryAction) {
                    Button(action.title, systemImage: action.symbolName) {
                        action.perform(model, openURL)
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
        }
        .animation(motion.standard, value: section)
    }
}

/// The one action a pane offers, in the toolbar's trailing slot. Four panes
/// have one; the rest leave the slot empty rather than drawing an empty item.
private struct SettingsPaneAction {
    var title: String
    var symbolName: String
    var perform: @MainActor (AppModel, OpenURLAction) -> Void

    init?(section: SettingsSection) {
        switch section {
        case .account:
            title = "Sign Out"
            symbolName = "rectangle.portrait.and.arrow.right"
            perform = { model, _ in model.signOut() }
        case .diagnostics:
            title = "Reveal Logs"
            symbolName = "folder"
            perform = { _, _ in
                NSWorkspace.shared.activateFileViewerSelecting([CrashReporter.reportDirectory])
            }
        case .connectedApps:
            title = "Refresh"
            symbolName = "arrow.clockwise"
            perform = { model, _ in model.sessionController.refreshConnectedApps() }
        case .about:
            title = "Release Notes"
            symbolName = "doc.text"
            perform = { _, openURL in
                if let url = URL(string: "https://github.com/wingcord/wingcord/releases") {
                    openURL(url)
                }
            }
        default:
            return nil
        }
    }
}
