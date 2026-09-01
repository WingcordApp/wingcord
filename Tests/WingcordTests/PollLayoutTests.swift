import AppKit
import CoreGraphics
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// A poll's rectangles, which are also its only feedback.
@MainActor
@Suite("Poll layout")
struct PollLayoutTests {

    private let style = MessageTextStyle.current()

    private func poll(
        counts: [Int],
        mine: Int? = nil,
        finalized: Bool = false
    ) -> Poll {
        var answers: [Poll.Answer] = []
        for (index, count) in counts.enumerated() {
            let id = index + 1
            answers.append(Poll.Answer(
                id: id,
                text: "Answer \(id)",
                emoji: EmojiRef(name: "🔥"),
                count: count,
                isMine: id == mine
            ))
        }
        return Poll(question: "Pick one", answers: answers, isFinalized: finalized)
    }

    private func layout(_ value: Poll, width: CGFloat = 400) -> PollSlot {
        PollLayoutEngine.layout(
            value, origin: .zero, availableWidth: width, style: style
        )
    }

    @Test("Every answer gets a row, and the card encloses them all")
    func rowsAreEnclosed() {
        let slot = layout(poll(counts: [10, 2, 0]))
        #expect(slot.answers.count == 3)
        for answer in slot.answers {
            #expect(answer.rect.maxY <= slot.rect.maxY)
            #expect(answer.rect.maxX <= slot.rect.maxX)
        }
        #expect(slot.questionOrigin.y >= slot.rect.minY)
    }

    /// **Results are hidden until there is a reason to show them.** Bars before
    /// the reader has voted tell everybody how to vote.
    @Test("An open poll the reader has not answered shows no bars and no tally")
    func resultsAreHiddenBeforeVoting() {
        let slot = layout(poll(counts: [10, 2]))
        #expect(slot.answers.allSatisfy { $0.share == 0 })
        #expect(slot.answers.allSatisfy { $0.tally == nil })
        #expect(slot.isVotable)
    }

    @Test("After voting the bars and the tally appear, and voting is over")
    func resultsAppearAfterVoting() {
        let slot = layout(poll(counts: [10, 2], mine: 1))
        #expect(slot.answers[0].share > slot.answers[1].share)
        #expect(slot.answers.allSatisfy { $0.tally != nil })
        #expect(slot.answers[0].isMine)
        #expect(!slot.isVotable)
    }

    /// A closed poll cannot be voted in, and the winner is marked.
    @Test("A closed poll marks its winner and refuses a vote")
    func closedPoll() {
        let slot = layout(poll(counts: [10, 2], finalized: true))
        #expect(!slot.isVotable)
        #expect(slot.answers[0].isWinner)
        #expect(!slot.answers[1].isWinner)
    }

    /// Dividing by zero lays out as a crash, not as an empty bar.
    @Test("A poll nobody has answered has no share and no crash")
    func noVotes() {
        let slot = layout(poll(counts: [0, 0], finalized: true))
        #expect(slot.answers.allSatisfy { $0.share == 0 })
        #expect(slot.answers.allSatisfy { !$0.isWinner })
    }

    /// The tally is reserved before the label is laid out, so a long answer
    /// wraps around it rather than running underneath.
    @Test("A long answer leaves the tally room")
    func labelLeavesRoomForTheTally() throws {
        var value = poll(counts: [10, 2], mine: 1)
        value.answers[0].text = String(repeating: "a very long answer ", count: 6)
        let slot = layout(value)
        let answer = slot.answers[0]
        #expect(answer.labelOrigin.x + answer.label.size.width <= answer.tallyOrigin.x + 1)
        // A voted poll always lays out a tally, so its absence is a failure of
        // the layout rather than a case to skip past.
        let tally = try #require(answer.tally)
        #expect(answer.tallyOrigin.x + tally.size.width <= answer.rect.maxX)
    }

    @Test("The card is capped at the embed width, never the column's")
    func widthIsCapped() {
        #expect(layout(poll(counts: [1]), width: 900).rect.width == Metrics.embedMaxWidth)
        #expect(layout(poll(counts: [1]), width: 220).rect.width == 220)
    }
}
