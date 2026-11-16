import SwiftUI

/// A leaderboard: the leaders, the reader's own place, and when it was last
/// worked out.
struct LeaderboardCardView: View {
    var board: LeaderboardCardModel
    /// How many leaders the card shows; the sheet shows them all.
    var rowLimit: Int?

    private var rows: [LeaderboardCardModel.Row] {
        guard let rowLimit, board.rows.count > rowLimit else { return board.rows }
        let leaders = Array(board.rows.prefix(rowLimit))
        // The reader stays on the card wherever they rank.
        if let reader = board.rows.first(where: \.isReader), !leaders.contains(reader) {
            return leaders + [reader]
        }
        return leaders
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 2) {
                ForEach(rows) { row in
                    LeaderboardRowView(row: row)
                }
                if let unranked = board.unranked {
                    LeaderboardUnrankedRow(unranked: unranked)
                }
            }
            .padding(Spacing.base)
            LeaderboardFooter(lastUpdated: board.lastUpdated)
        }
    }
}
