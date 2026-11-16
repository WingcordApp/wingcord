import SwiftUI

/// What a card holds, by what it is and how far its data has come.
struct ServerHubCardBody: View {
    var widget: ServerHubPresentation.Widget
    var isWide: Bool

    var body: some View {
        switch widget.content {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 140)
        case .failed:
            ServerHubWidgetMessage(
                symbol: "exclamationmark.triangle",
                title: "This widget didn\u{2019}t load",
                detail: "Discord didn\u{2019}t answer. Leave and come back to try again."
            )
        case .awaitingSave(let title, let detail):
            ServerHubWidgetMessage(symbol: widget.symbolName ?? "square.dashed", title: title, detail: detail)
        case .notEnoughData(let title, let detail):
            ServerHubWidgetMessage(symbol: "chart.bar.xaxis", title: title, detail: detail)
        case .leaderboard(let board):
            LeaderboardCardView(board: board, rowLimit: 5)
        case .popularGames(let games):
            PopularGamesCardView(games: games)
        case .popularMusic(let music):
            PopularMusicCardView(music: music)
        case .imageText(let content):
            ImageTextCardView(content: content, isWide: isWide, widgetID: widget.id)
        case .whiteboard(let board):
            WhiteboardCardView(board: board)
        }
    }
}
