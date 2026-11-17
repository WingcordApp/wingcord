import Foundation
import WingcordCore

/// One of the reader's game lists, as a game profile's "Add to Profile" menu
/// offers it — Discord's (`581745`): Favorite, Games I Like, Games in
/// Rotation, Want to Play, each adding or removing this game.
struct GameListChoice: Identifiable, Equatable {
    var kind: ProfileWidgetKind
    var contains: Bool
    /// The list is at Discord's cap, so this game can't be added to it.
    var isFull: Bool

    var id: String { kind.rawValue }

    /// Discord's own words for the item.
    var label: String {
        switch kind {
        case .favouriteGames: contains ? "Unfavorite" : "Favorite"
        case .playedGames: contains ? "Remove from Games I Like" : "Games I Like"
        case .currentGames: contains ? "Remove from Games in Rotation" : "Games in Rotation"
        case .wantToPlayGames: contains ? "Remove from Want to Play" : "Want to Play"
        default: kind.title
        }
    }

    /// Discord's icons: a heart, a thumb, the rotate arrows, a joystick.
    var symbol: String {
        switch kind {
        case .favouriteGames: contains ? "heart.slash" : "heart"
        case .playedGames: "hand.thumbsup"
        case .currentGames: "arrow.triangle.2.circlepath"
        case .wantToPlayGames: "gamecontroller"
        default: "plus"
        }
    }
}

extension AppModel {

    /// The four lists, in Discord's order, or nil while the reader's own board
    /// isn't known yet.
    func gameListChoices(for gameID: ApplicationID) -> [GameListChoice]? {
        guard let me = currentUserID, let widgets = profileWidgets[me] else { return nil }
        let kinds: [ProfileWidgetKind] = [.favouriteGames, .playedGames, .currentGames, .wantToPlayGames]
        return kinds.map { kind in
            let games = widgets.first { $0.typeName == kind.rawValue }?.games ?? []
            let contains = games.contains { $0.gameID == gameID }
            return GameListChoice(
                kind: kind,
                contains: contains,
                isFull: !contains && games.count >= (kind.gameLimit ?? .max)
            )
        }
    }
}

extension SessionController {

    /// Adds the game to one of the reader's lists, or takes it off — the board
    /// written back whole, as the editor writes it. A list emptied by the
    /// removal goes, as Discord drops a discardable widget.
    func toggleGame(_ gameID: ApplicationID, in kind: ProfileWidgetKind) async {
        guard let me = model.currentUserID, var widgets = model.profileWidgets[me] else { return }
        let index = widgets.firstIndex { $0.typeName == kind.rawValue }
        let games = index.map { widgets[$0].games } ?? []
        let adding = !games.contains { $0.gameID == gameID }
        var updated = games.filter { $0.gameID != gameID }
        if adding {
            guard games.count < (kind.gameLimit ?? .max) else { return }
            updated.insert(ProfileWidgetGame(gameID: gameID), at: 0)
        }
        let content: ProfileWidget.Content? = switch kind {
        case .favouriteGames: .favouriteGames(updated)
        case .playedGames: .playedGames(updated)
        case .currentGames: .currentGames(updated)
        case .wantToPlayGames: .wantToPlayGames(updated)
        default: nil
        }
        guard let content else { return }
        if let index {
            if updated.isEmpty { widgets.remove(at: index) } else { widgets[index].content = content }
        } else {
            widgets.insert(ProfileWidget(id: ProfileEditor.draftIDPrefix + UUID().uuidString, content: content), at: 0)
        }
        let writes = widgets.compactMap(\.write)
        guard writes.count == widgets.count else {
            model.reportActionFailure(
                "Your board has a widget this version of Wingcord doesn't know, so it was left as it was."
            )
            return
        }
        guard !LaunchOptions.current.usesDemoFixtures else {
            model.profileWidgets[me] = widgets
            model.reportSuccess(adding ? "Added to \(kind.title)" : "Removed from \(kind.title)")
            return
        }
        do {
            model.profileWidgets[me] = try await rest.setProfileWidgets(writes)
            model.reportSuccess(adding ? "Added to \(kind.title)" : "Removed from \(kind.title)")
        } catch {
            model.reportActionFailure(Self.reason(for: error, verb: "change your profile's games"))
        }
    }
}
