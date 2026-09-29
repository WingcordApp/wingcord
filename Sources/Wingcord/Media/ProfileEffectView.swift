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
/// **Every frame, at the resolution the card draws it** — each layer streams
/// from its own `FilmSource` a few frames ahead (`FilmStream`), which is what
/// makes full fidelity affordable: a 450x880 layer is 1.6 MB a frame, and
/// holding a whole loop of them is what used to force a 512-pixel decode and a
/// frame budget onto effects authored above both.
///
///  1. **A finished layer is released.** An intro can never be needed again
///     once its slot is over, so its stream and its source go the moment it
///     ends. Peak is both layers; steady state is one.
///  2. **One host view, N sublayers, one timeline.** Each layer's frames are
///     picked from the same start, so the intro and the loop cannot drift
///     apart mid-handover.
///
/// The whole thing is inert when Reduce Motion is on: a single still frame from
/// `reducedMotionSrc`, which is what Discord ships that asset for.
struct ProfileEffectView: NSViewRepresentable {
    var effect: ProfileEffect
    /// The card's width in points. Sets the decode size for every layer.
    var width: CGFloat

    @Environment(\.displayScale) private var displayScale
    @Environment(\.motion) private var motion

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
            width: width * max(displayScale, 1),
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
        private var streams: [Int: FilmStream] = [:]
        private var loads: [Int: Task<Void, Never>] = [:]
        /// Layers whose slot is over. A finished intro must not be fetched again.
        private var retired: Set<Int> = []
        private var startTime: Double?
        private var isAnimated = true

        /// - Parameter width: the card's width in pixels, which with each
        ///   layer's own shape decides what it is decoded at.
        func configure(effect: ProfileEffect, width: CGFloat, isAnimated: Bool) {
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
                    let aspect = effect.layers.first.map(ProfileEffectView.aspect(of:)) ?? 1
                    view?.prepare(aspects: [aspect])
                    loadStill(url, pixelSize: Int((width * max(aspect, 1)).rounded(.up)))
                }
                return
            }
            view?.prepare(aspects: effect.layers.map(ProfileEffectView.aspect(of:)))

            startTime = AnimationClock.shared.time
            for (index, layer) in effect.layers.enumerated() {
                // The longest side as the card draws it. A decode never
                // enlarges, so a card wider than the art costs the art's own
                // pixels and no more.
                let aspect = ProfileEffectView.aspect(of: layer)
                let pixelSize = Int((width * max(aspect, 1)).rounded(.up))
                loads[index] = Task { [weak self] in
                    guard let data = try? await ImageStore.shared.data(for: layer.url) else { return }
                    let source = await Task.detached(priority: .userInitiated) {
                        FilmSource(data: data, maximumPixelSize: pixelSize)
                    }.value
                    guard let self, !Task.isCancelled, self.effect?.skuID == effect.skuID,
                          !self.retired.contains(index), let source,
                          let sublayer = self.view?.sublayer(at: index)
                    else { return }
                    let stream = FilmStream(
                        source: source,
                        layer: sublayer,
                        showsFirstFrame: false,
                        // **The catalogue's duration is the SLOT; the asset's
                        // own is the playback.** A layer that does not loop
                        // holds its last frame for the rest of its slot —
                        // SpongeBob's 4125 ms APNG in a 6000 ms slot used to
                        // wrap and perform twice.
                        loops: layer.loops
                    ) { [weak self] in self?.phase(of: index) }
                    self.streams[index] = stream
                    self.loads[index] = nil
                    stream.setPlaying(true)
                }
            }
        }

        /// Where one layer is in its own playback, or nil while it shows
        /// nothing — before its start, between passes, and once its slot is
        /// over, when it is released.
        private func phase(of index: Int) -> Double? {
            guard let effect, let startTime, effect.layers.indices.contains(index) else { return nil }
            let layer = effect.layers[index]
            let elapsed = AnimationClock.shared.time - startTime
            guard !layer.isFinished(at: elapsed) else {
                retire(index)
                return nil
            }
            return layer.phase(at: elapsed)
        }

        /// Gives a finished layer's stream and source back at once.
        private func retire(_ index: Int) {
            guard retired.insert(index).inserted else { return }
            streams.removeValue(forKey: index)?.stop()
            loads.removeValue(forKey: index)?.cancel()
            view?.hide(index)
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

        private func reset() {
            for task in loads.values { task.cancel() }
            loads.removeAll()
            for stream in streams.values { stream.stop() }
            streams.removeAll()
            retired.removeAll()
            startTime = nil
        }

        func tearDown() {
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

    /// One layer's `CALayer`, for a stream to play into.
    func sublayer(at index: Int) -> CALayer? {
        layers.indices.contains(index) ? layers[index] : nil
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
