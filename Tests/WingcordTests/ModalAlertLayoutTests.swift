import AppKit
import SwiftUI
import Testing
@testable import Wingcord

/// An alert's two capsules share the row while both labels fit their half,
/// and stack, the act on top, once one doesn't — "Move to Applicati…" was cut
/// short on 2026-11-14.
@MainActor
struct ModalAlertLayoutTests {
    private func height(_ actions: [ModalAlertAction]) -> CGFloat {
        let host = NSHostingView(rootView: ModalAlert(title: "Move Wingcord to Applications?", actions: actions))
        return host.fittingSize.height
    }

    @Test("Two short labels share one row; a label too long for its half stacks them")
    func longLabelStacks() {
        let row = height([.cancel("Not Now"), .act("Move", symbol: "folder") {}])
        let stacked = height([.cancel("Not Now"), .act("Move to Applications", symbol: "folder") {}])
        #expect(stacked > row + 20, "a second row of capsules")
        #expect(height([.okay()]) == height([.okay("Fine")]), "one capsule always has the row to itself")
    }
}
