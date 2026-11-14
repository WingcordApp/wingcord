import AppKit
import SwiftUI
import Testing
@testable import Wingcord

/// The card under the update arrow (docs/UPDATES.md D8), drawn in an offscreen
/// window — its notes are in a `ScrollView`, which draws nothing without one.
/// With `WINGCORD_RENDER_DIR` set each case is written there as a PNG to look
/// at; without it the cases still lay out, which is what catches a card whose
/// notes collapse to nothing or push the button off its bottom.
@MainActor
@Suite("Update card renders")
struct UpdateCardRenderTests {

    private let notes = """
    ### New
    - Wingcord updates itself: a new version downloads in the background and installs when you quit.
    - **Settings ▸ About** shows what's new in the version you're running.

    ### Fixed
    - Joining a call with AirPods no longer crashes when they're muted.
    """

    @Test("A ready update with notes, a critical one, and one without notes")
    func renders() throws {
        let cases: [(String, AppUpdates.Update)] = [
            ("update-card", .init(displayVersion: "1.0 Beta 2", build: "2", notes: notes, isCritical: false)),
            ("update-card-critical", .init(displayVersion: "1.0 Beta 3", build: "3", notes: notes, isCritical: true)),
            ("update-card-plain", .init(displayVersion: "1.0", build: "4", notes: nil, isCritical: false)),
        ]
        for (name, update) in cases {
            let size = try render(UpdateCard(update: update), named: name)
            #expect(size.width == UpdateCard.width, "\(name) keeps its width")
            #expect(size.height > (update.notes == nil ? 100 : 180), "\(name) laid out its notes and its button")
        }
    }

    private func render(_ view: some View, named name: String) throws -> CGSize {
        let model = AppModel()
        // The popover's dark ground, which the capture wouldn't otherwise have:
        // the card's ink is the light one, for a dark popover.
        let host = NSHostingView(rootView: AnyView(
            view.environment(model).fixedSize().background(Color(white: 0.17))
        ))
        let size = host.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.11, alpha: 1)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }

        if let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appending(path: "\(name).png"))
        }
        return host.bounds.size
    }
}
