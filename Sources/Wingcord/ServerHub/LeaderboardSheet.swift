import SwiftUI

/// A leaderboard, full size: every place on it, and the reader's.
struct LeaderboardSheet: View {
    var widget: ServerHubPresentation.Widget?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.base) {
                Image(systemName: "trophy")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                Text(widget?.title ?? "Leaderboard")
                    .font(.system(.title3, weight: .bold))
                if let accessory = widget?.accessory {
                    Text(accessory)
                        .font(.system(.caption, weight: .bold))
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Palette.accent.opacity(0.16), in: .capsule)
                        .help(widget?.accessoryHelp ?? accessory)
                }
                Spacer()
            }
            .padding(Spacing.group)
            Divider()
            if case .leaderboard(let board) = widget?.content {
                ScrollView {
                    LeaderboardCardView(board: board, rowLimit: nil)
                }
                .frame(minHeight: 360)
            } else {
                ContentUnavailableView("Nothing to show yet", systemImage: "trophy")
                    .frame(minHeight: 360)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Spacing.margin)
        }
        .frame(width: 620, height: 640)
    }

    private func close() {
        dismiss()
    }
}
