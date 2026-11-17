import Foundation
import WingcordNet

/// The web build Discord's page last said, kept between launches.
///
/// **Read at launch, refreshed in the background, used from the next launch.**
/// The identity a session sends is fixed for its life — a build number that
/// changed between two requests of one session is the one thing a real client
/// never does — so a fresher number waits for the next connection. A day
/// between reads: Discord ships several builds a day, and a number a day old is
/// still years ahead of a shipped constant.
nonisolated struct ClientBuildCache: Sendable {
    private static let numberKey = "client.discordWebBuild"
    private static let checkedKey = "client.discordWebBuildCheckedAt"
    static let interval: TimeInterval = 24 * 3600

    /// The defaults suite, by name, so the value is `Sendable` and can cross
    /// into the background read; nil is the app's own.
    var suiteName: String? = nil

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// The newest number known: the cached one when it is ahead of the
    /// shipped floor, the floor otherwise.
    var baseline: ClientMetadata.Baseline {
        let cached = defaults.integer(forKey: Self.numberKey)
        return ClientMetadata.Baseline.current.with(webBuildNumber: cached > 0 ? cached : nil)
    }

    /// Whether a day has passed since the page was last read.
    func isStale(now: Date = .now) -> Bool {
        guard let checked = defaults.object(forKey: Self.checkedKey) as? Date else { return true }
        return now.timeIntervalSince(checked) >= Self.interval
    }

    /// Records a reading. A failed read still counts as a check, so a page
    /// that changed shape is asked once a day rather than at every launch.
    func record(_ number: Int?, now: Date = .now) {
        defaults.set(now, forKey: Self.checkedKey)
        if let number { defaults.set(number, forKey: Self.numberKey) }
    }
}
