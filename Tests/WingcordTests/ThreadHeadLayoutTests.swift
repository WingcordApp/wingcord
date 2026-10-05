import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// A thread's transcript opens with Discord's heads, not a channel's welcome —
/// `sL` for a thread, `iX` for a forum post — and a post carries its bar under
/// the opening message (`rg`).
@MainActor
@Suite("Thread and post heads")
struct ThreadHeadLayoutTests {

    private func rows(
        _ items: [TimelineItem],
        head: ChannelHead,
        postActions: PostActions? = nil
    ) -> [TimelineRow] {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        return TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: items,
                width: 720,
                style: MessageTextStyle.current(),
                mentions: MentionContext(),
                channelName: "the app crashes",
                head: head,
                postActions: postActions,
                channelSymbol: DiscordGlyph.thread,
                authors: [:],
                calendar: .current,
                settings: PresentationRevision.shared.timeline
            ),
            cache: &cache
        )
    }

    private func text(_ block: TimelineTextBlock?) -> String? {
        block.map { $0.text.attributed.string }
    }

    @Test("A thread: its name, then who started it, and how to bring people into a private one")
    func threadHead() throws {
        let slot = try #require(head(rows([.conversationStart], head: .thread(startedBy: "ana", isPrivate: true))))
        #expect(text(slot.title) == "the app crashes")
        #expect(text(slot.subtitle) == "Started by ana")
        #expect(text(slot.note) == "@mention users to add them to this private thread.")
        #expect(slot.editButton == nil)
    }

    @Test("An author nobody has told us about is Discord's ???")
    func unknownAuthor() throws {
        let slot = try #require(head(rows([.conversationStart], head: .thread(startedBy: nil, isPrivate: false))))
        #expect(text(slot.subtitle) == "Started by ???")
        #expect(slot.note == nil)
    }

    @Test("A post: its title and its tags, and the line Discord has for a deleted opening message")
    func postHead() throws {
        let tags = [ForumTag(id: ForumTagID(rawValue: 1), name: "Bug"), ForumTag(id: ForumTagID(rawValue: 2), name: "iOS")]
        let slot = try #require(head(rows([.conversationStart], head: .post(tags: tags, openerDeleted: true))))
        #expect(text(slot.title) == "the app crashes")
        #expect(slot.subtitle == nil)
        #expect(text(slot.note) == "Original message was deleted")
        #expect(slot.tags.map { text($0.label) } == ["Bug", "iOS"])
    }

    @Test("A post's bar hangs under its opening message, or under the head when that is gone")
    func barPlacement() {
        let postID: UInt64 = 1 << 30
        let opener = TimelineMessage(
            message: Message(
                id: MessageID(rawValue: postID),
                channelID: ChannelID(rawValue: postID),
                authorID: UserID(rawValue: 8),
                content: "it crashes"
            ),
            flags: []
        )
        let actions = PostActions(
            openerID: MessageID(rawValue: postID),
            openerDeleted: false,
            isFollowing: false,
            offersFollow: true,
            offersReaction: true,
            isLinkCopied: false
        )
        let laid = rows(
            [.conversationStart, .message(opener)],
            head: .post(tags: [], openerDeleted: false),
            postActions: actions
        )
        #expect(laid.count == 3)
        guard case .postActions(let slot)? = laid.last?.kind else {
            Issue.record("no bar under the opening message")
            return
        }
        #expect(slot.buttons.map(\.action) == [.react, .follow, .copyLink])
        #expect(slot.buttons.map(\.accessibilityLabel) == ["React to Post", "Follow", "Copy Link"])

        var gone = actions
        gone.openerDeleted = true
        gone.isLinkCopied = true
        let orphan = rows([.conversationStart], head: .post(tags: [], openerDeleted: true), postActions: gone)
        guard case .postActions(let copied)? = orphan.last?.kind else {
            Issue.record("no bar under the head")
            return
        }
        #expect(copied.buttons.last?.accessibilityLabel == "Copied")
    }

    private func head(_ rows: [TimelineRow]) -> ConversationStartSlot? {
        guard case .conversationStart(let slot)? = rows.first?.kind else { return nil }
        return slot
    }
}
