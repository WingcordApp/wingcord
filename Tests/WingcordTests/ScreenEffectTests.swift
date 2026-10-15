import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Screen effects (REDESIGN.md R14): which words celebrate, and which arrivals
/// are news rather than history.
@Suite("Screen effects")
struct ScreenEffectTests {
    @Test("The Messages app's phrases, as whole words in any case")
    func phrases() {
        #expect(ScreenEffect.matching("Happy birthday!!") == .balloons)
        #expect(ScreenEffect.matching("congrats on the launch 🎉") == .confetti)
        #expect(ScreenEffect.matching("CONGRATULATIONS") == .confetti)
        #expect(ScreenEffect.matching("Selamat!") == .confetti)
        #expect(ScreenEffect.matching("happy new year, everyone") == .fireworks)
        #expect(ScreenEffect.matching("happy   birthday,\nyou") == .balloons)
    }

    @Test("Accents fold, and a phrase inside a longer word does not count")
    func boundaries() {
        #expect(ScreenEffect.matching("Félicitations, congrâts") == .confetti)
        #expect(ScreenEffect.matching("uncongratsable") == nil)
        #expect(ScreenEffect.matching("happybirthday") == nil)
        #expect(ScreenEffect.matching("") == nil)
        #expect(ScreenEffect.matching("see you at the birthday party") == nil)
    }

    @Test("Only messages newer than the transcript's newest, sent just now, celebrate")
    func arrivals() {
        let now = Date()
        let old = message("congrats", at: now.addingTimeInterval(-600), sequence: 1)
        let fresh = message("happy birthday", at: now.addingTimeInterval(-2), sequence: 2)
        let items: [TimelineItem] = [row(old), row(fresh)]

        // Newer than what was there, and fresh.
        #expect(ScreenEffect.celebrated(in: items, after: old.id, now: now) == .balloons)
        // Nothing newer arrived.
        #expect(ScreenEffect.celebrated(in: items, after: fresh.id, now: now) == nil)
        // A first page has no "before": it is history, not news.
        #expect(ScreenEffect.celebrated(in: items, after: nil, now: now) == nil)
        // A newer page of old messages reconnecting to the present is not news.
        let stale = message("congratulations", at: now.addingTimeInterval(-3_600), sequence: 3)
        let anchor = message("hi", at: now.addingTimeInterval(-7_200), sequence: 4)
        #expect(ScreenEffect.celebrated(in: [row(anchor), row(stale)], after: anchor.id, now: now) == nil)
    }

    @Test("The newest arrival that asks wins")
    func newestWins() {
        let now = Date()
        let before = message("hi", at: now.addingTimeInterval(-60), sequence: 1)
        let first = message("congrats!", at: now.addingTimeInterval(-3), sequence: 2)
        let second = message("happy new year", at: now.addingTimeInterval(-1), sequence: 3)
        let plain = message("ok", at: now, sequence: 4)
        let items: [TimelineItem] = [row(before), row(first), row(second), row(plain)]
        #expect(ScreenEffect.celebrated(in: items, after: before.id, now: now) == .fireworks)
    }

    private func message(_ content: String, at date: Date, sequence: UInt64) -> Message {
        Message(
            id: MessageID(minting: date, sequence: sequence),
            channelID: ChannelID(rawValue: 7),
            authorID: UserID(rawValue: 11),
            content: content
        )
    }

    private func row(_ message: Message) -> TimelineItem {
        .message(TimelineMessage(message: message, flags: [.head, .tail]))
    }
}
