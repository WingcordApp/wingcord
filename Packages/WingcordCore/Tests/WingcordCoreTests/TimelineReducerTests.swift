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

    @Test("An empty page with more history lays a runway, not a spinner")
    func emptyWithHistory() {
        let rows = TimelineReducer.rows(messages: [], hasMoreHistory: true, skeletonDepth: 20)
        #expect(rows.count == 20)
        #expect(rows.allSatisfy { if case .historySkeleton = $0 { true } else { false } })
    }

    @Test("The runway is deeper than one flick can travel")
    func runwayDepth() {
        // Four groups is crossed in a few hundred milliseconds, which is less
        // than a round trip; twenty is past what one throw covers.
        #expect(TimelineReducer.rows(messages: [], hasMoreHistory: true).count == 20)
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
}
