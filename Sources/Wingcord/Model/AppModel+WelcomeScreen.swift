import Foundation
import WingcordCore

// MARK: - The Welcome Screen
//
// Discord's older greeting for a new member of a Community server — "Explore
// the Server" (`954784`) — raised after an invite into a server that has one,
// and previewed from its settings page.

extension AppModel {

    /// The greeting, as drawn for this server.
    ///
    /// **Only channels that exist and the reader may open** are offered, as
    /// Discord offers only those; the settings page shows the others with
    /// Discord's warning instead.
    func welcomeScreenPresentation(
        for guildID: GuildID,
        screen: WelcomeScreen,
        serverName fallbackName: String? = nil
    ) -> WelcomeScreenPresentation {
        let guild = guilds[guildID]
        let serverEmoji = guildEmojis[guildID] ?? []
        let options = screen.channels.enumerated().compactMap { index, entry -> WelcomeScreenPresentation.Option? in
            guard let channel = channelIndex[entry.channelID], canOpen(entry.channelID) else { return nil }
            return WelcomeScreenPresentation.Option(
                id: index,
                channelID: entry.channelID,
                channelName: channel.name,
                channelSymbol: channel.kind.symbolName,
                description: entry.description,
                emoji: entry.emoji(among: serverEmoji)
            )
        }
        let name = guild?.name ?? fallbackName ?? ""
        return WelcomeScreenPresentation(
            serverName: name,
            iconURL: guild?.iconHash.flatMap {
                CDN.guildIcon(guildID: guildID, hash: $0, side: 64)
            },
            monogram: guild?.monogram ?? AppModel.monogram(of: name),
            description: screen.description,
            options: options
        )
    }

    /// An option — Discord's `transitionToGuild(guild, channel)`: the server,
    /// then the channel, and the greeting gone.
    func openWelcomeScreenChannel(_ channelID: ChannelID) {
        welcomeScreenNotice = nil
        guard canOpen(channelID) else { return }
        selectGuild(channelIndex.guildID(of: channelID))
        selectChannel(channelID)
    }

    /// Raises the greeting after a join, where Discord would.
    ///
    /// **Not over Onboarding.** Discord's own page says Onboarding "will
    /// replace Welcome Screen if enabled", and a server with it on greets its
    /// new members with its questions instead — `GUILD_ONBOARDING` is the
    /// feature that says it is on.
    func offerWelcomeScreen(_ screen: WelcomeScreen?, inGuild guildID: GuildID, features: Set<String>) {
        guard let screen, !screen.isEmpty,
              !features.contains("GUILD_ONBOARDING"),
              welcomeScreenNotice == nil
        else { return }
        welcomeScreenNotice = WelcomeScreenNotice(guildID: guildID, screen: screen)
    }
}
