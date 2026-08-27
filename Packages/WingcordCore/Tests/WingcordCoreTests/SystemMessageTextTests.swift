import Foundation
import Testing
@testable import WingcordCore

/// The words under a `#welcome` channel are the client's, not the sender's.
@Suite("System message text")
struct SystemMessageTextTests {

    private func message(_ kind: MessageKind, id: UInt64 = 1) -> Message {
        Message(
            id: MessageID(rawValue: id),
            channelID: ChannelID(rawValue: 1),
            authorID: UserID(rawValue: 2),
            kind: kind
        )
    }

    @Test("A join names the member and nothing else")
    func joinNamesTheMember() {
        let sentence = SystemMessageText.sentence(
            for: message(.userJoin), name: "cinq"
        )
        #expect(sentence?.name == "cinq")
        #expect(sentence?.symbolName == "arrow.right")
        #expect(sentence?.tint == .affirmative)
        let whole = (sentence?.prefix ?? "") + (sentence?.name ?? "") + (sentence?.suffix ?? "")
        #expect(whole.contains("cinq"))
    }

    /// **The line is chosen by the message's own timestamp**, so the sentence
    /// under somebody's join is the same on every client, in every session, and
    /// after every re-fetch. A random choice would rewrite the channel's history
    /// on each scroll.
    @Test("The same message always gets the same line")
    func joinLineIsStable() {
        let id: UInt64 = 1_542_487_081_703_353_040
        let first = SystemMessageText.sentence(for: message(.userJoin, id: id), name: "cinq")
        let second = SystemMessageText.sentence(for: message(.userJoin, id: id), name: "cinq")
        #expect(first == second)
    }

    /// Every line in the table has to be reachable, or the ones past the end are
    /// dead weight nobody ever sees.
    @Test("Every welcome line is reachable")
    func everyLineIsReachable() {
        var seen = Set<String>()
        // A snowflake's high 42 bits are a millisecond timestamp, so stepping
        // the id by one millisecond steps the selection by one.
        for step in 0..<SystemMessageText.joinLines.count {
            let id = UInt64(step) << 22
            guard let sentence = SystemMessageText.sentence(
                for: message(.userJoin, id: id), name: "x"
            ) else { continue }
            seen.insert(sentence.prefix + "|" + sentence.suffix)
        }
        #expect(seen.count == SystemMessageText.joinLines.count)
    }

    @Test("A boost says which level it reached")
    func boostLevel() {
        let sentence = SystemMessageText.sentence(for: message(.guildBoostTier2), name: "ada")
        #expect(sentence?.suffix.contains("Level 2") == true)
    }

    /// Leaving and being removed arrive as the same wire kind and read very
    /// differently. Getting this backwards accuses somebody of a kick.
    @Test("Leaving and being removed are told apart by the subject")
    func departureVersusRemoval() {
        let left = SystemMessageText.sentence(
            for: message(.recipientRemove), name: "ada", subject: "ada"
        )
        let removed = SystemMessageText.sentence(
            for: message(.recipientRemove), name: "ada", subject: "bob"
        )
        #expect(left?.suffix.contains("left") == true)
        #expect(removed?.suffix.contains("removed") == true)
    }

    /// Anything somebody actually typed must fall through to the ordinary row.
    @Test(
        "A real message has no composed sentence",
        arguments: [MessageKind.default, .reply, .chatInputCommand, .threadStarterMessage]
    )
    func realMessagesAreNotSystem(_ kind: MessageKind) {
        #expect(SystemMessageText.sentence(for: message(kind), name: "ada") == nil)
    }
}
