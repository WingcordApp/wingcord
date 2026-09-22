import AppKit
import CoreGraphics
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The row of chips under a message, and the two controls at the end of it.
///
/// **The controls wrap with the chips rather than being pinned.** That is the
/// whole of what a test can hold here: geometry the painter and the hit test
/// both read, and which nothing on screen would report as wrong — a control laid
/// out past the measure simply draws off the edge of the column, and one laid
/// out on a row of its own leaves a gap nobody can name.
@MainActor
@Suite("The reaction row")
struct ReactionRowTests {

    /// The message's slots **and** the row's own height: `MessageRow` carries
    /// the slots and `TimelineRow` carries the height, and one of the things
    /// worth asserting spans both.
    private func laidOut(
        reactions: [Reaction],
        width: CGFloat = 400
    ) -> (row: MessageRow, height: CGFloat)? {
        let items: [TimelineItem] = [.message(TimelineMessage(
            message: Message(
                id: MessageID(rawValue: 1),
                channelID: ChannelID(rawValue: 1),
                authorID: UserID(rawValue: 1),
                content: "hello",
                payload: MessagePayload(reactions: reactions)
            ),
            flags: [.head, .tail]
        ))]
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let laid = TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: items,
                width: width,
                style: MessageTextStyle.current(),
                mentions: MentionContext(),
                channelName: "general",
                authors: [:],
                calendar: .current,
                settings: .comfortable
            ),
            cache: &cache
        )
        guard let first = laid.first, case .message(let row) = first.kind else { return nil }
        return (row, first.height)
    }

    private func reaction(_ name: String, count: Int = 1) -> Reaction {
        Reaction(emoji: EmojiRef(name: name), count: count, isMine: false)
    }

    @Test("A message nobody reacted to gets no row and no controls")
    func noReactionsNoRow() throws {
        let row = try #require(laidOut(reactions: [])).row
        #expect(row.reactions.isEmpty)
        // The hover bar already offers both acts. Two controls floating under
        // every message in a channel is chrome, not an affordance.
        #expect(row.reactionControls.isEmpty)
    }

    @Test("A reacted message gets both controls, in order")
    func bothControlsInOrder() throws {
        let row = try #require(laidOut(reactions: [reaction("👍")])).row
        #expect(row.reactionControls.map(\.kind) == [.addReaction, .bookmark])
    }

    @Test("They sit on the reaction row, after the last chip")
    func sitOnTheRow() throws {
        let row = try #require(laidOut(reactions: [reaction("👍"), reaction("🎉")])).row
        let lastChip = try #require(row.reactions.last)
        let add = try #require(row.reactionControls.first)
        #expect(add.rect.minY == lastChip.rect.minY)
        #expect(add.rect.minX > lastChip.rect.maxX)
        // Square, and the chips' own height: a control a point taller would
        // break the line the row sits on.
        #expect(add.rect.height == TimelineMetrics.reactionChipHeight)
        #expect(add.rect.width == add.rect.height)
    }

    @Test("The row is tall enough to hold them")
    func rowGrowsToFit() throws {
        // A drawn canvas has no layout to catch this: a control past the row's
        // own height draws over whatever is beneath it.
        let laid = try #require(laidOut(reactions: [reaction("👍")]))
        for control in laid.row.reactionControls {
            #expect(laid.height >= control.rect.maxY)
        }
    }

    @Test("They wrap with the chips rather than running off the column")
    func theyWrap() throws {
        // Eight chips in a narrow column: the controls have to find the end of
        // whatever line the chips actually finished on, and start a new one if
        // there is no room.
        let narrow = try #require(
            laidOut(reactions: (0..<8).map { reaction("👍", count: 100 + $0) }, width: 240)
        ).row
        let contentX = try #require(narrow.reactions.first).rect.minX
        for control in narrow.reactionControls {
            #expect(control.rect.maxX <= contentX + 240)
        }
        // And the last one is still the bookmark, whichever line it landed on.
        #expect(narrow.reactionControls.last?.kind == .bookmark)
    }

    @Test("A chip is a rounded square, not a capsule")
    func chipIsASquircle() {
        // The corner is derived from the chip's own height at a ratio traced off
        // a capture — see `TimelineMetrics.reactionChipRadius`. A capsule is
        // half the height, and that is what this drew.
        #expect(TimelineMetrics.reactionChipRadius < TimelineMetrics.reactionChipHeight / 2)
        #expect(TimelineMetrics.reactionChipRadius > 0)
        #expect(TimelineMetrics.reactionChipRadius == 5)
    }
}
