import Foundation

/// An opt-in trace of the connection's lifecycle, written to a file.
///
/// **A file, not stderr, and not only the unified log.** The app is normally
/// launched by Finder, where stderr goes nowhere a person can read; and `log
/// stream` interleaves the handful of lines that matter with everything else on
/// the machine. A connection that never comes up is diagnosed by reading the
/// ORDER of six events, and this is the cheapest way to get exactly those six.
///
/// Off by default and free when off — the check is one `Bool` read.
///
/// ```sh
/// defaults write dev.wingcord.Wingcord traceSession -bool YES
/// tail -f ~/Library/Application\ Support/Wingcord/Diagnostics/session.log
/// ```
nonisolated enum DiagnosticLog {
    /// Enabled by the defaults key or by the environment variable, so it can be
    /// turned on for a Finder launch *or* a terminal one.
    static let isEnabled: Bool =
        ProcessInfo.processInfo.environment["WINGCORD_TRACE"] == "1"
            || UserDefaults.standard.bool(forKey: "traceSession")

    private nonisolated(unsafe) static var handle: FileHandle? = {
        guard isEnabled else { return nil }
        let directory = CrashReporter.reportDirectory
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appending(path: "session.log")
        // Truncated per launch. A log that grows forever is one nobody reads,
        // and the interesting run is always the most recent one.
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()

    private static let lock = NSLock()
    private static let start = ContinuousClock.now

    /// Records one line, stamped with milliseconds since launch.
    ///
    /// The stamp is what makes the log worth having: "validating token" followed
    /// twenty seconds later by nothing says *where* the time went, which the
    /// lines alone do not.
    static func trace(_ category: String, _ message: @autoclosure () -> String) {
        guard isEnabled, let handle else { return }
        let elapsed = ContinuousClock.now - start
        let milliseconds = elapsed.components.seconds * 1000
            + elapsed.components.attoseconds / 1_000_000_000_000_000
        let line = "[\(milliseconds)ms] \(category): \(message())\n"
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
