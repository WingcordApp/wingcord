import Foundation
import Testing
@testable import WingcordCore

/// A board's live posts in Discord's order (`207777`), and its "NEW" (`573163`).
@Suite("Forum board order")
struct ForumOrderTests {
    /// A snowflake minted at a moment, so creation order is real.
    private func id(_ secondsAfterEpoch: Double) -> UInt64 {
        UInt64(secondsAfterEpoch * 1000) << 22
    }

    private func post(
        _ created: Double,
        lastMessage: Double? = nil,
        pinned: Bool = false,
        archived: Bool = false,
        tags: [UInt64] = []
    ) -> Channel {
        Channel(
            id: ChannelID(rawValue: id(created)),
            kind: .publicThread,
            lastMessageID: lastMessage.map { MessageID(rawValue: id($0)) },
            threadMetadata: ThreadMetadata(isArchived: archived),
            appliedTags: tags.map { ForumTagID(rawValue: $0) },
            flags: pinned ? .pinned : []
        )
    }

    @Test("The pinned post leads, then the most recent message")
    func pinnedThenActivity() {
        let old = post(100, lastMessage: 900)
        let new = post(500, lastMessage: 600)
        let pinned = post(50, pinned: true)
        let order = ForumOrder.livePosts([new, pinned, old], query: ForumQuery())
        #expect(order == [pinned.id, old.id, new.id])
    }

    @Test("Date Posted orders by the post itself, the pin still first")
    func creationDate() {
        let old = post(100, lastMessage: 900)
        let new = post(500, lastMessage: 600)
        let pinned = post(50, pinned: true)
        let order = ForumOrder.livePosts([old, new, pinned], query: ForumQuery(sortOrder: .creationDate))
        #expect(order == [pinned.id, new.id, old.id])
    }

    @Test("Match Some wants any chosen tag; Match All wants every one; no tags matches nothing")
    func tagFilter() {
        let both = post(1, tags: [1, 2])
        let one = post(2, tags: [1])
        let none = post(3)
        let chosen = Set([1, 2].map { ForumTagID(rawValue: $0) })
        let some = ForumOrder.livePosts([both, one, none], query: ForumQuery(tags: chosen))
        #expect(Set(some) == [both.id, one.id])
        let all = ForumOrder.livePosts(
            [both, one, none],
            query: ForumQuery(tagMatching: .all, tags: chosen)
        )
        #expect(all == [both.id])
    }

    @Test("NEW: unopened, live, after the forum's read mark and after joining")
    func isNew() {
        let joined = Date(timeIntervalSince1970: 1_420_070_400 + 100)
        let mark = MessageID(rawValue: id(300))
        let fresh = post(400)
        #expect(ForumOrder.isNew(fresh, readMark: mark, isOpened: false, joinedAt: joined))
        // Opened already, or read before, or archived — not new.
        #expect(!ForumOrder.isNew(fresh, readMark: mark, isOpened: true, joinedAt: joined))
        #expect(!ForumOrder.isNew(post(200), readMark: mark, isOpened: false, joinedAt: joined))
        #expect(!ForumOrder.isNew(post(400, archived: true), readMark: mark, isOpened: false, joinedAt: joined))
        // A forum never read, or a join date nobody knows, makes nothing new.
        #expect(!ForumOrder.isNew(fresh, readMark: nil, isOpened: false, joinedAt: joined))
        #expect(!ForumOrder.isNew(fresh, readMark: mark, isOpened: false, joinedAt: nil))
        // Posted before the reader joined.
        let lateJoin = Date(timeIntervalSince1970: 1_420_070_400 + 450)
        #expect(!ForumOrder.isNew(fresh, readMark: mark, isOpened: false, joinedAt: lateJoin))
    }
}
