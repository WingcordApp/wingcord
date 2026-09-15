import CoreGraphics
import Foundation
import Testing
@testable import WingcordCore

/// The overlay's widget arithmetic.
///
/// All of it exists so a layout survives the thing a Mac overlay does that a
/// Windows one rarely has to: the game moving to a different display, mid
/// session, at a different size.
@Suite("Overlay layout")
struct OverlayLayoutTests {

    private let hd = CGSize(width: 1920, height: 1080)
    private let retina = CGSize(width: 3456, height: 2234)
    private let toolbar = CGSize(width: 340, height: 48)

    // MARK: Normalisation

    @Test("A centred widget stays centred on a completely different display")
    func centredSurvivesResolution() {
        let layout = OverlayLayout.default
        let onHD = layout.frame(for: .quickActions, size: toolbar, in: hd)
        let onRetina = layout.frame(for: .quickActions, size: toolbar, in: retina)
        #expect(abs(onHD.midX - hd.width / 2) < 0.5)
        #expect(abs(onRetina.midX - retina.width / 2) < 0.5)
    }

    @Test("A widget keeps its point size, because a toolbar is sized for the pointer")
    func sizeDoesNotScale() {
        // The deliberate difference from Discord's stored size. A normalised
        // rect would make this toolbar 612 points wide on the retina display.
        let layout = OverlayLayout.default
        #expect(layout.frame(for: .quickActions, size: toolbar, in: hd).size == toolbar)
        #expect(layout.frame(for: .quickActions, size: toolbar, in: retina).size == toolbar)
    }

    @Test("A widget hard against an edge stays hard against that edge")
    func edgeIsPreserved() {
        var layout = OverlayLayout.default
        layout.move(.voice, to: CGPoint(x: 1, y: 0.5))
        for surface in [hd, retina, CGSize(width: 800, height: 600)] {
            let frame = layout.frame(for: .voice, size: toolbar, in: surface)
            #expect(abs(frame.maxX - surface.width) < 0.5, "surface \(surface)")
        }
    }

    // MARK: Staying reachable

    @Test("A widget is never allowed to hang off the surface")
    func staysWhole() {
        var layout = OverlayLayout.default
        layout.move(.voice, to: CGPoint(x: 1, y: 1))
        let frame = layout.frame(for: .voice, size: toolbar, in: hd)
        // A widget you cannot reach is a widget you cannot drag back.
        #expect(frame.minX >= -0.5)
        #expect(frame.minY >= -0.5)
        #expect(frame.maxX <= hd.width + 0.5)
        #expect(frame.maxY <= hd.height + 0.5)
    }

    @Test("A centre is clamped on the way IN, not on the way out")
    func clampedOnWrite() {
        // Storing 1.4 and correcting it at draw time means the *stored* layout
        // is wrong, and the next resolution change resolves from the wrong
        // number.
        var layout = OverlayLayout.default
        layout.move(.voice, to: CGPoint(x: 1.4, y: -0.3))
        #expect(layout.placement(for: .voice).centre == CGPoint(x: 1, y: 0))
    }

    @Test("A widget wider than the surface is pinned rather than centred off both edges")
    func oversizedWidget() {
        let tiny = CGSize(width: 200, height: 200)
        let layout = OverlayLayout.default
        let frame = layout.frame(for: .voice, size: CGSize(width: 400, height: 50), in: tiny)
        #expect(frame.width == 400)
        // It overflows — it must — but symmetrically, so the middle of it is
        // still the middle of the screen rather than a corner.
        #expect(abs(frame.midX - tiny.width / 2) < 0.5)
    }

    @Test("Normalising and resolving round-trip")
    func roundTrip() {
        let point = CGPoint(x: 640, y: 360)
        let normalised = OverlayLayout.normalised(point, in: hd)
        var layout = OverlayLayout.default
        layout.move(.voice, to: normalised)
        let frame = layout.frame(for: .voice, size: toolbar, in: hd)
        #expect(abs(frame.midX - point.x) < 0.5)
        #expect(abs(frame.midY - point.y) < 0.5)
    }

    @Test("A zero-sized surface normalises to the origin rather than dividing by nothing")
    func zeroSurface() {
        #expect(OverlayLayout.normalised(CGPoint(x: 10, y: 10), in: .zero) == .zero)
    }

    // MARK: What is drawn

    @Test("A locked overlay draws only what is pinned")
    func lockedDrawsPinnedOnly() {
        // The one rule the whole locked state is built on.
        let layout = OverlayLayout.default
        let locked = layout.visibleWidgets(locked: true)
        let unlocked = layout.visibleWidgets(locked: false)
        #expect(locked.allSatisfy { layout.placement(for: $0).isPinned })
        #expect(!locked.contains(.quickActions))
        #expect(unlocked.contains(.quickActions))
        #expect(unlocked.count > locked.count)
    }

    @Test("A widget switched off is drawn in neither state")
    func disabledIsGone() {
        var layout = OverlayLayout.default
        layout.setEnabled(false, for: .voice)
        #expect(!layout.visibleWidgets(locked: true).contains(.voice))
        #expect(!layout.visibleWidgets(locked: false).contains(.voice))
    }

    @Test("Pinning a widget puts it in the locked state and leaves the rest alone")
    func pinning() {
        var layout = OverlayLayout.default
        layout.setPinned(true, for: .quickActions)
        #expect(layout.visibleWidgets(locked: true).contains(.quickActions))
        #expect(layout.placement(for: .voice).isPinned)
    }

    @Test("The order is stable, because a widget that reorders itself flickers")
    func stableOrder() {
        var layout = OverlayLayout.default
        layout.move(.notifications, to: CGPoint(x: 0.9, y: 0.9))
        #expect(layout.visibleWidgets(locked: false) == OverlayWidgetKind.allCases)
    }

    // MARK: Persistence

    @Test("A layout round-trips through Codable, because it is written to defaults")
    func codable() throws {
        var layout = OverlayLayout.default
        layout.move(.voice, to: CGPoint(x: 0.25, y: 0.75))
        layout.setPinned(false, for: .notifications)
        let data = try JSONEncoder().encode(layout)
        let restored = try JSONDecoder().decode(OverlayLayout.self, from: data)
        #expect(restored == layout)
        #expect(restored.placement(for: .voice).centre == CGPoint(x: 0.25, y: 0.75))
    }

    @Test("A widget missing from a stored layout falls back to its own default")
    func missingWidgetFallsBack() {
        // A new widget added in a later version finds nothing in the reader's
        // stored layout, and must not land at (0,0).
        let sparse = OverlayLayout(placements: [:])
        #expect(sparse.placement(for: .voice).centre == OverlayWidgetKind.voice.defaultCentre)
        #expect(sparse.visibleWidgets(locked: false) == OverlayWidgetKind.allCases)
    }
}
