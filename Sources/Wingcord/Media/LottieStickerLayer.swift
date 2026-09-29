import AppKit
import Lottie
import QuartzCore
import SwiftUI

/// Makes and fits the layer a Lottie sticker plays in.
///
/// **The automatic engine, which for Discord's stickers is Core Animation.**
/// Every file in `stock stickers.har` is shape layers, precomps and track
/// mattes, all of which that engine turns into `CAAnimation`s once and hands to
/// the render server: 60 fps, vector-sharp at any size, and nothing per frame
/// in this process. The merge paths four of those six files carry and the rig
/// controllers in their effects are drawn by neither Lottie engine — nor by
/// rlottie, which is what Discord plays them with — so nothing is lost against
/// the reference by taking the faster one.
@MainActor
enum LottieStickerLayer {

    static func make(_ animation: LottieAnimation, scale: CGFloat) -> LottieAnimationLayer {
        let layer = LottieAnimationLayer(
            animation: animation,
            configuration: LottieConfiguration(renderingEngine: .automatic)
        )
        layer.loopMode = .loop
        // **Both scales** — `SuperReactionEffects` records why: a bare layer
        // rasterises its vectors at `screenScale`, which starts at 1.
        layer.contentsScale = scale
        layer.screenScale = scale
        // The automatic engine may swap roots once it has inspected the file,
        // and the replacement is laid out afresh.
        layer.animationLayerDidLoad = { layer, _ in fit(layer) }
        return layer
    }

    /// Fits the composition into the layer's bounds, aspect-fit and centred.
    ///
    /// **By hand, because the layer does not** — the fit a
    /// `LottieAnimationView` performs lives in the view.
    static func fit(_ layer: LottieAnimationLayer) {
        guard let root = layer.animationLayer, let animation = layer.animation,
              animation.size.width > 0, animation.size.height > 0
        else { return }
        let bounds = layer.bounds
        let scale = min(
            bounds.width / animation.size.width,
            bounds.height / animation.size.height
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.position = CGPoint(x: bounds.midX, y: bounds.midY)
        root.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }
}

/// A Lottie sticker in a SwiftUI surface.
///
/// Plays while the app is active and Reduce Motion is off, and otherwise holds
/// the frame it is on — Discord's own rule for stickers is "while focused".
struct LottieSticker: NSViewRepresentable {
    var url: URL

    @Environment(\.displayScale) private var displayScale
    @Environment(\.motion) private var motion

    func makeNSView(context: Context) -> LottieStickerView { LottieStickerView() }

    func updateNSView(_ view: LottieStickerView, context: Context) {
        view.configure(url: url, scale: max(displayScale, 1), animates: !motion.reduceMotion)
    }

    static func dismantleNSView(_ view: LottieStickerView, coordinator: ()) {
        view.tearDown()
    }
}

/// The view `LottieSticker` hosts: one layer-backed view holding one
/// `LottieAnimationLayer`.
final class LottieStickerView: NSView {
    private var url: URL?
    private var scale: CGFloat = 2
    private var animates = true
    private var lottie: LottieAnimationLayer?
    private var loadTask: Task<Void, Never>?
    private var activityObservers: [NSObjectProtocol] = []

    /// Flipped, like the transcript the same layer is hosted in: the engine
    /// builds its tree top-down, and AppKit flips a flipped view's backing
    /// layer to match.
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// A picture, not a control: clicks go to whatever it is drawn on.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(url: URL, scale: CGFloat, animates: Bool) {
        self.animates = animates
        if scale != self.scale {
            self.scale = scale
            lottie?.contentsScale = scale
            lottie?.screenScale = scale
        }
        guard url != self.url else {
            updatePlayback()
            return
        }
        self.url = url
        loadTask?.cancel()
        loadTask = nil
        lottie?.removeFromSuperlayer()
        lottie = nil

        // A parse already in hand plays on the frame this appears.
        if let cached = LottieDocuments.shared.cached(url) {
            install(cached)
            return
        }
        loadTask = Task { [weak self] in
            let animation = await LottieDocuments.shared.animation(for: url)
            guard let self, !Task.isCancelled, self.url == url, let animation else { return }
            self.install(animation)
        }
    }

    private func install(_ animation: LottieAnimation) {
        let layer = LottieStickerLayer.make(animation, scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        self.layer?.addSublayer(layer)
        CATransaction.commit()
        LottieStickerLayer.fit(layer)
        lottie = layer
        updatePlayback()
    }

    override func layout() {
        super.layout()
        guard let lottie, lottie.frame != bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lottie.frame = bounds
        CATransaction.commit()
        LottieStickerLayer.fit(lottie)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeActivityObservers()
        } else if activityObservers.isEmpty {
            let center = NotificationCenter.default
            let update: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePlayback() }
            }
            activityObservers = [
                center.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: nil, queue: .main, using: update
                ),
                center.addObserver(
                    forName: NSApplication.didResignActiveNotification,
                    object: nil, queue: .main, using: update
                ),
            ]
        }
        updatePlayback()
    }

    /// Plays while it can be seen and moving is allowed; otherwise holds.
    private func updatePlayback() {
        guard let lottie else { return }
        let plays = animates && window != nil && NSApp.isActive
        if plays {
            if !lottie.isAnimationPlaying { lottie.play() }
        } else if lottie.isAnimationPlaying {
            lottie.pause()
        }
    }

    private func removeActivityObservers() {
        for observer in activityObservers { NotificationCenter.default.removeObserver(observer) }
        activityObservers.removeAll()
    }

    func tearDown() {
        loadTask?.cancel()
        loadTask = nil
        removeActivityObservers()
        lottie?.removeFromSuperlayer()
        lottie = nil
        url = nil
    }
}
