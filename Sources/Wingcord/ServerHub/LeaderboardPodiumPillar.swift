import SwiftUI

/// One place on the podium, laid out as Discord's (`tN`, `.pillarColumn`): the
/// pennant behind it, the face in its ring, the name, the value, and the medal
/// — or the winner's trophy — at its foot.
///
/// Resting on it shows what they played (`LeaderboardPlayedCard`), as
/// Discord's pillar tooltip does; a click opens their profile on its Activity
/// tab.
struct LeaderboardPodiumPillar: View {
    var row: LeaderboardCardModel.Row
    var place: PodiumPlace
    /// The podium's entrance has run (`LeaderboardPodium`).
    var hasLanded: Bool
    var open: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false
    @State private var showsGames = false

    /// `.pillarColumn`'s padding and gap.
    private static let padding: CGFloat = 8
    private static let gap: CGFloat = 4

    var body: some View {
        Button(action: open) {
            content
                .padding(.top, Self.padding + (row.detail == nil ? 8 : 0))
                .padding(.horizontal, Self.padding)
                .frame(width: place.columnSize.width, height: place.columnSize.height, alignment: .top)
                .background(alignment: .topLeading) { card }
                .overlay(alignment: .topLeading) { medal }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(row.isHidden)
        .overlay(alignment: tooltipAlignment) {
            if showsGames {
                LeaderboardPlayedCard(row: row)
                    .alignmentGuide(.top) { $0[.bottom] - metricsTop + 6 }
                    .transition(.materialize(from: .bottom, blurring: false))
            }
        }
        .zIndex(showsGames ? 2 : (place == .first ? 1 : 0))
        .modifier(PodiumEntrance(place: place, hasLanded: hasLanded))
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
            if !hovering { showsGames = false }
        }
        // Discord's tooltip waits a beat, so sweeping across the podium
        // doesn't flash three cards.
        .task(id: isHovering) {
            guard isHovering, !row.isHidden else { return }
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            showsGames = true
        }
        .animation(motion.hover, value: showsGames)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Rank \(place.rawValue), \(row.name), \(row.value)"))
        .accessibilityHint(Text(row.playedSummary.map { "\($0). Opens their profile." } ?? "Opens their profile."))
        .accessibilityAddTraits(.isButton)
    }

    private var content: some View {
        VStack(spacing: Self.gap) {
            AvatarView(
                url: row.largeAvatarURL ?? row.avatarURL,
                monogram: row.isHidden ? "" : row.monogram,
                side: place.avatarSide
            )
            .overlay(alignment: .topLeading) {
                PodiumRing(place: place)
                    .offset(x: place.ringFrame.minX, y: place.ringFrame.minY)
            }
            VStack(spacing: 2) {
                LeaderboardName(row: row, size: 14)
                Text(row.value)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ink.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .modifier(PodiumContentEntrance(place: place, hasLanded: hasLanded))
    }

    /// The pennant, drawn out past the column for the winner's glow.
    private var card: some View {
        let spec = PodiumCardSpec.forPlace(place)
        return PodiumCard(place: place)
            .frame(width: spec.frame.width, height: spec.frame.height)
            .offset(x: spec.frame.minX, y: spec.frame.minY)
    }

    private var medal: some View {
        LeaderboardMedal(rank: place.rawValue, isTrophy: place == .first)
            .modifier(PodiumMedalEntrance(place: place, hasLanded: hasLanded))
            .offset(x: (place.columnSize.width - PodiumPlace.medalSide) / 2, y: place.medalTop)
    }

    /// Where the value line starts, from the column's top: the games card's
    /// foot sits just above it, as Discord's tooltip sits above the value.
    private var metricsTop: CGFloat {
        Self.padding + (row.detail == nil ? 8 : 0) + place.avatarSide + Self.gap + 18 + 2
    }

    /// The card hangs over the podium, kept inside the leaderboard's edges:
    /// second's from its leading side, third's from its trailing side.
    private var tooltipAlignment: Alignment {
        switch place {
        case .first: .top
        case .second: .topLeading
        case .third: .topTrailing
        }
    }
}
