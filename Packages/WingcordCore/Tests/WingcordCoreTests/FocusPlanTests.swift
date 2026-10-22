import Foundation
import Testing
@testable import WingcordCore

/// What a macOS Focus does to the reader's status, and what its end puts back.
struct FocusPlanTests {
    private let now = Date(timeIntervalSince1970: 1_792_500_000)
    private let focusing = CustomStatus(text: "Focusing", emoji: EmojiRef(name: "🌙"))
    private let gaming = CustomStatus(text: "In a match")
    private let own = CustomStatus(text: "Back at 5")

    @Test("A Focus sets its status and remembers the one before")
    func begins() {
        let changes = FocusPlan.begin(
            FocusRequest(status: .doNotDisturb, customStatus: focusing),
            currentStatus: .online, currentCustomStatus: own, existing: nil, now: now
        )
        #expect(changes.status == .doNotDisturb)
        #expect(changes.customStatus == .set(focusing))
        #expect(changes.takeover?.status == .init(before: .online, applied: .doNotDisturb))
        #expect(changes.takeover?.custom == .init(before: own, applied: focusing))
    }

    @Test("The end of a Focus puts back exactly what it changed")
    func ends() {
        let takeover = FocusTakeover(
            status: .init(before: .idle, applied: .doNotDisturb),
            custom: .init(before: nil, applied: focusing)
        )
        let changes = FocusPlan.end(
            currentStatus: .doNotDisturb, currentCustomStatus: focusing,
            existing: takeover, restores: true, now: now
        )
        #expect(changes.status == .idle)
        #expect(changes.customStatus == .set(nil))
        #expect(changes.takeover == nil)
    }

    @Test("An empty request is the end of a Focus — what the switch-off call carries")
    func emptyRequestEnds() {
        let takeover = FocusTakeover(status: .init(before: .online, applied: .doNotDisturb))
        let changes = FocusPlan.begin(
            FocusRequest(), currentStatus: .doNotDisturb, currentCustomStatus: nil,
            existing: takeover, now: now
        )
        #expect(changes.status == .online)
        #expect(changes.takeover == nil)
    }

    @Test("A status changed by hand during the Focus is left alone at its end")
    func respectsHandChanges() {
        let takeover = FocusTakeover(
            status: .init(before: .online, applied: .doNotDisturb),
            custom: .init(before: own, applied: focusing)
        )
        let changes = FocusPlan.end(
            currentStatus: .idle, currentCustomStatus: gaming,
            existing: takeover, restores: true, now: now
        )
        #expect(changes.changesNothing)
    }

    @Test("Invisible chosen by the reader is never raised to a visible status")
    func neverRaisesInvisible() {
        let changes = FocusPlan.begin(
            FocusRequest(status: .doNotDisturb), currentStatus: .invisible,
            currentCustomStatus: nil, existing: nil, now: now
        )
        #expect(changes.status == nil)
        #expect(changes.takeover == nil)
    }

    @Test("Switching Focus keeps the first 'before' and gives back what the second does not ask for")
    func switchesFocus() {
        let first = FocusPlan.begin(
            FocusRequest(status: .doNotDisturb, customStatus: focusing),
            currentStatus: .online, currentCustomStatus: nil, existing: nil, now: now
        )
        let second = FocusPlan.begin(
            FocusRequest(status: .idle), currentStatus: .doNotDisturb,
            currentCustomStatus: focusing, existing: first.takeover, now: now
        )
        #expect(second.status == .idle)
        #expect(second.customStatus == .set(nil))
        #expect(second.takeover?.status == .init(before: .online, applied: .idle))
        #expect(second.takeover?.custom == nil)
    }

    @Test("A hand change between two Focuses becomes the new 'before'")
    func handChangeBecomesBefore() {
        let takeover = FocusTakeover(status: .init(before: .online, applied: .doNotDisturb))
        let changes = FocusPlan.begin(
            FocusRequest(status: .doNotDisturb), currentStatus: .idle,
            currentCustomStatus: nil, existing: takeover, now: now
        )
        #expect(changes.takeover?.status == .init(before: .idle, applied: .doNotDisturb))
    }

    @Test("With 'put it back' off, the takeover is dropped and nothing changes")
    func restoreOff() {
        let takeover = FocusTakeover(status: .init(before: .online, applied: .doNotDisturb))
        let changes = FocusPlan.end(
            currentStatus: .doNotDisturb, currentCustomStatus: nil,
            existing: takeover, restores: false, now: now
        )
        #expect(changes.changesNothing)
        #expect(changes.takeover == nil)
    }

    @Test("A custom status that lapsed during the Focus is not brought back")
    func lapsedStatusStaysGone() {
        let lapsing = CustomStatus(text: "Lunch", expiresAt: now.addingTimeInterval(60))
        let takeover = FocusTakeover(custom: .init(before: lapsing, applied: focusing))
        let changes = FocusPlan.end(
            currentStatus: .online, currentCustomStatus: focusing,
            existing: takeover, restores: true, now: now.addingTimeInterval(3600)
        )
        #expect(changes.customStatus == .set(nil))
    }

    @Test("A takeover survives a relaunch")
    func takeoverRoundTrips() throws {
        let takeover = FocusTakeover(
            status: .init(before: .online, applied: .doNotDisturb),
            custom: .init(before: own, applied: focusing)
        )
        let data = try JSONEncoder().encode(takeover)
        #expect(try JSONDecoder().decode(FocusTakeover.self, from: data) == takeover)
    }
}
