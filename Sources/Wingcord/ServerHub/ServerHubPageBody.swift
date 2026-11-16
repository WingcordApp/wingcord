import SwiftUI

/// What sits under the banner: the widgets, or why there are none.
struct ServerHubPageBody: View {
    var presentation: ServerHubPresentation

    @Environment(AppModel.self) private var model

    var body: some View {
        switch presentation.phase {
        case .loading:
            SurfaceLoadingState(message: "Opening the Server Hub\u{2026}")
        case .failed:
            VStack(spacing: Spacing.snug) {
                SurfaceEmptyState(
                    symbol: "wifi.exclamationmark",
                    title: "The Server Hub didn\u{2019}t load",
                    detail: "Check your connection, then try again."
                )
                Button("Try Again", action: retry)
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
        case .missing:
            SurfaceEmptyState(
                symbol: "house",
                title: "No Server Hub yet",
                detail: "This server hasn\u{2019}t set up its Server Hub."
            )
        case .ready:
            ServerHubGrid(presentation: presentation)
        }
    }

    private func retry() {
        model.retryServerHub(presentation.guildID)
    }
}
