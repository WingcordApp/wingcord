import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// Draws an animated asset by swapping a layer's contents.
///
/// **A frame change here costs one property assignment and nothing else.** The
/// obvious SwiftUI shapes both cost far more: `TimelineView(.animation)` runs
/// its own display link *per view*, which is the one-timer-per-animation problem
/// `AnimationClock` exists to avoid; and driving an `Image` from `@State` runs a
/// full body evaluation, layout and render pass for every frame of every
/// decoration on screen.
///
/// Setting `layer.contents` skips all of it. There is no invalidation, no
/// layout, no redraw — the compositor already has the bitmap and is told to show
/// a different one. That is what makes dozens of these affordable.
///
/// The implicit animation on `contents` is disabled: Core Animation would
/// otherwise cross-fade every frame into the next, which both looks wrong and
/// pays for a blend the asset never asked for.
final class AnimatedLayerView: NSView {
    private var image: AnimatedImage?
    private var shownIndex = -1

    override var isFlipped: Bool { true }

    init(gravity: CALayerContentsGravity) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = gravity
        // Aspect-fill overflows its box by design, so the overflow is cut here
        // rather than by a modifier outside — a clip on the SwiftUI side would
        // clip the representable's frame, not the layer's oversized contents.
        layer?.masksToBounds = true
        // No implicit animation on the one property this view ever changes.
        layer?.actions = ["contents": NSNull()]
        layer?.drawsAsynchronously = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Installs a filmstrip, or clears one.
    ///
    /// Unconditional: the coordinator above only calls this when the asset it is
    /// showing has actually changed, so a guard here would be a second, weaker
    /// copy of a decision already made — and `AnimatedImage` has no identity to
    /// compare on anyway.
    func setImage(_ image: AnimatedImage?) {
        self.image = image
        shownIndex = -1
        if image == nil { layer?.contents = nil }
    }

    /// Shows the frame for `time`. Called from the shared clock.
    ///
    /// **Nothing happens when the frame has not changed**, which is the common
    /// case: the clock runs at up to 24 fps and the assets are authored at 10-20,
    /// so most ticks resolve to the frame already on screen. Assigning it again
    /// would hand Core Animation a new transaction for an identical picture.
    func show(at time: Double) {
        guard let image else { return }
        let index = image.index(at: time)
        guard index != shownIndex else { return }
        shownIndex = index
        layer?.contents = image.frames[index]
    }
}

/// The SwiftUI face of `AnimatedLayerView`.
///
/// Owns the clock subscription and the fetch. Falls back to drawing nothing when
/// the asset turns out to be a still — the caller stacks this over an ordinary
/// `RemoteImage`, so a still decoration is simply the static one showing
/// through.
struct AnimatedDecoration: NSViewRepresentable {
    var url: URL
    /// The side this is drawn at, in points. Decides the decode size.
    var side: CGFloat
    /// How the frames fill their box. A decoration is authored to sit around an
    /// avatar and must not be cropped; a banner is a strip that must fill its
    /// block and be cropped.
    var gravity: CALayerContentsGravity = .resizeAspect
    /// How much decoded film this asset is allowed to hold.
    ///
    /// **The default is sized for a decoration, and a banner is two orders of
    /// magnitude larger per frame.** A 92pt decoration frame is 33 KB, so the
    /// 6 MB default buys every frame the asset has. A guild banner decoded to
    /// cover its column is around a megabyte a frame, so the same budget buys
    /// *three* — and a sixty-frame loop sampled down to three frames is the
    /// whole of "the animated banner runs at almost no frame rate". The number
    /// is not a preference; it is frames, and the caller is the only one that
    /// knows how many pixels a frame will be.
    var byteBudget: Int = AnimatedImage.byteBudget
    /// Whether playback continues through a scroll.
    ///
    /// **Off everywhere it is chrome, on where it is the content.** A decoration
    /// beside a name or a banner behind a list is scenery, and parking it is
    /// what buys the scroll its frames. A GIF in a picker is the thing being
    /// chosen — one that freezes the moment you flick the list reads as the
    /// picker having stalled. See `AnimationClock.subscribe`.
    var animatesThroughScroll = false

    /// Reports whether there are frames on screen.
    ///
    /// A caller that stacks this over a still needs to know when to take the
    /// still away: the two are decoded by different paths at different sizes,
    /// and an asset with a soft or transparent rim shows the still as a second
    /// copy behind the moving one. It fires from the load's completion, never
    /// from `updateNSView` — a state write during an update is an update loop.
    var onPlayback: ((Bool) -> Void)?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.motion) private var motion

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnimatedLayerView {
        let view = AnimatedLayerView(gravity: gravity)
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: AnimatedLayerView, context: Context) {
        context.coordinator.onPlayback = onPlayback
        context.coordinator.animatesThroughScroll = animatesThroughScroll
        context.coordinator.configure(
            url: url,
            pixelSize: Int((side * max(displayScale, 1)).rounded(.up)),
            byteBudget: byteBudget,
            // Reduce Motion parks the asset on its first frame rather than
            // hiding it: the decoration is part of someone's identity, and the
            // preference is about movement, not about artwork.
            isAnimated: !motion.reduceMotion
        )
    }

    static func dismantleNSView(_ view: AnimatedLayerView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {
        weak var view: AnimatedLayerView?
        var onPlayback: ((Bool) -> Void)?
        var animatesThroughScroll = false
        private var key: AnimatedImageStore.Key?
        private var isSubscribed = false
        private var loadTask: Task<Void, Never>?
        private var isAnimated = true
        /// Bumped on every reconfigure and on teardown, so a deferred playback
        /// report belonging to a previous configuration is dropped. See
        /// `report(_:)`.
        private var generation = 0

        private var token: ObjectIdentifier { ObjectIdentifier(self) }

        func configure(url: URL, pixelSize: Int, byteBudget: Int, isAnimated: Bool) {
            let newKey = AnimatedImageStore.Key(
                url: url,
                maximumPixelSize: pixelSize,
                byteBudget: byteBudget
            )
            guard newKey != key || isAnimated != self.isAnimated else { return }
            key = newKey
            self.isAnimated = isAnimated
            generation &+= 1

            loadTask?.cancel()
            loadTask = nil

            // A cached filmstrip is installed with no hop at all, so a row
            // scrolled back into view draws its decoration on the first frame
            // rather than after a placeholder.
            if let hit = AnimatedImageStore.shared.cached(newKey) {
                install(hit)
                return
            }
            if AnimatedImageStore.shared.isKnownStill(newKey) {
                install(nil)
                return
            }
            view?.setImage(nil)
            unsubscribe()
            report(false)

            loadTask = Task { [weak self] in
                let image = await AnimatedImageStore.shared.image(for: newKey)
                guard let self, !Task.isCancelled, self.key == newKey else { return }
                self.install(image)
            }
        }

        private func install(_ image: AnimatedImage?) {
            view?.setImage(image)
            guard let image, isAnimated, image.frameCount > 1 else {
                // A still, or Reduce Motion: show one frame and never subscribe.
                if image != nil { view?.show(at: 0) }
                unsubscribe()
                report(image != nil)
                return
            }
            view?.show(at: AnimationClock.shared.time)
            subscribe()
            report(true)
        }

        /// Tells the caller whether there are frames on screen — **always out of
        /// the current update pass.**
        ///
        /// `configure` runs from `updateNSView`, and two of its three paths —
        /// a cached filmstrip and a known still — call `install` *synchronously*
        /// from there. A callback made on that stack is a `@State` write during
        /// a SwiftUI view update: undefined, and in practice it does not stick.
        ///
        /// **That is the whole of the "second hover draws the still behind the
        /// film" bug.** The first hover misses the cache, so the report comes
        /// from the load's continuation and lands; every hover after it hits the
        /// cache, reports from inside the update, and the write is dropped — so
        /// the still underneath is never taken away and an icon with a soft or
        /// transparent rim shows as two offset copies. The doc comment on
        /// `onPlayback` has always said this fires "never from `updateNSView`";
        /// this is what makes that true.
        ///
        /// **Guarded on the generation, not fired blind.** A report that arrived
        /// after a reconfigure or a teardown would hide the still for a film
        /// that is no longer there, which is an icon that draws nothing at all.
        private func report(_ playing: Bool) {
            let generation = generation
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation, self.view != nil else { return }
                self.onPlayback?(playing)
            }
        }

        private func subscribe() {
            guard !isSubscribed else { return }
            isSubscribed = true
            AnimationClock.shared.subscribe(token, throughScroll: animatesThroughScroll) { [weak self] in
                guard let self, let view = self.view else { return }
                // Every subscriber reads the SAME timestamp, so decorations stay
                // in step instead of each drifting on its own accumulated error.
                view.show(at: AnimationClock.shared.time)
            }
        }

        private func unsubscribe() {
            guard isSubscribed else { return }
            isSubscribed = false
            AnimationClock.shared.unsubscribe(token)
        }

        func tearDown() {
            loadTask?.cancel()
            loadTask = nil
            unsubscribe()
            view = nil
            // Any report still in flight belongs to a view that has gone.
            generation &+= 1
        }

        deinit {
            MainActor.assumeIsolated { tearDown() }
        }
    }
}
