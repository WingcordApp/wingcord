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

    /// Types 27–31 used to fall through to `unknown` and draw as "Message"
    /// beside an empty circle — Alex's images 20 and 21.
    @Test("The five stage kinds are recognised")
    func stageKinds() {
        #expect(MessageKind(rawValue: 27) == .stageStart)
        #expect(MessageKind(rawValue: 28) == .stageEnd)
        #expect(MessageKind(rawValue: 29) == .stageSpeaker)
        #expect(MessageKind(rawValue: 30) == .stageRaiseHand)
        #expect(MessageKind(rawValue: 31) == .stageTopic)
    }

    /// Discord's `Rv+TSM` / `zla/ux` / `Yy6vLs`: the topic is the message's
    /// content, set in bold after the verb.
    @Test("A stage's start, end and topic change carry the topic in bold")
    func stageTopicSentences() {
        func sentence(_ kind: MessageKind) -> SystemSentence? {
            var message = message(kind)
            message.content = "Friday Q&A"
            return SystemMessageText.sentence(for: message, name: "ada")
        }
        let start = sentence(.stageStart)
        #expect(start?.suffix == " started ")
        #expect(start?.emphasis == "Friday Q&A")
        #expect(start?.tint == .affirmative)
        #expect(sentence(.stageEnd)?.suffix == " ended ")
        #expect(sentence(.stageEnd)?.emphasis == "Friday Q&A")
        #expect(sentence(.stageTopic)?.suffix == " changed the Stage topic: ")
        #expect(sentence(.stageTopic)?.emphasis == "Friday Q&A")
    }

    @Test("A new speaker and a raised hand are plain sentences")
    func stageMemberSentences() {
        let speaker = SystemMessageText.sentence(for: message(.stageSpeaker), name: "ada")
        let hand = SystemMessageText.sentence(for: message(.stageRaiseHand), name: "ada")
        #expect(speaker?.suffix == " is now a speaker.")
        #expect(speaker?.emphasis.isEmpty == true)
        #expect(hand?.suffix == " requested to speak.")
        #expect(hand?.symbolName == "hand.raised.fill")
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

// MARK: - A poll that has ended

/// `POLL_RESULT`, type 46.
///
/// **The words are in an embed, and the row has nothing else.** The message's
/// content is empty and the embed is a bag of fields — so a renderer that knew
/// neither drew an author line over a blank space, which is what a closed poll
/// looked like in this transcript.
@Suite("Poll result messages")
struct PollResultMessageTests {

    private func message(fields: [Embed.Field]) -> Message {
        Message(
            id: MessageID(rawValue: 1 << 22),
            channelID: ChannelID(rawValue: 1),
            authorID: UserID(rawValue: 1),
            kind: .pollResult,
            payload: MessagePayload(embeds: [Embed(kind: "poll_result", fields: fields)])
        )
    }

    private func field(_ name: String, _ value: String) -> Embed.Field {
        Embed.Field(name: name, value: value, isInline: false)
    }

    @Test("Type 46 is a poll result, not an unknown message")
    func kindIsRecognised() {
        #expect(MessageKind(rawValue: 46) == .pollResult)
    }

    @Test("The question and the winner come out of the embed's fields")
    func readsTheFields() {
        let result = message(fields: [
            field("poll_question_text", "Nightly builds?"),
            field("victor_answer_text", "Yes, let them break!"),
            field("victor_answer_votes", "10"),
            field("total_votes", "12"),
        ]).pollResult
        #expect(result?.question == "Nightly builds?")
        #expect(result?.winner == "Yes, let them break!")
        #expect(abs((result?.share ?? 0) - 10.0 / 12.0) < 0.001)
    }

    @Test("A poll nobody voted in claims no winner")
    func noVotes() {
        // Saying a winner won with 0% is a claim the wire did not make.
        let sentence = SystemMessageText.sentence(
            for: message(fields: [field("poll_question_text", "Anything?")]),
            name: "vexlor"
        )
        #expect(sentence?.suffix.contains("Nobody voted") == true)
        #expect(sentence?.suffix.contains("Anything?") == true)
    }

    @Test("The sentence names the winner and its share")
    func sentenceCarriesTheOutcome() {
        let sentence = SystemMessageText.sentence(
            for: message(fields: [
                field("poll_question_text", "Nightly builds?"),
                field("victor_answer_text", "Yes, let them break!"),
                field("victor_answer_votes", "10"),
                field("total_votes", "12"),
            ]),
            name: "vexlor"
        )
        #expect(sentence?.name == "vexlor")
        #expect(sentence?.suffix.contains("Yes, let them break!") == true)
        #expect(sentence?.suffix.contains("83%") == true)
    }

    @Test("The result embed is never drawn as a card")
    func embedIsNotDrawn() {
        // It is a bag of field names — `victor_answer_id` and the rest — and an
        // ordinary embed card would list them at somebody.
        let message = message(fields: [field("poll_question_text", "Nightly builds?")])
        #expect(message.embeds.count == 1)
        #expect(message.drawableEmbeds.isEmpty)
    }
}
