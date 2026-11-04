import SwiftUI
import WingcordCore

// MARK: - Server Insights
//
// Discord's page (`cf`): two paragraphs about what Insights holds, and the way
// to it — "Server Insights is hosted on a separate website", the developer
// portal's `/developers/servers/{id}`. Every word is Discord's.
//
// **The four weekly numbers Discord shows under it are not drawn.** They come
// from `GET /guilds/{id}/analytics/overview`, whose answer has not been
// captured, and a card of guessed field names is a card of zeros.

struct ServerInsightsPane: View {
    let guildID: GuildID

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            Text("We\u{2019}ve put together a bunch of helpful data to help you better run your community. Learn how active your community is, where new members are coming from, and much more. Use what you learn to make informed decisions to improve your server\u{2019}s engagement!")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Analytics about Announcement Channels, Server Discovery, and Welcome Screen also live here.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsCard {
                DescribedRow(
                    "Server Insights",
                    detail: Text("Server Insights is hosted on a separate website so that it\u{2019}s easier to share links and browse cross platform.")
                ) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 32, height: 32)
                        .background(SettingsSurface.controlTrough, in: .circle)
                } trailing: {
                    if let url = URL(string: "https://discord.com/developers/servers/\(guildID.rawValue)") {
                        Link("Go to Server Insights", destination: url)
                            .buttonStyle(.glassProminent)
                            .buttonBorderShape(.capsule)
                            .tint(Palette.accent)
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}
