import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Decoding `detectables/games-v1.json`.
///
/// **The fixture is five entries lifted byte for byte out of the real file**,
/// fetched 2026-09-14 — including the `third_party_skus` this client ignores
/// and one entry that carries no `executables` at all. A hand-written fixture
/// would have had neither, and both are the thing under test.
@Suite("Detectable games decode")
struct DetectableGamesDecodeTests {

    private let fixture = """
    [{"aliases":["DOTA 2"],"executables":[{"name":"osx64/dota2.app","os":"darwin"},\
    {"name":"dota_osx.app","os":"darwin"},{"name":"dota2.exe","os":"win32"}],\
    "id":"356875988590965982","name":"Dota 2",\
    "third_party_skus":[{"distributor":"steam","id":"570"}]},\
    {"executables":[{"arguments":"-game tf","name":"hl2tf.exe","os":"win32"},\
    {"arguments":"-game tf","name":">hl2_osx","os":"darwin"},\
    {"arguments":"-game tf","name":">hl2.exe","os":"win32"}],\
    "id":"356888577311055876","name":"Team Fortress 2",\
    "third_party_skus":[{"distributor":"steam","id":"440"}]},\
    {"aliases":["Factorio: Space Age"],"executables":[{"name":"factorio.app","os":"darwin"},\
    {"name":"factorio","os":"linux"},{"name":"factorio.exe","os":"win32"}],\
    "id":"358422126604846487","name":"Factorio",\
    "third_party_skus":[{"distributor":"steam","id":"427520"}]},\
    {"aliases":["League of Legends (TW)"],"executables":[{"name":"leagueoflegends.app","os":"darwin"},\
    {"name":"garenalolth/gamedata/apps/lolth/lolex.exe","os":"win32"},\
    {"is_launcher":true,"name":"leagueclientux.exe","os":"win32"},\
    {"name":"garenaloltw/gamedata/apps/loltw/lol.exe","os":"win32"},\
    {"name":"league of legends.exe","os":"win32"},\
    {"name":"league of legends.app","os":"darwin"},{"name":"lollauncher.app","os":"darwin"}],\
    "id":"1402418696126858664","name":"League of Legends",\
    "third_party_skus":[{"distributor":"epic","id":"24B9B5E323BC40EEA252A10CDD3B2F10"}]},\
    {"id":"489916817146434690","name":"Seasons after Fall",\
    "third_party_skus":[{"distributor":"steam","id":"366320"}]}]
    """

    private func decoded() throws -> [DetectableGame] {
        try DetectableGames.decode(Data(fixture.utf8))
    }

    @Test("An entry with no executables is dropped, and 57% of the real file is that")
    func entriesWithoutExecutablesAreDropped() throws {
        let games = try decoded()
        // Five entries in, four out: "Seasons after Fall" can never match a
        // running process, so it is discarded before it costs a string.
        #expect(games.count == 4)
        #expect(!games.contains { $0.name == "Seasons after Fall" })
    }

    @Test("The id is a snowflake string on the wire and an ApplicationID here")
    func idDecodes() throws {
        let dota = try #require(decoded().first { $0.name == "Dota 2" })
        #expect(dota.id == ApplicationID(rawValue: 356_875_988_590_965_982))
        #expect(dota.aliases == ["DOTA 2"])
    }

    @Test("Every platform round-trips, linux included")
    func platforms() throws {
        let factorio = try #require(decoded().first { $0.name == "Factorio" })
        #expect(Set(factorio.executables.map(\.platform)) == [.macOS, .linux, .windows])
    }

    @Test("`>` and `arguments` survive decoding together")
    func sharedBinary() throws {
        let tf2 = try #require(decoded().first { $0.name == "Team Fortress 2" })
        let mac = try #require(tf2.executables.first { $0.platform == .macOS })
        #expect(mac.name == ">hl2_osx")
        #expect(mac.matchName == "hl2_osx")
        #expect(mac.arguments == "-game tf")
        #expect(mac.requiresArguments)
    }

    @Test("`is_launcher` is absent on almost every entry and false when it is")
    func launcherFlag() throws {
        let league = try #require(decoded().first { $0.name == "League of Legends" })
        let ux = try #require(league.executables.first { $0.matchName == "leagueclientux.exe" })
        #expect(ux.isLauncher)
        let bundle = try #require(league.executables.first { $0.matchName == "leagueoflegends.app" })
        #expect(!bundle.isLauncher)
    }

    @Test("The decoded catalog matches a real process, end to end")
    func decodeThenMatch() throws {
        // The two halves are tested apart; this is the seam between them, and
        // the seam is where a decoded name that kept its case would break every
        // match while both sides still passed their own tests.
        let index = DetectableGameIndex(games: try decoded())
        let dota = RunningProcess(
            executablePath: "/Users/a/Library/Application Support/Steam/steamapps/common/dota 2 beta/game/osx64/dota2.app/Contents/MacOS/dota2"
        )
        #expect(index.match(dota)?.game.name == "Dota 2")
    }

    @Test("An unknown os keeps the game and drops only that executable")
    func unknownPlatform() throws {
        // Discord adds platforms; a fourth one must not throw away the darwin
        // entry sitting beside it.
        let json = """
        [{"id":"1","name":"Future","executables":[\
        {"name":"future.app","os":"darwin"},{"name":"future.xr","os":"visionos"}]}]
        """
        let games = try DetectableGames.decode(Data(json.utf8))
        #expect(games.count == 1)
        #expect(games[0].executables.count == 1)
        #expect(games[0].executables[0].platform == .macOS)
    }
}
