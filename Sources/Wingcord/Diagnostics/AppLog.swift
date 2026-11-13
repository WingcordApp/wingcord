import AppKit
import Foundation
import WingcordCore

/// The app's half of the log (docs/BUG-REPORTING.md D18): opening it at launch,
/// the install's salt, and the lines only the app can write — launch, quit,
/// sleep and wake.
///
/// **Opened before anything else can log**, right after the crash handler, so
/// the first line of a run is its launch and every package's line has
/// somewhere to go.
nonisolated enum AppLog {
    /// The developer's switch for detailed logging for the whole run, as the
    /// session trace was: `defaults write dev.wingcord.Wingcord traceSession
    /// -bool YES`, or `WINGCORD_TRACE=1` from a terminal.
    static let isTracingEverything: Bool =
        ProcessInfo.processInfo.environment["WINGCORD_TRACE"] == "1"
            || UserDefaults.standard.bool(forKey: "traceSession")

    /// Opens the rings and writes the launch line. Idempotent.
    static func start() {
        guard Log.store == nil else { return }
        let directory = CrashReporter.reportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scrubber = LogScrubber(salt: InstallSalt.read(in: directory))
        let store = LogStore.open(in: directory, scrubber: scrubber)
        Log.install(store)
        if isTracingEverything {
            Log.setDetailed(true)
            mirrorToSessionLog(store, in: directory)
        }

        let bundle = Bundle.main
        let system = ProcessInfo.processInfo.operatingSystemVersion
        Log.info(
            .app,
            "launched \(public: bundle.displayVersion) (\(public: bundle.buildVersion))"
                + " on macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
                + " \(public: SystemFacts.machineModel()), detailed=\(Log.isDetailed)"
        )
        observeSystem()
    }

    /// **The developer's live view**, as the session trace was: every line,
    /// as the rings get it, appended to `session.log` — truncated per launch —
    /// so `tail -f` follows a run as it happens. The rings are fixed-size
    /// files overwritten in place, which `tail` cannot follow.
    ///
    /// ```sh
    /// defaults write dev.wingcord.Wingcord traceSession -bool YES
    /// tail -f ~/Library/Application\ Support/Wingcord/Diagnostics/session.log
    /// ```
    private static func mirrorToSessionLog(_ store: LogStore, in directory: URL) {
        let url = directory.appending(path: "session.log")
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        let lock = NSLock()
        store.setMirror { line in
            lock.lock()
            defer { lock.unlock() }
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    /// The last line of a run that ended on purpose. Its absence is what says,
    /// on the next launch, that a run did not.
    static func finish() {
        Log.info(.app, "quit")
    }

    /// Sleep and wake, which explain a connection that dropped and a call that
    /// ended better than anything the connection itself can say.
    private static func observeSystem() {
        let centre = NSWorkspace.shared.notificationCenter
        centre.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
            Log.info(.app, "the Mac is going to sleep")
        }
        centre.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            Log.info(.app, "the Mac woke")
        }
    }
}

/// The install's secret: 32 random bytes in the diagnostics folder, mixed into
/// every hash the log prints (`LogScrubber.hash`).
///
/// **Per install, never sent.** Without it a hash in a report could be undone
/// by hashing candidate ids; with it, one channel is one name across a report
/// and across reports from this Mac, and nothing more.
nonisolated enum InstallSalt {
    static let fileName = "install-salt"

    static func read(in directory: URL) -> [UInt8] {
        let url = directory.appending(path: fileName)
        if let data = try? Data(contentsOf: url), data.count == 32 {
            return Array(data)
        }
        var generator = SystemRandomNumberGenerator()
        let salt = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        FileManager.default.createFile(
            atPath: url.path(percentEncoded: false),
            contents: Data(salt),
            attributes: [.posixPermissions: 0o600]
        )
        return salt
    }
}

/// How the last run ended, read once at launch (docs/BUG-REPORTING.md D19).
///
/// **A crash leaves a report; a hang somebody gave up on leaves a marker.**
/// The crash handler's file is empty unless the run crashed, and the
/// watchdog's marker is deleted when a hang ends — so either one still there
/// at the next launch is how the last run ended. The newest of them is what
/// the launch-time prompt offers to report, once.
nonisolated enum PreviousRun {
    /// A report the last run left, not yet offered.
    nonisolated struct Ending: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case crash
            /// Closed while the main thread was not answering.
            case hang
        }

        var kind: Kind
        var file: URL
    }

    /// What `review()` found, for the prompt to offer.
    nonisolated(unsafe) private(set) static var unoffered: Ending?

    private static let offeredKey = "diagnostics.lastOfferedReport"
    /// Reports kept on disk: the newest ten, none past ninety days (§2's
    /// "retention ends by itself").
    private static let keptReports = 10
    private static let keptFor: TimeInterval = 90 * 24 * 60 * 60

    static func review() {
        let directory = CrashReporter.reportDirectory
        let manager = FileManager.default

        if manager.fileExists(atPath: MainThreadWatchdog.hangMarkerURL.path(percentEncoded: false)) {
            let kept = directory.appending(path: "hang-\(Int(Date().timeIntervalSince1970)).txt")
            try? manager.moveItem(at: MainThreadWatchdog.hangMarkerURL, to: kept)
            Log.fault(.perf, "the last run was closed while its main thread was not answering")
        }

        prune(in: directory)

        let candidates = reports(in: directory)
        guard let newest = candidates.first else { return }
        let kind: Ending.Kind = newest.lastPathComponent.hasPrefix("hang-") ? .hang : .crash
        if kind == .crash {
            let firstLine = (try? String(contentsOf: newest, encoding: .utf8))?
                .split(separator: "\n").first { $0.hasPrefix("===") }
                .map(String.init) ?? "a crash report"
            Log.fault(.app, .raw("a crash report is waiting from an earlier run: \(firstLine)"))
        }
        guard UserDefaults.standard.string(forKey: offeredKey) != newest.lastPathComponent else { return }
        unoffered = Ending(kind: kind, file: newest)
    }

    /// Says the report has been offered, so it is never offered again.
    static func markOffered() {
        guard let unoffered else { return }
        UserDefaults.standard.set(unoffered.file.lastPathComponent, forKey: offeredKey)
        Self.unoffered = nil
    }

    /// Crash reports and hang markers with something in them, newest first.
    static func reports(in directory: URL = CrashReporter.reportDirectory) -> [URL] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)
        )) ?? []
        return contents
            .filter { url in
                let name = url.lastPathComponent
                guard (name.hasPrefix("crash-") || name.hasPrefix("hang-")), name.hasSuffix(".txt") else { return false }
                return ((try? url.resourceValues(forKeys: keys))?.fileSize ?? 0) > 0
            }
            .sorted { modified($0) > modified($1) }
    }

    private static func prune(in directory: URL) {
        let cutoff = Date().addingTimeInterval(-keptFor)
        for (index, report) in reports(in: directory).enumerated()
        where index >= keptReports || modified(report) < cutoff {
            try? FileManager.default.removeItem(at: report)
        }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}
