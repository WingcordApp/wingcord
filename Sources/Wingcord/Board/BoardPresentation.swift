import Foundation
import WingcordCore

/// Everything the Board tab draws, resolved once.
///
/// **The same contract `ProfilePresentation` has, and for the same reason.** A
/// board tile joins four tables — the widgets, the games, the widget configs and
/// the person's linked identities — and doing that join inside a `body` means
/// doing it again on every scroll, every hover and every unrelated store write.
/// Resolved here, the views hold flat values and redraw only when those values
/// actually differ.
struct BoardPresentation: Hashable, Sendable {
    var tiles: [BoardTile]
    /// Whether games named by a tile are still on their way. The covers draw as
    /// plates until then, and the tile keeps its size so nothing reflows when
    /// they land.
    var isLoadingGames: Bool

    var isEmpty: Bool { tiles.isEmpty }
}

/// One tile.
struct BoardTile: Hashable, Sendable, Identifiable {
    /// The widget's own id — what a report names, and the only stable handle a
    /// tile has: its content is a list that the person can reorder.
    var id: String
    var title: String
    var content: Content

    enum Content: Hashable, Sendable {
        /// Favourite and rotation: a row per game, with its comment and badges.
        case detailed([BoardGame])
        /// Liked and wishlist: covers in a grid, four across.
        case grid([BoardGame])
        /// An application's own widget.
        case application(BoardApplicationTile)
        /// A widget the reader wrote: a cover and up to four labelled slots.
        case personal(PersonalWidget)
    }

    var games: [BoardGame] {
        switch content {
        case .detailed(let games), .grid(let games): games
        case .application, .personal: []
        }
    }

    /// The game "View Game Profile" opens from this tile's menu, when there is
    /// exactly one it could mean. A list tile has many and offers none.
    var linkedGameID: ApplicationID? {
        if case .application(let tile) = content { return tile.gameID }
        return nil
    }
}

/// One game as a tile draws it.
struct BoardGame: Hashable, Sendable, Identifiable {
    var gameID: ApplicationID
    /// Nil until `/games` answers. **Not defaulted to a placeholder string** —
    /// the tile draws a plate for an unresolved game rather than the word
    /// "Unknown" under a blank cover.
    var name: String?
    var coverURL: URL?
    /// Whether that picture is real box art or the square app icon standing in
    /// for it. The frame is portrait either way; what changes is whether the
    /// picture fills it or is centred on a blurred copy of itself — see
    /// `AppModel.gameArtIsCover`.
    var isCoverArt: Bool = true
    var comment: String?
    /// Skill first, then feeling, then social.
    var tags: [GameWidgetTag]

    var id: ApplicationID { gameID }
}

/// The proportions a game's art is drawn at.
nonisolated enum GameArt {
    /// IGDB's `t_cover_big` is 264x374 and Discord's own board frames it at
    /// three to four. Measured off their tiles: 176 wide by 233 tall.
    static let coverAspect: CGFloat = 3.0 / 4.0

    /// How wide a cover is at each size the app draws one.
    static let rowWidth: CGFloat = 68
    static let gridWidth: CGFloat = 92
    static let shelfWidth: CGFloat = 116
    /// The strip on the popout, which draws marks rather than covers —
    /// Discord's twenty-four.
    static let markSide: CGFloat = 24
}

/// An application widget, resolved against its config and the person's identity.
struct BoardApplicationTile: Hashable, Sendable {
    var applicationID: ApplicationID
    /// The application's own name, which is what the tile's header shows — not
    /// the config's `display_name`, which is the author's private label.
    var name: String
    var iconURL: URL?
    /// The header: a title, its subtitles and the artwork behind them.
    var top: ResolvedSurface?
    /// The stats block under it.
    var bottom: ResolvedSurface?
    /// The character art the game features for this person, when the config's
    /// own hero image did not resolve to one.
    var characterImageURL: URL?
    /// The game this widget is about, for "View Game Profile".
    var gameID: ApplicationID?

    /// Whether there is anything at all to draw. A widget whose config has not
    /// arrived and whose identity is empty is a card with a header and a void,
    /// and it is better to draw the header alone than to draw the void.
    var hasBody: Bool {
        (top.map { !$0.isEmpty } ?? false) || (bottom.map { !$0.isEmpty } ?? false)
    }
}

/// One card of the popout's widget stack, in the person's own widget order —
/// Discord's `UserProfileStackedWidgetPreviews` (module `657538`).
enum WidgetPreview: Hashable, Sendable, Identifiable {
    /// An application widget's `mini_profile` surface.
    case application(MiniApplicationWidget)
    /// "Game Collection": every game the board names, as one strip, at the
    /// place of the first game list.
    case games(GameCollection)
    /// A widget the person wrote.
    case personal(id: String, widget: PersonalWidget)

    var id: String {
        switch self {
        case .application(let widget): "application-\(widget.applicationID.rawValue)"
        case .games: "games"
        case .personal(let id, _): id
        }
    }
}

/// An application widget as the popout draws it: the name, the one stat its
/// `mini_profile` surface leads with, and a picture.
struct MiniApplicationWidget: Hashable, Sendable {
    var applicationID: ApplicationID
    var name: String
    var iconURL: URL?
    var surface: ResolvedSurface
}

/// The strip of game marks on the popout.
///
/// **A summary, and it opens onto the board.** It is the one thing on the small
/// card that says a person has games on their board, so its click target is
/// the Board tab of their full profile rather than any single game.
struct GameCollection: Hashable, Sendable {
    /// The marks to draw, at most `slots`.
    var covers: [BoardGame]
    /// Every game not drawn — printed over the last mark, which is dimmed
    /// under it. Zero draws no count.
    ///
    /// **The dimmed mark counts as drawn**, which is Discord's arithmetic
    /// (module `657538`): seventeen games are four marks and "+13".
    var overflow: Int

    static let slots = 4
}

/// A request to open a game's own profile.
struct GameProfileRequest: Hashable, Sendable, Identifiable {
    var gameID: ApplicationID
    var id: UInt64 { gameID.rawValue }
}
