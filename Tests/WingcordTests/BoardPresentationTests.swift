import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The joins that turn four tables into a board.
///
/// **The counting tests are the important ones.** The strip on the small card
/// reports a number the reader can go and count for themselves on the board one
/// click away, and the two can only agree if the deduplication and the overflow
/// arithmetic agree. A test that only checked which covers were drawn would
/// pass on an implementation whose chip was off by one.
@MainActor
@Suite("Board presentation")
struct BoardPresentationTests {

    private let owner = UserID(rawValue: 900_000_000_000_000_000)
    private let sims = ApplicationID(rawValue: 359_509_007_423_242_240)
    private let beatSaber = ApplicationID(rawValue: 451_991_967_149_195_264)
    private let endfield = ApplicationID(rawValue: 1_461_154_307_171_811_401)
    private let zenless = ApplicationID(rawValue: 1_257_819_671_114_289_184)
    private let application = ApplicationID(rawValue: 1_496_037_472_226_906_183)

    private func model(widgets: [ProfileWidget], games: [ApplicationID] = []) -> AppModel {
        let model = AppModel()
        model.currentUserID = UserID(rawValue: 7)
        model.profileWidgets[owner] = widgets
        for id in games {
            model.games[id] = Game(
                id: id,
                name: "Game \(id.rawValue)",
                media: GameMedia(icon: .hash("abc"))
            )
        }
        return model
    }

    private func game(_ id: ApplicationID, tags: [GameWidgetTag] = []) -> ProfileWidgetGame {
        ProfileWidgetGame(gameID: id, tags: tags)
    }

    // MARK: The strip on the small card

    @Test("The strip's covers plus its overflow is the whole collection")
    func overflowCounts() throws {
        // Six distinct games across four tiles, which is the demo fixture's own
        // shape and roughly a real board's.
        let model = model(
            widgets: [
                ProfileWidget(id: "a", content: .application(application)),
                ProfileWidget(id: "f", content: .favouriteGames([game(sims)])),
                ProfileWidget(
                    id: "r",
                    content: .currentGames([game(beatSaber), game(endfield)])
                ),
                ProfileWidget(
                    id: "l",
                    content: .playedGames([
                        game(sims), game(zenless),
                        game(ApplicationID(rawValue: 111)),
                        game(ApplicationID(rawValue: 222)),
                    ])
                ),
            ],
            games: [sims, beatSaber, endfield, zenless]
        )
        let collection = try #require(model.gameCollection(for: owner))
        #expect(collection.covers.count == 3)
        #expect(collection.overflow == 3)
        // The chip and the board agree: three drawn, three behind it, six there.
        #expect(collection.covers.count + collection.overflow == 6)
    }

    @Test("A collection that fits draws every cover and no chip")
    func noOverflow() throws {
        let model = model(
            widgets: [
                ProfileWidget(
                    id: "r",
                    content: .currentGames([game(sims), game(beatSaber), game(endfield)])
                ),
            ],
            games: [sims, beatSaber, endfield]
        )
        let collection = try #require(model.gameCollection(for: owner))
        #expect(collection.covers.count == 3)
        #expect(collection.overflow == 0)
    }

    @Test("Exactly four fills all four slots rather than showing three and a +1")
    func exactlyFourFits() throws {
        let model = model(
            widgets: [
                ProfileWidget(
                    id: "l",
                    content: .playedGames([
                        game(sims), game(beatSaber), game(endfield), game(zenless),
                    ])
                ),
            ],
            games: [sims, beatSaber, endfield, zenless]
        )
        let collection = try #require(model.gameCollection(for: owner))
        #expect(collection.covers.count == 4)
        #expect(collection.overflow == 0)
    }

    @Test("A game in three tiles is counted once")
    func deduplicates() throws {
        let model = model(
            widgets: [
                ProfileWidget(id: "f", content: .favouriteGames([game(sims)])),
                ProfileWidget(id: "r", content: .currentGames([game(sims)])),
                ProfileWidget(id: "l", content: .playedGames([game(sims)])),
            ],
            games: [sims]
        )
        let collection = try #require(model.gameCollection(for: owner))
        #expect(collection.covers.count == 1)
        #expect(collection.overflow == 0)
    }

    @Test("An application widget contributes no cover to the strip")
    func applicationWidgetIsNotAGame() {
        let model = model(widgets: [
            ProfileWidget(id: "a", content: .application(application)),
        ])
        #expect(model.gameCollection(for: owner) == nil)
    }

    @Test("Somebody with no board has no strip")
    func noBoardNoStrip() {
        let model = AppModel()
        #expect(model.gameCollection(for: owner) == nil)
    }

    // MARK: The board itself

    @Test("Only tabs with something behind them: no widgets, no board")
    func noBoardForMostPeople() {
        let model = AppModel()
        #expect(model.boardPresentation(for: owner) == nil)
    }

    @Test("An empty tile is not drawn")
    func emptyTilesDropped() {
        let model = model(widgets: [
            ProfileWidget(id: "f", content: .favouriteGames([])),
            ProfileWidget(id: "l", content: .playedGames([])),
        ])
        #expect(model.boardPresentation(for: owner) == nil)
    }

    @Test("A widget kind added after this was written draws nothing")
    func unknownKindDrawsNothing() {
        let model = model(widgets: [
            ProfileWidget(id: "x", content: .unknown("some_new_kind")),
        ])
        #expect(model.boardPresentation(for: owner) == nil)
    }

    @Test("Tiles keep the order the person arranged them in")
    func tileOrder() throws {
        let model = model(
            widgets: [
                ProfileWidget(id: "r", content: .currentGames([game(beatSaber)])),
                ProfileWidget(id: "f", content: .favouriteGames([game(sims)])),
                ProfileWidget(id: "l", content: .playedGames([game(endfield)])),
            ],
            games: [sims, beatSaber, endfield]
        )
        let board = try #require(model.boardPresentation(for: owner))
        #expect(board.tiles.map(\.id) == ["r", "f", "l"])
        #expect(board.tiles.map(\.title) == ["Games in Rotation", "Favourite Game", "Games I Like"])
    }

    @Test("A game still on its way is named nowhere and the board says it is loading")
    func unresolvedGame() throws {
        let model = model(
            widgets: [ProfileWidget(id: "f", content: .favouriteGames([game(sims)]))],
            games: []
        )
        let board = try #require(model.boardPresentation(for: owner))
        #expect(board.isLoadingGames)
        #expect(board.tiles.first?.games.first?.name == nil)
    }

    @Test("Badges are ordered skill, feeling, social however they arrived")
    func badgeOrder() throws {
        let model = model(
            widgets: [
                ProfileWidget(
                    id: "r",
                    content: .currentGames([
                        game(sims, tags: [.social(.openToTeach), .feeling(.loveIt), .skill(.expert)]),
                    ])
                ),
            ],
            games: [sims]
        )
        let board = try #require(model.boardPresentation(for: owner))
        #expect(
            board.tiles.first?.games.first?.tags
                == [.skill(.expert), .feeling(.loveIt), .social(.openToTeach)]
        )
    }

    @Test("An application tile with no resolved application is not drawn")
    func unresolvedApplication() {
        let model = model(widgets: [
            ProfileWidget(id: "a", content: .application(application)),
        ])
        // A card headed by a snowflake is worse than a card that has not
        // appeared yet.
        #expect(model.boardPresentation(for: owner) == nil)
    }

    @Test("An application tile carries the game its widget is about")
    func applicationTileNamesItsGame() throws {
        let model = model(widgets: [
            ProfileWidget(id: "a", content: .application(application)),
        ])
        model.widgetApplications[application] = WidgetApplication(
            id: application,
            name: "Arknights Endfield",
            linkedGameIDs: [endfield]
        )
        model.applicationIdentities[owner] = [
            ApplicationIdentity(
                applicationID: application,
                externalUserID: "1",
                profile: ApplicationProfile(
                    username: "Amin",
                    fields: ["level": .number(60)],
                    fieldOrder: ["level"]
                )
            ),
        ]
        let board = try #require(model.boardPresentation(for: owner))
        let tile = try #require(board.tiles.first)
        #expect(tile.linkedGameID == endfield)
        // With no config, the identity's own fields still fill the card.
        if case .application(let application) = tile.content {
            #expect(application.top?.title == "Amin")
            #expect(application.bottom?.stats.map(\.label) == ["Level"])
            #expect(application.bottom?.stats.map(\.value) == ["60"])
        } else {
            Issue.record("an application widget should resolve to an application tile")
        }
    }
}
