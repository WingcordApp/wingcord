import WingcordCore

/// Which of Discord's marks (`DiscordBrandIcon`) names a store or a game's link
/// — Discord's own pairs: its store buttons' `icon` (`SteamNeutralIcon`, …)
/// and its links row's switch over a website's category.
extension GameStore {
    var discordIcon: DiscordBrandIcon {
        switch self {
        case .steam: .steam
        case .xboxGamePass: .xbox
        case .epicGames: .epicGames
        case .roblox: .roblox
        case .battleNet: .battlenet
        case .riot: .riotGames
        case .minecraft: .minecraft
        }
    }
}

extension GameLinkCategory {
    /// The mark the links row draws; the globe for the official page and for
    /// anything Discord's row has no mark of its own for.
    var discordIcon: DiscordBrandIcon {
        switch self {
        case .twitter: .x
        case .youtube: .youtube
        case .facebook: .facebook
        case .instagram: .instagram
        case .bluesky: .bluesky
        case .reddit: .reddit
        case .twitch: .twitch
        case .itch: .itch
        case .wikia: .fandom
        case .iphone, .ipad: .apple
        case .android: .googlePlay
        case .roblox: .roblox
        case .steam: .steam
        case .epicGames: .epicGames
        case .battleNet: .battlenet
        case .riot: .riotGames
        case .minecraft: .minecraft
        case .official, .wikipedia, .gog, .discord: .globe
        }
    }
}
