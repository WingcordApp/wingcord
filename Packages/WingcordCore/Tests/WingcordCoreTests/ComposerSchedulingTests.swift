import Foundation
import Testing
@testable import WingcordCore

/// Discord's scheduling window and its poll editor's rules, against a fixed
/// clock and calendar.
struct ComposerSchedulingTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        return calendar
    }

    /// Thursday 2 October 2026 at the given local time.
    private func thursday(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: hour, minute: minute))!
    }

    private func local(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    // MARK: The window

    @Test("Early in the day both suggestions are today, and Monday is next week's")
    func morningPresets() {
        let presets = ScheduleWindow.presets(at: thursday(7), calendar: calendar)
        #expect(presets.map(\.title) == ["Today at 9:00am", "Today at 1:00pm", "Monday at 9:00am"])
        #expect(presets.map(\.date) == [local(2, 9), local(2, 13), local(5, 9)])
    }

    @Test("A suggestion inside the ten minutes moves to tomorrow")
    func latePresets() {
        let presets = ScheduleWindow.presets(at: thursday(8, 55), calendar: calendar)
        #expect(presets.map(\.title) == ["Tomorrow at 9:00am", "Today at 1:00pm", "Monday at 9:00am"])
        #expect(presets[0].date == local(3, 9))
    }

    @Test("On a Sunday, Monday is tomorrow; on a Monday, it is a week away")
    func mondayIsNextWeek() {
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 20))!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 7))!
        #expect(ScheduleWindow.presets(at: sunday, calendar: calendar)[2].date == local(5, 9))
        #expect(ScheduleWindow.presets(at: monday, calendar: calendar)[2].date == local(12, 9))
    }

    @Test("The custom picker starts on the next hour, or the one after inside ten minutes")
    func suggestedTime() {
        #expect(ScheduleWindow.suggestedTime(at: thursday(14, 20), calendar: calendar) == thursday(15))
        #expect(ScheduleWindow.suggestedTime(at: thursday(14, 55), calendar: calendar) == thursday(16))
    }

    @Test("Ten minutes to eight days")
    func bounds() {
        let now = thursday(12)
        #expect(ScheduleWindow.problem(with: now.addingTimeInterval(599), at: now) == .tooSoon)
        #expect(ScheduleWindow.problem(with: now.addingTimeInterval(600), at: now) == nil)
        #expect(ScheduleWindow.problem(with: now.addingTimeInterval(691_200), at: now) == nil)
        #expect(ScheduleWindow.problem(with: now.addingTimeInterval(691_201), at: now) == .tooFar)
    }

    // MARK: The poll editor

    @Test("A blank editor is refused for its question and its answers, and closes without asking")
    func blankPoll() {
        let draft = PollDraft()
        #expect(draft.problems == [.noQuestion, .noAnswers])
        #expect(draft.isUntouched)
    }

    @Test("Blank answers are dropped, not refused; an emoji with no words is refused")
    func answers() {
        var draft = PollDraft(question: "Pizza?")
        draft.answers[0].text = "  Yes  "
        #expect(draft.problems.isEmpty)
        #expect(draft.postedAnswers.map(\.text) == ["  Yes  "])

        draft.answers[1].emoji = EmojiRef(name: "🍕")
        #expect(draft.problems == [.answerWithoutWords(draft.answers[1].id)])
        #expect(!draft.isUntouched)
    }

    @Test("Ten answers at most, one at least")
    func answerCount() {
        var draft = PollDraft(answers: (0..<PollDraft.answerCountLimit).map { _ in PollDraft.Answer() })
        #expect(!draft.canAddAnswer)
        draft.answers = [PollDraft.Answer()]
        #expect(!draft.canRemoveAnswer)
    }

    @Test("The echo numbers the posted answers from one and expires with the duration")
    func echo() {
        var draft = PollDraft(question: " Lunch? ", duration: .threeDays)
        draft.answers = [
            PollDraft.Answer(text: ""),
            PollDraft.Answer(text: "Pizza", emoji: EmojiRef(name: "🍕")),
            PollDraft.Answer(text: "Sushi "),
        ]
        let posted = Date(timeIntervalSince1970: 1_790_000_000)
        let poll = draft.poll(postedAt: posted)
        #expect(poll.question == "Lunch?")
        #expect(poll.answers.map(\.id) == [1, 2])
        #expect(poll.answers.map(\.text) == ["Pizza", "Sushi"])
        #expect(poll.answers[0].emoji?.name == "🍕")
        #expect(poll.expiresAt == posted.addingTimeInterval(72 * 3600))
    }

    @Test("Durations read as Discord's labels")
    func durationTitles() {
        #expect(PollDraft.Duration.allCases.map(\.title)
            == ["1 hour", "4 hours", "8 hours", "24 hours", "3 days", "1 week", "2 weeks"])
    }
}
