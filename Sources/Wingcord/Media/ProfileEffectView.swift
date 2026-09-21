import AppKit
import Foundation
import QuartzCore
import SwiftUI
import WingcordCore

/// Plays a profile effect over a profile card.
///
/// **The composition is a timeline, not a picture.** Captured from Discord's
/// own catalogue: Kawaii Clouds is an intro that plays once over three seconds
/// followed by a loop that runs forever, each 36 frames at 12 fps, each authored
/// at 450x880 with alpha, stacked by `zIndex` above the card.
///
/// Two properties make it affordable, and both come straight out of that
/// timeline:
///
///  1. **A finished layer is released.** The intro is ~19 MB of decoded frames
///     and can never be needed again once its three seconds are up, so it is
///     evicted the moment it ends rather than held for as long as the card is
///     open. Peak is both layers; steady state is one.
///  2. **One host view, one clock subscription, N sublayers.** Each layer is a
///     `CALayer` whose `contents` is swapped — no SwiftUI invalidation, no
///     layout, no redraw — and all of them advance from the same timestamp, so
///     the intro and the loop cannot drift apart mid-handover.
///
/// The whole thing is inert when Reduce Motion is on: a single still frame from
/// `reducedMotionSrc`, which is what Discord ships that asset for.
struct ProfileEffectView: NSViewRepresentable {
    var effect: ProfileEffect
    /// The card's width in points. Sets the decode size for every layer.
    var width: CGFloat

    @Environment(\.displayScale) private var displayScale
    @Environment(\.motion) private var motion

    /// What one layer is decoded to.
    ///
    /// Deliberately below the card's retina size. The source is 450x880, so a
    /// 2x card would ask for an upscale it cannot benefit from, and each frame
    /// at that size is 837 KB — 30 MB for one 36-frame layer. At this cap a
    /// layer keeps every frame and its full 12 fps inside ~19 MB, which for
    /// drifting clouds and sparkles is the right side of the trade.
    private var pixelSize: Int { 512 }
    private var layerBudget: Int { 20 * 1024 * 1024 }

    /// A layer's authored height over its authored width.
    ///
    /// Kept per layer rather than assumed once for the composition: the
    /// catalogue sends a size with every layer, and a composition whose layers
    /// disagree would otherwise have one of them silently stretched to the
    /// other's shape.
    fileprivate static func aspect(of layer: ProfileEffect.Layer) -> CGFloat {
        guard layer.size.width > 0, layer.size.height > 0 else { return 1 }
        return layer.size.height / layer.size.width
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> EffectHostView {
        let view = EffectHostView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: EffectHostView, context: Context) {
        context.coordinator.configure(
            effect: effect,
            pixelSize: pixelSize,
            budget: layerBudget,
            isAnimated: !motion.reduceMotion
        )
    }

    static func dismantleNSView(_ view: EffectHostView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {
        weak var view: EffectHostView?
        private var effect: ProfileEffect?
        private var strips: [Int: AnimatedImage] = [:]
        private var keys: [Int: AnimatedImageStore.Key] = [:]
        /// Layers already released. A finished intro must not be re-fetched by
        /// the next tick.
        private var retired: Set<Int> = []
        private var loads: [Int: Task<Void, Never>] = [:]
        private var startTime: Double?
        private var isSubscribed = false
        private var isAnimated = true

        private var token: ObjectIdentifier { ObjectIdentifier(self) }

        func configure(
            effect: ProfileEffect,
            pixelSize: Int,
            budget: Int,
            isAnimated: Bool
        ) {
            guard self.effect?.skuID != effect.skuID || self.isAnimated != isAnimated else {
                return
            }
            reset()
            self.effect = effect
            self.isAnimated = isAnimated

            guard isAnimated else {
                // Reduce Motion: one still, no clock, no strips. It is the same
                // composition flattened, so it takes the composition's aspect.
                if let url = effect.reducedMotionURL {
                    let aspect = effect.layers.first.map(ProfileEffectView.aspect(of:))
                    view?.prepare(aspects: [aspect ?? 1])
                    loadStill(url, pixelSize: pixelSize)
                }
                return
            }
            view?.prepare(aspects: effect.layers.map(ProfileEffectView.aspect(of:)))

            startTime = AnimationClock.shared.time
            for (index, layer) in effect.layers.enumerated() {
                let key = AnimatedImageStore.Key(
                    url: layer.url,
                    maximumPixelSize: pixelSize,
                    byteBudget: budget
                )
                keys[index] = key
                if let hit = AnimatedImageStore.shared.cached(key) {
                    strips[index] = hit
                    continue
                }
                loads[index] = Task { [weak self] in
                    let image = await AnimatedImageStore.shared.image(for: key)
                    guard let self, !Task.isCancelled, self.effect?.skuID == effect.skuID
                    else { return }
                    if let image { self.strips[index] = image }
                    self.loads[index] = nil
                }
            }
            subscribe()
        }

        private func loadStill(_ url: URL, pixelSize: Int) {
            let key = ImageStore.Key(url: url, maximumPixelSize: pixelSize)
            if let hit = ImageStore.shared.cached(key, bucket: .artwork) {
                view?.show(hit, at: 0)
                return
            }
            loads[0] = Task { [weak self] in
                let image = await ImageStore.shared.image(for: key, bucket: .artwork)
                guard let self, !Task.isCancelled, let image else { return }
                self.view?.show(image, at: 0)
            }
        }

        private func tick() {
            guard let effect, let startTime, let view else { return }
            let elapsed = AnimationClock.shared.time - startTime

            for (index, layer) in effect.layers.enumerated() {
                guard !retired.contains(index) else { continue }

                // A non-looping layer that has run its course is released here
                // and never asked for again. This is where the intro's ~19 MB
                // goes back.
                if layer.isFinished(at: elapsed) {
                    retired.insert(index)
                    strips[index] = nil
                    loads[index]?.cancel()
                    loads[index] = nil
                    if let key = keys[index] { AnimatedImageStore.shared.evict(key) }
                    view.hide(index)
                    continue
                }

                guard let phase = layer.phase(at: elapsed), let strip = strips[index] else {
                    view.hide(index)
                    continue
                }
                // **The catalogue's duration is the SLOT; the asset's own is the
                // playback.** They are not the same number and treating them as
                // one is what made SpongeBob perform twice: his entry is a
                // 6000 ms slot holding a 4125 ms APNG, so the looping lookup
                // wrapped at 4.125 s and replayed the opening 1.875 s before the
                // slot expired. A layer that does not loop holds its last frame
                // for the rest of its slot instead, which is what `num_plays: 1`
                // means and what a browser does with the same file.
                view.show(strip.frame(at: phase, looping: layer.loops), at: index)
            }

            // Nothing left that can ever draw again: stop the clock work.
            if retired.count == effect.layers.count { unsubscribe() }
        }

        private func subscribe() {
            guard !isSubscribed else { return }
            isSubscribed = true
            AnimationClock.shared.subscribe(token) { [weak self] in self?.tick() }
        }

        private func unsubscribe() {
            guard isSubscribed else { return }
            isSubscribed = false
            AnimationClock.shared.unsubscribe(token)
        }

        private func reset() {
            for task in loads.values { task.cancel() }
            loads.removeAll()
            strips.removeAll()
            keys.removeAll()
            retired.removeAll()
            startTime = nil
            unsubscribe()
        }

        func tearDown() {
            // The strips are the largest allocation the app makes. A card that
            // closes must give them back immediately rather than waiting for the
            // cache to feel pressure.
            for key in keys.values { AnimatedImageStore.shared.evict(key) }
            reset()
            view = nil
        }

        deinit { MainActor.assumeIsolated { tearDown() } }
    }
}

/// Hosts one `CALayer` per effect layer, in paint order.
///
/// **Each layer is laid out at the composition's own shape, anchored to the top
/// of the card, and the card clips whatever runs past its foot.**
///
/// The obvious arrangement — one layer filling the card, aspect-filled — is
/// wrong in a way that only shows on real cards. The compositions are authored
/// 450x880, a shape no profile card has: on a 320x410 card, filling scales the
/// art by the *height* and then crops 108pt off each side, which is precisely
/// where these compositions put the things that identify them. Kawaii Clouds
/// lost both chains and the corner clouds that way, leaving only the sparkles
/// in the middle — an effect that looked like a different, cheaper effect.
///
/// Anchoring instead means the top of the composition and the top of the card
/// are the same line, which is the relationship the artwork was drawn for: the
/// dense half sits over the banner and the name, and a short card simply shows
/// less of the quiet half. Nothing is ever cropped horizontally.
final class EffectHostView: NSView {
    private var layers: [CALayer] = []
    /// Authored height over authored width, per layer, in paint order.
    private var aspects: [CGFloat] = []

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Never takes a click. The effect sits above the card's controls and must
    /// not swallow their input.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func prepare(aspects: [CGFloat]) {
        guard aspects != self.aspects else { return }
        let countChanged = aspects.count != layers.count
        self.aspects = aspects
        if countChanged {
            layers.forEach { $0.removeFromSuperlayer() }
            layers = aspects.map { _ in
                let sublayer = CALayer()
                // The frame already carries the authored shape, so the contents
                // fill it exactly: `.resize` neither crops nor letterboxes.
                sublayer.contentsGravity = .resize
                // No implicit animation on the one property that ever changes;
                // Core Animation would otherwise cross-fade every frame.
                sublayer.actions = ["contents": NSNull(), "hidden": NSNull()]
                layer?.addSublayer(sublayer)
                return sublayer
            }
        }
        needsLayout = true
    }

    func show(_ image: CGImage, at index: Int) {
        guard layers.indices.contains(index) else { return }
        let sublayer = layers[index]
        if sublayer.isHidden { sublayer.isHidden = false }
        sublayer.contents = image
    }

    func hide(_ index: Int) {
        guard layers.indices.contains(index), !layers[index].isHidden else { return }
        layers[index].isHidden = true
    }

    override func layout() {
        super.layout()
        // Sublayers are positioned by the host rather than by constraints — a
        // layout pass touching N constraint sets per frame would undo the point
        // of driving this at the layer level — and this runs on resize only,
        // never on a frame swap.
        let width = bounds.width
        guard width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, sublayer) in layers.enumerated() {
            let aspect = index < aspects.count ? aspects[index] : 1
            sublayer.frame = CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: width,
                height: (width * aspect).rounded()
            )
        }
        CATransaction.commit()
    }
}

/// What a profile effect does when the pointer is over the card.
///
/// **Discord's own numbers, off its stylesheet.** `.profileEffects` carries
/// `transition: opacity .6s ease-in-out`, and the class it gains on hover —
/// `.hovered` — is exactly `opacity: .35`.
///
/// The reason is legibility rather than decoration: these compositions are
/// authored over the banner and the name, and at full strength a busy one sits
/// on top of the text somebody opened the card to read. Stepping back under the
/// pointer hands the content back without taking the effect away.
///
/// Stated once, because both profile surfaces do it and two copies of `0.35`
/// are two places for it to drift.
enum ProfileEffectFade {
    static let hovered: Double = 0.35
    static let duration: Double = 0.6
    static var animation: Animation { .easeInOut(duration: duration) }
}
