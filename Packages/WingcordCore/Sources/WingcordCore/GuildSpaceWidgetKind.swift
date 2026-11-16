import Foundation

/// What a Server Hub widget is — Discord's `GuildSpaceWidgetType`.
///
/// **An open set.** Discord adds kinds; one this client doesn't know is kept,
/// saved back exactly as it came and simply not drawn, so editing a hub here
/// never deletes somebody's widget.
public struct GuildSpaceWidgetKind: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let leaderboard = Self(rawValue: "leaderboard")
    public static let whiteboard = Self(rawValue: "whiteboard")
    public static let popularMusic = Self(rawValue: "popular_music")
    public static let imageText = Self(rawValue: "image_text")
    public static let popularGames = Self(rawValue: "popular_games")

    /// The kinds this client draws.
    public static let drawn: Set<Self> = [.leaderboard, .whiteboard, .popularMusic, .imageText, .popularGames]

    /// Whether this client draws it.
    public var isDrawn: Bool { Self.drawn.contains(self) }
}
