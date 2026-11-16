import Foundation

/// What a server's members played this past week — the Popular Games widget.
public struct GuildSpacePopularGames: Hashable, Sendable {
    /// Members who played anything, for the faces in the footer.
    public var userIDs: [UserID]
    /// The games, most played first.
    public var games: [Game]
    /// How many members played: "64 members played 9,278 games".
    public var totalUsers: Int
    public var totalGames: Int

    public struct Game: Hashable, Sendable, Identifiable {
        public var applicationID: ApplicationID
        public var userIDs: [UserID]

        public var id: ApplicationID { applicationID }

        public init(applicationID: ApplicationID, userIDs: [UserID]) {
            self.applicationID = applicationID
            self.userIDs = userIDs
        }
    }

    public init(userIDs: [UserID], games: [Game], totalUsers: Int, totalGames: Int) {
        self.userIDs = userIDs
        self.games = games
        self.totalUsers = totalUsers
        self.totalGames = totalGames
    }

    /// Discord's empty rule (`lu`): no games, or fewer than three players.
    public var hasEnoughData: Bool { !games.isEmpty && totalUsers >= 3 }
}
