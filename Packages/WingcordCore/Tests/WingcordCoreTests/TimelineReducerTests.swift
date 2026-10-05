import Foundation
import Testing
@testable import WingcordCore

@Suite("Timeline reducer")
struct TimelineReducerTests {

    /// Builds a message whose snowflake encodes `secondsFromEpoch`, so the run
    /// gap and day boundaries are exercised through the same path the app uses:
    /// the id, never a separate timestamp field.
    private func message(
        _ id: UInt64,
        author: UInt64,
        at secondsFromDiscordEpoch: Double,
        kind: MessageKind = .default,
        content: String = "hi"
    ) -> Message {
        let milliseconds = UInt64(secondsFromDiscordEpoch * 1000)
        let snowflake = MessageID(rawValue: (milliseconds << 22) | id)
        return Message(
            id: snowflake,
            channelID: ChannelID(rawValue: 1),
            authorID: UserID(rawValue: author),
            content: content,
            kind: kind
        )
    }

    private func messages(_ rows: [TimelineItem]) -> [TimelineMessage] {
        rows.compactMap { if case .message(let item) = $0 { item } else { nil } }
    }

    @Test("An empty channel with no history shows its beginning")
    func emptyChannel() {
        let rows = TimelineReducer.rows(messages: [])
        #expect(rows == [.conversationStart])
    }

    @Test("An empty page still loading is one quiet line, not a wall of bars")
    func emptyWithHistory() {
        let rows = TimelineReducer.rows(messages: [], hasMoreHistory: true, skeletonDepth: 20)
        #expect(rows == [.loadingFirstPage])
    }

    @Test("The runway is deeper than one flick can travel — above real messages")
    func runwayDepth() {
        // A runway is a gesture affordance: somewhere for a flick that is
        // already travelling to go. That only exists where there is already
        // content to flick, which is why the depth is asserted over a loaded
        // page and the empty case above gets a single line instead.
        //
        // Four groups is crossed in a few hundred milliseconds, less than a
        // round trip; twenty is past what one throw covers.
        let rows = TimelineReducer.rows(
            messages: [message(1, author: 10, at: 0)],
            hasMoreHistory: true
        )
        let skeletons = rows.filter { if case .historySkeleton = $0 { true } else { false } }
        let count = skeletons.count
        #expect(count == 20)
        // And the runway is ABOVE the content, not interleaved with it.
        let firstMessageIndex = rows.firstIndex { $0.messageID != nil }
        #expect(firstMessageIndex != nil)
        let lastSkeletonIndex = rows.lastIndex {
            if case .historySkeleton = $0 { true } else { false }
        }
        #expect(lastSkeletonIndex != nil)
        if let firstMessageIndex, let lastSkeletonIndex {
            #expect(lastSkeletonIndex < firstMessageIndex)
        }
    }

    @Test("A window cut off from the present gets a runway below it too")
    func newerRunway() {
        let rows = TimelineReducer.rows(
            messages: [message(1, author: 10, at: 0), message(2, author: 10, at: 1)],
            hasMoreHistory: true,
            hasMoreNewer: true
        )
        // Twenty above, twenty below, the messages between — and no two rows
        // the same value, so the index runs on rather than restarting.
        let skeletonIndices = rows.compactMap { item -> Int? in
            if case .historySkeleton(let index) = item { index } else { nil }
        }
        #expect(skeletonIndices == Array(0..<40))
        // Runway, the day, two messages, runway.
        #expect(rows.lastIndex { $0.messageID != nil } == 22)
        #expect(rows.count == 43)
    }

    @Test("A mark goes above its first message, which heads a run")
    func topicMarker() {
        let first = message(1, author: 10, at: 0)
        let start = message(2, author: 10, at: 1)
        let topic = TimelineMark(
            kind: .topic,
            id: 2,
            title: "Game state concerns",
            startMessageID: start.id,
            messageCount: 31
        )
        let rows = TimelineReducer.rows(messages: [first, start], marks: [topic])
        let markerIndex = rows.firstIndex { if case .marker = $0 { true } else { false } }
        #expect(markerIndex != nil)
        #expect(rows[(markerIndex ?? 0) + 1].messageID == start.id)
        // Same author a second later, and still a run head: the marker is
        // between them.
        #expect(messages(rows).last?.isRunHead == true)

        // One message is not a stretch worth marking.
        var single = topic
        single.messageCount = 1
        let unmarked = TimelineReducer.rows(messages: [first, start], marks: [single])
        #expect(!unmarked.contains { if case .marker = $0 { true } else { false } })
    }

    @Test("A summary and a topic beginning at one message are both marked, in order")
    func twoMarksAtOneMessage() {
        let start = message(2, author: 10, at: 1)
        let summary = TimelineMark(
            kind: .summary, id: 7, title: "Nitro Credits Bug",
            startMessageID: start.id, messageCount: 19
        )
        let topic = TimelineMark(
            kind: .topic, id: 9, title: "Credits",
            startMessageID: start.id, messageCount: 4
        )
        let rows = TimelineReducer.rows(messages: [start], marks: [summary, topic])
        let kinds = rows.compactMap { row -> TimelineMark.Kind? in
            if case .marker(let kind, _, _) = row { kind } else { nil }
        }
        #expect(kinds == [.summary, .topic])
        #expect(rows.last?.messageID == start.id)
    }

    @Test("A window that reaches the present ends on its newest message")
    func noNewerRunway() {
        let rows = TimelineReducer.rows(
            messages: [message(1, author: 10, at: 0)],
            hasMoreHistory: false,
            hasMoreNewer: false
        )
        #expect(rows.last?.messageID != nil)
    }

    @Test("A page that failed says so, rather than loading forever")
    func failedFirstPage() {
        // "Loading" and "failed" are the same picture from the reader's side,
        // and only one of them is going to change on its own.
        let rows = TimelineReducer.rows(
            messages: [],
            hasMoreHistory: true,
            failure: "Discord returned 500."
        )
        #expect(rows == [.historyUnavailable(reason: "Discord returned 500.")])
    }

    @Test("A failure outranks an empty beginning")
    func failureOutranksBeginning() {
        let rows = TimelineReducer.rows(
            messages: [],
            hasMoreHistory: false,
            failure: "You do not have access to this channel."
        )
        #expect(rows.count == 1)
        if case .historyUnavailable = rows[0] {} else {
            Issue.record("expected a failure row, got \(rows)")
        }
    }

    @Test("Consecutive messages from one author form a run")
    func runGrouping() {
        let rows = TimelineReducer.rows(messages: [
            message(1, author: 10, at: 0),
            message(2, author: 10, at: 30),
            message(3, author: 10, at: 60),
        ])
        let items = messages(rows)
        #expect(items.count == 3)
        #expect(items[0].isRunHead)
        #expect(!items[1].isRunHead)
        #expect(!items[2].isRunHead)
        #expect(items[2].isRunTail)
        #expect(!items[0].isRunTail)
    }

    @Test("A different author breaks the run")
    func differentAuthorBreaksRun() {
        let items = messages(TimelineReducer.rows(messages: [
            message(1, author: 10, at: 0),
            message(2, author: 11, at: 5),
        ]))
        #expect(items[0].isRunHead)
        #expect(items[0].isRunTail)
        #expect(items[1].isRunHead)
    }

    @Test("A gap longer than the run gap breaks the run")
    func gapBreaksRun() {
        let items = messages(TimelineReducer.rows(messages: [
            message(1, author: 10, at: 0),
            message(2, author: 10, at: TimelineReducer.runGap + 1),
        ]))
        #expect(items[1].isRunHead)
    }

    @Test("A gap inside the run gap does not")
    func shortGapKeepsRun() {
        let items = messages(TimelineReducer.rows(messages: [
            message(1, author: 10, at: 0),
            message(2, author: 10, at: TimelineReducer.runGap - 1),
        ]))
        #expect(!items[1].isRunHead)
    }

    @Test("A long burst is broken so the author line stays near the text")
    func runLengthCap() {
        var burst: [Message] = []
        for index in 0..<40 {
            burst.append(message(UInt64(index + 1), author: 10, at: Double(index)))
        }
        let items = messages(TimelineReducer.rows(messages: burst))
        let heads = items.count { $0.isRunHead }
        let capIndex = TimelineReducer.maximumRunLength
        #expect(heads == 2)
        #expect(items[capIndex].isRunHead)
    }

    @Test("A reply always starts its own run")
    func replyBreaksRun() {
        let items = messages(TimelineReducer.rows(messages: [
            message(1, author: 10, at: 0),
            message(2, author: 10, at: 5, kind: .reply),
        ]))
        #expect(items[1].isRunHead)
    }

    @Test("A system event never joins a run, in either direction")
    func systemEventBreaksRun() {
        let items = messages(TimelineReducer.rows(messages: [
            message(1, author: 10, at: 0),
            message(2, author: 10, at: 5, kind: .userJoin),
            message(3, author: 10, at: 10),
        ]))
        #expect(items[1].isRunHead)
        #expect(items[2].isRunHead)
    }

    @Test("A day change inserts one separator and breaks the run")
    func daySeparator() {
        let day: Double = 60 * 60 * 24
        let rows = TimelineReducer.rows(
            messages: [
                message(1, author: 10, at: 0),
                message(2, author: 10, at: day * 2),
            ],
            calendar: {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC")!
                return calendar
            }()
        )
        let separators = rows.count { if case .daySeparator = $0 { true } else { false } }
        // One for each day: the first message opens a day too.
        #expect(separators == 2)
        #expect(messages(rows)[1].isRunHead)
    }

    @Test("The unread divider sits before the first message past the anchor")
    func unreadDivider() {
        let list = [
            message(1, author: 10, at: 0),
            message(2, author: 10, at: 10),
            message(3, author: 10, at: 20),
        ]
        let rows = TimelineReducer.rows(messages: list, unreadAnchor: list[0].id)

        let dividerIndex = rows.firstIndex { if case .unreadDivider = $0 { true } else { false } }
        #expect(dividerIndex != nil)

        // The row directly after the divider is the second message.
        let afterDivider = (dividerIndex ?? -1) + 1
        if dividerIndex != nil, case .message(let item) = rows[afterDivider] {
            #expect(item.id == list[1].id)
            #expect(item.flags.contains(.firstUnread))
        } else {
            Issue.record("no message directly after the divider")
        }
    }

    @Test("Exactly one divider, however many unread messages there are")
    func singleDivider() {
        var list: [Message] = []
        for index in 0..<10 {
            list.append(message(UInt64(index + 1), author: 10, at: Double(index) * 5))
        }
        let rows = TimelineReducer.rows(messages: list, unreadAnchor: list[0].id)
        let dividers = rows.count { if case .unreadDivider = $0 { true } else { false } }
        #expect(dividers == 1)
    }

    @Test("Everything read means no divider")
    func noDividerWhenRead() {
        let list = [message(1, author: 10, at: 0), message(2, author: 10, at: 10)]
        let rows = TimelineReducer.rows(messages: list, unreadAnchor: list[1].id)
        #expect(!rows.contains { if case .unreadDivider = $0 { true } else { false } })
    }

    @Test("An anchor behind the loaded page puts the divider at the top")
    func anchorBehindPage() {
        let list = [message(5, author: 10, at: 100), message(6, author: 10, at: 110)]
        let rows = TimelineReducer.rows(
            messages: list,
            unreadAnchor: MessageID(rawValue: 1)
        )
        let dividerIndex = rows.firstIndex { if case .unreadDivider = $0 { true } else { false } }
        let afterDivider = (dividerIndex ?? -1) + 1
        if dividerIndex != nil, case .message(let item) = rows[afterDivider] {
            #expect(item.id == list[0].id)
        } else {
            Issue.record("divider not at the head of the page")
        }
    }

    @Test("A direct mention is flagged")
    func directMention() {
        var mentioned = message(1, author: 10, at: 0)
        mentioned.payload = MessagePayload(mentionedUserIDs: [UserID(rawValue: 99)])
        let items = messages(TimelineReducer.rows(
            messages: [mentioned],
            mentionedIDs: [99]
        ))
        #expect(items[0].flags.contains(.mentionsMe))
    }

    @Test("A role mention is flagged through the same set")
    func roleMention() {
        var mentioned = message(1, author: 10, at: 0)
        mentioned.payload = MessagePayload(mentionedRoleIDs: [RoleID(rawValue: 7)])
        let items = messages(TimelineReducer.rows(
            messages: [mentioned],
            mentionedIDs: [7]
        ))
        #expect(items[0].flags.contains(.mentionsMe))
    }

    @Test("Someone else's mention is not mine")
    func otherPersonsMention() {
        var mentioned = message(1, author: 10, at: 0)
        mentioned.payload = MessagePayload(mentionedUserIDs: [UserID(rawValue: 42)])
        let items = messages(TimelineReducer.rows(
            messages: [mentioned],
            mentionedIDs: [99]
        ))
        #expect(!items[0].flags.contains(.mentionsMe))
    }

    @Test("An @everyone counts, and can be told not to")
    func everyoneMention() {
        var mentioned = message(1, author: 10, at: 0)
        mentioned.payload = MessagePayload(mentionsEveryone: true)
        #expect(messages(TimelineReducer.rows(
            messages: [mentioned], mentionedIDs: [99]
        ))[0].flags.contains(.mentionsMe))
        #expect(!messages(TimelineReducer.rows(
            messages: [mentioned],
            mentionedIDs: [99],
            mentionsEveryoneCountsAsMention: false
        ))[0].flags.contains(.mentionsMe))
    }

    @Test("Every message belongs to exactly one run, head and tail balanced")
    func runsAreWellFormed() {
        var list: [Message] = []
        for index in 0..<60 {
            let id = UInt64(index + 1)
            let author = UInt64(index / 3 + 10)
            let seconds = Double(index) * 20
            list.append(message(id, author: author, at: seconds))
        }
        let items = messages(TimelineReducer.rows(messages: list))
        let heads = items.count { $0.isRunHead }
        let tails = items.count { $0.isRunTail }
        let lastIndex = items.count - 1
        #expect(items.count == 60)
        #expect(heads == tails)
        // The first row opens a run and the last closes one, always.
        #expect(items[0].isRunHead)
        #expect(items[lastIndex].isRunTail)
    }

    // MARK: Folds — Discord's MESSAGE_GROUP_BLOCKED / _IGNORED / _SUSPENDED_USER

    private func folds(_ rows: [TimelineItem]) -> [CollapsedGroup] {
        rows.compactMap { if case .collapsedGroup(let group) = $0 { group } else { nil } }
    }

    @Test("A blocked author's run is one shut line, and its messages are not rows")
    func blockedRunFolds() throws {
        let rows = TimelineReducer.rows(
            messages: [
                message(1, author: 10, at: 0),
                message(2, author: 66, at: 10),
                message(3, author: 66, at: 20),
                message(4, author: 10, at: 30),
            ],
            blockedUserIDs: [UserID(rawValue: 66)]
        )
        let fold = try #require(folds(rows).first)
        #expect(folds(rows).count == 1)
        #expect(fold.reason == .blocked && fold.count == 2 && !fold.isOpen)
        #expect(messages(rows).map(\.message.authorID.rawValue) == [10, 10])
        // The message after the fold starts a run of its own.
        #expect(messages(rows)[1].isRunHead)
    }

    @Test("Blocked and ignored fold apart, and an ignore never outranks a block")
    func reasonsDoNotMix() {
        let rows = TimelineReducer.rows(
            messages: [
                message(1, author: 66, at: 0),
                message(2, author: 77, at: 10),
                message(3, author: 88, at: 20),
            ],
            blockedUserIDs: [UserID(rawValue: 66), UserID(rawValue: 88)],
            ignoredUserIDs: [UserID(rawValue: 77), UserID(rawValue: 88)]
        )
        #expect(folds(rows).map(\.reason) == [.blocked, .ignored, .blocked])
    }

    @Test("A new day starts a new fold, as Discord's heading sits between them")
    func dayBreaksFold() {
        let day: Double = 86_400
        let rows = TimelineReducer.rows(
            messages: [
                message(1, author: 66, at: 0),
                message(2, author: 66, at: day * 2),
            ],
            blockedUserIDs: [UserID(rawValue: 66)],
            calendar: {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC")!
                return calendar
            }()
        )
        #expect(folds(rows).count == 2)
    }

    @Test("An AutoMod action never folds; a suspended account always does, and stays shut")
    func automodAndSuspended() throws {
        var suspended = message(2, author: 55, at: 10)
        suspended.flags = [.hiddenSuspendedUser]
        let rows = TimelineReducer.rows(
            messages: [message(1, author: 66, at: 0, kind: .autoModerationAction), suspended],
            blockedUserIDs: [UserID(rawValue: 66)],
            openGroups: [suspended.id]
        )
        #expect(messages(rows).count == 1)
        let fold = try #require(folds(rows).first)
        #expect(fold.reason == .suspended && !fold.canOpen && !fold.isOpen)
    }

    @Test("The unread line goes above a shut fold, wherever in it the line falls")
    func unreadAboveShutFold() throws {
        let first = message(1, author: 66, at: 10)
        let second = message(2, author: 66, at: 20)
        let rows = TimelineReducer.rows(
            messages: [message(3, author: 10, at: 0), first, second],
            unreadAnchor: first.id,
            blockedUserIDs: [UserID(rawValue: 66)]
        )
        let divider = try #require(rows.firstIndex(of: .unreadDivider))
        let fold = try #require(rows.firstIndex { if case .collapsedGroup = $0 { true } else { false } })
        #expect(divider == fold - 1)
        #expect(rows.count { $0 == .unreadDivider } == 1)
    }

    @Test("An open fold puts its messages back under its line, on the fold's tint")
    func openFold() {
        let first = message(1, author: 66, at: 0)
        let second = message(2, author: 66, at: 10)
        let rows = TimelineReducer.rows(
            messages: [first, second],
            blockedUserIDs: [UserID(rawValue: 66)],
            openGroups: [first.id]
        )
        #expect(folds(rows).first?.isOpen == true)
        let shown = messages(rows)
        #expect(shown.count == 2)
        #expect(shown.allSatisfy { $0.flags.contains(.inOpenGroup) })
        #expect(shown[0].isRunHead && shown[1].isRunTail)
    }

    @Test("A jump into a fold opens it — any of its messages is enough")
    func jumpOpensFold() {
        let first = message(1, author: 66, at: 0)
        let target = message(2, author: 66, at: 10)
        let rows = TimelineReducer.rows(
            messages: [first, target],
            blockedUserIDs: [UserID(rawValue: 66)],
            openGroups: [target.id]
        )
        #expect(folds(rows).first?.isOpen == true)
        #expect(messages(rows).contains { $0.id == target.id })
    }
}
