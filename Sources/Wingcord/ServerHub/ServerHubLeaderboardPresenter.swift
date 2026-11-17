import SwiftUI

/// The full leaderboard, over the window.
///
/// **Its own layer, under the profiles** (docs/ACTIVITIES-CALLS-PICKER.md,
/// decision 22). It was a system sheet, which is a window of its own, and a
/// profile opened from one of its rows came up in the main window, behind it.
/// Discord stacks the profile modal on top of its leaderboard modal; attached
/// before `presentsProfiles()` at the root, this does the same, and Escape or
/// the ✕ under the profile comes back to the leaderboard.
struct ServerHubLeaderboardPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                if let widget = expandedWidget {
                    // Outside the card closes it, as a modal's scrim does; and
                    // Escape, unless a profile is up over it (the profile
                    // answers Escape then).
                    Button(action: close) {
                        Color.black.opacity(0.5).ignoresSafeArea()
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(model.profileRequest == nil ? .cancelAction : nil)
                    .accessibilityLabel(Text("Close"))
                    .transition(.opacity)

                    LeaderboardPanel(widget: widget, close: close)
                        .padding(Spacing.section)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
            .animation(motion.panel, value: model.serverHub.expandedLeaderboard)
            .onChange(of: model.selectedGuildID) {
                if model.serverHub.expandedLeaderboard != nil { close() }
            }
        }
    }

    private var expandedWidget: ServerHubPresentation.Widget? {
        guard let id = model.serverHub.expandedLeaderboard,
              let presentation = model.serverHubPresentation
        else { return nil }
        return presentation.columns.joined().first { $0.id == id }
    }

    private func close() {
        model.serverHub.expandedLeaderboard = nil
    }
}

extension View {
    /// The Server Hub's full leaderboard. Before `presentsProfiles()`.
    func presentsServerHubLeaderboard() -> some View {
        modifier(ServerHubLeaderboardPresenter())
    }
}
