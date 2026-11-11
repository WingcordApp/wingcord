import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The game behind an activity's application — Discord's `getCanonicalGameId`.
/// A console title's activity names an application that is no game; its record
/// names the game, and that hop is what its card's click needs.
@MainActor
@Suite("Canonical game")
struct CanonicalGameTests {

    private let console = ApplicationID(rawValue: 1_000_000_000_000_000_001)
    private let game = ApplicationID(rawValue: 1_000_000_000_000_000_002)
    private let editor = ApplicationID(rawValue: 1_000_000_000_000_000_003)

    @Test("An application that is itself a game is its own answer")
    func gameIsItself() {
        let model = AppModel()
        model.games[game] = Game(id: game, name: "Astro Bot")
        #expect(model.canonicalGameID(for: game) == game)
        #expect(model.gameProfileOpener(for: game) != nil)
    }

    @Test("A console title's application opens the game it is linked to")
    func consoleTitleFollowsItsLink() {
        let model = AppModel()
        model.games[game] = Game(id: game, name: "Astro Bot")
        // Before the application's record has arrived there is nothing to click…
        #expect(model.gameProfileOpener(for: console) == nil)
        // …and once it names the game, there is.
        model.widgetApplications[console] = WidgetApplication(
            id: console, name: "Astro Bot", linkedGameIDs: [game]
        )
        #expect(model.canonicalGameID(for: console) == game)
        #expect(model.gameProfileOpener(for: console) != nil)
    }

    @Test("An application with no game behind it still opens nothing")
    func editorHasNoPage() {
        let model = AppModel()
        model.widgetApplications[editor] = WidgetApplication(id: editor, name: "An editor")
        #expect(model.canonicalGameID(for: editor) == editor)
        #expect(model.gameProfileOpener(for: editor) == nil)
        #expect(model.gameProfileOpener(for: nil) == nil)
    }
}
