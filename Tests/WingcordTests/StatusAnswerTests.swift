import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Answering somebody's custom status.
///
/// **There is no status route.** Captured both ways in
/// `reply + react to status.har`: reacting and replying both `POST` to the
/// conversation with the person, and the only thing that makes them about a
/// status is the content the client composes. The two bodies below are verbatim
/// from that capture.
@Suite("Answering a status")
@MainActor
struct StatusAnswerTests {

    private let status = CustomStatus(text: "test", emoji: EmojiRef(name: "🤷🏿"))

    /// The capture's own reaction body, byte for byte.
    @Test("A bare emoji composes the Reacted body")
    func reactionBody() {
        #expect(
            SessionController.statusAnswer(
                handle: "robinresting", status: status, answer: "😺"
            ) == "> -# *Reacted to robinresting's status*\n> 🤷🏿 test\n😺"
        )
    }

    /// And the reply's, which differs in exactly one word.
    @Test("Words compose the Replied body")
    func replyBody() {
        #expect(
            SessionController.statusAnswer(
                handle: "robinresting", status: status, answer: "nice"
            ) == "> -# *Replied to robinresting's status*\n> 🤷🏿 test\nnice"
        )
    }

    /// **The handle, not the display name.** The capture writes
    /// `robinresting's status` where that account's display name is something
    /// else — a client that wrote the display name would compose a sentence
    /// Discord's own never does.
    @Test("An emoji with a modifier is still a reaction")
    func modifiedEmojiIsAReaction() {
        let answer = SessionController.statusAnswer(
            handle: "alex", status: status, answer: "👍🏽"
        )
        #expect(answer.hasPrefix("> -# *Reacted"))
    }

    @Test("An emoji with words beside it is a reply")
    func emojiWithWordsIsAReply() {
        let answer = SessionController.statusAnswer(
            handle: "alex", status: status, answer: "😺 nice one"
        )
        #expect(answer.hasPrefix("> -# *Replied"))
    }

    /// Either half of a status may be missing and the quote is still one line.
    @Test("A status with only words, or only an emoji, quotes cleanly")
    func halfStatusesQuoteCleanly() {
        #expect(
            SessionController.statusAnswer(
                handle: "alex", status: CustomStatus(text: "afk"), answer: "ok"
            ) == "> -# *Replied to alex's status*\n> afk\nok"
        )
        #expect(
            SessionController.statusAnswer(
                handle: "alex",
                status: CustomStatus(emoji: EmojiRef(name: "🌙")),
                answer: "ok"
            ) == "> -# *Replied to alex's status*\n> 🌙\nok"
        )
    }

    /// A custom emoji goes in as the composer spells it, not as its name.
    @Test("A custom status emoji is quoted as a mention")
    func customEmojiIsQuotedAsAMention() {
        let custom = CustomStatus(
            text: "hi",
            emoji: EmojiRef(id: EmojiID(rawValue: 12), name: "wave", isAnimated: true)
        )
        #expect(
            SessionController.statusAnswer(handle: "alex", status: custom, answer: "yo")
                .contains("<a:wave:12>")
        )
    }

    @Test("An empty answer composes nothing to send")
    func emptyAnswerSendsNothing() {
        #expect(
            SessionController.statusAnswer(handle: "alex", status: status, answer: "   ")
                .isEmpty
        )
    }

    /// The whole reason this is plain markdown: it renders as a quoted reply on
    /// every client, including the ones that have never heard of the feature.
    /// **Our own transcript is one of those**, so the shape has to parse here.
    @Test("The composed body parses as a quote holding subtext")
    func bodyParsesAsAQuotedSubtext() {
        let body = SessionController.statusAnswer(
            handle: "robinresting", status: status, answer: "nice"
        )
        let blocks = MarkdownParser().parse(body).blocks
        guard case .quote(let inner)? = blocks.first else {
            Issue.record("first block is not a quote: \(blocks)")
            return
        }
        guard case .subtext? = inner.first else {
            Issue.record("quote does not open with subtext: \(inner)")
            return
        }
        // The answer itself is outside the quote, which is what puts it in the
        // reader's own voice under the thing it answers.
        #expect(blocks.count == 2)
    }
}
