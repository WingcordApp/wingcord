import OSLog

/// Named intervals on the paths a profile is read for.
///
/// **So a recording answers "what was the main thread doing" in the app's own
/// words.** A Time Profiler trace names functions, and the question after a
/// freeze is rarely which function: it is which *job* — one transcript layout,
/// or forty; a server list built once, or five times a second. Each interval
/// here shows as a bar under Points of Interest in Instruments, so how often a
/// job ran and how long each run took can be read straight off the timeline.
///
/// They cost next to nothing when nothing is recording: the signposter checks
/// that it is enabled and returns.
nonisolated enum Signposts {
    static let signposter = OSSignposter(
        subsystem: "dev.wingcord.Wingcord", category: .pointsOfInterest
    )

    /// Runs `work` inside an interval named `name`.
    static func interval<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try work()
    }
}
