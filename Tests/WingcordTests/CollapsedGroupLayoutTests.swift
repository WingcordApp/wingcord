import AppKit
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Discord's folds — "2 blocked messages — Show" — and its quote of a blocked
/// author, through the real layout engine.
struct CollapsedGroupLayoutTests {
    private func layout(_ items: [TimelineItem], authors: [UserID: TimelineLayoutEngine.AuthorInfo] = [:]) -> [TimelineRow] {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        return TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: items,
                width: 520,
                style: MessageTextStyle.current(),
                mentions: MentionContext(),
                channelName: "general",
                authors: authors,
                calendar: .current,
                settings: PresentationRevision.shared.timeline
            ),
            cache: &cache
        )
    }

    private func fold(_ reason: CollapsedGroup.Reason, count: Int, isOpen: Bool) -> CollapsedGroup {
        CollapsedGroup(
            reason: reason,
            messageIDs: (1...count).map { MessageID(rawValue: UInt64($0) << 22) },
            isOpen: isOpen
        )
    }

    @Test("A shut fold reads Discord's sentence, a dash, and Show")
    func shutFold() throws {
        let rows = layout([.collapsedGroup(fold(.blocked, count: 2, isOpen: false))])
        guard case .collapsedGroup(let slot)? = rows.first?.kind else {
            Issue.record("no fold row")
            return
        }
        #expect(slot.text.text.attributed.string == "2 blocked messages \u{2014} ")
        let action = try #require(slot.action)
        #expect(action.word == "Show")
        // The word sits straight after the sentence, on its line.
        #expect(action.rect.minX == slot.textOrigin.x + slot.text.size.width)
        #expect(slot.symbolName == "nosign")
    }

    @Test("An open fold says Hide; one message is singular")
    func openFold() {
        let rows = layout([.collapsedGroup(fold(.ignored, count: 1, isOpen: true))])
        guard case .collapsedGroup(let slot)? = rows.first?.kind else {
            Issue.record("no fold row")
            return
        }
        #expect(slot.text.text.attributed.string.hasPrefix("1 ignored message "))
        #expect(slot.action?.word == "Hide")
        #expect(slot.symbolName == "eye.slash")
    }

    @Test("A suspended account's fold offers nothing to press")
    func suspendedFold() {
        let rows = layout([.collapsedGroup(fold(.suspended, count: 3, isOpen: false))])
        guard case .collapsedGroup(let slot)? = rows.first?.kind else {
            Issue.record("no fold row")
            return
        }
        #expect(slot.text.text.attributed.string == "Some messages removed from a suspended account.")
        #expect(slot.action == nil)
    }

    @Test("A reply quoting somebody the reader blocked says Blocked message")
    func blockedQuote() throws {
        let blocked = UserID(rawValue: 66)
        var reply = Message(
            id: MessageID(rawValue: 9 << 22),
            channelID: ChannelID(rawValue: 1),
            authorID: UserID(rawValue: 1),
            content: "agreed",
            kind: .reply
        )
        reply.payload = MessagePayload(reference: MessageReference(
            messageID: MessageID(rawValue: 8 << 22),
            authorID: blocked,
            excerpt: "something they said"
        ))
        let author = TimelineLayoutEngine.AuthorInfo(
            name: "them", colorValue: nil, avatarURL: nil, monogram: "T",
            decorationURL: nil, isBot: false, isBlocked: true
        )
        let rows = layout(
            [.message(TimelineMessage(message: reply, flags: [.head, .tail]))],
            authors: [blocked: author]
        )
        guard case .message(let row)? = rows.first?.kind else {
            Issue.record("no message row")
            return
        }
        #expect(try #require(row.replyHeader).excerpt == "Blocked message")
    }
}
