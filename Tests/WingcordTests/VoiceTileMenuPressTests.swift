import AppKit
import SwiftUI
import Testing
import WingcordCore

@testable import Wingcord

/// The ⋯ on a call tile, pressed with real mouse events in a real window — as
/// `CanvasAnchorTests` presses the transcript. Hover state is not in a render,
/// and neither is how long a press takes to answer or where its menu hangs.
///
/// Alex, 2026-11-17: the menu came up "not in the right place and it's not
/// instant". Measured: the double-click wrapped around the whole tile held
/// every button on it for 355 ms, and the anchor was in the window's space
/// rather than the root's, one titlebar strip low.
///
/// **The window is ordered in, far off every display, and never activated**:
/// a window that isn't on screen routes no clicks, and nothing here may take
/// the keyboard from whoever is using the Mac. Hover is delivered to SwiftUI's
/// own tracking areas, since the real pointer is elsewhere.
///
/// **Run on their own**: `WINGCORD_EVENT_TESTS=1 swift test --filter
/// VoiceTileMenuPressTests`. In the full run three hundred other suites share
/// this thread while these wait, and their pointer events can end the tile's
/// hover for seconds at a time — once in three full runs no press landed at
/// all. Alone they pass every time; a suite that fails one run in three is
/// worse than one that waits to be asked.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["WINGCORD_EVENT_TESTS"] != nil))
struct VoiceTileMenuPressTests {
    private final class Record {
        var anchors: [CGRect] = []
        var spotlights = 0
    }

    /// A test window is never key, and a click on a window that isn't is spent
    /// making it key. This takes it, as the key window's view would.
    private final class Host: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// **Never key.** In a key window SwiftUI checks a hover against the real
    /// pointer, which is wherever the person at the Mac left it — so the ⋯
    /// never appears. A window other suites leave behind closing can make an
    /// ordinary one key mid-test, which is how these failed in the full run
    /// and passed alone.
    private final class NeverKeyWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private static let size = CGSize(width: 320, height: 200)
    /// The ⋯: top trailing, the chip inset (10) in, a pill 26 tall and 35.1 wide.
    private static let dots = CGRect(x: 320 - 10 - 26 * 1.35, y: 10, width: 26 * 1.35, height: 26)

    private let participant = VoiceParticipant(
        id: UserID(rawValue: 900_000_000_000_000_001),
        displayName: "Rowan",
        avatarURL: nil,
        monogram: "R",
        ground: VoiceTileGround(flat: 0xC9897A),
        isSpeaking: false,
        isSelfMuted: false,
        isServerMuted: false,
        isDeafened: false,
        isCameraOn: false,
        isStreaming: false,
        isSelf: false,
        hasLiveVideo: false,
        isWatched: false
    )

    /// The tile as the grid builds it, in a root that records its origin as
    /// the app's does (`PresentationOrigin`).
    private func mount(_ record: Record) -> (Host, NSWindow) {
        let tile = VoiceTile(
            participant: participant,
            attachVideo: { _, _ in },
            openMenu: { record.anchors.append($0) },
            toggleSpotlight: { record.spotlights += 1 }
        )
        .onSecondaryClick { _ in }
        .frame(width: Self.size.width, height: Self.size.height)
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { PresentationOrigin.record($0) }

        let host = Host(rootView: AnyView(tile))
        let window = NeverKeyWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        spin(0.05)
        return (host, window)
    }

    /// A point in the tile's own top-left space, in the host's.
    private func point(_ point: CGPoint, in host: NSView) -> CGPoint {
        host.isFlipped ? point : CGPoint(x: point.x, y: host.bounds.height - point.y)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView, clickCount: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    /// The pointer arriving at `point`: an enter for each of SwiftUI's tracking
    /// areas, to whoever owns it, then a move.
    private func hover(_ host: NSView, at point: CGPoint) throws {
        for area in host.trackingAreas {
            guard let owner = area.owner as? NSResponder else { continue }
            owner.mouseEntered(with: try #require(NSEvent.enterExitEvent(
                with: .mouseEntered, location: host.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window?.windowNumber ?? 0,
                context: nil, eventNumber: 0, trackingNumber: unsafeBitCast(area, to: Int.self), userData: nil
            )))
        }
        let move = try event(.mouseMoved, at: point, in: host)
        for area in host.trackingAreas { (area.owner as? NSResponder)?.mouseMoved(with: move) }
    }

    private func click(_ host: NSView, at point: CGPoint, clickCount: Int = 1) throws {
        NSApp.sendEvent(try event(.leftMouseDown, at: point, in: host, clickCount: clickCount))
        spin(0.02)
        NSApp.sendEvent(try event(.leftMouseUp, at: point, in: host, clickCount: clickCount))
    }

    private func spin(_ seconds: Double) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// Hovers the tile and presses the ⋯, again if the press landed on nothing,
    /// and says how long the menu took to be asked for after the button came up.
    ///
    /// **A retry for the harness, never for the answer.** Another suite's pointer
    /// events, or a first render still settling, can leave the ⋯ not there to
    /// press; a press that lands is timed on the first one.
    private func pressDots(_ host: NSView, record: Record) throws -> TimeInterval? {
        let dots = point(CGPoint(x: Self.dots.midX, y: Self.dots.midY), in: host)
        for _ in 0..<5 {
            let before = record.anchors.count
            try hover(host, at: dots)
            spin(0.05)
            try click(host, at: dots)
            let released = Date()
            while Date().timeIntervalSince(released) < 1 {
                if record.anchors.count > before { return Date().timeIntervalSince(released) }
                spin(0.005)
            }
        }
        return nil
    }

    @Test("The ⋯ asks for its menu at once, not after a double-click's wait")
    func menuAtOnce() throws {
        let previous = PresentationOrigin.value
        defer { PresentationOrigin.record(previous) }
        let record = Record()
        let (host, window) = mount(record)
        defer { window.orderOut(nil) }
        // Answered in about 5 ms; held for a possible second click it was 355
        // (the system's 500 ms interval), so the line between them is wide.
        let waited = try #require(try pressDots(host, record: record), "no press reached the ⋯")
        #expect(waited < 0.2, "the press was held back \(Int(waited * 1000)) ms, as for a double-click")
        spin(0.05)
        #expect(record.anchors.count == 1)
        #expect(record.spotlights == 0, "a press on the ⋯ is not the picture's")
    }

    @Test("The menu hangs from the ⋯ itself, in the window root's space")
    func menuHangsFromTheButton() throws {
        let previous = PresentationOrigin.value
        defer { PresentationOrigin.record(previous) }
        let record = Record()
        let (host, window) = mount(record)
        defer { window.orderOut(nil) }
        _ = try #require(try pressDots(host, record: record), "no press reached the ⋯")
        let anchor = try #require(record.anchors.first)
        // In the root's space the tile starts at zero, so the ⋯ sits exactly
        // where the tile draws it; in the window's it would sit a titlebar
        // lower.
        #expect(abs(anchor.minX - Self.dots.minX) < 1)
        #expect(abs(anchor.minY - Self.dots.minY) < 1, "anchor at y \(anchor.minY), the ⋯ at \(Self.dots.minY)")
        #expect(abs(anchor.width - Self.dots.width) < 1 && abs(anchor.height - Self.dots.height) < 1)
    }

    @Test("A double-click on the picture still fills the stage")
    func doubleClickFillsTheStage() throws {
        let previous = PresentationOrigin.value
        defer { PresentationOrigin.record(previous) }
        let record = Record()
        let (host, window) = mount(record)
        defer { window.orderOut(nil) }
        let middle = point(CGPoint(x: 160, y: 100), in: host)
        try hover(host, at: middle)
        spin(0.05)
        try click(host, at: middle, clickCount: 1)
        spin(0.05)
        try click(host, at: middle, clickCount: 2)
        spin(0.1)
        #expect(record.spotlights == 1)
        #expect(record.anchors.isEmpty)
    }
}
