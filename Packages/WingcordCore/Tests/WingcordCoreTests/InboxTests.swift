import Foundation
import Testing
@testable import WingcordCore

/// The inbox's pure decisions: how a list is grouped, how it is ordered, and
/// which of two tabs a saved message belongs to.
struct InboxTests {

    private func message(_ id: UInt64, channel: UInt64) -> Message {
        Message(
            id: MessageID(rawValue: id),
            channelID: ChannelID(rawValue: channel),
            authorID: UserID(rawValue: 1)
        )
    }

    private func saved(
        _ id: UInt64,
        channel: UInt64,
        savedAt: Date,
        dueAt: Date? = nil
    ) -> SavedMessage {
        SavedMessage(
            message: nil,
            saveData: SaveData(
                channelID: ChannelID(rawValue: channel),
                messageID: MessageID(rawValue: id),
                savedAt: savedAt,
                dueAt: dueAt
            )
        )
    }

    // MARK: Grouping

    @Test func neighbouringMessagesInOneChannelShareAHeader() {
        let runs = InboxGrouping.runs(of: [
            message(3, channel: 10),
            message(2, channel: 10),
            message(1, channel: 20),
        ])
        #expect(runs.map(\.count) == [2, 1])
        #expect(runs[0].map(\.id.rawValue) == [3, 2])
    }

    @Test func aChannelThatComesBackLaterGetsASecondHeader() {
        // **The whole reason this is run-length and not `Dictionary(grouping:)`.**
        // Two mentions in one channel with another channel's mention between
        // them draw three headers, which is what Discord's own inbox does. A
        // bucket-per-channel grouping would merge the first and third and
        // silently reorder the list around them.
        let runs = InboxGrouping.runs(of: [
            message(3, channel: 10),
            message(2, channel: 20),
            message(1, channel: 10),
        ])
        #expect(runs.map(\.count) == [1, 1, 1])
        #expect(runs.map { $0[0].channelID.rawValue } == [10, 20, 10])
    }

    @Test func groupingPreservesTheOrderItWasGiven() {
        // Whatever sorted the list is the ordering the reader sees. This must
        // never re-sort, or the reminders tab (soonest first) and the mentions
        // tab (newest first) could not share one rule.
        let input = [message(1, channel: 10), message(9, channel: 10), message(5, channel: 10)]
        #expect(InboxGrouping.runs(of: input)[0].map(\.id.rawValue) == [1, 9, 5])
    }

    @Test func anEmptyListGroupsToNothing() {
        #expect(InboxGrouping.runs(of: [Message]()).isEmpty)
        #expect(InboxGrouping.runs(of: [SavedMessage]()).isEmpty)
    }

    @Test func savedMessagesGroupOnTheSaveNotTheMessage() {
        // Every message here is nil — deleted, or in a lost channel. Reading
        // the channel off `message` would drop each into a run of its own and
        // draw one header per orphaned bookmark.
        let now = Date(timeIntervalSince1970: 1_000)
        let runs = InboxGrouping.runs(of: [
            saved(1, channel: 10, savedAt: now),
            saved(2, channel: 10, savedAt: now),
            saved(3, channel: 20, savedAt: now),
        ])
        #expect(runs.map(\.count) == [2, 1])
    }

    // MARK: Bookmarks and reminders are one list

    @Test func dueAtIsTheWholeDiscriminator() {
        let now = Date(timeIntervalSince1970: 1_000)
        let list = [
            saved(1, channel: 10, savedAt: now),
            saved(2, channel: 10, savedAt: now, dueAt: now.addingTimeInterval(60)),
        ]
        #expect(list.bookmarks.map(\.id.rawValue) == [1])
        #expect(list.reminders.map(\.id.rawValue) == [2])
        #expect(list[0].isReminder == false)
        #expect(list[1].isReminder)
    }

    @Test func bookmarksAreNewestSavedFirst() {
        // Sorted on when it was *saved*, not on the message id: bookmarking a
        // two-year-old message must put it at the top, not the bottom.
        let base = Date(timeIntervalSince1970: 1_000)
        let list = [
            saved(900, channel: 10, savedAt: base),
            saved(100, channel: 10, savedAt: base.addingTimeInterval(60)),
        ]
        #expect(list.bookmarks.map(\.id.rawValue) == [100, 900])
    }

    @Test func remindersAreSoonestDueFirst() {
        // The opposite direction to the bookmarks, and the point of the tab.
        let base = Date(timeIntervalSince1970: 1_000)
        let list = [
            saved(1, channel: 10, savedAt: base, dueAt: base.addingTimeInterval(600)),
            saved(2, channel: 10, savedAt: base, dueAt: base.addingTimeInterval(60)),
        ]
        #expect(list.reminders.map(\.id.rawValue) == [2, 1])
    }

    // MARK: Tabs

    @Test func tabRawValuesAreDiscordsOwn() {
        // These numbers cross the wire in the settings proto. Renumbering them
        // would write a value Discord's own clients read as a different tab.
        #expect(InboxTab.mentions.rawValue == 1)
        #expect(InboxTab.unreads.rawValue == 2)
        #expect(InboxTab.reminders.rawValue == 3)
        #expect(InboxTab.bookmarks.rawValue == 6)
        #expect(InboxTab.scheduled.rawValue == 7)
    }

    @Test func displayOrderIsNotRawValueOrder() {
        // `allCases` is raw-value order, which would put Mentions before
        // Unreads and Reminders before Bookmarks.
        #expect(InboxTab.displayOrder == [.unreads, .mentions, .bookmarks, .reminders, .scheduled])
        #expect(InboxTab.displayOrder.count == InboxTab.allCases.count)
        #expect(Set(InboxTab.displayOrder) == Set(InboxTab.allCases))
    }

    @Test func tabsThisClientDoesNotDrawResolveToSomethingSelectable() {
        // FOR_YOU (4) and GAME_INVITES (5) are real tabs Discord numbers.
        #expect(InboxTab.decoded(rawValue: 4) == .unreads)
        #expect(InboxTab.decoded(rawValue: 5) == .unreads)
        #expect(InboxTab.decoded(rawValue: 0) == .unreads)
        #expect(InboxTab.decoded(rawValue: 99) == .unreads)
    }

    // MARK: Friend requests

    @Test func incomingRequestsComeBeforeOutgoing() {
        // Only one of the two is a question addressed to the reader. Sorting
        // the halves together by date would bury an answer somebody is waiting
        // for under the reader's own sent requests.
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 9_000)
        let requests = FriendRequest.friendRequests(
            from: [
                UserID(rawValue: 1): .outgoingRequest,
                UserID(rawValue: 2): .incomingRequest,
            ],
            facts: [
                UserID(rawValue: 1): RelationshipFacts(since: recent),
                UserID(rawValue: 2): RelationshipFacts(since: old),
            ]
        )
        #expect(requests.map(\.id.rawValue) == [2, 1])
        #expect(requests[0].isIncoming)
    }

    @Test func requestsAreNewestFirstWithinEachHalf() {
        let base = Date(timeIntervalSince1970: 1_000)
        let requests = FriendRequest.friendRequests(
            from: [
                UserID(rawValue: 1): .incomingRequest,
                UserID(rawValue: 2): .incomingRequest,
            ],
            facts: [
                UserID(rawValue: 1): RelationshipFacts(since: base),
                UserID(rawValue: 2): RelationshipFacts(since: base.addingTimeInterval(60)),
            ]
        )
        #expect(requests.map(\.id.rawValue) == [2, 1])
    }

    @Test func anUndatedRequestSortsLastNotFirst() {
        // `.distantPast` is the honest stand-in for "no date". Putting it first
        // would give it the position that belongs to the most recent request.
        let base = Date(timeIntervalSince1970: 1_000)
        let requests = FriendRequest.friendRequests(
            from: [
                UserID(rawValue: 1): .incomingRequest,
                UserID(rawValue: 2): .incomingRequest,
            ],
            facts: [UserID(rawValue: 2): RelationshipFacts(since: base)]
        )
        #expect(requests.map(\.id.rawValue) == [2, 1])
    }

    @Test func theOrderIsTotalSoTheListCannotReshuffleItself() {
        // Two requests with identical dates must order the same way every run,
        // or a list that nothing changed visibly reorders itself.
        let base = Date(timeIntervalSince1970: 1_000)
        let table: [UserID: Relationship] = [
            UserID(rawValue: 10): .incomingRequest,
            UserID(rawValue: 20): .incomingRequest,
            UserID(rawValue: 30): .incomingRequest,
        ]
        let facts = Dictionary(
            uniqueKeysWithValues: table.keys.map { ($0, RelationshipFacts(since: base)) }
        )
        let first = FriendRequest.friendRequests(from: table, facts: facts).map(\.id)
        for _ in 0..<8 {
            #expect(FriendRequest.friendRequests(from: table, facts: facts).map(\.id) == first)
        }
        #expect(first.map(\.rawValue) == [30, 20, 10])
    }

    @Test func onlyIncomingRequestsAreBadged() {
        // An outgoing request is not waiting on anybody here.
        let count = FriendRequest.incomingCount(of: [
            UserID(rawValue: 1): .incomingRequest,
            UserID(rawValue: 2): .outgoingRequest,
            UserID(rawValue: 3): .friend,
            UserID(rawValue: 4): .blocked,
            UserID(rawValue: 5): .incomingRequest,
        ])
        #expect(count == 2)
    }

    @Test func friendsAndBlocksAreNotRequests() {
        let requests = FriendRequest.friendRequests(
            from: [
                UserID(rawValue: 1): .friend,
                UserID(rawValue: 2): .blocked,
                UserID(rawValue: 3): .none,
            ],
            facts: [:]
        )
        #expect(requests.isEmpty)
    }
}
