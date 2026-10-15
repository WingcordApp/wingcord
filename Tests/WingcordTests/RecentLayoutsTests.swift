import Testing
import WingcordCore
@testable import Wingcord

/// The transcript keeps the layouts of the last two conversations it left, so
/// going back to one is not a layout of every row.
@Suite("Recent layouts")
struct RecentLayoutsTests {
    private let a = ChannelID(rawValue: 1)
    private let b = ChannelID(rawValue: 2)
    private let c = ChannelID(rawValue: 3)
    private let d = ChannelID(rawValue: 4)

    @Test("Going back to a conversation finds its layouts")
    func backAndForth() {
        var recent = RecentLayouts<[Int]>()
        // a → b: nothing kept for b yet; a's rows go aside.
        #expect(recent.swap(leaving: a, cache: [1, 2], arriving: b, width: 600) == nil)
        // b → a: a's rows come back, b's go aside.
        #expect(recent.swap(leaving: b, cache: [3], arriving: a, width: 600) == [1, 2])
        // a → b: and b's come back.
        #expect(recent.swap(leaving: a, cache: [1, 2], arriving: b, width: 600) == [3])
    }

    @Test("Two are kept, and the oldest goes first")
    func keepsTwo() {
        var recent = RecentLayouts<[Int]>()
        _ = recent.swap(leaving: a, cache: [1], arriving: b, width: 600)
        _ = recent.swap(leaving: b, cache: [2], arriving: c, width: 600)
        _ = recent.swap(leaving: c, cache: [3], arriving: d, width: 600)
        #expect(recent.kept.map(\.channelID) == [b, c])
        #expect(recent.swap(leaving: d, cache: [4], arriving: a, width: 600) == nil)
        #expect(recent.swap(leaving: a, cache: [], arriving: c, width: 600) == [3])
    }

    @Test("Layouts made at another width are not handed back")
    func widthMustMatch() {
        var recent = RecentLayouts<[Int]>()
        _ = recent.swap(leaving: a, cache: [1], arriving: b, width: 600)
        #expect(recent.swap(leaving: b, cache: [2], arriving: a, width: 720) == nil)
        #expect(!recent.kept.contains { $0.channelID == a })
    }

    @Test("A conversation with nothing laid out is not kept, and shedding empties it")
    func emptyAndShed() {
        var recent = RecentLayouts<[Int]>()
        _ = recent.swap(leaving: a, cache: [], arriving: b, width: 600)
        #expect(recent.kept.isEmpty)
        _ = recent.swap(leaving: b, cache: [2], arriving: c, width: 600)
        recent.removeAll()
        #expect(recent.swap(leaving: c, cache: [3], arriving: b, width: 600) == nil)
    }
}
