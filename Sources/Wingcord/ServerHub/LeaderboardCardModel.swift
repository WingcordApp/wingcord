import Foundation
import WingcordCore

/// A leaderboard, resolved for drawing: names, faces, games and values.
struct LeaderboardCardModel: Equatable {
    var stat: GuildSpaceLeaderboard.Stat
    /// From the competition's last day on, the top three on their podium
    /// (Discord's "podium" state, decision 19), in rank order. Empty otherwise.
    var podium: [Row] = []
    /// The top twenty (from 4th when there's a podium), then the reader where
    /// they rank below them.
    var rows: [Row]
    /// The reader, when they aren't on the board at all.
    var unranked: Unranked?
    var lastUpdated: Date?

    struct Row: Equatable, Identifiable {
        var id: UserID
        var rank: Int
        var name: String
        var nameColor: UInt32?
        /// The face they chose for their name — Discord's leaderboard draws it
        /// (`displayNameStylesFont`) in their role colour, without the effect.
        var nameFont: DisplayNameFont?
        var avatarURL: URL?
        /// The face at the podium's size, for the top three.
        var largeAvatarURL: URL?
        var monogram: String
        /// "Last played Fortnite".
        var lastPlayed: String?
        var value: String
        /// The time behind a count of days or games.
        var detail: String?
        var valueSymbol: String
        var games: [Game]
        /// Games past the ones shown: "+3".
        var moreGames: Int
        var isReader: Bool
        /// Blocked or ignored: drawn without a face or a game.
        var isHidden: Bool
        /// "Played Honkai: Star Rail, ROBLOX and 3 others", in Discord's
        /// words: the games tooltip on a pillar and on the games stack.
        var playedSummary: String?
    }

    struct Game: Equatable, Identifiable {
        var id: ApplicationID
        var name: String
        var iconURL: URL?
    }

    struct Unranked: Equatable {
        var name: String
        var avatarURL: URL?
        var monogram: String
        var message: String
    }
}
