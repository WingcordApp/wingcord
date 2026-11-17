import AppKit
import SwiftUI
import Testing
import WingcordCore

@testable import Wingcord

/// The reader's own status bubble, pressed with real mouse events in a real
/// window (Alex, 2026-11-17, Image 84: "I have to press on a specific location
/// to open the flyout"). Every point of the drawn bubble must open it.
///
/// Opt-in like `VoiceTileMenuPressTests`, for its reason: `WINGCORD_EVENT_TESTS=1
/// swift test --filter StatusBubblePressTests`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["WINGCORD_EVENT_TESTS"] != nil))
struct StatusBubblePressTests {
    private final class Record { var presses = 0 }

    private final class Host: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private final class NeverKeyWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private static let size = CGSize(width: 340, height: 220)
    private static let bannerHeight: CGFloat = 108
    private static let drop: CGFloat = Metrics.avatarProfile / 2 - 6

    /// The banner's arrangement, as the card builds it: the bubble as the
    /// card's own button, bottom-leading on the artwork.
    private func mount(_ record: Record, card: Bool) -> (Host, NSWindow) {
        let bubble = CustomStatusBubble(
            text: nil,
            emoji: nil,
            placeholder: "A useless talent of yours?",
            avatarDrop: Self.drop,
            cardWidth: Self.size.width
        )
        let banner = ZStack(alignment: .bottomLeading) {
            Color.clear.frame(height: Self.bannerHeight)
            if card {
                OwnStatusBubbleButton(bubble: bubble) { record.presses += 1 }
            } else {
                Button { record.presses += 1 } label: { bubble }
                    .buttonStyle(.plain)
            }
        }
        .padding(.bottom, Self.drop + 8)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)

        let host = Host(rootView: AnyView(banner.resolvesMotion()))
        let window = NeverKeyWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        return (host, window)
    }

    private func click(_ host: NSView, at point: CGPoint) throws {
        let flipped = host.isFlipped ? point : CGPoint(x: point.x, y: host.bounds.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(
                with: type, location: host.convert(flipped, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window?.windowNumber ?? 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            )))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    /// Points across the drawn bubble: its top, middle and foot rows, from just
    /// inside its leading edge to well into its words.
    private var bubblePoints: [CGPoint] {
        let layout = StatusBubbleLayout(
            avatarSide: Metrics.avatarProfile, avatarDrop: Self.drop, cardWidth: Self.size.width,
            margin: Spacing.margin, surface: .card
        )
        let left = layout.leadingInset + 8
        let top = Self.bannerHeight - 7 + 6
        return [0.0, 0.5, 0.95].flatMap { row -> [CGPoint] in
            let y = top + row * 30
            return [left, left + 40, left + 90].map { CGPoint(x: $0, y: y) }
        }
    }

    @Test("Every point of the drawn bubble opens the editor")
    func wholeBubbleTakesTheClick() throws {
        let record = Record()
        let (host, window) = mount(record, card: true)
        defer { window.orderOut(nil) }
        var missed: [CGPoint] = []
        for point in bubblePoints {
            let before = record.presses
            try click(host, at: point)
            if record.presses == before { missed.append(point) }
        }
        #expect(missed.isEmpty, "presses missed at \(missed)")
    }

    /// The arrangement before the fix, kept to show the cause: the offset
    /// inside the button's label.
    @Test("Diagnosis: a bubble offset inside its button's label misses presses")
    func offsetInsideTheLabel() throws {
        let record = Record()
        let (host, window) = mount(record, card: false)
        defer { window.orderOut(nil) }
        var landed = 0
        for point in bubblePoints {
            let before = record.presses
            try click(host, at: point)
            if record.presses > before { landed += 1 }
        }
        print("offset-in-label landed \(landed) of \(bubblePoints.count)")
    }
}
