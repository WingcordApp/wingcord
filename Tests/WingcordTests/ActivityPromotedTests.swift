import Testing
import WingcordCore
@testable import Wingcord

/// Discord's PROMOTED badge (Alex, 2026-11-18): an application flag, not an
/// ad decision — `ApplicationFlags.PROMOTED`, `1 << 29`.
@Suite("Promoted activities")
struct ActivityPromotedTests {
    private let id = ApplicationID(rawValue: 880_218_394_199_220_334)

    @Test("Bit 29 of the application's flags is the badge")
    func promotedFlag() {
        var app = ActivityApp(id: id, name: "How to Rob a Bank")
        #expect(!app.isPromoted)
        app.flags = 1 << 29
        #expect(app.isPromoted)
        // The neighbouring bits — `QUEST` is 38 — are not it.
        app.flags = (1 << 38) | (1 << 30)
        #expect(!app.isPromoted)
    }

    @Test("A launcher row carries the badge from its app")
    func rowCarriesIt() {
        var app = ActivityApp(id: id, name: "EXOPLANET")
        app.flags = 1 << 29
        #expect(AppModel.row(for: app).isPromoted)
    }
}
