import Foundation

/// A poll attached to a message.
///
/// Discord sends the question, the answers and the tally as one object beside
/// `content`, so a message carrying one has **no body at all** — a renderer that
/// does not know about polls draws an author line over an empty row, which on a
/// voting channel is every message in it.
public struct Poll: Hashable, Sendable, Codable {
    public struct Answer: Hashable, Sendable, Codable, Identifiable {
        /// Discord's own answer id, which is what a vote is cast against.
        public var id: Int
        public var text: String
        public var emoji: EmojiRef?
        public var count: Int
        /// Whether the reader picked this one.
        public var isMine: Bool

        public init(id: Int, text: String, emoji: EmojiRef? = nil, count: Int = 0, isMine: Bool = false) {
            self.id = id
            self.text = text
            self.emoji = emoji
            self.count = count
            self.isMine = isMine
        }
    }

    public var question: String
    public var answers: [Answer]
    /// When voting closes. Nil for a poll with no expiry.
    public var expiresAt: Date?
    public var allowsMultiselect: Bool
    /// Whether Discord has finalised the tally.
    ///
    /// **Not the same as expired**, and both are needed: a poll can be past its
    /// expiry with the tally not yet sealed, and until it is sealed the counts
    /// are provisional. The reader is told "closed" on either.
    public var isFinalized: Bool

    public init(
        question: String,
        answers: [Answer],
        expiresAt: Date? = nil,
        allowsMultiselect: Bool = false,
        isFinalized: Bool = false
    ) {
        self.question = question
        self.answers = answers
        self.expiresAt = expiresAt
        self.allowsMultiselect = allowsMultiselect
        self.isFinalized = isFinalized
    }

    public var totalVotes: Int {
        answers.reduce(0) { $0 + $1.count }
    }

    /// Whether voting is over.
    public var isClosed: Bool {
        if isFinalized { return true }
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    /// Whether the reader has already voted.
    public var hasVoted: Bool {
        answers.contains { $0.isMine }
    }

    /// **Results are shown once there is a reason to show them**, which is after
    /// the reader has voted or after the poll has closed. Before that the bars
    /// would tell everybody how to vote, which is the whole reason Discord hides
    /// them too.
    public var showsResults: Bool {
        isClosed || hasVoted
    }

    /// One answer's share of the vote, 0...1.
    ///
    /// Zero total votes is a real state — a poll nobody has answered — and
    /// dividing by it would produce a bar of NaN width, which lays out as a
    /// crash rather than as an empty bar.
    public func share(of answer: Answer) -> Double {
        let total = totalVotes
        guard total > 0 else { return 0 }
        return Double(answer.count) / Double(total)
    }

    /// The answer with the most votes, once the poll has closed and there is an
    /// unambiguous one. Nil on a tie, because "winning answer" is a claim and a
    /// tie is not one.
    public var winner: Answer? {
        guard isClosed, totalVotes > 0 else { return nil }
        let best = answers.max { $0.count < $1.count }
        guard let best, answers.filter({ $0.count == best.count }).count == 1 else { return nil }
        return best
    }
}
