import Foundation

/// A poll being written — Discord's poll editor (module `143657`) as a value.
///
/// **Discord's limits, from `412136`**: a question of 300 characters, up to ten
/// answers of 55, at least one of them with words, and a life of one hour to two
/// weeks. Blank answers are dropped as it posts rather than refused, so the two
/// empty rows the editor opens with cost nothing; an answer with an emoji and no
/// words is refused, because it would post as a bare picture.
public struct PollDraft: Hashable, Sendable {
    public struct Answer: Hashable, Sendable, Identifiable {
        /// This editor's own handle on the row, never sent.
        public let id: UUID
        public var text: String
        public var emoji: EmojiRef?

        public init(id: UUID = UUID(), text: String = "", emoji: EmojiRef? = nil) {
            self.id = id
            self.text = text
            self.emoji = emoji
        }

        var hasWords: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// How long voting stays open. The raw value is Discord's own: hours.
    public enum Duration: Int, CaseIterable, Hashable, Sendable, Identifiable {
        case oneHour = 1
        case fourHours = 4
        case eightHours = 8
        case oneDay = 24
        case threeDays = 72
        case oneWeek = 168
        case twoWeeks = 336

        public var id: Int { rawValue }

        public var title: String {
            switch self {
            case .oneHour: "1 hour"
            case .fourHours, .eightHours, .oneDay: "\(rawValue) hours"
            case .threeDays: "3 days"
            case .oneWeek: "1 week"
            case .twoWeeks: "2 weeks"
            }
        }
    }

    /// Why Post was refused — Discord's three sentences, one per field.
    public enum Problem: Hashable, Sendable {
        case noQuestion
        /// Pinned to the first answer row, as Discord pins it.
        case noAnswers
        case answerWithoutWords(Answer.ID)

        public var message: String {
            switch self {
            case .noQuestion: "Oops, you forgot something. Please add a question."
            case .noAnswers: "Oops, you forgot something. Please add at least one answer."
            case .answerWithoutWords: "Don\u{2019}t leave the answer field hanging! Please add some text."
            }
        }
    }

    public static let questionLimit = 300
    public static let answerLimit = 55
    public static let answerCountLimit = 10
    public static let minimumAnswerCount = 1

    public var question: String
    public var answers: [Answer]
    public var allowsMultiselect: Bool
    public var duration: Duration
    /// Set by Schedule Poll: the poll is queued rather than posted.
    public var scheduledAt: Date?

    /// Discord's blank editor: two empty answers and a day.
    public init(
        question: String = "",
        answers: [Answer] = [Answer(), Answer()],
        allowsMultiselect: Bool = false,
        duration: Duration = .oneDay,
        scheduledAt: Date? = nil
    ) {
        self.question = question
        self.answers = answers
        self.allowsMultiselect = allowsMultiselect
        self.duration = duration
        self.scheduledAt = scheduledAt
    }

    /// The answers that are posted: every one with words, in order.
    public var postedAnswers: [Answer] { answers.filter(\.hasWords) }

    /// What stops Post, in the order the fields sit. Empty when it may go.
    public var problems: [Problem] {
        var problems: [Problem] = []
        if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append(.noQuestion)
        }
        if postedAnswers.count < Self.minimumAnswerCount {
            problems.append(.noAnswers)
        }
        for answer in answers where answer.emoji != nil && !answer.hasWords {
            problems.append(.answerWithoutWords(answer.id))
        }
        return problems
    }

    /// Nothing written yet, so closing loses nothing — Discord asks "Are you
    /// sure?" only past this.
    public var isUntouched: Bool {
        question.isEmpty && !answers.contains(where: \.hasWords)
    }

    public var canAddAnswer: Bool { answers.count < Self.answerCountLimit }
    public var canRemoveAnswer: Bool { answers.count > Self.minimumAnswerCount }

    /// The poll as the transcript draws it before Discord has answered — the
    /// echo of a send. Answers are numbered from 1, as Discord numbers them.
    public func poll(postedAt date: Date) -> Poll {
        Poll(
            question: question.trimmingCharacters(in: .whitespacesAndNewlines),
            answers: postedAnswers.enumerated().map { index, answer in
                Poll.Answer(
                    id: index + 1,
                    text: answer.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    emoji: answer.emoji
                )
            },
            expiresAt: date.addingTimeInterval(TimeInterval(duration.rawValue) * 3600),
            allowsMultiselect: allowsMultiselect
        )
    }
}
