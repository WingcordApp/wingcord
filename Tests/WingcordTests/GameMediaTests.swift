import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// What the game profile's media tray is handed.
///
/// **The trailer leads, and it was drawn nowhere at all until now.**
/// `GameTrailer` has been decoded since the page was written — a game's own
/// moving pitch, sitting in the payload behind a shelf of stills — and the
/// ordering is the one thing about it a rendered view cannot be asked.
@MainActor
@Suite("Game media")
struct GameMediaTests {

    private let sims = ApplicationID(rawValue: 359_509_007_423_242_240)

    private func model(_ game: Game) -> AppModel {
        let model = AppModel()
        model.currentUserID = UserID(rawValue: 7)
        model.games[game.id] = game
        return model
    }

    @Test("A trailer leads the stills")
    func trailerFirst() throws {
        let model = model(Game(
            id: sims,
            name: "The Sims 4",
            screenshotURLs: [
                URL(string: "https://example.com/a.png")!,
                URL(string: "https://example.com/b.png")!,
            ],
            trailers: [GameTrailer(id: "1234", applicationID: sims, mimeType: "video/mp4")]
        ))
        let media = try #require(model.gamePresentation(for: sims)).media
        #expect(media.count == 3)
        #expect(media.first?.isTrailer == true)
        // A store asset, and therefore `.mp4` under `/store/` — the same shape
        // the activity preview already probed live.
        #expect(media.first?.id.absoluteString.hasSuffix("/store/1234.mp4") == true)
        #expect(media.dropFirst().allSatisfy { !$0.isTrailer })
    }

    /// The common case: no trailer at all, and the tray is stills.
    @Test("A game with no trailer shows only stills")
    func stillsOnly() throws {
        let model = model(Game(
            id: sims,
            name: "The Sims 4",
            screenshotURLs: [URL(string: "https://example.com/a.png")!]
        ))
        let media = try #require(model.gamePresentation(for: sims)).media
        #expect(media == [.still(URL(string: "https://example.com/a.png")!)])
    }

    /// A game with neither draws no stage, which is what an empty list means to
    /// the view — there is no placeholder frame for a game Discord has no
    /// pictures of.
    @Test("A game with no media at all is empty")
    func nothing() throws {
        let media = try #require(model(Game(id: sims, name: "x")).gamePresentation(for: sims)).media
        #expect(media.isEmpty)
    }

    /// **Themes were decoded and never drawn**, and they are what fills the
    /// space the mockup spent on a stat trio whose three numbers were invented.
    @Test("Themes reach the presentation")
    func themes() throws {
        let model = model(Game(id: sims, name: "The Sims 4", themes: ["Sandbox", "Comedy"]))
        #expect(try #require(model.gamePresentation(for: sims)).themes == ["Sandbox", "Comedy"])
    }
}
