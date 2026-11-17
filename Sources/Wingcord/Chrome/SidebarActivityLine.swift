import SwiftUI

/// "Wordle · 3 playing" under a voice room, with the app's icon.
struct SidebarActivityLine: View {
    var activity: SidebarChannelActivity

    var body: some View {
        HStack(spacing: Spacing.tight) {
            RemoteImage(url: activity.iconURL, side: 16) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
            }
            .frame(width: 16, height: 16)
            .clipShape(.rect(cornerRadius: 4, style: .continuous))
            Text(activity.name)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            if activity.playerCount > 0 {
                Text("\u{00B7} \(activity.playerCount) playing")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
