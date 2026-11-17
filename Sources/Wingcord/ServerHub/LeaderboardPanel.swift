import SwiftUI

/// A leaderboard full size: the trophy, its title and badge, the round glass ✕,
/// then every place on it (the podium on its last day) and the reader's own.
struct LeaderboardPanel: View {
    var widget: ServerHubPresentation.Widget
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.base) {
                Image(systemName: "trophy")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .accessibilityHidden(true)
                Text(widget.title)
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(Ink.primary)
                    .accessibilityAddTraits(.isHeader)
                if let accessory = widget.accessory {
                    ServerHubBadge(
                        text: accessory,
                        help: widget.accessoryHelp ?? accessory,
                        isMuted: widget.accessoryIsMuted
                    )
                }
                Spacer(minLength: Spacing.base)
                // The scrim answers Escape; the ✕ is the pointer's way out.
                ModalCloseButton(answersEscape: false, action: close)
            }
            .padding(.horizontal, Spacing.group)
            .padding(.vertical, Spacing.margin)
            Rectangle().fill(Ink.quaternary).frame(height: 1)
            if case .leaderboard(let board) = widget.content {
                // The list scrolls itself, taller here (Discord's in-modal
                // 560), so the reader's own row can float as it does on the card.
                LeaderboardCardView(board: board, isExpanded: true)
            } else {
                ContentUnavailableView("Nothing to show yet", systemImage: "trophy")
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 640)
        .frame(maxHeight: 720)
        .modifier(ModalCardChrome())
    }
}
