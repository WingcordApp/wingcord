import Foundation
import Testing
@testable import Wingcord

/// The welcome's particles: where they gather, and when they swarm between the
/// word and the wings (docs/LOGIN-ONBOARDING.md §6).
@MainActor
@Suite("Welcome particles")
struct WelcomeParticlesTests {

    private func extent(_ targets: [Float]) -> (minX: Float, maxX: Float, minY: Float, maxY: Float) {
        var minX = Float.infinity, maxX = -Float.infinity, minY = Float.infinity, maxY = -Float.infinity
        for index in stride(from: 0, to: targets.count, by: 3) {
            minX = min(minX, targets[index]); maxX = max(maxX, targets[index])
            minY = min(minY, targets[index + 1]); maxY = max(maxY, targets[index + 1])
        }
        return (minX, maxX, minY, maxY)
    }

    @Test("The word is wide and low, inside its own box, centred", arguments: [ParticleLockup.Shape.wordmark])
    func word(shape: ParticleLockup.Shape) {
        let targets = ParticleLockup.targets(shape, count: 4_000)
        #expect(targets.count == 12_000)
        let box = ParticleLockup.box(shape)
        let e = extent(targets)
        let halfWidth = box.aspect * box.halfHeight
        #expect(e.minX >= -halfWidth && e.maxX <= halfWidth)
        #expect(e.minY >= -box.halfHeight && e.maxY <= box.halfHeight)
        // It fills the width far more than the height, and sits on the centre.
        #expect(e.maxX - e.minX > 3 * (e.maxY - e.minY))
        #expect(abs((e.maxX + e.minX) / 2) < 0.05)
    }

    @Test("The wings are about square, inside their box, centred")
    func wings() {
        let targets = ParticleLockup.targets(.wings, count: 4_000, seed: 7)
        let box = ParticleLockup.box(.wings)
        let e = extent(targets)
        #expect(e.minX >= -box.halfHeight && e.maxX <= box.halfHeight)
        #expect(e.minY >= -box.halfHeight && e.maxY <= box.halfHeight)
        let width = e.maxX - e.minX, height = e.maxY - e.minY
        #expect(width / height > 0.8 && width / height < 1.25)
        #expect(abs((e.maxY + e.minY) / 2) < 0.05)
    }

    @Test("Every particle has a place on both: the same count, nothing left at the origin")
    func paired() {
        let word = ParticleLockup.targets(.wordmark, count: 2_000)
        let wings = ParticleLockup.targets(.wings, count: 2_000, seed: 7)
        #expect(word.count == wings.count)
        for index in stride(from: 0, to: word.count, by: 3) {
            #expect(word[index] != 0 || word[index + 1] != 0)
            #expect(wings[index] != 0 || wings[index + 1] != 0)
        }
    }

    @Test("The cycle: the word while it forms and holds, the wings, and back")
    func cycle() {
        let formed = EmberRenderer.lockupFormedAt
        let hold = EmberRenderer.wordHold, swap = EmberRenderer.swapTime, wings = EmberRenderer.wingsHold
        #expect(EmberRenderer.swap(at: 0) == 0)
        #expect(EmberRenderer.swap(at: formed + hold - 0.01) == 0)
        #expect(abs(EmberRenderer.swap(at: formed + hold + swap / 2) - 0.5) < 0.01)
        #expect(EmberRenderer.swap(at: formed + hold + swap + wings / 2) == 1)
        #expect(abs(EmberRenderer.swap(at: formed + hold + swap + wings + swap / 2) - 0.5) < 0.01)
        let cycle = hold + swap + wings + swap
        #expect(EmberRenderer.swap(at: formed + cycle + 0.5) == 0)
    }

    @Test("The gather comes first: no swap before the word has formed")
    func gatherFirst() {
        #expect(EmberRenderer.morph(at: EmberRenderer.scatterHold - 0.1) == 0)
        #expect(EmberRenderer.morph(at: EmberRenderer.lockupFormedAt) == 1)
        #expect(EmberRenderer.swap(at: EmberRenderer.lockupFormedAt) == 0)
    }
}
