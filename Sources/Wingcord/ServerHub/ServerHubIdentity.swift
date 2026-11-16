import SwiftUI

/// The server's icon, name and counts, over the banner's dimming.
///
/// **White ink, on purpose**: it always sits on the dimmed foot of a picture,
/// never on the app's ground, so the light and dark inks would be wrong here.
struct ServerHubIdentity: View {
    var header: ServerHubPresentation.Header

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.margin) {
            ServerHubServerIcon(url: header.iconURL, monogram: header.monogram)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(header.name)
                    .font(.system(.title, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                HStack(spacing: Spacing.margin) {
                    if let online = header.onlineCount {
                        ServerHubStat(
                            text: "\(online.formatted()) Online",
                            dot: Palette.presenceOnline
                        )
                    }
                    if let members = header.memberCount {
                        ServerHubStat(
                            text: GuildSpaceFormatting.count(members, "Member", "Members"),
                            dot: .white.opacity(0.7)
                        )
                    }
                    ServerHubStat(
                        text: GuildSpaceFormatting.count(header.boostCount, "Boost", "Boosts"),
                        systemImage: "diamond.fill"
                    )
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
