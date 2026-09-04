import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The block at the top of a channel.
///
/// **The defect this exists for was a fixed height.** The row was 120 points
/// whatever it held, with two strings painted at `+30` and `+62` — so a channel
/// with a long name truncated, a channel with a topic had nowhere to put it, and
/// every channel paid for a band of empty space under the second line. All three
/// are geometry, and geometry is what a test can hold.
@MainActor
@Suite("Channel head layout")
struct ChannelHeadLayoutTests {

    private func rows(
        name: String,
        topic: String?,
        width: CGFloat = 720
    ) -> [TimelineRow] {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        return TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: [.conversationStart],
                width: width,
                style: MessageTextStyle.current(),
                mentions: MentionContext(),
                channelName: name,
                channelSymbol: "number",
                channelTopic: topic,
                authors: [:],
                calendar: .current,
                settings: PresentationRevision.shared.timeline
            ),
            cache: &cache
        )
    }

    private func head(_ rows: [TimelineRow]) -> ConversationStartSlot? {
        guard case .conversationStart(let slot)? = rows.first?.kind else { return nil }
        return slot
    }

    @Test("The row is exactly as tall as what it holds")
    func heightFollowsContent() {
        let bare = rows(name: "general", topic: nil)
        let described = rows(name: "general", topic: "Vote on things here")
        #expect(bare.count == 1)
        #expect(described.count == 1)
        // A topic makes the row taller. The old fixed height could not, which is
        // why the topic had nowhere to go.
        #expect(described[0].height > bare[0].height)
    }

    @Test("Nothing is left over below the last line")
    func noEmptyBand() {
        let list = rows(name: "general", topic: nil)
        guard let slot = head(list) else {
            Issue.record("no conversation start row")
            return
        }
        let lastInk = slot.subtitleOrigin.y + slot.subtitle.size.height
        // The band under the last line is the padding and nothing else. The old
        // row left about forty points of nothing here — the "weird space".
        #expect(list[0].height - lastInk <= TimelineMetrics.conversationStartBottomPadding + 1)
    }

    @Test("A topic is laid out, and only when there is one")
    func topicIsOptional() {
        #expect(head(rows(name: "voting", topic: nil))?.topic == nil)
        #expect(head(rows(name: "voting", topic: "   "))?.topic == nil)
        #expect(head(rows(name: "voting", topic: "Vote on things here"))?.topic != nil)
    }

    @Test("A long name wraps rather than truncating")
    func longNameWraps() {
        let short = rows(name: "general", topic: nil)
        let long = rows(
            name: "a-channel-with-a-genuinely-very-long-name-that-cannot-fit-on-one-line-at-all",
            topic: nil,
            width: 320
        )
        #expect(long[0].height > short[0].height)
    }

    @Test("The icon and the text share the column's leading edge")
    func alignment() {
        guard let slot = head(rows(name: "general", topic: "Vote on things here")) else {
            Issue.record("no conversation start row")
            return
        }
        #expect(slot.iconRect.minX == TimelineMetrics.horizontalMargin)
        #expect(slot.titleOrigin.x == TimelineMetrics.horizontalMargin)
        #expect(slot.subtitleOrigin.x == TimelineMetrics.horizontalMargin)
        #expect(slot.topicOrigin.x == TimelineMetrics.horizontalMargin)
        // The glyph is centred in its tile, which is what stops a `#` sitting in
        // the corner of a 64-point square.
        #expect(abs(slot.glyphRect.midX - slot.iconRect.midX) < 0.51)
        #expect(abs(slot.glyphRect.midY - slot.iconRect.midY) < 0.51)
    }

    @Test("The head draws ink, and the topic adds more of it")
    func drawsInk() {
        // A painter that draws nothing lays out perfectly and renders an empty
        // view; only ink on a bitmap can tell the difference.
        // **Counted in pixels, not as a fraction.** A topic makes the row
        // taller, so the bitmap is bigger — and more ink spread over a larger
        // area is a *smaller* fraction. Comparing the fractions asserted the
        // opposite of what it read as, and it failed on a correct renderer.
        let height = 220
        func ink(topic: String?) -> Double {
            let list = rows(name: "general", topic: topic, width: 400)
            return RenderProbe.inkFraction(width: 400, height: height) { context, frame in
                TimelineRowPainter.draw(
                    row: list[0],
                    in: CGRect(x: 0, y: 0, width: frame.width, height: list[0].height),
                    context: context,
                    style: MessageTextStyle.current(),
                    state: TimelineRowPainter.State(),
                    images: ImageStore.shared,
                    scale: 2
                )
            }
        }
        let bare = ink(topic: nil)
        #expect(bare > 0.01)
        #expect(ink(topic: "Vote on things here") > bare)
    }
}
