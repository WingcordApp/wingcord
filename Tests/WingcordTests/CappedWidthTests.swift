import AppKit
import SwiftUI
import Testing
@testable import Wingcord

/// A tooltip's words must fit the glass sized for them — the server mark's
/// "People with an invite link can join." ran out of its flyout, because
/// `frame(maxWidth:)` under `fixedSize()` measured it on one line and drew it
/// on two.
@MainActor
struct CappedWidthTests {

    private static let sentence = "People with an invite link can join."

    private func fitting(_ view: some View) -> CGSize {
        NSHostingView(rootView: view).fittingSize
    }

    @Test("A sentence past the cap is measured wrapped, at the cap")
    func measuresWrapped() {
        let capped = fitting(CappedWidth(max: 120) { Text(Self.sentence) }.fixedSize())
        let wrapped = fitting(Text(Self.sentence).frame(width: 120).fixedSize(horizontal: false, vertical: true))
        let oneLine = fitting(Text(Self.sentence).fixedSize())
        #expect(capped.width <= 120)
        #expect(capped.height == wrapped.height)
        #expect(capped.height > oneLine.height)
    }

    @Test("Words narrower than the cap keep their own width")
    func hugsShortWords() {
        let capped = fitting(CappedWidth(max: 190) { Text("Verified") }.fixedSize())
        let own = fitting(Text("Verified").fixedSize())
        #expect(capped == own)
    }
}
