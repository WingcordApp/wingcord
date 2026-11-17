import SwiftUI

/// The top three on their podium: 2nd, 1st, 3rd from left to right, the winner
/// taller and lit — Discord's "podium" state (`tb`, `.podium_i8iX4X`), measured
/// value for value: a 230-point stage, columns 8 apart, the star field behind.
///
/// **Content, not chrome**: the pennants are drawn on the card's own surface
/// with no glass (HIG: "Don't use Liquid Glass in the content layer").
struct LeaderboardPodium: View {
    /// The top three, in rank order.
    var rows: [LeaderboardCardModel.Row]
    var open: (LeaderboardCardModel.Row) -> Void

    @Environment(\.motion) private var motion
    @State private var hasLanded = false
    /// The gold flash behind the winner as it lands.
    @State private var flare = false

    var body: some View {
        HStack(alignment: .center, spacing: PodiumPlace.columnGap) {
            ForEach(order, id: \.row.id) { place in
                LeaderboardPodiumPillar(
                    row: place.row,
                    place: place.place,
                    hasLanded: hasLanded,
                    open: { open(place.row) }
                )
                .background {
                    if place.place == .first { winnerFlare }
                }
            }
        }
        .frame(maxWidth: .infinity)
        // **The top three stand as rows first** (`.podiumRowExit`), then fade
        // one after another while the podium grows under them.
        .overlay(alignment: .bottom) {
            if !motion.reduceMotion {
                VStack(spacing: 2) {
                    ForEach(Array(rows.prefix(3).enumerated()), id: \.element.id) { index, row in
                        LeaderboardRowView(row: row, showsGames: false)
                            .opacity(hasLanded ? 0 : 1)
                            .animation(
                                .timingCurve(0.33, 0, 0.67, 1, duration: 0.28)
                                    .delay(PodiumPlace.hold + Double(index) * 0.1),
                                value: hasLanded
                            )
                    }
                }
                .padding(.horizontal, Spacing.base)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(height: hasLanded ? PodiumPlace.podiumHeight : PodiumPlace.collapsedHeight)
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.9).delay(PodiumPlace.hold), value: hasLanded)
        .background {
            PodiumBackdrop()
                .scaleEffect(hasLanded ? 1 : 0.7)
                .brightness(hasLanded ? 0 : 0.5)
                .opacity(hasLanded ? 1 : 0)
                .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.8).delay(PodiumPlace.hold + 0.64), value: hasLanded)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Top three"))
        .task {
            // Under Reduce Motion it is simply there, as Discord's is outside
            // `.full-motion`.
            guard !motion.reduceMotion else {
                var settled = Transaction()
                settled.disablesAnimations = true
                withTransaction(settled) { hasLanded = true }
                return
            }
            hasLanded = true
            try? await Task.sleep(for: .milliseconds(Int((PodiumPlace.hold + 0.64) * 1_000)))
            withAnimation(.easeOut(duration: 0.3)) { flare = true }
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.easeOut(duration: 0.4)) { flare = false }
        }
    }

    /// `.winnerFlare`: a soft gold glow 24 points out from the winner's column.
    private var winnerFlare: some View {
        RadialGradient(
            colors: [Color(red: 1, green: 196 / 255, blue: 64 / 255).opacity(0.55), .clear],
            center: .center,
            startRadius: 0,
            endRadius: 110
        )
        .padding(-24)
        .scaleEffect(flare ? 1 : 0.8)
        .opacity(flare ? 1 : 0)
        .allowsHitTesting(false)
    }

    /// 2nd, 1st, 3rd: the winner in the middle.
    private var order: [(row: LeaderboardCardModel.Row, place: PodiumPlace)] {
        guard rows.count >= 3 else { return [] }
        return [(rows[1], .second), (rows[0], .first), (rows[2], .third)]
    }
}
