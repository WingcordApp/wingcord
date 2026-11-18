import CoreGraphics
import Testing
@testable import Wingcord

/// The air between the newest message and the composer (Alex, 2026-11-18:
/// "wayy too much space between the composer and the messages").
@Suite("Composer clearance")
struct ComposerClearanceTests {
    @Test("Without a typing or slowmode row, the air is the clearance")
    func plain() {
        #expect(TimelineMetrics.clearance(above: 0) == TimelineMetrics.composerClearance)
        #expect(TimelineMetrics.composerClearance == 12)
    }

    /// The row rides in the composer's bar, so its height is already in the
    /// inset; the clearance takes it in instead of stacking on it.
    @Test("The status row counts as air, with a hairline left over it")
    func rowIsTheAir() {
        let slowmode: CGFloat = 25
        #expect(TimelineMetrics.clearance(above: slowmode) == Spacing.tight)
        // Total over the composer: the larger of the two, never their sum.
        #expect(slowmode + TimelineMetrics.clearance(above: slowmode) == slowmode + Spacing.tight)
        #expect(5 + TimelineMetrics.clearance(above: 5) == TimelineMetrics.composerClearance)
    }
}
