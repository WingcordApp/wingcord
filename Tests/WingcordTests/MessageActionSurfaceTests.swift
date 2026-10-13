import AppKit
import CoreGraphics
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// What the hover pill and the menu offer, and where the reply header lands.
@MainActor
@Suite("Message action surfaces")
struct MessageActionSurfaceTests {

    // MARK: The pill

    private let everything: MessageActions = [
        .addReaction, .joinReaction, .reply, .forward, .edit, .delete,
        .pin, .copyText, .copyLink, .markUnread, .report, .copyID,
    ]

    @Test("The pill's ordinary set ends with the menu button")
    func barEndsWithMore() {
        let items = everything.barItems(shifted: false)
        #expect(items == [.react, .reply, .forward, .edit, .more])
    }

    @Test("Shift swaps the set rather than extending it")
    func shiftSwaps() {
        let shifted = everything.barItems(shifted: true)
        #expect(shifted == [.copyID, .copyLink, .markUnread, .pin, .delete])
        // No `more` under the modifier: the direct actions are the whole point,
        // and a menu button there would be a second way to the same list.
        #expect(!shifted.contains(.more))
    }

    @Test("Shift can never blank the pill, because Copy Link is always there")
    func shiftNeverEmptiesThePill() {
        // Somebody else's message in a channel with no manage, no history and
        // developer mode off. Copy Message Link is granted by seeing the channel
        // at all, so the modifier always has something to offer.
        let bare: MessageActions = [.joinReaction, .forward, .copyText, .copyLink]
        #expect(bare.barItems(shifted: true) == [.copyLink])
    }

    @Test("Pin and unpin never both appear on the pill")
    func pillShowsOnePinState() {
        var pinned = everything
        pinned.remove(.pin)
        pinned.insert(.unpin)
        let items = pinned.barItems(shifted: true)
        #expect(items.contains(.unpin))
        #expect(!items.contains(.pin))
    }

    // MARK: The menu

    @Test("An empty band draws no separator for itself")
    func menuDropsEmptyGroups() {
        // A system event: no reply, no edit, no forward, no report.
        let event: MessageActions = [.joinReaction, .pin, .copyLink, .markUnread]
        let groups = event.menuGroups
        // One band, in the band's own order — and no separator above or below
        // it, because the three groups around it are empty.
        #expect(groups == [[.pin, .markUnread, .copyLink]])
    }

    @Test("Every offered action reaches the menu exactly once")
    func menuIsComplete() {
        let flat = everything.menuGroups.flatMap { $0 }
        #expect(Set(flat).count == flat.count)
        for kind in MessageActionKind.allCases where kind != .more {
            guard let requirement = kind.requirement else { continue }
            #expect(
                everything.contains(requirement) == flat.contains(kind),
                "\(kind) should be in the menu exactly when it is permitted"
            )
        }
    }

    @Test("A message with nothing to offer opens no menu")
    func nothingOffersNothing() {
        #expect(MessageActions().isEmpty)
        #expect(MessageActions().menuGroups.isEmpty)
    }

    // MARK: The reply header

    private func replyRow(
        excerpt: String,
        authorID: UserID? = UserID(rawValue: 7),
        isDeleted: Bool = false,
        width: CGFloat = 620
    ) -> MessageRow? {
        let message = Message(
            id: MessageID(rawValue: 2),
            channelID: ChannelID(rawValue: 9),
            authorID: UserID(rawValue: 5),
            content: "hey",
            kind: .reply,
            payload: MessagePayload(
                reference: MessageReference(
                    messageID: MessageID(rawValue: 1),
                    authorID: authorID,
                    excerpt: excerpt,
                    isDeleted: isDeleted
                )
            )
        )
        let engine = TimelineLayoutEngine(presentationRevision: 1)
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let laid = engine.layout(
            TimelineLayoutEngine.Input(
                items: [.message(TimelineMessage(message: message, flags: [.head, .tail]))],
                width: width,
                style: MessageTextStyle.current(),
                mentions: MentionContext(),
                channelName: "general",
                authors: [
                    UserID(rawValue: 7): TimelineLayoutEngine.AuthorInfo(
                        name: "robinresting",
                        colorValue: nil,
                        avatarURL: nil,
                        monogram: "N",
                        decorationURL: nil,
                        isBot: false
                    )
                ],
                calendar: .current,
                settings: .comfortable
            ),
            cache: &cache
        )
        guard case .message(let row) = laid[0].kind else { return nil }
        return row
    }

    @Test("The header sits above the author line and pushes it down")
    func headerIsAboveTheAuthor() throws {
        let row = try #require(replyRow(excerpt: "hey man"))
        let header = try #require(row.replyHeader)
        #expect(header.rect.maxY <= row.authorRect.minY)
        #expect(header.rect.height == TimelineMetrics.replyHeight)
        // The elbow drops to where the author line begins, so the connector
        // reads as coming out of the face rather than floating beside it.
        #expect(header.elbowBottom == header.rect.maxY + TimelineMetrics.replyGap)
    }

    @Test("The face, the name and the quote run left to right without overlapping")
    func headerPartsAreOrdered() throws {
        let row = try #require(replyRow(excerpt: "hey man"))
        let header = try #require(row.replyHeader)
        #expect(header.avatarRect.minX == TimelineMetrics.contentInset)
        #expect(header.nameRect.minX >= header.avatarRect.maxX)
        #expect(header.excerptRect.minX >= header.nameRect.maxX)
        #expect(header.name == "@robinresting")
        #expect(header.excerpt == "hey man")
        #expect(header.targetID == MessageID(rawValue: 1))
    }

    @Test("The elbow starts in the avatar gutter and stops short of the face")
    func elbowSpansTheGutter() throws {
        let row = try #require(replyRow(excerpt: "hey"))
        let header = try #require(row.replyHeader)
        #expect(TimelineMetrics.replyElbowX == 16 + Metrics.avatarMessage / 2)
        #expect(TimelineMetrics.replyElbowEndX < TimelineMetrics.contentInset)
        // The strip's own bounds start at the elbow, so a click anywhere along
        // the line it draws lands on it.
        #expect(header.rect.minX == TimelineMetrics.replyElbowX)
    }

    @Test("A deleted target says so, wears the badge, and goes nowhere")
    func deletedTargetIsInert() throws {
        let row = try #require(replyRow(excerpt: "", authorID: nil, isDeleted: true))
        let header = try #require(row.replyHeader)
        #expect(header.targetID == nil)
        #expect(header.avatarRect == .zero)
        #expect(header.badgeRect.width == TimelineMetrics.replyAvatarSide)
        #expect(header.name.isEmpty)
        #expect(header.excerpt == "Original message was deleted")
        #expect(header.excerptFont == MessageTextStyle.current().metadataItalicFont)
    }

    @Test("A target nobody fetched could not be loaded, and still jumps to it")
    func unloadedTargetStillJumps() throws {
        let row = try #require(replyRow(excerpt: "", authorID: nil))
        let header = try #require(row.replyHeader)
        #expect(header.excerpt == "Message could not be loaded")
        #expect(header.targetID == MessageID(rawValue: 1))
        #expect(header.badgeRect != .zero)
        #expect(header.avatarRect == .zero)
        // The quote starts after the badge, as it does after a face.
        #expect(header.excerptRect.minX >= header.badgeRect.maxX)
    }

    @Test("A quote in words keeps the face and the plain metadata face")
    func loadedQuoteHasNoBadge() throws {
        let row = try #require(replyRow(excerpt: "hey man"))
        let header = try #require(row.replyHeader)
        #expect(header.badgeRect == .zero)
        #expect(header.avatarRect != .zero)
        #expect(header.excerptFont == MessageTextStyle.current().metadataFont)
    }

    @Test("A message with no reference has no header and costs nothing")
    func plainMessagesHaveNoHeader() {
        let message = Message(
            id: MessageID(rawValue: 3),
            channelID: ChannelID(rawValue: 9),
            authorID: UserID(rawValue: 5),
            content: "plain"
        )
        let engine = TimelineLayoutEngine(presentationRevision: 1)
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let laid = engine.layout(
            TimelineLayoutEngine.Input(
                items: [.message(TimelineMessage(message: message, flags: [.head, .tail]))],
                width: 620,
                style: MessageTextStyle.current(),
                mentions: MentionContext(),
                channelName: "general",
                authors: [:],
                calendar: .current,
                settings: .comfortable
            ),
            cache: &cache
        )
        guard case .message(let row) = laid[0].kind else {
            Issue.record("expected a message row")
            return
        }
        #expect(row.replyHeader == nil)
    }

    @Test("The header adds its own height to the row and nothing more")
    func headerCostsItsOwnHeight() throws {
        let withHeader = try #require(replyRow(excerpt: "hey man"))
        let header = try #require(withHeader.replyHeader)
        // The body starts below the header plus the author line, which is what
        // stops the quote overlapping the message it belongs to.
        #expect(withHeader.textOrigin.y > header.rect.maxY)
    }

    // MARK: The role-chip cap

    @Test("Roles that fit in the cap are all shown")
    func shortRoleListIsWhole() {
        let names = ["Admin", "Mod"]
        #expect(RoleChipFit.visibleCount(names: names, total: 2, width: 288, rows: 2) == 2)
    }

    @Test("A long list is cut to leave room for the count")
    func longRoleListElides() {
        let names = (0..<50).map { "Community Role \($0)" }
        let shown = RoleChipFit.visibleCount(names: names, total: 50, width: 288, rows: 2)
        #expect(shown > 0)
        #expect(shown < 50)
        // What is shown, plus the chip standing for the rest, has to fit.
        var widths = names.prefix(shown).map(RoleChipFit.chipWidth)
        widths.append(RoleChipFit.overflowWidth(50 - shown))
        #expect(rowsNeeded(widths, width: 288) <= 2)
        // And one more would not have.
        var overfull = names.prefix(shown + 1).map(RoleChipFit.chipWidth)
        overfull.append(RoleChipFit.overflowWidth(50 - shown - 1))
        #expect(rowsNeeded(overfull, width: 288) > 2)
    }

    @Test("A cap of zero rows, or no width, shows nothing rather than everything")
    func degenerateCaps() {
        #expect(RoleChipFit.visibleCount(names: ["Admin"], total: 1, width: 288, rows: 0) == 0)
        #expect(RoleChipFit.visibleCount(names: ["Admin"], total: 1, width: 0, rows: 2) == 0)
    }

    @Test("A single role wider than the card is still elided rather than trapped")
    func oneEnormousRole() {
        let names = [String(repeating: "Extremely Long Role Name ", count: 8), "Mod"]
        let shown = RoleChipFit.visibleCount(names: names, total: 2, width: 200, rows: 2)
        #expect(shown >= 0)
        #expect(shown <= 2)
    }

    private func rowsNeeded(_ widths: [CGFloat], width: CGFloat) -> Int {
        var rows = 1
        var x: CGFloat = 0
        for itemWidth in widths {
            if x > 0, x + RoleChipFit.spacing + itemWidth > width {
                rows += 1
                x = itemWidth
            } else {
                x += x > 0 ? RoleChipFit.spacing + itemWidth : itemWidth
            }
        }
        return rows
    }
}

/// The row cache, which is the only thing between a changed message and a
/// stale row.
@MainActor
@Suite("Timeline row cache")
struct TimelineRowCacheTests {

    private func layout(
        _ message: Message,
        cache: inout [MessageID: TimelineLayoutEngine.CacheEntry],
        identityToken: UInt64 = 0,
        width: CGFloat = 620
    ) -> MessageRow? {
        var mentions = MentionContext()
        mentions.token = identityToken
        let engine = TimelineLayoutEngine(presentationRevision: 1)
        let laid = engine.layout(
            TimelineLayoutEngine.Input(
                items: [.message(TimelineMessage(message: message, flags: [.head, .tail]))],
                width: width,
                style: MessageTextStyle.current(),
                mentions: mentions,
                channelName: "general",
                authors: [:],
                calendar: .current,
                settings: .comfortable
            ),
            cache: &cache
        )
        guard case .message(let row) = laid[0].kind else { return nil }
        return row
    }

    private func message(
        content: String = "hello",
        reactions: [Reaction] = [],
        editedAt: Date? = nil
    ) -> Message {
        Message(
            id: MessageID(rawValue: 1),
            channelID: ChannelID(rawValue: 9),
            authorID: UserID(rawValue: 5),
            content: content,
            editedAt: editedAt,
            payload: reactions.isEmpty ? nil : MessagePayload(reactions: reactions)
        )
    }

    @Test("An unchanged message is served from the cache")
    func unchangedMessageHits() {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        _ = layout(message(), cache: &cache)
        #expect(cache.count == 1)
        let first = cache[MessageID(rawValue: 1)]?.row.authorRect
        _ = layout(message(), cache: &cache)
        #expect(cache.count == 1)
        #expect(cache[MessageID(rawValue: 1)]?.row.authorRect == first)
    }

    @Test("A reaction arriving re-lays the row out")
    func reactionsInvalidate() throws {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let before = try #require(
            layout(message(reactions: [Reaction(emoji: EmojiRef(name: "🔥"), count: 12, isMine: false)]), cache: &cache)
        )
        #expect(before.reactions.count == 1)
        #expect(before.reactions[0].count == 12)

        // The same emoji, one higher. `MessagePayload.hash` folds counts rather
        // than values, so a key built from a hash would collide here — and the
        // chip would sit at twelve for ever.
        let after = try #require(
            layout(message(reactions: [Reaction(emoji: EmojiRef(name: "🔥"), count: 13, isMine: true)]), cache: &cache)
        )
        #expect(after.reactions[0].count == 13)
        #expect(after.reactions[0].isMine)
    }

    @Test("An edit re-lays the row out")
    func editsInvalidate() throws {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let before = try #require(layout(message(content: "hello"), cache: &cache))
        let after = try #require(
            layout(message(content: "a rather longer body than the one it replaced", editedAt: .now),
                   cache: &cache)
        )
        // A fresh framesetting, not the shared block a cache hit returns.
        #expect(after.textBlock !== before.textBlock)
        #expect(cache[MessageID(rawValue: 1)]?.message.editedAt != nil)
    }

    @Test("A pin re-lays the row out, because the menu reads the row's own state")
    func pinsInvalidate() throws {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        _ = layout(message(), cache: &cache)
        var pinned = message()
        pinned.isPinned = true
        _ = layout(pinned, cache: &cache)
        #expect(cache[MessageID(rawValue: 1)]?.message.isPinned == true)
    }

    @Test("A rename re-lays the row out, through the mention table's token")
    func identityInvalidates() {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        _ = layout(message(), cache: &cache, identityToken: 1)
        #expect(cache[MessageID(rawValue: 1)]?.identityToken == 1)
        _ = layout(message(), cache: &cache, identityToken: 2)
        #expect(cache[MessageID(rawValue: 1)]?.identityToken == 2)
    }

    @Test("A miss replaces its entry rather than growing a second one beside it")
    func missesDoNotAccumulate() {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        for width in stride(from: 400.0, through: 700.0, by: 20.0) {
            _ = layout(message(), cache: &cache, width: width)
        }
        #expect(cache.count == 1)
    }
}
