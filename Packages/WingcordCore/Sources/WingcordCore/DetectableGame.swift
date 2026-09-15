import Foundation

// MARK: - Discord's detectable-games database
//
// `https://cdn.discordapp.com/detectables/games-v1.json` — 24,323 entries,
// 4.3 MB, and **every fact about its shape below was read out of the file
// rather than recalled.** The route behind it is `GET /games/detectable`; the
// CDN copy is what the client actually fetches and it is unauthenticated.
//
// The number that decides the whole design:
//
//     win32  11,154 executables
//     darwin      67          (across 62 games)
//     linux        8
//
// **Discord's macOS detection list is effectively abandoned.** Sixty-two games,
// and the roster reads like 2016 — Undertale, HuniePop, Shovel Knight, Card
// Hunter. A client that matched only `darwin` entries would detect almost
// nothing on a Mac and the feature would look broken rather than empty.
//
// So this matcher does three things, in order, and the second is what makes it
// useful at all:
//
//   1. Match `darwin` entries against the running bundle.
//   2. Match `win32` entries against a Windows executable running under a
//      translation layer — Whisky, CrossOver, Game Porting Toolkit, Parallels.
//      That is how most Mac gaming happens now, and the Windows executable name
//      is sitting in the process arguments.
//   3. Fall back to whatever the reader added by hand.

/// Which operating system an executable entry describes.
///
/// A raw string rather than a closed set at the decode boundary: the file has
/// three values today and an unrecognised fourth must not throw away the entry
/// it belongs to.
public enum DetectablePlatform: String, Hashable, Sendable, Codable {
    case macOS = "darwin"
    case windows = "win32"
    case linux
}

/// One executable that identifies a game.
public struct DetectableExecutable: Hashable, Sendable {

    /// The name to match, **already lowercase in the file** — all 11,229 of
    /// them, checked — and `/`-separated when it carries path context.
    ///
    /// Three forms appear, and they are matched differently:
    ///
    /// - `factorio.app` — a bundle name.
    /// - `osx64/dota2.app` — a bundle name with enough parent directory to
    ///   disambiguate it. 9,298 names carry a `/`.
    /// - `hl2_osx` — a bare Unix executable, for games that ship no bundle.
    ///
    /// The leading `>` is stripped into ``requiresArguments``.
    public var name: String

    public var platform: DetectablePlatform

    /// The command line that disambiguates a shared binary.
    ///
    /// **`>` and `arguments` are the same fact, and the file proves it**: nine
    /// entries begin with `>` and all nine carry arguments; no entry carries
    /// arguments without the `>`. It marks a binary that serves several games
    /// and cannot identify one on its own — `hl2_osx` is Half-Life 2, Team
    /// Fortress 2, Left 4 Dead 2 *and* Garry's Mod, separated only by
    /// `-game hl2` / `-game tf` / `-game left4dead2` / `-game garrysmod`, and
    /// `java` is Minecraft only when it is running
    /// `net.minecraft.client.main.Main`.
    public var arguments: String?

    /// Whether this process is the game's launcher rather than the game.
    ///
    /// Twenty entries, all Windows — League of Legends' `leagueclientux.exe`,
    /// Rust's own `rust.exe`, Fortnite's anti-cheat shim. Kept because Discord
    /// reports the game while the launcher is up, and dropping the flag would
    /// make the presence flicker off between launcher and game.
    public var isLauncher: Bool

    public init(
        name: String,
        platform: DetectablePlatform,
        arguments: String? = nil,
        isLauncher: Bool = false
    ) {
        // Defensive rather than decorative: the file is lowercase today and a
        // single capitalised name added tomorrow would silently stop matching.
        self.name = name.lowercased()
        self.platform = platform
        self.arguments = arguments
        self.isLauncher = isLauncher
    }

    /// The name with its `>` marker removed, which is what actually gets
    /// compared.
    public var matchName: String {
        name.hasPrefix(">") ? String(name.dropFirst()) : name
    }

    /// Whether the arguments have to match too. See ``arguments``.
    public var requiresArguments: Bool {
        name.hasPrefix(">") && arguments != nil
    }
}

/// One game in the database.
public struct DetectableGame: Hashable, Sendable, Identifiable {
    public var id: ApplicationID
    public var name: String
    /// Other names the same game is published under — `"World of Warcraft™"`,
    /// `"Tom Clancy's Rainbow Six Siege"`. 1,401 entries carry them.
    ///
    /// Decoded but not matched against: an alias names the *game*, never the
    /// executable, so it is display text for a client that resolved the game
    /// some other way.
    public var aliases: [String]
    public var executables: [DetectableExecutable]

    public init(
        id: ApplicationID,
        name: String,
        aliases: [String] = [],
        executables: [DetectableExecutable] = []
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.executables = executables
    }
}

// MARK: - A process this Mac is running

/// What the matcher needs to know about a running process.
///
/// Deliberately a value with no AppKit in it, so the whole matcher is testable
/// without launching anything. `GameDetector` fills it from
/// `NSWorkspace.runningApplications`.
public struct RunningProcess: Hashable, Sendable {

    /// The executable's absolute path, as the OS reports it —
    /// `/Applications/Factorio.app/Contents/MacOS/factorio`.
    public var executablePath: String

    /// The process's arguments, the launch path excluded.
    ///
    /// **This is where a translated Windows game hides its real identity.** A
    /// title running under Whisky or Game Porting Toolkit is
    /// `wine64-preloader` or `wine64` with `…/Game.exe` somewhere in here, and
    /// matching the process name alone finds the translation layer every time.
    public var arguments: [String]

    /// What the OS would call it in a menu bar. Used only to name a game the
    /// database does not know.
    public var localizedName: String?

    public init(executablePath: String, arguments: [String] = [], localizedName: String? = nil) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.localizedName = localizedName
    }

    // MARK: Derived forms, each lowercased once

    /// Every path component, lowercased — the unit every rule below compares.
    var components: [String] {
        executablePath.lowercased().split(separator: "/").map(String.init)
    }

    /// The bundle path as the database spells it: everything up to and
    /// including the last `.app`, so `osx64/dota2.app` has something to match
    /// against.
    ///
    /// Nil for a bare Unix executable, which is the `hl2_osx` case.
    var bundlePath: [String]? {
        let parts = components
        guard let last = parts.lastIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return Array(parts[...last])
    }

    /// The Windows executable this process is really running, if it is a
    /// translation layer.
    ///
    /// **Matched on the argument, never on the process.** Every Wine-family
    /// runner presents as its own binary — `wine64-preloader`, `wine64`,
    /// `wineserver`, CrossOver's `wine` — and the game is an argument. Taking
    /// the *last* `.exe` is deliberate: a launcher chain puts the real title
    /// after the bootstrapper.
    var translatedWindowsExecutable: [String]? {
        guard isTranslationLayer else { return nil }
        let exe = arguments.lazy
            .map { $0.lowercased() }
            .last { $0.hasSuffix(".exe") }
        guard let exe else { return nil }
        return exe.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
    }

    /// Whether this process is a Windows translation layer rather than a game.
    ///
    /// The list is the runners, not the products: Whisky and Heroic both ship
    /// Wine, CrossOver ships a fork of it, and Apple's Game Porting Toolkit is
    /// Wine with a Direct3D translator bolted on. All of them exec a binary
    /// whose name begins `wine`.
    var isTranslationLayer: Bool {
        guard let name = components.last else { return false }
        return name.hasPrefix("wine") || name == "crossover" || name == "gameportingtoolkit"
    }
}

// MARK: - The index

/// Discord's database, arranged so a launch costs a dictionary lookup.
///
/// **Built once and kept.** The file is 24,323 games and 11,229 executables;
/// walking it per launched process would be tens of milliseconds on every app
/// the reader opens, and `NSWorkspace` reports every app, not every game.
///
/// The index is keyed on the executable's **last path component**, which is the
/// only part every form shares. Candidates that collide on that key — 31 names
/// in the file do, `hl2_osx` across four Source games worst of all — are
/// resolved by the rules in ``match(_:)``.
public struct DetectableGameIndex: Sendable {

    /// A key's worth of candidates, in the order the file listed them.
    private var byLastComponent: [String: [Candidate]]

    private struct Candidate: Sendable {
        var game: DetectableGame
        var executable: DetectableExecutable
    }

    public private(set) var gameCount: Int

    public init(games: [DetectableGame]) {
        var table: [String: [Candidate]] = [:]
        table.reserveCapacity(games.count)
        for game in games {
            for executable in game.executables {
                guard let key = executable.matchName.split(separator: "/").last.map(String.init)
                else { continue }
                table[key, default: []].append(Candidate(game: game, executable: executable))
            }
        }
        byLastComponent = table
        gameCount = games.count
    }

    public var isEmpty: Bool { byLastComponent.isEmpty }

    // MARK: Matching

    /// What a running process turned out to be.
    public struct Match: Hashable, Sendable {
        public var game: DetectableGame
        /// Whether the matched executable was the game's launcher.
        public var isLauncher: Bool
        /// Whether the match came through a Windows translation layer.
        public var isTranslated: Bool
    }

    /// The game this process is, or nil.
    ///
    /// Three passes, in the order that prefers certainty:
    ///
    /// 1. A `darwin` entry against the running bundle. A real Mac build.
    /// 2. A `win32` entry against the Windows executable a translation layer is
    ///    running. See ``RunningProcess/translatedWindowsExecutable``.
    /// 3. Nothing.
    ///
    /// Within a pass, an entry carrying **more path context wins** — `osx64/`
    /// `dota2.app` beats a bare `dota2.app` — because the longer name is the
    /// one whose author knew the short one was ambiguous.
    public func match(_ process: RunningProcess) -> Match? {
        if let bundle = process.bundlePath,
           let hit = best(in: bundle, platform: .macOS, process: process) {
            return Match(game: hit.game, isLauncher: hit.executable.isLauncher, isTranslated: false)
        }
        // A game with no bundle at all — `hl2_osx`, `java`. Only reachable when
        // the path has no `.app` in it, so it cannot shadow the case above.
        if process.bundlePath == nil,
           let hit = best(in: process.components, platform: .macOS, process: process) {
            return Match(game: hit.game, isLauncher: hit.executable.isLauncher, isTranslated: false)
        }
        if let windows = process.translatedWindowsExecutable,
           let hit = best(in: windows, platform: .windows, process: process) {
            return Match(game: hit.game, isLauncher: hit.executable.isLauncher, isTranslated: true)
        }
        return nil
    }

    /// The best candidate for one path, or nil.
    private func best(
        in path: [String],
        platform: DetectablePlatform,
        process: RunningProcess
    ) -> Candidate? {
        guard let key = path.last, let candidates = byLastComponent[key] else { return nil }
        var winner: Candidate?
        var winningDepth = -1
        for candidate in candidates where candidate.executable.platform == platform {
            let parts = candidate.executable.matchName.split(separator: "/").map(String.init)
            guard path.count >= parts.count, Array(path.suffix(parts.count)) == parts else { continue }
            // A shared binary identifies nothing until its arguments agree.
            if candidate.executable.requiresArguments {
                guard let required = candidate.executable.arguments,
                      process.matchesArguments(required)
                else { continue }
            }
            // Ties go to the first the file listed, which is why this is a
            // strict comparison.
            if parts.count > winningDepth {
                winningDepth = parts.count
                winner = candidate
            }
        }
        return winner
    }
}

extension RunningProcess {

    /// Whether the process was launched with `required` somewhere in its
    /// command line.
    ///
    /// **Token-wise, not substring.** `-game hl2` must not match
    /// `-game hl2mp`, and the four Source games in the file differ by exactly
    /// that suffix. The required string is split the same way the command line
    /// is, and every token has to appear — in order, but not necessarily
    /// adjacently, because a launcher inserts its own flags between them.
    func matchesArguments(_ required: String) -> Bool {
        let needles = required.lowercased().split(separator: " ").map(String.init)
        guard !needles.isEmpty else { return true }
        var remaining = needles[...]
        for argument in arguments.lazy.map({ $0.lowercased() }) {
            guard let next = remaining.first else { break }
            if argument == next { remaining = remaining.dropFirst() }
        }
        return remaining.isEmpty
    }
}
