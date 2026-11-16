import SwiftUI

/// The reader, when they aren't on the board: a question mark for a place, and
/// how to get on it.
struct LeaderboardUnrankedRow: View {
    var unranked: LeaderboardCardModel.Unranked

    var body: some View {
        HStack(spacing: Spacing.snug) {
            Text("?")
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .frame(width: 30)
                .accessibilityLabel(Text("Unranked"))
            AvatarView(url: unranked.avatarURL, monogram: unranked.monogram, side: ServerHubMetrics.leaderboardAvatar)
            VStack(alignment: .leading, spacing: 1) {
                Text(unranked.name)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Text(unranked.message)
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.base)
        .background(Palette.accent.opacity(0.12), in: .rect(cornerRadius: Radius.chip))
        .overlay { RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Palette.accent.opacity(0.3), lineWidth: 1) }
        .padding(.top, Spacing.tight)
        .accessibilityElement(children: .combine)
    }
}
