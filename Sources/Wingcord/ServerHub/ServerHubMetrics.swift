import CoreGraphics

/// The Server Hub's measurements, in one place (swiftui-pro: one shared set of
/// constants, so the page stays of a piece and can be tuned in one edit).
enum ServerHubMetrics {
    /// The page's widest: two columns and their gap.
    static let pageWidth: CGFloat = 1_120
    /// The side column, Discord's narrow one.
    static let sideColumnWidth: CGFloat = 360
    /// Below this the two columns stack, main over side.
    static let twoColumnMinimum: CGFloat = 820

    static let bannerHeight: CGFloat = 248
    static let bannerIconSide: CGFloat = 76
    static let cardRadius: CGFloat = 18

    static let leaderboardRowHeight: CGFloat = 56
    static let leaderboardAvatar: CGFloat = 32
    static let leaderboardGameIcon: CGFloat = 22
    /// How many rows a card shows before its own scroll.
    static let leaderboardVisibleRows: CGFloat = 6

    static let gameTileWidth: CGFloat = 116
    static let gameTileAspect: CGFloat = 4.0 / 3.0
    static let maxGameTiles = 5

    static let musicArt: CGFloat = 40
    static let whiteboardHeight: CGFloat = 420
}
