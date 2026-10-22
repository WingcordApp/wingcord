import AppKit
import Observation
import WingcordCore
import WingcordNet

// MARK: - What the reader is playing
//
// `NSWorkspace`'s launch and terminate notifications, matched against Discord's
// detectable-games database. Three things make this cheaper than it looks:
//
//   * **The index is built once** and the match is a dictionary lookup, so a
//     launch costs one hash of the executable's last path component.
//   * **Nothing polls.** The only timer here is the one that re-checks the
//     catalog, and it runs once a day.
//   * **The arguments are read once per launch**, not per match, because
//     `KERN_PROCARGS2` is a syscall and a copy.
//
// The catalog is fetched off the main actor and the index built there too;
// only the result crosses back.

/// A game this Mac is running.
struct DetectedGame: Hashable, Sendable, Identifiable {
    var id: ApplicationID
    var name: String
    /// When this client first saw it, which is what the elapsed clock counts
    /// from.
    ///
    /// **Not the process's own start time.** A game already running when
    /// Wingcord launches would otherwise publish an elapsed time the reader
    /// never spent in Discord, and Discord's own clients report the moment the
    /// presence began.
    var startedAt: Date
    /// Whether the matched executable was the game's launcher rather than the
    /// game. Twenty entries in the database carry it.
    var isLauncher: Bool
    /// Whether the match came through a Windows translation layer.
    var isTranslated: Bool
    /// The process, so a terminate notification can retire exactly this game.
    var processIdentifier: pid_t

    /// The presence this publishes. Type 0 is "Playing".
    ///
    /// **A game added by hand goes out by name alone.** Its id is Wingcord's
    /// own (`RegisteredGamesStore.manualID`), which no application on Discord
    /// has; sending it as one would name an application that does not exist.
    var activity: RichPresenceActivity {
        RichPresenceActivity(
            type: 0,
            name: name,
            timestamps: .init(start: Int(startedAt.timeIntervalSince1970 * 1000), end: nil),
            applicationID: isAddedByHand ? nil : id
        )
    }

    /// Whether the reader added it — Wingcord's own ids carry the top bit.
    var isAddedByHand: Bool { id.rawValue & (1 << 63) != 0 }
}

@Observable
@MainActor
final class GameDetector {

    /// What is running now, or nil.
    ///
    /// **One game, not a set.** Discord publishes a single activity for a
    /// running game and the roster draws one line; a reader with two games open
    /// gets the one they started most recently, which is the one they are
    /// looking at.
    private(set) var runningGame: DetectedGame?

    /// Everything running that could be added by hand — the Registered Games
    /// picker's list. Resolved on demand, never kept in step.
    var candidates: [RunningCandidate] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let name = app.localizedName,
                  let url = app.executableURL
            else { return nil }
            return RunningCandidate(
                processIdentifier: app.processIdentifier, name: name, executableURL: url
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    struct RunningCandidate: Hashable, Sendable, Identifiable {
        var processIdentifier: pid_t
        var name: String
        var executableURL: URL
        var id: pid_t { processIdentifier }
    }

    /// Called whenever `runningGame` changes, so the session can republish.
    var onChange: (() -> Void)?

    @ObservationIgnored private var index = DetectableGameIndex(games: [])
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Games the reader added by hand, by executable path. Registered Games
    /// writes this; detection reads it.
    @ObservationIgnored private var manual: [String: DetectedGameOverride] = [:]

    struct DetectedGameOverride: Hashable, Sendable {
        var id: ApplicationID
        var name: String
    }

    // MARK: Lifetime

    /// Loads the catalog and starts watching.
    ///
    /// **The cached catalog is applied before the network is touched**, so a
    /// game already running at launch is detected in the first frame rather
    /// than after a four-megabyte download.
    func start() {
        guard observers.isEmpty else { return }
        let centre = NSWorkspace.shared.notificationCenter
        // **Only the pid crosses the closure**, and that is not a style
        // choice: `Notification` and `NSRunningApplication` are both
        // non-`Sendable`, so capturing either into a main-actor closure is a
        // compile error under Swift 6. The queue is already `.main`, so the
        // read below happens on the main thread; the pid is an `Int32` and the
        // application is resolved again on the other side.
        observers = [
            centre.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let pid = app?.processIdentifier else { return }
                MainActor.assumeIsolated { self?.applicationLaunched(pid: pid) }
            },
            centre.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let pid = app?.processIdentifier else { return }
                MainActor.assumeIsolated { self?.applicationTerminated(pid: pid) }
            },
        ]
        refreshTask = Task { [weak self] in await self?.loadCatalog() }
    }

    func stop() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
        if runningGame != nil {
            runningGame = nil
            onChange?()
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    // MARK: The catalog

    private func loadCatalog() async {
        // Disk first. `DetectableGamesCache.load` decodes about four megabytes,
        // so it happens off the main actor and only the index comes back.
        let cached = await Task.detached(priority: .utility) {
            DetectableGamesCache.load()
        }.value
        if let cached {
            apply(games: cached.games)
        }

        do {
            let fetched = try await Task.detached(priority: .utility) {
                try await DetectableGames.fetch(etag: cached?.etag)
            }.value
            // nil is a 304: the cached copy is current and there is nothing to
            // do. Not an error, and not a reason to clear anything.
            guard let fetched else { return }
            apply(games: fetched.games)
            await Task.detached(priority: .utility) {
                DetectableGamesCache.save(fetched)
            }.value
        } catch {
            // A catalog that will not download costs detection until the next
            // launch, and nothing else. There is nothing for the reader to do
            // about it and nothing worth putting on screen.
            Breadcrumbs.record("games: catalog fetch failed")
        }
    }

    private func apply(games: [DetectableGame]) {
        index = DetectableGameIndex(games: games)
        // A game may already have been running before the catalog arrived.
        //
        // **And the session has to hear about it.** `rescan` only moves the
        // value; a game already open when Wingcord launched was matched here
        // and never published, because nothing told the session — it stayed
        // invisible until the game quit.
        let before = runningGame
        rescan()
        if runningGame != before { onChange?() }
    }

    // MARK: Watching

    private func applicationLaunched(pid: pid_t) {
        // Resolved again rather than carried: see the note in `start()`. A
        // process that died between the notification and here is simply gone.
        guard let app = NSRunningApplication(processIdentifier: pid),
              let detected = detect(app)
        else { return }
        // The newest launch wins. See `runningGame`.
        runningGame = detected
        onChange?()
    }

    private func applicationTerminated(pid: pid_t) {
        guard runningGame?.processIdentifier == pid else { return }
        runningGame = nil
        // Something else may still be running — a launcher left open behind the
        // game, or a second game.
        rescan()
        onChange?()
    }

    /// Walks everything running and keeps the newest match.
    ///
    /// **Only on a catalog change or a termination**, never on a timer: a scan
    /// reads the arguments of every regular application the reader has open,
    /// which is a syscall each.
    private func rescan() {
        var newest: DetectedGame?
        for app in NSWorkspace.shared.runningApplications {
            guard let detected = detect(app) else { continue }
            if newest == nil || detected.startedAt > newest!.startedAt { newest = detected }
        }
        guard newest != runningGame else { return }
        // A game already running keeps the clock it was first seen with, so a
        // rescan does not reset somebody's elapsed time to zero.
        if let newest, let existing = runningGame, existing.id == newest.id {
            return
        }
        runningGame = newest
    }

    private func detect(_ app: NSRunningApplication) -> DetectedGame? {
        guard app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let executable = app.executableURL
        else { return nil }

        // A game the reader added by hand wins over the database: they said so.
        if let override = manual[executable.path] {
            return DetectedGame(
                id: override.id,
                name: override.name,
                startedAt: Date(),
                isLauncher: false,
                isTranslated: false,
                processIdentifier: app.processIdentifier
            )
        }

        guard !index.isEmpty else { return nil }
        let process = RunningProcess(
            executablePath: executable.path,
            arguments: ProcessInspector.arguments(of: app.processIdentifier),
            localizedName: app.localizedName
        )
        guard let match = index.match(process) else { return nil }
        return DetectedGame(
            id: match.game.id,
            name: match.game.name,
            startedAt: Date(),
            isLauncher: match.isLauncher,
            isTranslated: match.isTranslated,
            processIdentifier: app.processIdentifier
        )
    }

    // MARK: Games added by hand

    /// Registers `game` for the executable at `path`, the way Discord's
    /// "Add it!" does.
    func addManualGame(_ game: DetectedGameOverride, forExecutableAt path: String) {
        manual[path] = game
        rescan()
        onChange?()
    }

    func removeManualGame(forExecutableAt path: String) {
        manual[path] = nil
        rescan()
        onChange?()
    }
}
