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

    // MARK: Super reactions

    private let shaq = EmojiRef(id: EmojiID(rawValue: 1_122_960_370_512_957_560), name: "x_shaq")

    @Test("An emoji with both kinds is two chips, the super one first")
    func bothHalvesTwoChips() throws {
        let row = try #require(laidOut(reactions: [
            Reaction(
                emoji: shaq, count: 3, isMine: true,
                burstCount: 194, isMineBurst: false, burstColors: [0x40_1B_17]
            ),
        ])).row
        // Discord's own order: module 279182 pushes an emoji's burst half
        // before its plain half.
        #expect(row.reactions.map(\.kind) == [.burst, .normal])
        #expect(row.reactions.map(\.count) == [194, 3])
        #expect(row.reactions.map(\.isMine) == [false, true])
        // The super chip carries its colours; the plain one draws as it always
        // did.
        #expect(row.reactions[0].palette != nil)
        #expect(row.reactions[1].palette == nil)
    }

    @Test("A reaction with only super reactions has no plain chip")
    func onlyBurst() throws {
        // The captured case: count 194, all of them super. Reading the wire's
        // `count` as the plain tally drew a second, plain chip reading 194.
        let row = try #require(laidOut(reactions: [
            Reaction(emoji: shaq, count: 0, isMine: false, burstCount: 194, burstColors: [0x40_1B_17]),
        ])).row
        #expect(row.reactions.map(\.kind) == [.burst])
    }

    @Test("A custom emoji's picture is asked for at the size the chip draws it")
    func emojiAtDrawnSize() throws {
        let row = try #require(laidOut(reactions: [
            Reaction(emoji: shaq, count: 1, isMine: false),
        ])).row
        let url = try #require(row.reactions.first?.imageURL)
        let rung = CDN.rung(forSide: TimelineMetrics.reactionGlyphSide)
        #expect(url.query?.contains("size=\(rung)") == true)
    }

    @Test("The prefetch asks for every chip's picture, and an animated one's strip")
    func prefetchAsksForChips() throws {
        let animated = EmojiRef(id: EmojiID(rawValue: 1_458_335_056_203_403_164), name: "AutoRolePetPet", isAnimated: true)
        let row = try #require(laidOut(reactions: [
            Reaction(emoji: shaq, count: 2, isMine: false, burstCount: 1, burstColors: [0x40_1B_17]),
            Reaction(emoji: animated, count: 386, isMine: false),
            Reaction(emoji: EmojiRef(name: "🔥"), count: 1, isMine: false),
        ])).row
        // **This is the whole of "custom emoji in reactions do not render":**
        // the painter peeked for these and nothing ever asked for them.
        let requests = TimelineImageRequests.requests(
            for: [row], scale: 2, loadsArtwork: true, playsAnimatedEmoji: true
        )
        let still = requests.filter { $0.key.url == row.reactions[0].imageURL }
        let film = requests.filter { $0.key.url == row.reactions[2].imageURL }
        // One request for the emoji's two chips — the key is the same.
        #expect(still.count == 1)
        #expect(still.first?.source == .still(.thumbnail))
        #expect(film.first?.source == .film)
        // Keyed exactly as the painter peeks.
        #expect(still.first?.key.maximumPixelSize == Int((TimelineMetrics.reactionGlyphSide * 2).rounded(.up)))
        // A Unicode emoji is a glyph, and asks for nothing.
        #expect(requests.count == 2)
    }

    @Test("The tooltip reads as Discord's does", arguments: [
        (["PapaPysklo", "f2p", "🍃"], 191, ReactionKind.burst,
         ":x_shaq: Super reacted by PapaPysklo, f2p, 🍃, and 191 others"),
        (["Ana"], 0, .normal, ":x_shaq: reacted by Ana"),
        (["Ana"], 1, .normal, ":x_shaq: reacted by Ana and 1 other"),
        (["Ana", "Bo"], 0, .normal, ":x_shaq: reacted by Ana and Bo"),
        (["Ana", "Bo"], 5, .burst, ":x_shaq: Super reacted by Ana, Bo, and 5 others"),
        (["Ana", "Bo", "Cy"], 0, .normal, ":x_shaq: reacted by Ana, Bo, and Cy"),
    ])
    func tooltipSentence(_ names: [String], _ remaining: Int, _ kind: ReactionKind, _ expected: String) {
        // The first row is the capture — the tooltip over the `x_shaq` chip,
        // three names out of 194.
        #expect(ReactionTooltipText.sentence(
            emojiName: ":x_shaq:", names: names, remaining: remaining, kind: kind
        ) == expected)
    }

    @Test("Nobody to name is no tooltip, and a Unicode emoji is named by its shortcode")
    func tooltipEdges() {
        #expect(ReactionTooltipText.sentence(emojiName: ":a:", names: [], remaining: 4, kind: .normal) == nil)
        #expect(ReactionTooltipText.name(of: EmojiRef(name: "🔥")) == ":fire:")
        #expect(ReactionTooltipText.name(of: shaq) == ":x_shaq:")
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
