import SwiftUI

/// The hub's one sheet, by what it was opened for.
struct ServerHubSheetContent: View {
    var sheet: ServerHubSheet
    var presentation: ServerHubPresentation

    var body: some View {
        switch sheet {
        case .addWidget(let column, let index):
            AddWidgetSheet(guildID: presentation.guildID, column: column, index: index)
        case .leaderboard:
            // Never a sheet: see `ServerHubLeaderboardPresenter`.
            EmptyView()
        case .imageText(let widgetID):
            ImageTextEditorSheet(widgetID: widgetID)
        case .whiteboardAccess:
            WhiteboardAccessSheet(guildID: presentation.guildID)
        }
    }

    private func widget(_ id: String) -> ServerHubPresentation.Widget? {
        presentation.columns.joined().first { $0.id == id }
    }
}
