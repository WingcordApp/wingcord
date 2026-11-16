import Foundation

/// What the hydrate route answered for one widget.
///
/// **Told apart by shape, not by a type field**: Discord's answer is
/// `{id, data}` with nothing saying which kind of data it is, and the widget
/// whose id it carries is what gives it a meaning.
public enum GuildSpaceHydration: Hashable, Sendable {
    case leaderboard(GuildSpaceLeaderboard)
    case popularGames(GuildSpacePopularGames)
    case popularMusic(GuildSpacePopularMusic)
    /// An answer for a kind this client doesn't draw.
    case other
}
