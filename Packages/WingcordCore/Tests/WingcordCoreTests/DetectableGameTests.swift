import Foundation
import Testing
@testable import WingcordCore

/// Matching a running process against Discord's detectable-games database.
///
/// **Every fixture below is lifted verbatim out of `games-v1.json`**, fetched
/// 2026-09-14 — the executables, the arguments, the application ids, the
/// lowercasing. They were chosen because they disagree with each other: one
/// game has two bundle spellings, four games share one binary, one game is
/// Windows-only, and one carries a launcher.
@Suite("Detectable games")
struct DetectableGameTests {

    // MARK: Fixtures, verbatim

    private let dota = DetectableGame(
        id: ApplicationID(rawValue: 356_875_988_590_965_982),
        name: "Dota 2",
        aliases: ["DOTA 2"],
        executables: [
            DetectableExecutable(name: "osx64/dota2.app", platform: .macOS),
            DetectableExecutable(name: "dota_osx.app", platform: .macOS),
            DetectableExecutable(name: "dota2.exe", platform: .windows),
        ]
    )

    private let factorio = DetectableGame(
        id: ApplicationID(rawValue: 358_422_126_604_846_487),
        name: "Factorio",
        executables: [
            DetectableExecutable(name: "factorio.app", platform: .macOS),
            DetectableExecutable(name: "factorio", platform: .linux),
            DetectableExecutable(name: "factorio.exe", platform: .windows),
        ]
    )

    private let tf2 = DetectableGame(
        id: ApplicationID(rawValue: 356_888_577_311_055_876),
        name: "Team Fortress 2",
        executables: [
            DetectableExecutable(name: ">hl2_osx", platform: .macOS, arguments: "-game tf"),
            DetectableExecutable(name: "hl2tf.exe", platform: .windows, arguments: "-game tf"),
        ]
    )

    private let halfLife = DetectableGame(
        id: ApplicationID(rawValue: 359_510_373_362_795_534),
        name: "Half-Life 2",
        executables: [
            DetectableExecutable(name: ">hl2_osx", platform: .macOS, arguments: "-game hl2"),
        ]
    )

    private let hades = DetectableGame(
        id: ApplicationID(rawValue: 1_402_418_342_127_987_040),
        name: "Hades",
        executables: [DetectableExecutable(name: "hades.exe", platform: .windows)]
    )

    private let league = DetectableGame(
        id: ApplicationID(rawValue: 1_402_418_696_126_858_664),
        name: "League of Legends",
        executables: [
            DetectableExecutable(name: "leagueoflegends.app", platform: .macOS),
            DetectableExecutable(name: "leagueclientux.exe", platform: .windows, isLauncher: true),
        ]
    )

    private var index: DetectableGameIndex {
        DetectableGameIndex(games: [dota, factorio, tf2, halfLife, hades, league])
    }

    // MARK: A Mac build

    @Test("A bundle matches by its own name, whatever is above it")
    func bundleMatch() {
        let process = RunningProcess(
            executablePath: "/Applications/Factorio.app/Contents/MacOS/factorio"
        )
        #expect(index.match(process)?.game.name == "Factorio")
    }

    @Test("Matching is case-insensitive, because the file is lowercase and the disk is not")
    func caseInsensitive() {
        // The bundle on disk is `Factorio.app`; the database says `factorio.app`.
        // A case-sensitive compare detects nothing at all, which is the whole
        // feature failing silently.
        let shouty = RunningProcess(executablePath: "/APPLICATIONS/FACTORIO.APP/CONTENTS/MACOS/FACTORIO")
        #expect(index.match(shouty)?.game.name == "Factorio")
    }

    @Test("A deeper name wins, because its author knew the short one was ambiguous")
    func deeperNameWins() {
        // Dota ships both `osx64/dota2.app` and `dota_osx.app`. A real install
        // is under `osx64/`, and the qualified entry has to be preferred or the
        // choice is whichever the file happened to list first.
        let process = RunningProcess(
            executablePath: "/Users/a/Library/Steam/dota 2 beta/game/osx64/dota2.app/Contents/MacOS/dota2"
        )
        #expect(index.match(process)?.game.name == "Dota 2")
    }

    @Test("A path segment must match whole, not as a suffix of a longer one")
    func componentsAreWhole() {
        // `notosx64/dota2.app` is not `osx64/dota2.app`, and a string-suffix
        // compare would say it is.
        let process = RunningProcess(
            executablePath: "/games/notosx64/dota2.app/Contents/MacOS/dota2"
        )
        #expect(index.match(process) == nil)
    }

    // MARK: The shared binary

    @Test("Four games share one binary and the arguments are the only thing telling them apart")
    func sharedBinaryNeedsArguments() {
        let path = "/Users/a/Library/Steam/steamapps/common/Team Fortress 2/hl2_osx"
        let asTF2 = RunningProcess(executablePath: path, arguments: ["-game", "tf"])
        let asHL2 = RunningProcess(executablePath: path, arguments: ["-game", "hl2"])
        #expect(index.match(asTF2)?.game.name == "Team Fortress 2")
        #expect(index.match(asHL2)?.game.name == "Half-Life 2")
    }

    @Test("A shared binary with no arguments identifies nothing")
    func sharedBinaryWithoutArguments() {
        let bare = RunningProcess(
            executablePath: "/Users/a/Library/Steam/steamapps/common/Half-Life 2/hl2_osx"
        )
        #expect(index.match(bare) == nil)
    }

    @Test("Arguments match token-wise, so -game hl2 is not -game hl2mp")
    func argumentsAreTokens() {
        // Source's own mod suffixes are exactly this shape. A substring compare
        // reports Half-Life 2 for every mod built on it.
        let mod = RunningProcess(
            executablePath: "/steam/hl2_osx", arguments: ["-game", "hl2mp"]
        )
        #expect(index.match(mod) == nil)
    }

    @Test("A launcher's own flags may sit between the tokens")
    func argumentsNeedNotBeAdjacent() {
        let viaSteam = RunningProcess(
            executablePath: "/steam/hl2_osx",
            arguments: ["-steam", "-game", "-novid", "tf"]
        )
        // `-game` then `tf`, in order, with Steam's flag in between.
        #expect(index.match(viaSteam)?.game.name == "Team Fortress 2")
    }

    // MARK: Windows under translation

    @Test("A Windows game under Whisky is matched on its argument, not on wine")
    func translatedWindowsGame() {
        // This is the case that makes the feature worth building: Discord's
        // darwin list is 62 games, and this is how the rest of Mac gaming runs.
        let whisky = RunningProcess(
            executablePath: "/Applications/Whisky.app/Contents/Resources/Libraries/Wine/bin/wine64-preloader",
            arguments: ["C:\\Program Files\\Hades\\Hades.exe"]
        )
        let match = index.match(whisky)
        #expect(match?.game.name == "Hades")
        #expect(match?.isTranslated == true)
    }

    @Test("A launcher chain resolves to the LAST executable, which is the game")
    func lastExecutableWins() {
        let chained = RunningProcess(
            executablePath: "/opt/gameportingtoolkit/bin/wine64",
            arguments: ["bootstrapper.exe", "--launch", "D:\\games\\Hades.exe"]
        )
        #expect(index.match(chained)?.game.name == "Hades")
    }

    @Test("Wine running nothing recognised is not a game")
    func translationLayerAlone() {
        let idle = RunningProcess(
            executablePath: "/Applications/Whisky.app/Contents/Resources/wine64-preloader",
            arguments: ["winecfg.exe"]
        )
        #expect(index.match(idle) == nil)
    }

    @Test("A Windows executable NOT under a translation layer is ignored")
    func windowsEntriesNeedTheLayer() {
        // A file called `hades.exe` sitting in a Downloads folder and somehow
        // executing is not Hades, and reporting it would publish a presence
        // from a name on disk.
        let notWine = RunningProcess(
            executablePath: "/Users/a/Downloads/hades.exe", arguments: []
        )
        #expect(index.match(notWine) == nil)
    }

    // MARK: The rest

    @Test("A launcher is reported as the game, and says that it is the launcher")
    func launcherIsFlagged() {
        let client = RunningProcess(
            executablePath: "/opt/wine/bin/wine64",
            arguments: ["C:\\Riot Games\\LeagueClientUx.exe"]
        )
        let match = index.match(client)
        #expect(match?.game.name == "League of Legends")
        #expect(match?.isLauncher == true)
    }

    @Test("An ordinary Mac app is not a game")
    func ordinaryAppIsNotAGame() {
        let safari = RunningProcess(executablePath: "/Applications/Safari.app/Contents/MacOS/Safari")
        #expect(index.match(safari) == nil)
    }

    @Test("A linux entry never matches, even where the name would")
    func linuxEntriesAreInert() {
        // Factorio's linux executable is the bare name `factorio`, which is also
        // the binary inside the Mac bundle. Without the platform check, every
        // `.app`-less path ending in `factorio` would match the wrong entry.
        let bare = RunningProcess(executablePath: "/usr/local/bin/factorio")
        #expect(index.match(bare) == nil)
    }

    @Test("An empty index matches nothing and does not trap")
    func emptyIndex() {
        let empty = DetectableGameIndex(games: [])
        #expect(empty.isEmpty)
        #expect(empty.match(RunningProcess(executablePath: "/Applications/Factorio.app/Contents/MacOS/factorio")) == nil)
    }
}
