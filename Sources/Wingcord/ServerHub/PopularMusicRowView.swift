import SwiftUI

/// One song, artist or listener, with its rank and its plays.
struct PopularMusicRowView: View {
    var row: PopularMusicCardModel.Row

    private let side = ServerHubMetrics.musicArt

    var body: some View {
        HStack(spacing: Spacing.snug) {
            Text("\(row.rank)")
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .monospacedDigit()
                .frame(width: 20)
            art
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(.callout))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.base)
            Text(row.plays)
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, Spacing.base)
        .frame(minHeight: 50)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var art: some View {
        if row.isPerson {
            AvatarView(url: row.imageURL, monogram: row.monogram, side: side)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Palette.accent.opacity(0.22))
                Text(row.monogram)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.accent)
                RemoteImage(url: row.imageURL, side: side) { Color.clear }
                    .scaledToFill()
            }
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: 8))
        }
    }
}
