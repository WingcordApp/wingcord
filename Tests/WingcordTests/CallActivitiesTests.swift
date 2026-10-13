import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// The call's activity suggestions: the shelf's top launchable apps, in the
/// shelf's own order — Discord's `getShelfActivities(guildId)`.
@MainActor
@Suite("Call activities")
struct CallActivitiesTests {

    private func app(_ id: UInt64, launchable: Bool = true) -> ActivityApp {
        ActivityApp(
            id: ApplicationID(rawValue: id),
            name: "App \(id)",
            config: launchable ? EmbeddedActivityConfig(supportedPlatforms: ["web"]) : nil
        )
    }

    @Test("Suggestions follow the shelf's order and skip what cannot launch")
    func suggestions() {
        let model = AppModel()
        let apps = [app(3), app(1, launchable: false), app(2), app(4), app(5), app(6), app(7)]
        model.activityDirectory = ActivityDirectory(
            collections: [],
            apps: Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) }),
            shelf: apps.map(\.id)
        )
        #expect(model.suggestedActivities(5).map(\.id.rawValue) == [3, 2, 4, 5, 6])
        #expect(model.suggestedActivities(3).map(\.id.rawValue) == [3, 2, 4])
    }

    /// The shelf that spun for ever: the directory is `@ObservationIgnored`,
    /// so a view that read only it never heard it arrive. Reading the
    /// suggestions must subscribe to the counter the directory announces
    /// itself through.
    @Test("Reading the suggestions hears the directory arrive")
    func suggestionsAreObserved() {
        let model = AppModel()
        let heard = Heard()
        withObservationTracking {
            _ = model.suggestedActivities(5)
        } onChange: {
            heard.value = true
        }
        model.activityRevision &+= 1
        #expect(heard.value)
    }
}

nonisolated private final class Heard: @unchecked Sendable {
    var value = false
}
