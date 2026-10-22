import Foundation
import Observation
import QuartzCore
import WingcordCore

// MARK: - What games say, kept for clips
//
// docs/CLIPS-PRESENCE.md, D17 / Phase 3.4. The sources a Mac can read, all
// running only while clips are on:
//
//   * **Dota 2** (native) and **Counter-Strike 2** (in a CrossOver or Whisky
//     bottle) — Valve's Game State Integration, POSTed to `GameStateServer`
//     once "Set Up…" has written the cfg file into the game's folder.
//   * **League of Legends** — its Live Client Data, polled once a second
//     while League is the game in front. Nothing to set up.
//   * **Steam Timeline** — not read: Steam keeps its timelines only while its
//     own Game Recording is on, and none exist on this Mac to read the format
//     from (§2.4). Said in Settings rather than guessed at.
//
// Events land on the host clock — the one a clip's pictures are stamped on —
// and are kept for the clip window.

@Observable
@MainActor
final class GameEventHub {

    /// Where one Valve game stands.
    enum Setup: Equatable {
        /// Not on this Mac.
        case notFound
        /// Found; its cfg file is not there yet. `folder` is where it goes.
        case found(folder: URL)
        /// The cfg file is in place.
        case ready(file: URL)
    }

    private(set) var dota: Setup = .notFound
    /// Every bottle with Counter-Strike 2 in it, by bottle name.
    private(set) var counterStrike: [String: Setup] = [:]
    private(set) var isReadingLeague = false
    /// The last event any source reported, for the settings pane.
    private(set) var lastEvent: GameEventMoment?

    @ObservationIgnored private var recent: [GameEventMoment] = []
    @ObservationIgnored private var server: GameStateServer?
    @ObservationIgnored private var dotaReader = DotaGameStateReader()
    @ObservationIgnored private var counterStrikeReader = CounterStrikeGameStateReader()
    @ObservationIgnored private var leagueTask: Task<Void, Never>?
    @ObservationIgnored private var window: Double = 123

    // MARK: Running

    /// Starts listening for the games that are set up, as long as clips are
    /// on; stops otherwise.
    func refresh(clipsEnabled: Bool, window: Double, game: DetectedGame?) {
        self.window = window
        discover()
        if clipsEnabled {
            if server == nil {
                let server = GameStateServer(port: GameEventSettings.port)
                server.onDocument = { [weak self] body in self?.receive(body) }
                server.start()
                self.server = server
            }
        } else {
            server?.stop()
            server = nil
            recent = []
        }
        let isLeague = clipsEnabled && game.map { Self.isLeague($0.name) } == true
        if isLeague, leagueTask == nil {
            startLeague()
        } else if !isLeague, let leagueTask {
            leagueTask.cancel()
            self.leagueTask = nil
            isReadingLeague = false
        }
    }

    /// The events between `start` and `end` on the host clock.
    func moments(from start: Double, to end: Double) -> [GameEventMoment] {
        recent.filter { $0.time >= start && $0.time <= end }
    }

    /// Everything kept, for a clip about to be saved.
    var kept: [GameEventMoment] { recent }

    private func note(_ moments: [GameEventMoment]) {
        guard !moments.isEmpty else { return }
        recent += moments
        let cutoff = CACurrentMediaTime() - window
        recent.removeAll { $0.time < cutoff }
        lastEvent = moments.last
    }

    /// One document from the listener. Internal for the tests.
    func receive(_ body: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        // A document without the token the cfg file carries is not from one
        // of the games this app set up.
        let auth = root["auth"] as? [String: Any]
        guard auth?["token"] as? String == GameEventSettings.token else { return }
        let appID = (root["provider"] as? [String: Any])?["appid"] as? Int
        let now = CACurrentMediaTime()
        switch appID {
        case 570: note(dotaReader.read(body, at: now))
        case 730: note(counterStrikeReader.read(body, at: now))
        default: break
        }
    }

    // MARK: League

    static func isLeague(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("League of Legends")
    }

    private func startLeague() {
        let client = LeagueLiveClient()
        leagueTask = Task { [weak self] in
            var reader = LeagueEventReader()
            var me: String?
            while !Task.isCancelled {
                do {
                    if me == nil { me = try await client.activePlayerName() }
                    if let me {
                        let (events, gameTime) = try await client.events()
                        let moments = reader.read(events, me: me, gameTime: gameTime, at: CACurrentMediaTime())
                        self?.isReadingLeague = true
                        self?.note(moments)
                    }
                } catch {
                    // Between matches the API is not there: a new match counts
                    // its events from zero, and may be somebody else's account.
                    reader.reset()
                    me = nil
                    self?.isReadingLeague = false
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Setting up

    /// Finds Dota 2 in the Mac's Steam libraries and CS2 in its bottles.
    func discover() {
        dota = Self.setup(forGameFolder: GameInstalls.dotaFolder(), cfgSubfolder: "game/dota/cfg/gamestate_integration")
        var bottles: [String: Setup] = [:]
        for (bottle, folder) in GameInstalls.counterStrikeFolders() {
            bottles[bottle] = Self.setup(forGameFolder: folder, cfgSubfolder: "game/csgo/cfg")
        }
        counterStrike = bottles
    }

    private static func setup(forGameFolder folder: URL?, cfgSubfolder: String) -> Setup {
        guard let folder else { return .notFound }
        let cfgFolder = folder.appendingPathComponent(cfgSubfolder, isDirectory: true)
        let file = cfgFolder.appendingPathComponent(GameStateIntegration.fileName)
        return FileManager.default.fileExists(atPath: file.path) ? .ready(file: file) : .found(folder: cfgFolder)
    }

    /// Writes the cfg file the game reads at its next launch.
    func setUp(_ setup: Setup, components: [String]) throws {
        let folder: URL
        switch setup {
        case .found(let cfgFolder): folder = cfgFolder
        case .ready(let file): folder = file.deletingLastPathComponent()
        case .notFound: return
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = GameStateIntegration.configuration(
            port: GameEventSettings.port, token: GameEventSettings.token, components: components
        )
        try Data(text.utf8).write(to: folder.appendingPathComponent(GameStateIntegration.fileName), options: .atomic)
        discover()
    }

    /// Takes the cfg file back out.
    func remove(_ setup: Setup) {
        guard case .ready(let file) = setup else { return }
        try? FileManager.default.removeItem(at: file)
        discover()
    }
}

// MARK: - The listener's address

/// The port and token the cfg files carry. **Chosen once and kept**: a cfg
/// file already in a game's folder names them, so they cannot move.
enum GameEventSettings {
    private static let portKey = "gameEvents.port"
    private static let tokenKey = "gameEvents.token"

    static var port: UInt16 {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: portKey) as? Int, let port = UInt16(exactly: stored) { return port }
        // A dynamic port, so nothing else on the Mac is expected to want it.
        let port = UInt16.random(in: 49_152...60_999)
        defaults.set(Int(port), forKey: portKey)
        return port
    }

    static var token: String {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: tokenKey) { return stored }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(token, forKey: tokenKey)
        return token
    }
}

// MARK: - Where the games are

enum GameInstalls {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Dota 2's own folder in any of the Mac's Steam libraries.
    static func dotaFolder() -> URL? {
        let steam = home.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
        return steamLibraries(root: steam)
            .map { $0.appendingPathComponent("steamapps/common/dota 2 beta", isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("game/dota").path) }
    }

    /// Whether League's own app is installed — it answers nothing to set up,
    /// so this is all there is to say about it before a match.
    static var leagueInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/League of Legends.app")
    }

    /// Counter-Strike 2's folder in every CrossOver and Whisky bottle that has
    /// Windows Steam with it installed.
    static func counterStrikeFolders() -> [(bottle: String, folder: URL)] {
        let bottleRoots = [
            home.appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true),
            home.appendingPathComponent("Library/Containers/com.isaacmarovitz.Whisky/Bottles", isDirectory: true),
        ]
        var found: [(String, URL)] = []
        for root in bottleRoots {
            guard let bottles = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for bottle in bottles {
                let driveC = bottle.appendingPathComponent("drive_c", isDirectory: true)
                let steam = driveC.appendingPathComponent("Program Files (x86)/Steam", isDirectory: true)
                for library in steamLibraries(root: steam, driveC: driveC) {
                    let folder = library.appendingPathComponent(
                        "steamapps/common/Counter-Strike Global Offensive", isDirectory: true
                    )
                    if FileManager.default.fileExists(atPath: folder.appendingPathComponent("game/csgo").path) {
                        found.append((bottle.lastPathComponent, folder))
                    }
                }
            }
        }
        return found
    }

    /// Steam's own folder and every library its `libraryfolders.vdf` names —
    /// a Windows Steam's `C:\…` paths read inside its bottle.
    static func steamLibraries(root: URL, driveC: URL? = nil) -> [URL] {
        var libraries = [root]
        let vdf = root.appendingPathComponent("steamapps/libraryfolders.vdf")
        guard let text = try? String(contentsOf: vdf, encoding: .utf8) else { return libraries }
        for path in libraryPaths(inVDF: text) {
            let url: URL
            if let driveC, path.count > 2, path.dropFirst().hasPrefix(":") {
                // `C:\\Program Files (x86)\\Steam` → drive_c/Program Files (x86)/Steam.
                let rest = path.dropFirst(2).replacingOccurrences(of: "\\\\", with: "/").replacingOccurrences(of: "\\", with: "/")
                url = driveC.appendingPathComponent(String(rest.drop { $0 == "/" }), isDirectory: true)
            } else {
                url = URL(fileURLWithPath: path, isDirectory: true)
            }
            if !libraries.contains(url) { libraries.append(url) }
        }
        return libraries
    }

    /// Every `"path"` value in a `libraryfolders.vdf`.
    static func libraryPaths(inVDF text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\"", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard parts.count >= 2, parts[0] == "path" else { return nil }
            return parts[1]
        }
    }
}
