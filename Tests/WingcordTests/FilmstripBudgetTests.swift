import CoreGraphics
import Foundation
import Testing
@testable import Wingcord

/// How much film a caller can afford.
///
/// **The budget is a frame count wearing a memory unit** — `INVARIANTS.md` §2 —
/// and the whole of "the banner renders at very low fps" was a number picked by
/// hand being right for one asset at one size.
@Suite("Filmstrip budget")
struct FilmstripBudgetTests {

    @Test("A profile banner's loop is affordable at the size it is drawn")
    func bannerLoop() {
        // 360 x 210 at 2x is 720 x 420, which is 1.21 MB a frame — so a
        // forty-eight frame loop needs about 58 MB, where the hand-picked 12 MB
        // bought nine. The point of the assertion is the *relationship*, not the
        // number: whatever the size, the budget covers a full loop.
        let size = CGSize(width: 360, height: 210)
        let budget = AnimatedImage.budget(forDrawn: size)
        let bytesPerFrame = Int(size.width * 2 * size.height * 2 * 4)
        #expect(budget / bytesPerFrame >= AnimatedImage.frameBudget)
    }

    @Test("A small asset keeps the default rather than being given less")
    func neverBelowTheDefault() {
        // A 26-point row avatar's decoration is a few kilobytes a frame, and a
        // budget derived from it would be *smaller* than the allowance every
        // caller has always had.
        let tiny = AnimatedImage.budget(forDrawn: CGSize(width: 31, height: 31))
        #expect(tiny == AnimatedImage.byteBudget)
    }

    @Test("A degenerate size does not divide by zero or go negative")
    func degenerate() {
        #expect(AnimatedImage.budget(forDrawn: .zero) == AnimatedImage.byteBudget)
    }
}
