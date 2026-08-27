import Foundation
import Testing
@testable import WingcordCore

/// A profile effect's timeline.
///
/// The numbers are Kawaii Clouds', captured from Discord's catalogue and
/// confirmed against the assets themselves: an intro that plays once over three
/// seconds, then a loop that runs forever, each 36 frames at 12 fps.
struct ProfileEffectTests {

    private func intro() -> ProfileEffect.Layer {
        ProfileEffect.Layer(
            url: URL(string: "https://cdn.discordapp.com/assets/content/intro")!,
            start: 0, duration: 3, loops: false, zIndex: 100,
            size: CGSize(width: 450, height: 880)
        )
    }

    private func loop() -> ProfileEffect.Layer {
        ProfileEffect.Layer(
            url: URL(string: "https://cdn.discordapp.com/assets/content/loop")!,
            start: 3, duration: 3, loops: true, zIndex: 101,
            size: CGSize(width: 450, height: 880)
        )
    }

    @Test("The intro plays once and then stops existing")
    func introPlaysOnce() {
        let layer = intro()
        #expect(layer.phase(at: 0) == 0)
        #expect(layer.phase(at: 1.5) == 1.5)
        // Past its duration it is not merely invisible — it is done, which is
        // what lets the player release ~19 MB of decoded frames.
        #expect(layer.phase(at: 3.1) == nil)
        #expect(layer.isFinished(at: 3.1))
        #expect(!layer.isFinished(at: 2.9))
    }

    @Test("The loop waits for its start, then repeats forever")
    func loopStartsLateAndRepeats() {
        let layer = loop()
        // Before its cue it must draw nothing, or the handover shows both.
        #expect(layer.phase(at: 2.9) == nil)
        #expect(layer.phase(at: 3) == 0)
        let midway = layer.phase(at: 4.5)
        #expect(midway == 1.5)
        // Second pass, same phase.
        let wrapped = layer.phase(at: 7.5)
        #expect(wrapped == 1.5)
        // And it is never finished.
        #expect(!layer.isFinished(at: 10_000))
    }

    @Test("Layers are held in paint order regardless of how they arrive")
    func layersSortByZIndex() {
        // Discord does not promise an order in the array; the zIndex is the
        // order, and getting it backwards puts the clouds over the chains.
        let effect = ProfileEffect(
            skuID: "1", title: "Kawaii Clouds", accessibilityLabel: nil,
            reducedMotionURL: nil, layers: [loop(), intro()]
        )
        #expect(effect.layers.map(\.zIndex) == [100, 101])
    }

    @Test("An effect with a looping layer never ends")
    func loopsForever() {
        let forever = ProfileEffect(
            skuID: "1", title: "", accessibilityLabel: nil,
            reducedMotionURL: nil, layers: [intro(), loop()]
        )
        #expect(forever.loopsForever)

        let once = ProfileEffect(
            skuID: "2", title: "", accessibilityLabel: nil,
            reducedMotionURL: nil, layers: [intro()]
        )
        #expect(!once.loopsForever)
    }

    @Test("A zero-duration layer cannot divide by zero")
    func zeroDurationIsSafe() {
        let layer = ProfileEffect.Layer(
            url: URL(string: "https://example.invalid/a")!,
            start: 0, duration: 0, loops: true, zIndex: 1, size: .zero
        )
        #expect(layer.phase(at: 5) == 0)
    }
}
