import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Slowmode: the wait's own rules, the sentence it is described with, and the
/// store deciding who waits and when a send is held back.
@Suite("Slowmode")
@MainActor
struct SlowmodeTests {

    private let readerID = UserID(rawValue: 1)
    private let ownerID = UserID(rawValue: 2)
    private let slowGuild = GuildID(rawValue: 100)
    private let ownGuild = GuildID(rawValue: 200)
    /// Ten seconds of slowmode, in a server the reader is an ordinary member of.
    private let slow = ChannelID(rawValue: 1001)
    /// No slowmode, same server.
    private let fast = ChannelID(rawValue: 1002)
    /// Five seconds of slowmode, same server.
    private let brief = ChannelID(rawValue: 1003)
    /// Slowmode, in a server the reader owns — so they hold Bypass Slowmode.
    private let owned = ChannelID(rawValue: 2001)
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.guilds = [
            slowGuild: Guild(id: slowGuild, name: "Counter-Strike", ownerID: ownerID),
            ownGuild: Guild(id: ownGuild, name: "Mine", ownerID: readerID),
        ]
        // `@everyone` may talk and nothing more — in particular, not bypass.
        let everyone = RoleID(rawValue: slowGuild.rawValue)
        model.roles[slowGuild] = [
            everyone: Role(
                id: everyone,
                name: "@everyone",
                position: 0,
                permissions: [.viewChannel, .sendMessages, .readMessageHistory]
            ),
        ]
        model.members[slowGuild] = [readerID: Member(userID: readerID, roleIDs: [])]

        var index = ChannelIndex()
        index.replaceChannels(
            [
                Channel(
                    id: slow, kind: .text, guildID: slowGuild, name: "general",
                    rateLimitPerUser: 10
                ),
                Channel(id: fast, kind: .text, guildID: slowGuild, name: "media"),
                Channel(
                    id: brief, kind: .text, guildID: slowGuild, name: "trading",
                    rateLimitPerUser: 5
                ),
            ],
            inGuild: slowGuild
        )
        index.replaceChannels(
            [Channel(id: owned, kind: .text, guildID: ownGuild, name: "mine", rateLimitPerUser: 60)],
            inGuild: ownGuild
        )
        model.channelIndex = index
        return model
    }

    // MARK: The wait

    @Test("A landed send starts the limit plus Discord's tenth of a second")
    func afterSend() throws {
        let cooldown = try #require(SlowmodeCooldown.afterSend(rateLimit: 10, now: now))
        #expect(cooldown.endsAt == now.addingTimeInterval(10.1))
        #expect(cooldown.rateLimit == 10)
        #expect(SlowmodeCooldown.afterSend(rateLimit: 0, now: now) == nil)
    }

    @Test("What the server reports is what is left, plus the same tenth")
    func reported() throws {
        // The captured typing answer: 1096 ms left.
        let cooldown = try #require(SlowmodeCooldown.reported(1.096, rateLimit: 5, now: now))
        #expect(cooldown.endsAt == now.addingTimeInterval(1.196))
        #expect(SlowmodeCooldown.reported(0, rateLimit: 5, now: now) == nil)
        #expect(SlowmodeCooldown.reported(3, rateLimit: 0, now: now) == nil)
    }

    @Test("A changed limit moves a running wait, and only a changed one")
    func reconciled() throws {
        let running = try #require(SlowmodeCooldown.afterSend(rateLimit: 60, now: now))
        let later = now.addingTimeInterval(5)

        // A channel event that did not touch the limit leaves it alone.
        #expect(running.reconciled(toRateLimit: 60, now: later) == running)
        // Lowered: never longer than the new limit from now.
        #expect(running.reconciled(toRateLimit: 10, now: later)?.endsAt == later.addingTimeInterval(10))
        // Raised: the wait does not grow — Discord's `min(remaining, limit)`.
        #expect(running.reconciled(toRateLimit: 120, now: later)?.endsAt == running.endsAt)
        // Slowmode off ends it.
        #expect(running.reconciled(toRateLimit: 0, now: later) == nil)
    }

    // MARK: The sentence

    @Test("The limit is described the way Discord's strings describe it", arguments: [
        (1, "1 second"),
        (10, "10 seconds"),
        (60, "1 minute"),
        (150, "2 minutes 30 seconds"),
        (3600, "1 hour"),
        (3725, "1 hour 2 minutes 5 seconds"),
        (21600, "6 hours"),
    ])
    func sentence(seconds: Int, span: String) {
        #expect(SlowmodeSentence.span(seconds) == span)
        #expect(
            SlowmodeSentence.describe(rateLimit: seconds)
                == "Slowmode is enabled. Members can send one message every \(span)."
        )
    }

    // MARK: The store

    @Test("A send in a slowmode channel starts a wait that holds the next one")
    func startsAndHolds() throws {
        let model = model()
        model.startSlowmode(afterSendIn: slow, now: now)

        #expect(model.slowmodeWait(in: slow, now: now) == now.addingTimeInterval(10.1))
        #expect(model.slowmodeWait(in: slow, now: now.addingTimeInterval(11)) == nil)

        // Held, and the hold is announced to the one channel it happened in.
        #expect(model.holdsForSlowmode(slow, now: now))
        let first = try #require(model.slowmodeNudge)
        #expect(first.channelID == slow)
        // A second hold is a second nudge, or the indicator would not flash
        // for it.
        #expect(model.holdsForSlowmode(slow, now: now))
        #expect(model.slowmodeNudge != first)
        // And once the wait is over, nothing is held.
        #expect(!model.holdsForSlowmode(slow, now: now.addingTimeInterval(11)))
    }

    @Test("A channel with no slowmode never waits, and never flashes")
    func noLimitNoWait() {
        let model = model()
        model.startSlowmode(afterSendIn: fast, now: now)
        #expect(model.slowmodeCooldowns[fast] == nil)
        #expect(!model.holdsForSlowmode(fast))
        #expect(model.slowmodeNudge == nil)
    }

    @Test("A reader who holds Bypass Slowmode is never made to wait")
    func immune() {
        let model = model()
        #expect(model.isSlowmodeImmune(in: owned))
        #expect(!model.isSlowmodeImmune(in: slow))

        model.startSlowmode(afterSendIn: owned, now: now)
        model.applySlowmode(remaining: 30, in: owned, now: now)
        #expect(model.slowmodeCooldowns[owned] == nil)
        #expect(!model.holdsForSlowmode(owned))
    }

    @Test("A typing answer sets the wait a send elsewhere started")
    func typingAnswer() {
        let model = model()
        model.applySlowmode(remaining: 4, in: slow, now: now)
        #expect(model.slowmodeWait(in: slow, now: now) == now.addingTimeInterval(4.1))
    }

    @Test("A refusal with no wait in it still starts one, and flashes")
    func refusalWithoutWait() {
        let model = model()
        model.applySlowmodeRefusal(retryAfter: nil, in: slow)
        #expect(model.slowmodeWait(in: slow) != nil)
        #expect(model.slowmodeNudge?.channelID == slow)
    }

    @Test("A moderator changing the limit moves the running wait")
    func channelUpdate() throws {
        let model = model()
        model.startSlowmode(afterSendIn: slow, now: now)

        var channel = try #require(model.channelIndex[slow])
        channel.rateLimitPerUser = 0
        model.channelIndex.upsert(channel)
        model.reconcileSlowmode(in: slow, now: now)
        #expect(model.slowmodeCooldowns[slow] == nil)
        #expect(!model.holdsForSlowmode(slow))
    }

    @Test("Expired waits are swept when a new one is set")
    func sweep() {
        let model = model()
        model.startSlowmode(afterSendIn: brief, now: now)
        // Twenty seconds on, `brief`'s five have long run out.
        model.startSlowmode(afterSendIn: slow, now: now.addingTimeInterval(20))
        #expect(Set(model.slowmodeCooldowns.keys) == [slow])
    }

    // MARK: Sending

    @Test("A send held for slowmode leaves the draft and the reply where they were")
    func heldSendKeepsTheDraft() {
        let model = model()
        let reply = MessageID(rawValue: 42)
        model.mutateBox(slow) {
            $0.draft = "is Prime worth it"
            $0.replyingTo = reply
        }
        model.startSlowmode(afterSendIn: slow, now: .now)

        model.sendMessage("is Prime worth it", in: slow)

        #expect(model.messages(in: slow)?.draft == "is Prime worth it")
        #expect(model.messages(in: slow)?.replyingTo == reply)
        #expect(model.slowmodeNudge?.channelID == slow)
    }

    @Test("An empty Return inside a wait is not a send, and flashes nothing")
    func emptyReturnIsNotHeld() {
        let model = model()
        model.startSlowmode(afterSendIn: slow, now: .now)
        model.sendMessage("   ", in: slow)
        #expect(model.slowmodeNudge == nil)
    }

    @Test("A draft comes back after a failed send, but never over a new one")
    func restoresOnlyIntoAnEmptyComposer() {
        let model = model()
        let lost = UnsentDraft(text: "old ones were way better", replyingTo: MessageID(rawValue: 7))

        model.restoreDraft(lost, in: slow)
        #expect(model.messages(in: slow)?.draft == "old ones were way better")
        #expect(model.messages(in: slow)?.replyingTo == MessageID(rawValue: 7))

        model.mutateBox(fast) { $0.draft = "typing the next one" }
        model.restoreDraft(lost, in: fast)
        #expect(model.messages(in: fast)?.draft == "typing the next one")
    }
}
