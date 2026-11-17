import Foundation
import Testing
@testable import Wingcord
@testable import WingcordNet

/// The web build kept between launches: the next launch's identity, raised
/// only, read again after a day (docs/ACTIVITY-CARDS.md decision 1).
@Suite("Client build cache")
struct ClientBuildCacheTests {

    private func cache() -> ClientBuildCache {
        let name = "wingcord.tests.clientbuild.\(UUID().uuidString)"
        return ClientBuildCache(suiteName: name)
    }

    @Test func nothingStoredSendsTheShippedFloor() {
        let cache = cache()
        #expect(cache.baseline.webBuildNumber == ClientMetadata.Baseline.current.webBuildNumber)
        #expect(cache.isStale())
    }

    @Test func aNewerReadingIsWhatTheNextLaunchSends() {
        let cache = cache()
        let newer = ClientMetadata.Baseline.current.webBuildNumber + 1_234
        cache.record(newer, now: .now)
        #expect(cache.baseline.webBuildNumber == newer)
        #expect(!cache.isStale())
    }

    @Test func anOlderReadingNeverLowersIt() {
        let cache = cache()
        cache.record(ClientMetadata.Baseline.current.webBuildNumber - 50_000, now: .now)
        #expect(cache.baseline.webBuildNumber == ClientMetadata.Baseline.current.webBuildNumber)
    }

    @Test func aFailedReadStillWaitsADay() {
        let cache = cache()
        let then = Date(timeIntervalSince1970: 1_800_000_000)
        cache.record(nil, now: then)
        #expect(!cache.isStale(now: then.addingTimeInterval(3600)))
        #expect(cache.isStale(now: then.addingTimeInterval(ClientBuildCache.interval + 1)))
    }
}
