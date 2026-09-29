import Foundation
import Testing
import WingcordCore

/// The entry that is the current activity, and so not a recent one.
///
/// **The report**: the game somebody was playing sat in Recent activity under
/// its own current card. Discord leaves a live, unexpired entry out of the list
/// (modules `146655` and `583846`) and draws its chips on the card instead.
@Suite("Ongoing activity")
struct RecentActivityOngoingTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(live: Bool, expiresIn: TimeInterval?, name: String = "Counter-Strike 2") -> RecentActivity {
        RecentActivity(
            id: "1",
            authorID: UserID(rawValue: 1),
            subject: .game(name: name, applicationID: ApplicationID(rawValue: 730)),
            traits: live ? [.live, .streak(days: 21), .trending] : [.streak(days: 21)],
            expiresAt: expiresIn.map { now.addingTimeInterval($0) }
        )
    }

    @Test("Live and unexpired is happening now; expired or finished is recent")
    func ongoing() {
        #expect(entry(live: true, expiresIn: 600).isOngoing(at: now))
        #expect(entry(live: true, expiresIn: nil).isOngoing(at: now))
        #expect(!entry(live: true, expiresIn: -1).isOngoing(at: now))
        #expect(!entry(live: false, expiresIn: 600).isOngoing(at: now))
    }

    @Test("An entry is the record of the activity with its application, or its name")
    func records() {
        let playing = Activity(kind: .playing, name: "Counter-Strike 2", applicationID: ApplicationID(rawValue: 730))
        let byName = Activity(kind: .playing, name: "Counter-Strike 2")
        let other = Activity(kind: .playing, name: "Esports Manager 2026", applicationID: ApplicationID(rawValue: 9))
        let row = entry(live: true, expiresIn: 600)
        #expect(row.records(playing))
        #expect(row.records(byName))
        #expect(!row.records(other))
    }
}
