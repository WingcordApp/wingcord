import AppKit
import CoreGraphics
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The transcript's redesigned parts, drawn: with `WINGCORD_RENDER_DIR` set
/// each is written there as a PNG to be looked at; without it the tests only
/// hold that drawing them puts something on the canvas.
@MainActor
@Suite("Transcript redesign, drawn")
struct TranscriptRedesignRenderTests {
    private let style = MessageTextStyle.current()
    private static let width: CGFloat = 560

    private func rows(_ messages: [Message], width: CGFloat = TranscriptRedesignRenderTests.width) -> [TimelineRow] {
        let engine = TimelineLayoutEngine(presentationRevision: 0)
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        return engine.layout(
            TimelineLayoutEngine.Input(
                items: messages.enumerated().map { index, message in
                    .message(TimelineMessage(message: message, flags: index == 0 ? [.head, .tail] : [.tail]))
                },
                width: width,
                style: style,
                mentions: MentionContext(),
                channelName: "general",
                authors: [
                    UserID(rawValue: 7): TimelineLayoutEngine.AuthorInfo(
                        name: "Ada", colorValue: nil, avatarURL: nil,
                        monogram: "A", decorationURL: nil, isBot: false
                    ),
                ],
                calendar: .current,
                settings: .comfortable
            ),
            cache: &cache
        )
    }

    /// Draws rows one under another at 2×, on the room's own ground.
    @discardableResult
    private func render(
        _ rows: [TimelineRow],
        name: String,
        state: (Int) -> TimelineRowPainter.State = { _ in TimelineRowPainter.State() }
    ) throws -> Int {
        let scale: CGFloat = 2
        let height = rows.reduce(0) { $0 + $1.height } + 12
        let size = CGSize(width: Self.width, height: height)
        let context = try #require(CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(ThemeInk.current.canvas)
        context.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        var y: CGFloat = 6
        for (index, row) in rows.enumerated() {
            TimelineRowPainter.draw(
                row: row,
                in: CGRect(x: 0, y: y, width: Self.width, height: row.height),
                context: context,
                style: style,
                state: state(index),
                images: ImageStore.shared,
                scale: scale
            )
            y += row.height
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = try #require(context.makeImage())
        if let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"] {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        return image.height
    }

    private func message(_ id: UInt64, _ content: String, payload: MessagePayload = MessagePayload()) -> Message {
        Message(
            id: MessageID(rawValue: id << 22),
            channelID: ChannelID(rawValue: 1),
            authorID: UserID(rawValue: 7),
            content: content,
            payload: payload
        )
    }

    @Test("Reaction chips: at rest, under the pointer, and the reader's own")
    func reactions() throws {
        let reactions = [
            Reaction(emoji: EmojiRef(name: "👀"), count: 6, isMine: false),
            Reaction(emoji: EmojiRef(name: "🔥"), count: 12, isMine: true),
            Reaction(emoji: EmojiRef(name: "💯"), count: 128, isMine: false),
        ]
        let laid = rows([
            message(1, "bit of smaller more bugfix", payload: MessagePayload(reactions: reactions)),
            message(2, "next one will be larger 🙏", payload: MessagePayload(reactions: reactions)),
            message(3, "and one that is kept", payload: MessagePayload(reactions: reactions)),
        ])
        let height = try render(laid, name: "reactions") { index in
            var state = TimelineRowPainter.State()
            state.canAddReaction = true
            // The first at rest, the second under the pointer, the third kept.
            state.isHovered = index == 1
            state.isBookmarked = index == 2
            return state
        }
        #expect(height > 0)
    }

    @Test("Tapbacks under a name: beside it, the bubble where it would be without them")
    func tapbacksUnderCaption() throws {
        let thumbs = [Reaction(emoji: EmojiRef(name: "👍"), count: 1, isMine: false)]
        // Each message a run of its own, so each carries the name over it.
        func bubbleRow(_ id: UInt64, _ content: String, reactions: [Reaction] = []) -> TimelineRow? {
            let engine = TimelineLayoutEngine(presentationRevision: 0)
            var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
            return engine.layout(
                TimelineLayoutEngine.Input(
                    items: [.message(TimelineMessage(
                        message: message(id, content, payload: MessagePayload(reactions: reactions)),
                        flags: [.head, .tail]
                    ))],
                    width: Self.width,
                    style: style,
                    mentions: MentionContext(),
                    channelName: "general",
                    authors: [
                        UserID(rawValue: 7): TimelineLayoutEngine.AuthorInfo(
                            name: "Ada Lovelace", colorValue: nil, avatarURL: nil,
                            monogram: "A", decorationURL: nil, isBot: false
                        ),
                    ],
                    calendar: .current,
                    settings: .comfortable,
                    arrangement: .bubbles(namesAuthors: true)
                ),
                cache: &cache
            ).first { if case .message = $0.kind { true } else { false } }
        }
        let laid = try [
            #require(bubbleRow(1, "you don't really have to, this update has no features")),
            #require(bubbleRow(2, "you don't really have to, this update has no features", reactions: thumbs)),
            #require(bubbleRow(3, "ok", reactions: thumbs)),
        ]
        #expect(try render(laid, name: "tapbacks-under-caption") > 0)
    }
}
