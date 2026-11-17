import SwiftUI

/// A leaderboard: the leaders, the reader's own place, and when it was last
/// worked out.
///
/// **On its last day the top three stand on a podium** (decision 19): the card
/// shows the podium and the reader's own row, as Discord's does; the full view
/// adds everybody from 4th down.
struct LeaderboardCardView: View {
    var board: LeaderboardCardModel
    /// How many leaders the card shows; the full view shows them all.
    var rowLimit: Int?

    @Environment(AppModel.self) private var model

    private var rows: [LeaderboardCardModel.Row] {
        // The card with a podium: only the reader's own place under it.
        if !board.podium.isEmpty, rowLimit != nil {
            return board.rows.filter(\.isReader)
        }
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
            if !board.podium.isEmpty {
                LeaderboardPodium(rows: board.podium, isCompact: rowLimit != nil, open: open)
            }
            VStack(spacing: 2) {
                ForEach(rows) { row in
                    Button {
                        open(row)
                    } label: {
                        LeaderboardRowView(row: row)
                    }
                    .buttonStyle(.plain)
                    .disabled(row.isHidden)
                    .accessibilityHint(Text("Opens their profile"))
                }
                if let unranked = board.unranked {
                    LeaderboardUnrankedRow(unranked: unranked)
                }
            }
            .padding(Spacing.base)
            LeaderboardFooter(lastUpdated: board.lastUpdated)
        }
    }

    /// A place opens the person's profile on its Activity tab, as Discord's
    /// row does (`openUserProfileModal`, RECENT_ACTIVITY), over whatever
    /// raised it.
    private func open(_ row: LeaderboardCardModel.Row) {
        model.openProfile(row.id, anchor: .zero, depth: .full, tab: .activity)
    }
}
