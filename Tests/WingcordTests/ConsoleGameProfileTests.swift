import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// A console activity opens its game profile (docs/BETA3.md §7, round 2): his
/// friend's GTA VI "Playing on PlayStation" only selected its title here,
/// where Discord opens the game.
@MainActor
@Suite("Console game profiles")
struct ConsoleGameProfileTests {
    private let gta = ApplicationID(rawValue: 7_000)

    @Test("A playing activity with no usable id opens the game its name names")
    func nameFindsTheGame() {
        let model = AppModel()
        let activity = Activity(kind: .playing, name: "Grand Theft Auto VI")
        #expect(model.gameProfileOpener(for: activity) == nil)

        model.gamesByActivityName[AppModel.activityNameKey("grand theft auto vi")] = gta
        // Not until the game's record is in: Discord opens only a game that has one.
        #expect(model.gameProfileOpener(for: activity) == nil)
        model.games[gta] = Game(id: gta, name: "Grand Theft Auto VI")
        #expect(model.gameProfileOpener(for: activity) != nil)
    }

    @Test("Names match without case or accents, and only as a whole")
    func nameKey() {
        #expect(AppModel.activityNameKey("  Pokémon Legends  ") == AppModel.activityNameKey("pokemon legends"))
        #expect(AppModel.activityNameKey("Grand Theft Auto V") != AppModel.activityNameKey("Grand Theft Auto VI"))
    }

    @Test("Anything but playing opens no game profile")
    func onlyPlaying() {
        let model = AppModel()
        model.gamesByActivityName[AppModel.activityNameKey("Spotify")] = gta
        model.games[gta] = Game(id: gta, name: "Spotify")
        #expect(model.gameProfileOpener(for: Activity(kind: .listening, name: "Spotify")) == nil)
    }
}
