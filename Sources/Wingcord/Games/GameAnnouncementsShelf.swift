import SwiftUI
import WingcordCore

/// Recent posts from the game's own server — Discord's Community Announcements
/// on a game's profile (`nJ`, `1b720c29…`).
///
/// **Cards the size of Discord's**: about two to a row (44 % of the shelf),
/// up to 328 points tall, a 16∶9 picture, the post's heading as a one-line
/// title and its words rendered under it, the date and the reactions at the
/// foot. They step one card at a time, snapping to a card's edge, with arrows
/// that come up under the pointer.
struct GameAnnouncementsShelf: View {
    var announcements: [GameAnnouncementCard]
    /// Opens the whole channel. **Always available**: the reader does not have
    /// to be in the server, because opening it starts a preview — see
    /// `AppModel.openAnnouncement`.
    var openChannel: (() -> Void)?
    /// Opens one post where it was made.
    var openMessage: ((MessageID) -> Void)?
    /// The announcements' own server's mention table, so a role in a post is
    /// named where this session knows the server.
    var mentions: MentionContext?
    /// Where a link in a post goes.
    var openLink: ((String) -> Void)?

    @Environment(\.motion) private var motion
    @State private var leading: MessageID?
    @State private var isHovering = false

    /// Discord's `max-height`, which every card here is.
    static let cardHeight: CGFloat = 328
    private static let gap: CGFloat = 16

    private var leadingIndex: Int {
        leading.flatMap { id in announcements.firstIndex { $0.id == id } } ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            header
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Self.gap) {
                    ForEach(announcements) { announcement in
                        GameAnnouncementCardView(
                            announcement: announcement,
                            mentions: mentions,
                            open: openMessage.map { open in { open(announcement.id) } },
                            openLink: openLink
                        )
                        // `calc(44% - var(--space-sm) / 2)`, and never so narrow
                        // that a title has no room.
                        .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in
                            max(280, length * 0.44 - Self.gap / 2)
                        }
                        .frame(height: Self.cardHeight)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $leading, anchor: .leading)
            .overlay(alignment: .leading) { stepButton(forward: false) }
            .overlay(alignment: .trailing) { stepButton(forward: true) }
            .onHover { hovering in
                guard isHovering != hovering else { return }
                isHovering = hovering
            }
            .animation(motion.hover, value: isHovering)
            .animation(motion.hover, value: leadingIndex)
        }
    }

    private var header: some View {
        HStack {
            Text("Community Announcements")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(InkColor.primary)
            Spacer(minLength: Spacing.base)
            if let openChannel {
                Button(action: openChannel) {
                    HStack(spacing: 3) {
                        Text("View All")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(InkColor.primary)
                    .padding(.horizontal, Spacing.snug)
                    .padding(.vertical, 5)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .interactiveChrome()
            }
        }
    }

    /// One card along, in either direction — a glass circle at the shelf's
    /// edge while the pointer is over it and there is somewhere to go.
    @ViewBuilder
    private func stepButton(forward: Bool) -> some View {
        let target = leadingIndex + (forward ? 1 : -1)
        // Two cards are on screen at a time, so the last step forward is the
        // one that brings the final card fully in.
        let canGo = forward ? leadingIndex < announcements.count - 2 : leadingIndex > 0
        if isHovering, canGo, announcements.indices.contains(target) {
            Button {
                withAnimation(motion.reposition) { leading = announcements[target].id }
            } label: {
                Image(systemName: forward ? "arrow.right" : "arrow.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(InkColor.solid)
                    .frame(width: 40, height: 40)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .padding(.horizontal, Spacing.base)
            .help(forward ? "Next announcement" : "Previous announcement")
            .accessibilityLabel(Text(forward ? "Next announcement" : "Previous announcement"))
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}
