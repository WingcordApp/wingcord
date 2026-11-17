import SwiftUI

/// The top three on their podium: 2nd, 1st, 3rd from left to right, the winner
/// taller and lit (Discord's "podium" state, docs/ACTIVITIES-CALLS-PICKER.md
/// decision 19).
///
/// **Content, not chrome**: the pillars sit on the card's own material with a
/// quiet star field behind them, no glass (HIG: "Don't use Liquid Glass in the
/// content layer").
struct LeaderboardPodium: View {
    /// The top three, in rank order.
    var rows: [LeaderboardCardModel.Row]
    /// The card's smaller podium, or the full view's.
    var isCompact: Bool
    var open: (LeaderboardCardModel.Row) -> Void

    var body: some View {
        ZStack {
            LeaderboardPodiumBackdrop()
            HStack(alignment: .center, spacing: isCompact ? 10 : 16) {
                ForEach(order, id: \.row.id) { place in
                    LeaderboardPodiumPillar(
                        row: place.row,
                        place: place.number,
                        scale: isCompact ? 0.82 : 1,
                        open: { open(place.row) }
                    )
                }
            }
            .padding(.vertical, isCompact ? Spacing.margin : Spacing.group)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Top three"))
    }

    /// 2nd, 1st, 3rd: the winner in the middle.
    private var order: [(row: LeaderboardCardModel.Row, number: Int)] {
        guard rows.count >= 3 else { return rows.enumerated().map { ($1, $0 + 1) } }
        return [(rows[1], 2), (rows[0], 1), (rows[2], 3)]
    }
}
