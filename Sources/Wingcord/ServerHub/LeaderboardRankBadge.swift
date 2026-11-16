import SwiftUI

/// A place: gold, silver and bronze medals for the podium, a plain number after.
///
/// **Shape and number, not colour alone** (HIG: "Avoid relying solely on
/// color"): every medal carries its place, so the three read apart without
/// telling gold from bronze.
struct LeaderboardRankBadge: View {
    var rank: Int

    private static let side: CGFloat = 26

    var body: some View {
        ZStack {
            if let colors = medal {
                Image(systemName: "seal.fill")
                    .font(.system(size: Self.side))
                    .foregroundStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                    .shadow(color: colors[1].opacity(0.45), radius: 4, y: 1)
                Text("\(rank)")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1)
            } else {
                Text("\(rank)")
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .monospacedDigit()
            }
        }
        .frame(width: Self.side + 4, height: Self.side + 4)
        .accessibilityLabel(Text("Rank \(rank)"))
    }

    private var medal: [Color]? {
        switch rank {
        case 1: [Color(hex: 0xFFD966), Color(hex: 0xE8A317)]
        case 2: [Color(hex: 0xE3E8EF), Color(hex: 0x9AA5B4)]
        case 3: [Color(hex: 0xF4B07A), Color(hex: 0xB86B2E)]
        default: nil
        }
    }
}
