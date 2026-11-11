import AppKit
import Testing
@testable import Wingcord

/// The window's buttons stay where the shell puts them through AppKit's own
/// title-bar layout — which is what moved the green light out of line for a
/// frame on every channel switch.
@MainActor
@Suite("Traffic light pin")
struct TrafficLightPinTests {

    private let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    private func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        return window
    }

    private func target(_ index: Int) -> NSPoint { NSPoint(x: 30 + CGFloat(index) * 20, y: 3) }

    @Test("A change of title leaves every pinned button where it was pinned")
    func titleChangeKeepsThePlace() throws {
        let window = window()
        defer { window.close() }
        for (index, type) in types.enumerated() {
            let button = try #require(window.standardWindowButton(type))
            #expect(TrafficLightPin.pin(button) { _ in self.target(index) })
            button.setFrameOrigin(target(index))
        }
        // AppKit lays the title bar out again for each of these, and puts the
        // buttons back at its own places — through the pin, at ours.
        for round in 0..<5 {
            window.title = "channel \(round)"
            window.setFrame(window.frame.insetBy(dx: -6, dy: -4), display: false)
            for (index, type) in types.enumerated() {
                let button = try #require(window.standardWindowButton(type))
                #expect(button.frame.origin == target(index), "\(type.rawValue) after round \(round)")
            }
        }
    }

    @Test("Unpinned, the same change does move them — which is what the pin is for")
    func unpinnedButtonsAreMoved() throws {
        let window = window()
        defer { window.close() }
        let zoom = try #require(window.standardWindowButton(.zoomButton))
        zoom.setFrameOrigin(target(2))
        window.title = "another channel"
        // If this ever holds without a pin, AppKit has stopped re-placing the
        // buttons and the pin can go.
        #expect(zoom.frame.origin != target(2))
    }

    @Test("A target of nothing lets the system's own place stand, and the class still answers as itself")
    func nilTargetPassesThrough() throws {
        let window = window()
        defer { window.close() }
        let close = try #require(window.standardWindowButton(.closeButton))
        let original: AnyClass = type(of: close)
        #expect(TrafficLightPin.pin(close) { _ in nil })
        close.setFrameOrigin(NSPoint(x: 41, y: 2))
        #expect(close.frame.origin == NSPoint(x: 41, y: 2))
        #expect(close.isKind(of: original))
        // Pinning twice only changes where it is pinned.
        #expect(TrafficLightPin.pin(close) { _ in NSPoint(x: 12, y: 1) })
        close.setFrameOrigin(NSPoint(x: 99, y: 99))
        #expect(close.frame.origin == NSPoint(x: 12, y: 1))
    }
}
