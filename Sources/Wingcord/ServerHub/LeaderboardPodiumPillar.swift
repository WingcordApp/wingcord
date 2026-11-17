import SwiftUI

/// One place on the podium: a pennant with the face in its ring, the name, the
/// value, and the trophy or the medal at its foot.
///
/// Hover lists the games behind the value, as Discord's pillar does; a click
/// opens the person's profile on its Activity tab.
struct LeaderboardPodiumPillar: View {
    var row: LeaderboardCardModel.Row
    var place: Int
    var scale: CGFloat
    var open: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private var isWinner: Bool { place == 1 }
    private var size: CGSize {
        isWinner ? CGSize(width: 150 * scale, height: 206 * scale) : CGSize(width: 122 * scale, height: 168 * scale)
    }
    private var face: CGFloat { (isWinner ? 72 : 46) * scale }
    private var tone: PodiumTone { PodiumTone(place: place) }

    var body: some View {
        Button(action: open) {
            VStack(spacing: 6 * scale) {
                AvatarView(
                    url: row.largeAvatarURL ?? row.avatarURL,
                    monogram: row.isHidden ? "" : row.monogram,
                    side: face
                )
                .padding(3 * scale)
                .overlay {
                    Circle().strokeBorder(tone.rim, lineWidth: isWinner ? 3 : 2.5)
                }
                .shadow(color: tone.glow.opacity(isWinner ? 0.55 : 0.3), radius: isWinner ? 10 : 6)
                Text(row.name)
                    .font(.system(isWinner ? .headline : .subheadline, weight: .bold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 10 * scale)
                Text(row.value)
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(Ink.primary.opacity(0.85))
                    .monospacedDigit()
                Spacer(minLength: 0)
                medal
                    .padding(.bottom, (isWinner ? 34 : 30) * scale)
            }
            .padding(.top, 16 * scale)
            .frame(width: size.width, height: size.height)
            .background {
                PodiumPillarShape(point: 26 * scale)
                    .fill(LinearGradient(colors: tone.fill, startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                PodiumPillarShape(point: 26 * scale)
                    .strokeBorder(tone.rim.opacity(0.9), lineWidth: isWinner ? 1.5 : 1)
            }
            // The winner's light, kept soft (Alex: glow restrained).
            .shadow(color: tone.glow.opacity(isWinner ? 0.35 : 0), radius: 18)
            .contentShape(PodiumPillarShape(point: 26 * scale))
            .scaleEffect(isHovering ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .disabled(row.isHidden)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .help(row.playedSummary ?? row.name)
        .accessibilityLabel(Text("Rank \(place), \(row.name), \(row.value)"))
        .accessibilityHint(Text("Opens their profile"))
    }

    @ViewBuilder
    private var medal: some View {
        if isWinner {
            Image(systemName: "trophy.fill")
                .font(.system(size: 26 * scale))
                .foregroundStyle(LinearGradient(colors: tone.medal, startPoint: .top, endPoint: .bottom))
                .shadow(color: tone.glow.opacity(0.5), radius: 4)
                .accessibilityHidden(true)
        } else {
            LeaderboardRankBadge(rank: place)
                .accessibilityHidden(true)
        }
    }
}
