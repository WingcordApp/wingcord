import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The joins that turn four tables into a board.
///
/// **The counting tests are the important ones.** The strip on the popout
/// reports a number the reader can go and count for themselves on the board one
/// click away, and it matches Discord's only if the deduplication and the
/// overflow arithmetic both do. A test that only checked which marks were drawn
/// would pass on an implementation whose count was off by one.
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

    // MARK: The popout's stack

    private func strip(_ model: AppModel) -> GameCollection? {
        for preview in model.widgetPreviews(for: owner) {
            if case .games(let collection) = preview { return collection }
        }
        return nil
    }

    /// **Discord's arithmetic** (module `657538`): four marks, the last dimmed
    /// under the count, and the count is every game not drawn — the dimmed one
    /// is drawn. Six games are four marks and "+2".
    @Test("Past four, the fourth mark carries the count of every game not drawn")
    func overflowCounts() throws {
        let model = model(
            widgets: [
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
        let collection = try #require(strip(model))
        #expect(collection.covers.map(\.gameID) == [sims, beatSaber, endfield, zenless])
        #expect(collection.overflow == 2)
    }

    @Test("A collection that fits draws every mark and no count")
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
        let collection = try #require(strip(model))
        #expect(collection.covers.count == 3)
        #expect(collection.overflow == 0)
    }

    @Test("Exactly four draws four and no count")
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
        let collection = try #require(strip(model))
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
        let collection = try #require(strip(model))
        #expect(collection.covers.count == 1)
        #expect(collection.overflow == 0)
        // One strip for every list together.
        #expect(model.widgetPreviews(for: owner).count == 1)
    }

    @Test("An application widget's own game is in the strip, where its widget is")
    func applicationGameCounts() throws {
        let model = model(
            widgets: [
                ProfileWidget(id: "a", content: .application(application)),
                ProfileWidget(id: "f", content: .favouriteGames([game(sims)])),
            ],
            games: [sims, endfield]
        )
        model.widgetApplications[application] = WidgetApplication(
            id: application,
            name: "Arknights Endfield",
            linkedGameIDs: [endfield]
        )
        let collection = try #require(strip(model))
        #expect(collection.covers.map(\.gameID) == [endfield, sims])
    }

    @Test("Application widgets alone make no strip")
    func applicationWidgetAloneHasNoStrip() {
        let model = model(widgets: [
            ProfileWidget(id: "a", content: .application(application)),
        ])
        #expect(strip(model) == nil)
    }

    @Test("A game answered for with no art is skipped; one on its way is a plate")
    func artlessGames() throws {
        let model = model(
            widgets: [
                ProfileWidget(
                    id: "l",
                    content: .playedGames([game(sims), game(beatSaber), game(endfield)])
                ),
            ],
            games: [sims]
        )
        model.games[beatSaber] = Game(id: beatSaber, name: "Beat Saber")
        let collection = try #require(strip(model))
        #expect(collection.covers.map(\.gameID) == [sims, endfield])
        #expect(collection.covers.last?.coverURL == nil)
    }

    @Test("Somebody with no board has no stack")
    func noBoardNoStack() {
        let model = AppModel()
        #expect(model.widgetPreviews(for: owner).isEmpty)
    }

    /// An application card needs its application, its template and the
    /// person's identity, and a template with a `mini_profile` surface.
    @Test("Cards follow the board's order, and an application waits for all it needs")
    func previewOrder() throws {
        let personal = PersonalWidget(header: "Now reading", cover: .init(title: "Dune"))
        let model = model(
            widgets: [
                ProfileWidget(id: "p", content: .personal(personal)),
                ProfileWidget(id: "a", content: .application(application)),
                ProfileWidget(id: "f", content: .favouriteGames([game(sims)])),
            ],
            games: [sims]
        )
        #expect(model.widgetPreviews(for: owner).map(\.id) == ["p", "games"])

        model.widgetApplications[application] = WidgetApplication(id: application, name: "Gramophone")
        model.applicationIdentities[owner] = [
            ApplicationIdentity(
                applicationID: application,
                externalUserID: "1",
                profile: ApplicationProfile(fields: ["preview_value": .text("102.3k Scrobbles")])
            ),
        ]
        let text = WidgetField.field(.init(valueType: .data, presentationType: .text, value: "preview_value"))
        model.widgetConfigs[application] = WidgetConfig(
            configID: "1",
            applicationID: application,
            displayName: "Gramophone",
            surfaces: [
                "mini_profile": WidgetSurface(
                    layout: "mini_profile_contained_stat",
                    components: ["stat": WidgetComponent(fields: ["text": text])]
                ),
            ]
        )
        let previews = model.widgetPreviews(for: owner)
        #expect(previews.map(\.id) == ["p", "application-\(application.rawValue)", "games"])
        if case .application(let mini)? = previews.dropFirst().first {
            #expect(mini.surface.headline?.value == "102.3k Scrobbles")
        } else {
            Issue.record("the application widget should be the second card")
        }
    }

    @Test("A template with no mini_profile surface is no card")
    func noMiniSurfaceNoCard() {
        let model = model(widgets: [
            ProfileWidget(id: "a", content: .application(application)),
        ])
        model.widgetApplications[application] = WidgetApplication(id: application, name: "Endfield")
        model.applicationIdentities[owner] = [
            ApplicationIdentity(applicationID: application, externalUserID: "1"),
        ]
        model.widgetConfigs[application] = WidgetConfig(
            configID: "1",
            applicationID: application,
            displayName: "Endfield",
            surfaces: ["widget_bottom": WidgetSurface(layout: "widget_bottom_stats", components: [:])]
        )
        #expect(model.widgetPreviews(for: owner).isEmpty)
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

    /// Vexlor's goal: keyed on stats alone, the board found none and printed
    /// the identity's raw fraction as "0,69 Progress".
    @Test("A goal widget draws its bar, not the identity's raw fields")
    func progressTileKeepsItsTemplate() throws {
        let model = model(widgets: [
            ProfileWidget(id: "a", content: .application(application)),
        ])
        model.widgetApplications[application] = WidgetApplication(id: application, name: "User Stats")
        model.applicationIdentities[owner] = [
            ApplicationIdentity(
                applicationID: application,
                externalUserID: "0",
                profile: ApplicationProfile(
                    username: "some_username",
                    fields: ["progress": .number(0.69)],
                    fieldOrder: ["progress"]
                )
            ),
        ]
        model.widgetConfigs[application] = WidgetConfig(
            configID: "1",
            applicationID: application,
            displayName: "User Stats",
            surfaces: [
                "widget_bottom": WidgetSurface(
                    layout: "widget_bottom_progress",
                    components: [
                        "progress": WidgetComponent(fields: [
                            "current": .field(.init(valueType: .data, presentationType: .number, value: "progress")),
                        ]),
                    ]
                ),
            ]
        )
        let tile = try #require(model.boardPresentation(for: owner)?.tiles.first)
        guard case .application(let application) = tile.content else {
            Issue.record("an application widget should resolve to an application tile")
            return
        }
        #expect(application.bottom?.progress?.caption == "69%")
        #expect(application.bottom?.stats.isEmpty == true)
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
