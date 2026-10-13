import AppKit
import SwiftUI
import Testing
@testable import Wingcord

/// The tab strip is Clock's: 36 points tall, at the extra-large size.
///
/// SwiftUI writes the environment's control size onto a hosted `NSControl`
/// after `makeNSView` returns, so a size set on the control itself is
/// overwritten — every strip in the app drew at the regular size's 24 points
/// (references 54 and 55). The size now comes from the environment, and this
/// measures the control AppKit actually laid out.
@MainActor
struct SegmentedPickerTests {
    private enum Tab: Hashable { case unreads, mentions, bookmarks }

    @Test("A strip is 36 points tall, wherever it is placed")
    func stripIsClocksHeight() throws {
        _ = NSApplication.shared
        let picker = SegmentedPicker<Tab>(
            options: [.init(.unreads, "Unreads"), .init(.mentions, "Mentions"), .init(.bookmarks, "Bookmarks")],
            selection: .constant(.unreads)
        )
        // A surrounding size must not reach it: the strip's size is the strip's.
        let host = NSHostingView(rootView: picker.controlSize(.small))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 120)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()

        let control = try #require(segmentedControl(in: host))
        #expect(control.controlSize == .extraLarge)
        #expect(control.frame.height == 36)
    }

    private func segmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        for subview in view.subviews {
            if let control = segmentedControl(in: subview) { return control }
        }
        return nil
    }
}
