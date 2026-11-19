import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import WingcordCore

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

    /// Puts a player's layer in this view, filling it.
    func host(_ film: CALayer) {
        hosted?.removeFromSuperlayer()
        hosted = film
        film.frame = bounds
        layer?.addSublayer(film)
    }

    private var hosted: CALayer?

    override func layout() {
        super.layout()
        guard let hosted, hosted.frame != bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted.frame = bounds
        CATransaction.commit()
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

/// A moving picture in a SwiftUI surface — a decoration, a banner, a face, a
/// picker's cell.
///
/// **On a `FilmPlayer`**: every frame, at the asset's own rate and the size it
/// is drawn, played by the render server or streamed a few frames ahead. It
/// used to run a filmstrip sampled to forty-eight frames and a byte budget on a
/// clock capped at twenty-four ticks a second, which is the whole of "the
/// decoration and the banner run at a low frame rate".
///
/// **A WebM is the exception** — a nameplate's moving form. ImageIO cannot read
/// one, so it still plays from the filmstrip `WebMFilmstrip` decodes, on the
/// shared clock, within `byteBudget`.
///
/// Falls back to drawing nothing when the asset turns out to be a still — the
/// caller stacks this over an ordinary `RemoteImage`, so a still decoration is
/// simply the static one showing through.
struct AnimatedDecoration: NSViewRepresentable {
    var url: URL
    /// The side this is drawn at, in points. Decides the decode size.
    var side: CGFloat
    /// How the frames fill their box. A decoration is authored to sit around an
    /// avatar and must not be cropped; a banner is a strip that must fill its
    /// block and be cropped.
    var gravity: CALayerContentsGravity = .resizeAspect
    /// How much decoded film a WebM may hold. Nothing else has a budget: a
    /// picture ImageIO reads plays whole or streams.
    var byteBudget: Int = AnimatedImage.byteBudget

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
        context.coordinator.configure(
            url: url,
            pixelSize: Int((side * max(displayScale, 1)).rounded(.up)),
            byteBudget: byteBudget,
            gravity: gravity,
            // Reduce Motion leaves the still the caller draws underneath: the
            // decoration is part of someone's identity, and the preference is
            // about movement, not about artwork.
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
        private var player: FilmPlayer?
        private var key: AnimatedImageStore.Key?
        private var isSubscribed = false
        private var loadTask: Task<Void, Never>?
        private var isAnimated = true
        /// Bumped on every reconfigure and on teardown, so a deferred playback
        /// report belonging to a previous configuration is dropped. See
        /// `report(_:)`.
        private var generation = 0
        /// The last answer this configuration gave, so it is given once.
        private var reported: Bool?

        private var token: ObjectIdentifier { ObjectIdentifier(self) }

        func configure(
            url: URL, pixelSize: Int, byteBudget: Int,
            gravity: CALayerContentsGravity, isAnimated: Bool
        ) {
            let newKey = AnimatedImageStore.Key(
                url: url,
                maximumPixelSize: pixelSize,
                byteBudget: byteBudget
            )
            guard newKey != key || isAnimated != self.isAnimated else { return }
            key = newKey
            self.isAnimated = isAnimated
            generation &+= 1
            reported = nil

            loadTask?.cancel()
            loadTask = nil
            player?.tearDown()
            player = nil
            view?.setImage(nil)
            unsubscribe()

            guard isAnimated else {
                report(false)
                return
            }
            guard WebMFilmstrip.handles(url) else {
                // Nothing on screen until the player says so: a caller that
                // swapped assets shows its still again meanwhile.
                report(false)
                play(url: url, pixelSize: pixelSize, gravity: gravity)
                return
            }

            // A cached filmstrip is installed with no hop at all, so a row
            // scrolled back into view draws its nameplate on the first frame
            // rather than after a placeholder.
            if let hit = AnimatedImageStore.shared.cached(newKey) {
                install(hit)
                return
            }
            if AnimatedImageStore.shared.isKnownStill(newKey) {
                install(nil)
                return
            }
            report(false)
            loadTask = Task { [weak self] in
                let image = await AnimatedImageStore.shared.image(for: newKey)
                guard let self, !Task.isCancelled, self.key == newKey else { return }
                // Profiles, DM rows and nameplates play through here rather
                // than a hover film (docs/BETA3.md §1.2). Once per asset: the
                // store remembers the stills.
                if image == nil {
                    Log.info(.media, "a moving picture (profile, DM row or nameplate) didn't load, or is a still")
                }
                self.install(image)
            }
        }

        /// A picture ImageIO reads, on its own player.
        private func play(url: URL, pixelSize: Int, gravity: CALayerContentsGravity) {
            guard let view else { return }
            let player = FilmPlayer(key: FilmPlayer.Key(url: url, maximumPixelSize: pixelSize))
            player.layer.contentsGravity = gravity
            let generation = generation
            player.onPlayback = { [weak self] playing in
                guard let self, self.generation == generation else { return }
                self.report(playing)
            }
            view.host(player.layer)
            self.player = player
        }

        /// A WebM's filmstrip, on the shared clock.
        private func install(_ image: AnimatedImage?) {
            view?.setImage(image)
            guard let image, image.frameCount > 1 else {
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
        /// `configure` runs from `updateNSView`, and a cached filmstrip calls
        /// `install` *synchronously* from there. A callback made on that stack
        /// is a `@State` write during a SwiftUI view update: undefined, and in
        /// practice it does not stick — which was the whole of the "second
        /// hover draws the still behind the film" bug.
        ///
        /// **Guarded on the generation, not fired blind.** A report that arrived
        /// after a reconfigure or a teardown would hide the still for a film
        /// that is no longer there, which is an icon that draws nothing at all.
        private func report(_ playing: Bool) {
            let generation = generation
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation, self.view != nil,
                      self.reported != playing
                else { return }
                self.reported = playing
                self.onPlayback?(playing)
            }
        }

        private func subscribe() {
            guard !isSubscribed else { return }
            isSubscribed = true
            AnimationClock.shared.subscribe(token) { [weak self] in
                guard let self, let view = self.view else { return }
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
            player?.tearDown()
            player = nil
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
