import Foundation
import WingcordCore

/// Popular Games, resolved for drawing.
struct PopularGamesCardModel: Equatable {
    var tiles: [Tile]
    /// The top game's cover, blurred behind the card.
    var backdropURL: URL?
    var playerCount: Int
    var gameCount: Int
    var faces: [StackedFace]
    /// Players past the faces shown.
    var moreFaces: Int

    struct Tile: Equatable, Identifiable {
        var id: ApplicationID
        var name: String
        var coverURL: URL?
        var iconURL: URL?
        var players: Int
    }
}
