import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The bubble arrangement's geometry, through the engine the transcript calls.
///
/// **The fixtures go through `TimelineReducer`**, which is where the
/// transcript's run flags come from — a hand-set `.tail` would test a run the
/// app never builds (§2.6).
@MainActor
@Suite("Message bubbles")
struct BubbleLayoutTests {
    private static let me = UserID(rawValue: 1)
    private static let them = UserID(rawValue: 2)
    private static let width: CGFloat = 800
    private static let margin = TimelineMetrics.horizontalMargin

    private func messages(_ lines: [(UserID, String)]) -> [Message] {
        lines.enumerated().map { index, line in
            Message(
                id: MessageID(rawValue: UInt64(index + 1)),
                channelID: ChannelID(rawValue: 9),
                authorID: line.0,
                content: line.1
            )
        }
    }

    private func layout(
        _ messages: [Message],
        arrangement: MessageArrangement = .bubbles(namesAuthors: true),
        settings: TimelineSettings = .comfortable,
        failed: Set<MessageID> = [],
        cache: inout [MessageID: TimelineLayoutEngine.CacheEntry]
    ) -> [TimelineRow] {
        TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: TimelineReducer.rows(messages: messages, failed: failed),
                width: Self.width,
                style: MessageTextStyle.current(),
                mentions: MentionContext(selfIDs: [Self.me.rawValue]),
                channelName: "general",
                authors: [
                    Self.me: .init(
                        name: "Wren", colorValue: nil, avatarURL: nil,
                        monogram: "W", decorationURL: nil, isBot: false
                    ),
                    Self.them: .init(
                        name: "Alder", colorValue: nil, avatarURL: nil,
                        monogram: "A", decorationURL: nil, isBot: false
                    ),
                ],
                calendar: .current,
                settings: settings,
                arrangement: arrangement
            ),
            cache: &cache
        )
    }

    private func rows(
        _ lines: [(UserID, String)],
        arrangement: MessageArrangement = .bubbles(namesAuthors: true),
        settings: TimelineSettings = .comfortable,
        failed: Set<MessageID> = []
    ) -> [MessageRow] {
        rows(messages(lines), arrangement: arrangement, settings: settings, failed: failed)
    }

    private func rows(
        _ messages: [Message],
        arrangement: MessageArrangement = .bubbles(namesAuthors: true),
        settings: TimelineSettings = .comfortable,
        failed: Set<MessageID> = []
    ) -> [MessageRow] {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        return layout(messages, arrangement: arrangement, settings: settings, failed: failed, cache: &cache).compactMap {
            if case .message(let row) = $0.kind { row } else { nil }
        }
    }

    @Test("The reader's bubbles trail in their own glass and everyone else's lead, each hugging its words")
    func sides() throws {
        let laid = rows([(Self.them, "hello there"), (Self.me, "hi")])
        let theirs = try #require(laid[0].bubbles?.bubble)
        let mine = try #require(laid[1].bubbles?.bubble)
        #expect(laid[0].bubbles?.side == .leading)
        #expect(laid[1].bubbles?.side == .trailing)
        #expect(mine.rect.maxX == Self.width - Self.margin)
        #expect(theirs.rect.minX == Self.margin + BubbleMetrics.avatarSide + BubbleMetrics.avatarGap)
        #expect(mine.ground == .own)
        #expect(theirs.ground == .neutral)
        // Hugged: a word is not a lane-wide bar.
        #expect(mine.rect.width < 100)
        #expect(theirs.rect.width < 160)
    }

    @Test("The accent is the reader's opt-in, and only ever on their own bubbles")
    func accentIsOptIn() throws {
        var settings = TimelineSettings.comfortable
        settings.tintsOwnBubbles = true
        let laid = rows([(Self.them, "hello there"), (Self.me, "hi")], settings: settings)
        #expect(laid[0].bubbles?.bubble?.ground == .neutral)
        #expect(laid[1].bubbles?.bubble?.ground == .accent)
    }

    private func reacted(_ author: UserID, _ text: String, _ reactions: [Reaction]) -> Message {
        Message(
            id: MessageID(rawValue: 1),
            channelID: ChannelID(rawValue: 9),
            authorID: author,
            content: text,
            payload: MessagePayload(reactions: reactions)
        )
    }

    private static func thumbs(_ count: Int, mine: Bool = false) -> Reaction {
        Reaction(emoji: EmojiRef(name: "👍"), count: count, isMine: mine)
    }

    @Test("Up to three reactions ride the bubble's top corner, on the side facing the conversation")
    func tapbacks() throws {
        let reactions = [Self.thumbs(1), Reaction(emoji: EmojiRef(name: "🔥"), count: 4, isMine: true)]
        let theirs = try #require(rows([reacted(Self.them, "a sentence of some length", reactions)]).first)
        let bubble = try #require(theirs.bubbles?.bubble)
        #expect(theirs.reactions.count == 2)
        #expect(theirs.reactions.allSatisfy { $0.isTapback })
        #expect(theirs.reactionControls.isEmpty)
        let first = theirs.reactions[0].rect
        // On the trailing top corner of somebody else's bubble, half above it…
        #expect(first.midY < bubble.rect.minY + TimelineMetrics.tapbackSide / 2)
        #expect(first.minY < bubble.rect.minY)
        #expect(first.minX < bubble.rect.maxX && first.maxX > bubble.rect.maxX)
        // …and the next leads away from the bubble.
        #expect(theirs.reactions[1].rect.minX > first.maxX)
        // A single reaction is a circle; a count makes it a capsule.
        #expect(first.width == TimelineMetrics.tapbackSide)
        #expect(theirs.reactions[1].rect.width > TimelineMetrics.tapbackSide)
        // The bubble stepped down for them, so the badge stays inside its row.
        #expect(first.minY >= 0)

        let mine = try #require(rows([reacted(Self.me, "a sentence of some length", [Self.thumbs(2)])]).first)
        let ownBubble = try #require(mine.bubbles?.bubble)
        let badge = try #require(mine.reactions.first?.rect)
        // The reader's own: the leading top corner.
        #expect(badge.minX < ownBubble.rect.minX && badge.maxX > ownBubble.rect.minX)
    }

    @Test("A gap is cut round each tapback into the bubble it rides")
    func tapbackNotch() throws {
        let row = try #require(rows([reacted(Self.them, "a sentence of some length", [Self.thumbs(1)])]).first)
        let bubble = try #require(row.bubbles?.bubble)
        let badge = try #require(row.reactions.first?.rect)
        // Inside the body's corner, under the badge: cut away.
        let underBadge = CGPoint(x: badge.midX, y: bubble.rect.minY + 1)
        #expect(!bubble.path.contains(underBadge))
        // Well clear of it: still the bubble.
        #expect(bubble.path.contains(CGPoint(x: bubble.rect.minX + 20, y: bubble.rect.midY)))
    }

    @Test("Past three reactions every one hangs under the bubble as a chip")
    func chipsPastThree() throws {
        let reactions = ["👍", "🔥", "😀", "🎉"].map { Reaction(emoji: EmojiRef(name: $0), count: 1, isMine: false) }
        let row = try #require(rows([reacted(Self.them, "hello", reactions)]).first)
        let bubble = try #require(row.bubbles?.bubble)
        #expect(row.reactions.count == 4)
        #expect(!row.reactions.contains { $0.isTapback })
        #expect(row.reactions.allSatisfy { $0.rect.minY >= bubble.rect.maxY })
    }

    @Test("A refused send keeps its glass, with Messages' red mark beside it and the caption under it")
    func failedSend() throws {
        let row = try #require(rows([(Self.me, "this will not arrive")], failed: [MessageID(rawValue: 1)]).first)
        let bubble = try #require(row.bubbles?.bubble)
        let failure = try #require(row.bubbles?.failure)
        #expect(bubble.ground == .own)
        // The disc sits past the tail, inside the row, and the bubble made room.
        #expect(failure.badge.minX > bubble.rect.maxX + BubbleMetrics.tailReach)
        #expect(failure.badge.maxX <= Self.width - Self.margin + 0.5)
        #expect(abs(failure.badge.midY - bubble.rect.midY) <= 1)
        // The caption hangs under the bubble's trailing edge, and the row holds it.
        #expect(failure.caption.minY > bubble.rect.maxY)
        #expect(abs(failure.caption.maxX - bubble.rect.maxX) < 0.5)
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let laid = layout(
            messages([(Self.me, "this will not arrive")]), failed: [MessageID(rawValue: 1)], cache: &cache
        )
        let height = try #require(laid.first { if case .message = $0.kind { true } else { false } }?.height)
        #expect(height >= failure.caption.maxY)

        // Somebody else's message is never marked, and Discord's columns keep
        // their own failure ink.
        let columns = try #require(
            rows([(Self.me, "this will not arrive")], arrangement: .columns, failed: [MessageID(rawValue: 1)]).first
        )
        #expect(columns.bubbles == nil)
    }

    @Test("Words sit inside their bubble, padded on every side, and the bubble stays in its lane")
    func wordsInsideTheirBubble() throws {
        let long = String(repeating: "a sentence that has to wrap more than once in its bubble ", count: 4)
        let row = try #require(rows([(Self.me, long)]).first)
        let bubble = try #require(row.bubbles?.bubble)
        let block = try #require(row.textBlock)
        let words = CGRect(origin: row.textOrigin, size: block.size)
        let inner = bubble.rect.insetBy(
            dx: BubbleMetrics.horizontalPadding - 0.5, dy: BubbleMetrics.verticalPadding - 0.5
        )
        #expect(inner.contains(words))
        let lane = MessageLane.bubble(rowWidth: Self.width, side: .trailing, indent: 0)
        #expect(bubble.rect.minX >= lane.minX - 0.5)
        #expect(bubble.rect.maxX <= lane.maxX + 0.5)
        // It wrapped, rather than running past the lane.
        #expect(block.size.height > MessageTextStyle.current().bodyFont.pointSize * 3)
    }

    @Test("A row is tall enough for its bubble's padding")
    func rowHoldsItsBubble() throws {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let laid = layout(messages([(Self.me, "hi")]), cache: &cache)
        let row = try #require(laid.first { $0.messageID != nil })
        guard case .message(let message) = row.kind else { return }
        let bubble = try #require(message.bubbles?.bubble)
        #expect(row.height >= bubble.rect.maxY)
    }

    @Test("Only the last bubble of a run wears the tail, and the face sits beside it on its foot")
    func tailAndFace() throws {
        let laid = rows([(Self.them, "one"), (Self.them, "two"), (Self.them, "three")])
        #expect(laid.map { $0.bubbles?.bubble?.hasTail } == [false, false, true])
        #expect(laid.map { $0.avatarRect != nil } == [false, false, true])
        #expect(laid.map(\.hasAuthorLine) == [true, false, false])
        let face = try #require(laid[2].avatarRect)
        let bubble = try #require(laid[2].bubbles?.bubble)
        #expect(face.maxY == bubble.rect.maxY)
        #expect(face.maxX <= bubble.rect.minX)
        #expect(face.width == BubbleMetrics.avatarSide)
    }

    @Test("The reader's own messages carry no name, no face and no header time")
    func ownMessagesAreUnnamed() {
        let laid = rows([(Self.me, "one"), (Self.me, "two")])
        #expect(laid.allSatisfy { !$0.hasAuthorLine && $0.avatarRect == nil && $0.timestampText.isEmpty })
    }

    @Test("A one-to-one conversation names nobody and keeps no room for faces")
    func directMessageNamesNobody() {
        let laid = rows([(Self.them, "one"), (Self.them, "two")], arrangement: .bubbles(namesAuthors: false))
        #expect(laid.allSatisfy { !$0.hasAuthorLine && $0.avatarRect == nil })
        #expect(laid[0].bubbles?.bubble?.rect.minX == Self.margin)
    }

    @Test("The time sits beside the bubble on the side the row leaves open, and the pill beyond it")
    func timeAndPill() throws {
        let laid = rows([(Self.them, "hello"), (Self.me, "hi")])
        let theirs = try #require(laid[0].bubbles)
        let mine = try #require(laid[1].bubbles)
        let theirBubble = try #require(theirs.bubble)
        let myBubble = try #require(mine.bubble)
        #expect(theirs.timeRect.minX >= theirBubble.rect.maxX + BubbleMetrics.timeGap - 0.5)
        #expect(mine.timeRect.maxX <= myBubble.rect.minX - BubbleMetrics.timeGap + 0.5)
        #expect(abs(mine.timeRect.midY - myBubble.rect.midY) <= 0.5)
        let myPill = try #require(mine.pillAnchor)
        let theirPill = try #require(theirs.pillAnchor)
        #expect(myPill.edge == .trailing && myPill.x < mine.timeRect.minX)
        #expect(theirPill.edge == .leading && theirPill.x > theirs.timeRect.maxX)
        #expect(myPill.midY == mine.timeRect.midY)
    }

    @Test("One bubble holds the words and everything under them, on its own side")
    func oneBubbleHoldsTheMessage() throws {
        let picture = WingcordCore.Attachment(
            id: AttachmentID(rawValue: 1),
            filename: "cat.png",
            url: "https://cdn.discordapp.com/attachments/1/2/cat.png",
            proxyURL: "https://media.discordapp.net/attachments/1/2/cat.png",
            contentType: "image/png",
            width: 400,
            height: 300
        )
        for author in [Self.me, Self.them] {
            let message = Message(
                id: MessageID(rawValue: 1),
                channelID: ChannelID(rawValue: 9),
                authorID: author,
                content: "look",
                payload: MessagePayload(
                    attachments: [picture],
                    stickers: [StickerRef(id: 9, name: "wave", format: .png)]
                )
            )
            var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
            let row = try #require(layout([message], cache: &cache).lazy.compactMap { row -> MessageRow? in
                if case .message(let message) = row.kind { message } else { nil }
            }.first)
            let bubbles = try #require(row.bubbles)
            let bubble = try #require(bubbles.bubble)
            let words = CGRect(origin: row.textOrigin, size: try #require(row.textBlock).size)
            #expect(bubble.rect.contains(words))
            // A card's inset in from every edge.
            let inner = bubble.rect.insetBy(
                dx: TimelineMetrics.attachmentGap - 0.5, dy: TimelineMetrics.attachmentGap - 0.5
            )
            for rect in row.attachments.map(\.rect) + row.stickers.map(\.rect) {
                #expect(inner.contains(rect))
            }
            // Against its own side, and the time beside the whole bubble.
            if author == Self.me {
                #expect(bubble.rect.maxX == Self.width - Self.margin)
                #expect(bubbles.timeRect.maxX < bubble.rect.minX)
            } else {
                #expect(bubble.rect.minX == Self.margin + BubbleMetrics.avatarSide + BubbleMetrics.avatarGap)
                #expect(bubbles.timeRect.minX > bubble.rect.maxX)
            }
            // Level with the words' line, not halfway down the picture.
            #expect(bubbles.timeRect.midY < words.maxY)
        }
    }

    @Test("Emoji on their own take a bubble too, against their side")
    func jumboEmojiAreBubbled() throws {
        // Alex, 2026-10-26: "emoji-only messages get no bubble" — they were
        // drawn bare, as Messages draws them.
        let row = try #require(rows([(Self.me, "😀")]).first)
        let block = try #require(row.textBlock)
        let bubble = try #require(row.bubbles?.bubble)
        #expect(bubble.rect.maxX == Self.width - Self.margin)
        // The emoji inside it, centred across it.
        #expect(bubble.rect.contains(CGPoint(x: row.textOrigin.x + block.size.width / 2, y: bubble.rect.midY)))
        // A single emoji is a circle, never a pill pinched round it.
        #expect(bubble.rect.width >= bubble.rect.height - 0.5)
    }

    /// Alex, 2026-10-26: "see if there's any other types of these bugs with
    /// other types of messages". Every message the demo holds, laid out as the
    /// transcript lays it out — so a kind of message that comes out bare fails
    /// here, whichever kind it is, rather than waiting for somebody to see it.
    @Test("Every kind of message the demo holds takes a bubble")
    func everyKindTakesABubble() {
        let model = AppModel()
        DemoFixtures.populate(model)
        var bare: [String] = []
        var seen: [String: Int] = [:]
        // The demo forwards nothing, so one is added for the sweep to meet.
        let forward = Message(
            id: MessageID(rawValue: 1),
            channelID: ChannelID(rawValue: 9),
            authorID: Self.them,
            payload: MessagePayload(forwarded: ForwardedMessage(content: "from elsewhere"))
        )
        for box in model.messageBoxes.values {
            var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
            let messages = box.messages + [forward]
            let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let laid = layout(messages, cache: &cache)
            for row in laid {
                guard case .message(let drawn) = row.kind, let message = byID[drawn.id] else { continue }
                // A system event is a sentence across the transcript, not
                // somebody saying something.
                guard !message.isSystemEvent else { continue }
                for (name, holds) in [
                    ("words", !message.content.isEmpty), ("attachment", !message.attachments.isEmpty),
                    ("sticker", !message.stickers.isEmpty), ("embed", !message.embeds.isEmpty),
                    ("poll", message.poll != nil), ("activity", message.activityInvite != nil),
                    ("listenAlong", message.listenAlong != nil), ("theme", message.sharedTheme != nil),
                    ("forward", message.forwarded != nil), ("reply", message.reference != nil),
                    ("buttons", !message.components.isEmpty), ("componentsV2", !message.displayComponents.isEmpty),
                    ("command", message.interaction != nil), ("edited", message.editedAt != nil),
                ] where holds {
                    seen[name, default: 0] += 1
                }
                if drawn.bubbles?.bubble == nil {
                    bare.append("\(message.kind) “\(message.content.prefix(30))” attachments \(message.attachments.count) "
                        + "embeds \(message.embeds.count) stickers \(message.stickers.count)")
                }
            }
        }
        #expect(bare.isEmpty, "\(bare.count) bare: \(bare.prefix(12))")
        // The sweep is only worth what it covered.
        for name in ["words", "attachment", "sticker", "embed", "poll", "activity", "forward", "reply", "buttons", "componentsV2", "command", "edited"] {
            #expect(seen[name, default: 0] > 0, "the demo holds no \(name) to sweep")
        }
    }

    @Test("A new message takes the tail, and the bubble that lost it is laid out again")
    func theTailMoves() {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let lines: [(UserID, String)] = [(Self.me, "one"), (Self.me, "two")]
        let first = layout(Array(messages(lines).prefix(1)), cache: &cache).compactMap(\.bubble)
        #expect(first.map(\.hasTail) == [true])
        let second = layout(messages(lines), cache: &cache).compactMap(\.bubble)
        #expect(second.map(\.hasTail) == [false, true])
    }

    @Test("A reply over the reader's bubble sits on its side, with no elbow")
    func replyHeaderHasNoElbow() throws {
        let reply = Message(
            id: MessageID(rawValue: 2),
            channelID: ChannelID(rawValue: 9),
            authorID: Self.me,
            content: "agreed",
            kind: .reply,
            payload: MessagePayload(
                reference: MessageReference(messageID: MessageID(rawValue: 1), authorID: Self.them, excerpt: "hey")
            )
        )
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let laid = layout([reply], cache: &cache).compactMap { row -> MessageRow? in
            if case .message(let message) = row.kind { message } else { nil }
        }
        let header = try #require(laid.first?.replyHeader)
        #expect(header.elbowBottom == nil)
        #expect(abs(header.rect.maxX - (Self.width - Self.margin)) <= 0.5)
    }

    @Test("Columns are untouched: no bubbles, and the words start after the gutter")
    func columnsAreUntouched() {
        let laid = rows([(Self.them, "hello"), (Self.me, "hi")], arrangement: .columns)
        #expect(laid.allSatisfy { $0.bubbles == nil })
        #expect(laid.allSatisfy { $0.textOrigin.x == TimelineMetrics.contentInset })
        #expect(laid.map(\.hasAuthorLine) == [true, true])
    }

    @Test("A tail reaches past the body on its own side, and no further than its reach")
    func tailShape() {
        let body = CGRect(x: 100, y: 10, width: 120, height: 30)
        let trailing = BubbleShape.path(body: body, radius: 15, tail: .trailing).boundingBoxOfPath
        let leading = BubbleShape.path(body: body, radius: 15, tail: .leading).boundingBoxOfPath
        let bare = BubbleShape.path(body: body, radius: 15, tail: nil).boundingBoxOfPath
        #expect(trailing.maxX > body.maxX)
        #expect(trailing.maxX <= body.maxX + BubbleMetrics.tailReach + 0.01)
        #expect(trailing.minX >= body.minX - 0.01)
        #expect(leading.minX < body.minX)
        #expect(leading.minX >= body.minX - BubbleMetrics.tailReach - 0.01)
        #expect(leading.maxX <= body.maxX + 0.01)
        #expect(abs(bare.minX - body.minX) < 0.01 && abs(bare.maxX - body.maxX) < 0.01)
    }

    @Test("A hugged block breaks the same lines, at the width its words take")
    func huggedBlockBreaksTheSameLines() {
        let style = MessageTextStyle.current()
        let source = "one two three four five six seven eight nine ten"
        let text = MessageTextBuilder.build(
            document: MarkdownParser().parse(source), context: MentionContext(), style: style
        )
        let wide = TimelineTextBlock(text: text, width: 140, style: style)
        let hugged = TimelineTextBlock(text: text, width: 140, style: style, hugsText: true)
        let everything = NSRange(location: 0, length: text.attributed.length)
        #expect(wide.size.width == 140)
        #expect(hugged.size.width < 140)
        #expect(hugged.size.height == wide.size.height)
        #expect(hugged.selectionRects(for: everything).count == wide.selectionRects(for: everything).count)
    }

    @Test("The painter fills the bubble and leaves the rest of the row alone")
    func paintsTheBubble() throws {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let laid = layout(messages([(Self.me, "hi")]), cache: &cache)
        let row = try #require(laid.first { $0.messageID != nil })
        guard case .message(let message) = row.kind else { return }
        let bubble = try #require(message.bubbles?.bubble)
        let width = Int(Self.width)
        let height = Int(row.height.rounded(.up))
        let pixels = RenderProbe.pixels(width: width, height: height) { context, _ in
            TimelineRowPainter.draw(
                row: row,
                in: CGRect(x: 0, y: 0, width: Self.width, height: row.height),
                context: context,
                style: MessageTextStyle.current(),
                state: TimelineRowPainter.State(),
                images: ImageStore.shared,
                scale: 1
            )
        }
        func isGround(_ x: CGFloat, _ y: CGFloat) -> Bool {
            let index = (Int(y) * width + Int(x)) * 4
            let grey = UInt8(RenderProbe.ground * 255)
            return pixels[index] == grey && pixels[index + 1] == grey && pixels[index + 2] == grey
        }
        // Inside the bubble, between its edge and its words: the fill.
        #expect(!isGround(bubble.rect.minX + 4, bubble.rect.midY))
        // Across the row, away from the bubble: nothing — no band, no tint.
        #expect(isGround(Self.width / 3, bubble.rect.midY))
    }
}

private extension TimelineRow {
    var bubble: MessageBubble? {
        if case .message(let row) = kind { row.bubbles?.bubble } else { nil }
    }
}
