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

/// A one-shot asset inside a slot longer than itself.
///
/// **The profile-effect catalogue's `duration` is the SLOT; the APNG's own is
/// the playback, and they are not the same number.** SpongeBob's entry gives him
/// 6000 ms and the file is 4125 ms with `acTL num_plays: 1`. Fed through the
/// looping lookup, the last 1875 ms of the slot replayed the opening 1875 ms of
/// the animation — he walked on, flew away, and walked on again before being cut
/// off mid-stride. Measured off the real asset, not guessed.
@MainActor
@Suite("One-shot playback")
struct OneShotPlaybackTests {

    /// Four frames, a quarter-second each: a one-second asset.
    private func strip() -> AnimatedImage {
        let frames = (0..<4).map { index -> CGImage in
            let context = CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(gray: CGFloat(index) / 4, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            return context.makeImage()!
        }
        return AnimatedImage(
            frames: frames,
            ends: [0.25, 0.5, 0.75, 1.0],
            duration: 1.0,
            cost: 0
        )
    }

    @Test("A one-shot asset holds its last frame instead of starting over")
    func holdsTheLastFrame() {
        let film = strip()
        let last = film.frames[3]
        // Inside its own duration it plays normally.
        #expect(film.frame(at: 0.1, looping: false) === film.frames[0])
        #expect(film.frame(at: 0.6, looping: false) === film.frames[2])
        // **Past the end it holds**, for as long as the slot runs on.
        #expect(film.frame(at: 1.2, looping: false) === last)
        #expect(film.frame(at: 5.9, looping: false) === last)
    }

    @Test("A looping asset still wraps")
    func loopingStillWraps() {
        let film = strip()
        // The other half of the same rule: a layer Discord marks `loop: true`
        // carries `num_plays: 0` and must keep going.
        #expect(film.frame(at: 1.1, looping: true) === film.frames[0])
        #expect(film.frame(at: 2.6, looping: true) === film.frames[2])
    }

    @Test("SpongeBob's own numbers, as captured")
    func spongebobSlot() {
        // The catalogue: 6000 ms, loop false. The APNG: 4125 ms, 99 frames.
        let film = AnimatedImage(
            frames: strip().frames, ends: [1.03, 2.06, 3.09, 4.125],
            duration: 4.125, cost: 0
        )
        // At 5.0 s the slot is still running and the looping lookup would be
        // 0.875 s into a *second* performance — frame 0.
        #expect(film.frame(at: 5.0, looping: true) === film.frames[0])
        // One-shot holds the final frame instead, which is what the reader sees
        // on Discord: he is gone, and stays gone.
        #expect(film.frame(at: 5.0, looping: false) === film.frames[3])
    }
}
