import AppKit
import MetalKit
import SwiftUI

/// The sign-in screen's living ground: MetalForge's ember wallpaper and, on the
/// welcome, its particles gathering into the wings and the wordmark. See
/// `EmberRenderer`.
///
/// **State goes in through `updateNSView` and nothing comes back out** (INVARIANTS
/// §1, a representable never reports state from there). Where Metal can't be
/// had, the ember's own colours stand in, still.
struct SignInBackdrop: View {
    var stage: EmberRenderer.Stage

    @Environment(\.motion) private var motion

    var body: some View {
        ZStack {
            // Under the Metal view: what shows if it can't start.
            RadialGradient(
                colors: [Color(red: 0.16, green: 0.04, blue: 0.07), Color(red: 0.02, green: 0.008, blue: 0.012)],
                center: .center,
                startRadius: 0,
                endRadius: 900
            )
            BackdropMetalView(stage: stage, reduceMotion: motion.reduceMotion)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct BackdropMetalView: NSViewRepresentable {
    var stage: EmberRenderer.Stage
    var reduceMotion: Bool

    final class Coordinator {
        var renderer: EmberRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> BackdropMTKView {
        let view = BackdropMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = true
        view.setAccessibilityElement(false)
        // MetalForge's colours are sRGB, as its SwiftUI `colorEffect` drew them
        // colour-managed. Untagged, a P3 panel would take them as its own and
        // oversaturate the ember.
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        guard let renderer = EmberRenderer(view: view, stage: stage, reduceMotion: reduceMotion) else {
            // Nothing drawn: the gradient underneath stays the ground.
            view.isPaused = true
            view.layer?.isOpaque = false
            return view
        }
        view.layer?.isOpaque = true
        view.delegate = renderer
        context.coordinator.renderer = renderer
        view.onPointer = { [weak renderer] point in renderer?.pointer(point) }
        view.onVisibility = { [weak renderer] visible in renderer?.isWindowVisible = visible }
        return view
    }

    func updateNSView(_ view: BackdropMTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        renderer.stage = stage
        renderer.reduceMotion = reduceMotion
    }

    static func dismantleNSView(_ view: BackdropMTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        coordinator.renderer = nil
    }
}

/// The Metal view, with the two things it needs from AppKit: the pointer, for
/// the particles to part round, and whether the window can be seen at all.
final class BackdropMTKView: MTKView {
    var onPointer: ((CGPoint) -> Void)?
    var onVisibility: ((Bool) -> Void)?
    private var occlusion: NSObjectProtocol?

    /// Decoration: every click goes to what's drawn over it, or nowhere.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // A tracking area isn't occlusion-tested (INVARIANTS §1), which is what
        // lets the pointer move the particles under the SwiftUI drawn over them.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        onPointer?(CGPoint(x: point.x / bounds.width, y: 1 - point.y / bounds.height))
    }

    /// The observer goes when the view leaves its window — which it always does
    /// before it goes — so nothing needs undoing in `deinit`.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        guard let window else { return }
        onVisibility?(window.occlusionState.contains(.visible))
        occlusion = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                self.onVisibility?(window.occlusionState.contains(.visible))
            }
        }
    }
}
