import Foundation
import Testing
@testable import WingcordCore

/// Who is where on a stage.
///
/// The split is the whole of the surface's logic, and it is a pure function of
/// the voice states — which is why it is tested here rather than through a
/// pane that would need a store, a socket and a room full of people.
@Suite("Stage roster")
struct StageRosterTests {

    private func state(
        _ id: UInt64,
        suppressed: Bool,
        requestedAt: Date? = nil
    ) -> VoiceState {
        VoiceState(
            userID: UserID(rawValue: id),
            channelID: ChannelID(rawValue: 1),
            isSuppressed: suppressed,
            requestToSpeakAt: requestedAt
        )
    }

    @Test("`suppress` is what makes somebody the audience")
    func suppressSplitsTheRoom() {
        // The rule the whole surface rests on, and the one that is easy to get
        // wrong: a suppressed member is *not* a muted speaker. They have no
        // microphone on the stage at all, and the two are drawn differently
        // because the acts that undo them are different.
        let roster = StageRoster.resolve([
            state(1, suppressed: false),
            state(2, suppressed: true),
            state(3, suppressed: false),
        ])
        #expect(roster.speakers.map(\.rawValue) == [1, 3])
        #expect(roster.audience.map(\.rawValue) == [2])
    }

    @Test("A raised hand is still in the audience")
    func aHandIsAlsoAListener() {
        // The two lists overlap by design: somebody with their hand up has not
        // left the audience, and the moderator's queue is a view onto it
        // rather than a fourth place to stand. Drawing them only in the queue
        // would make the audience count wrong by exactly the number of people
        // asking to join it.
        let roster = StageRoster.resolve([
            state(1, suppressed: true, requestedAt: Date(timeIntervalSince1970: 10)),
            state(2, suppressed: true),
        ])
        #expect(roster.audience.map(\.rawValue) == [1, 2])
        #expect(roster.requests.map(\.rawValue) == [1])
    }

    @Test("A speaker's stale timestamp is not a request")
    func aSpeakerIsNeverInTheQueue() {
        // **This is the trap the route sets.** Unsuppressing somebody sets
        // their `request_to_speak_timestamp` to *now* — Discord does it, not
        // the client — so an invited speaker comes back with a raised hand in
        // the payload. A queue that filtered on the timestamp alone would keep
        // showing the person it just promoted.
        let roster = StageRoster.resolve([
            state(1, suppressed: false, requestedAt: Date(timeIntervalSince1970: 10)),
        ])
        #expect(roster.speakers.map(\.rawValue) == [1])
        #expect(roster.requests.isEmpty)
    }

    @Test("Hands are ordered oldest first")
    func theQueueIsAQueue() {
        // Which is why the field is a timestamp and not a flag: the moderator
        // answers them in the order they went up, and a `Bool` cannot say.
        let roster = StageRoster.resolve([
            state(3, suppressed: true, requestedAt: Date(timeIntervalSince1970: 30)),
            state(1, suppressed: true, requestedAt: Date(timeIntervalSince1970: 10)),
            state(2, suppressed: true, requestedAt: Date(timeIntervalSince1970: 20)),
        ])
        #expect(roster.requests.map(\.rawValue) == [1, 2, 3])
    }

    @Test("Two hands raised in the same instant still have an order")
    func tiesAreStable() {
        // Not hypothetical: the client computes the timestamp it sends, and
        // two of them can agree. An unstable order here is a queue that
        // reshuffles under the moderator's pointer between one repaint and the
        // next.
        let instant = Date(timeIntervalSince1970: 10)
        let forwards = StageRoster.resolve([
            state(2, suppressed: true, requestedAt: instant),
            state(1, suppressed: true, requestedAt: instant),
        ])
        let backwards = StageRoster.resolve([
            state(1, suppressed: true, requestedAt: instant),
            state(2, suppressed: true, requestedAt: instant),
        ])
        #expect(forwards.requests == backwards.requests)
        #expect(forwards.requests.map(\.rawValue) == [1, 2])
    }

    @Test("An empty channel is three empty lists, not a nil")
    func emptyIsEmpty() {
        let roster = StageRoster.resolve([])
        #expect(roster.speakers.isEmpty)
        #expect(roster.audience.isEmpty)
        #expect(roster.requests.isEmpty)
    }

    /// `public` is deprecated by Discord and still on the wire, so it decodes
    /// rather than being folded into guild-only — a client that read every
    /// unknown value as private would quietly claim a public stage was not.
    @Test("Both privacy levels survive the wire")
    func privacyLevels() {
        #expect(StagePrivacyLevel(rawValue: 1) == .publicStage)
        #expect(StagePrivacyLevel(rawValue: 2) == .guildOnly)
        // Anything Discord adds later is guild-only, which is the safe
        // direction: it under-claims reach rather than over-claiming it.
        #expect(StagePrivacyLevel(rawValue: 7) == .guildOnly)
    }
}
