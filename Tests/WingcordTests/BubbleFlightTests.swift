import AppKit
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// A send's flight from the composer into its bubble, on the real canvas.
///
/// **Driven on the canvas, not through the coordinator**: the coordinator
/// reads the reader's bubble preference from the shared presentation, and
/// flipping it here would lay out every other suite running beside this one in
/// bubbles (`INVARIANTS.md` on tests and shared stores).
@MainActor
@Suite("Send flights")
struct BubbleFlightTests {
    private static let me = UserID(rawValue: 1)
    private static let nonce = MessageID(rawValue: (1_700_000_000_000 << 22) | 1)
    private static let launch = SendLaunch(
        firstBaseline: CGPoint(x: 40, y: 60),
        field: CGRect(x: 30, y: 40, width: 500, height: 38),
        fontSize: 13,
        isOneLine: true
    )

    private func message(id: MessageID) -> Message {
        Message(
            id: id,
            channelID: ChannelID(rawValue: 9),
            authorID: Self.me,
            content: "hello",
            payload: MessagePayload(nonce: String(Self.nonce.rawValue))
        )
    }

    private func rows(_ messages: [Message]) -> [TimelineRow] {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        return TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: TimelineReducer.rows(messages: messages),
                width: 700,
                style: MessageTextStyle.current(),
                mentions: MentionContext(selfIDs: [Self.me.rawValue]),
                channelName: "general",
                authors: [:],
                calendar: .current,
                settings: .comfortable,
                arrangement: .bubbles(namesAuthors: true)
            ),
            cache: &cache
        )
    }

    private func mounted() -> (NSWindow, TimelineCanvasView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let canvas = TimelineCanvasView(style: MessageTextStyle.current())
        canvas.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView?.addSubview(canvas)
        return (window, canvas)
    }

    @Test("A send flies, keeps flying through Discord's copy replacing its echo, and lands when its row is gone")
    func flightFollowsItsNonce() {
        let (window, canvas) = mounted()
        canvas.apply(rows: rows([message(id: Self.nonce)]))
        canvas.launchBubble(nonce: Self.nonce, from: Self.launch, reducesMotion: false)
        #expect(canvas.flyingNonces == [Self.nonce])
        #expect(canvas.isFlying(Self.nonce))

        // Discord's copy arrives under its own id, carrying the nonce.
        let real = MessageID(rawValue: (1_700_000_000_100 << 22) | 7)
        canvas.apply(rows: rows([message(id: real)]))
        canvas.followFlights { $0 == Self.nonce ? real : nil }
        #expect(canvas.flyingNonces == [Self.nonce])
        #expect(canvas.isFlying(real))
        #expect(!canvas.isFlying(Self.nonce))

        // A channel switch, a trim: the row is gone, and the flight lands.
        canvas.apply(rows: [])
        canvas.followFlights { _ in nil }
        #expect(canvas.flyingNonces.isEmpty)
        withExtendedLifetime(window) {}
    }

    @Test("A row with no bubble has nothing to fly")
    func nothingFliesWithoutABubble() {
        let (window, canvas) = mounted()
        // Emoji on their own are drawn bare.
        let bare = Message(
            id: Self.nonce, channelID: ChannelID(rawValue: 9), authorID: Self.me, content: "😀"
        )
        canvas.apply(rows: rows([bare]))
        canvas.launchBubble(nonce: Self.nonce, from: Self.launch, reducesMotion: false)
        #expect(canvas.flyingNonces.isEmpty)
        withExtendedLifetime(window) {}
    }

    @Test("A send's words are drawn for the flight, at the window's scale")
    func wordsAreDrawnOnce() throws {
        let laid = rows([message(id: Self.nonce)])
        let row = try #require(laid.lazy.compactMap { row -> MessageRow? in
            if case .message(let message) = row.kind { message } else { nil }
        }.first)
        let block = try #require(row.textBlock)
        let image = try #require(BubbleFlight.wordsImage(
            block, style: MessageTextStyle.current(), plates: ThemeInk.current.ownBubblePlates, scale: 2
        ))
        #expect(image.width == Int((block.size.width * 2).rounded(.up)))
        #expect(image.height == Int((block.size.height * 2).rounded(.up)))
    }
}
