import AppKit
import Lottie
import QuartzCore
import WingcordCore

/// Plays super reaction effects over one drawn transcript.
///
/// Discord's `BurstReactionEffectsStore` (module `900210`) and its effect
/// component (`299072`), ported to a canvas. The rules are the store's:
///
///  - **One effect per reaction at a time.** A reaction already playing is
///    not started again, whatever asks.
///  - **A hover never interrupts.** Pointing at a chip that is already playing
///    does nothing.
///  - **A reaction arriving replaces a hover** — somebody's new super reaction
///    is news, and it restarts the effect rather than waiting for the hover's
///    to finish.
///  - **At most five of each trigger at once.** A sixth hover or ambient play
///    is dropped; a sixth arrival takes the place of the oldest arrival, so a
///    channel being flooded shows the newest.
///
/// **The effect is a layer, and the main thread does nothing per frame.** Each
/// plays once on Lottie's Core Animation engine, which hands the whole timeline
/// to the render server, and is removed when it completes — all but StarBlast,
/// whose mirrored strokes that engine cannot express, and which plays on the
/// main thread's engine for its two and a half seconds. What the canvas
/// draws for it is two cheap things: the chip without its emoji, because the
/// effect is the emoji now, and the chip's half-second shake.
@MainActor
final class SuperReactionEffects {

    /// What started an effect. Discord's `HOVER`, `EXTERNAL` and `RANDOM`.
    enum Trigger {
        /// The pointer moved onto the chip.
        case hover
        /// A super reaction arrived — somebody else's, or the echo of the
        /// reader's own.
        case arrival
        /// The chip's own ambient roll. See `TimelineCanvasView`'s ambient
        /// timer.
        case ambient
    }

    struct Key: Hashable {
        var messageID: MessageID
        var emoji: ReactionEmojiKey
    }

    /// Everything needed to start one, resolved by the canvas at the moment of
    /// asking.
    struct Request {
        var key: Key
        var emoji: EmojiRef
        var channelID: ChannelID
        var accent: UInt32
    }

    private final class Effect {
        let trigger: Trigger
        var layer: LottieAnimationLayer?
        /// The clock time the layer went on screen — the chip's shake runs from
        /// here, and until it is set the chip is untouched.
        var shownAt: Double?
        var loading: Task<Void, Never>?

        init(trigger: Trigger) { self.trigger = trigger }
    }

    /// Every effect asked for and not yet finished, in the order asked.
    private var effects: [Key: Effect] = [:]
    private var order: [Key] = []

    /// The canvas: its layer is where effects are added, and it is asked where
    /// a chip is at the moment one is ready — never before, because a row can
    /// move while the artwork loads.
    private unowned let host: NSView
    /// Where an effect for `key` belongs right now — the centre of the chip's
    /// emoji, in the host's coordinates — or nil when the chip is gone.
    var locate: (Key) -> CGPoint? = { _ in nil }
    /// Called when a chip's effect appears or goes, so the chip can hide its
    /// emoji, shake, and show it again.
    var onChange: (Key) -> Void = { _ in }

    init(host: NSView) {
        self.host = host
    }

    // MARK: Asking

    /// Starts an effect, if the store's rules allow it.
    func play(_ request: Request, trigger: Trigger) {
        let key = request.key
        if let existing = effects[key] {
            // A hover never interrupts, and only an arrival replaces anything —
            // and only a hover that is already on screen.
            guard trigger == .arrival, existing.trigger == .hover, existing.layer != nil
            else { return }
            finish(key)
        }
        let running = order.filter { effects[$0]?.trigger == trigger }
        if running.count >= Self.limit {
            guard trigger == .arrival, let oldest = running.first else { return }
            finish(oldest)
        }

        let effect = Effect(trigger: trigger)
        effects[key] = effect
        order.append(key)
        let scale = host.window?.backingScaleFactor ?? 2
        let index = SuperReactionEffect.index(
            channelID: request.channelID,
            messageID: key.messageID,
            emojiName: request.emoji.name
        )
        effect.loading = Task { [weak self] in
            guard let picture = await SuperReactionArt.emojiImage(
                      request.emoji, side: SuperReactionArt.effectSide, scale: scale
                  ),
                  let animation = await SuperReactionArt.animation(
                      index: index,
                      accent: request.accent,
                      pictureWidth: picture.width,
                      pictureHeight: picture.height
                  )
            else {
                self?.finish(key, only: effect)
                return
            }
            guard let self, !Task.isCancelled, effects[key] === effect else { return }
            show(effect, key: key, animation: animation, picture: picture, scale: scale)
        }
    }

    /// Discord's cap: five of one trigger in a channel at once.
    private static let limit = 5

    // MARK: Showing

    private func show(
        _ effect: Effect,
        key: Key,
        animation: LottieAnimation,
        picture: CGImage,
        scale: CGFloat
    ) {
        effect.loading = nil
        guard let hostLayer = host.layer, let center = locate(key) else {
            finish(key, only: effect)
            return
        }
        let layer = LottieAnimationLayer(
            animation: animation,
            imageProvider: SuperReactionImageProvider(image: picture),
            // Automatic: the Core Animation engine, falling back to the main
            // thread's only for an effect that uses something the first cannot
            // render. Seventeen of the eighteen play on the first; StarBlast's
            // mirrored sparks send it to the second — `SuperReactionEffectTests`
            // pins both halves of that.
            configuration: LottieConfiguration(renderingEngine: .automatic)
        )
        layer.loopMode = .playOnce
        // **Both scales, because they are two different things.** The layer's
        // own `contentsScale` is its backing; `screenScale` is what Lottie
        // rasterises its vector layers at, and a bare layer starts it at 1 —
        // a `LottieAnimationView` sets it from its window, and nothing else
        // does. Left alone, every effect draws at half resolution on Retina.
        layer.contentsScale = scale
        layer.screenScale = scale
        // Discord's box clips: `overflow: hidden` on a square 7.5 times the
        // emoji, centred on it.
        layer.masksToBounds = true
        layer.zPosition = 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = Self.box(around: center)
        Self.fit(layer)
        // The engine can be swapped once the file has been inspected — the
        // automatic fallback — and the replacement root is laid out afresh.
        layer.animationLayerDidLoad = { layer, _ in Self.fit(layer) }
        hostLayer.addSublayer(layer)
        CATransaction.commit()

        effect.layer = layer
        effect.shownAt = AnimationClock.shared.time
        onChange(key)
        // **Its own effect, not whatever holds the key by then.** An arrival
        // that replaces a hover removes the hover's layer, and a layer taken off
        // screen still reports its animation stopped — which, unguarded, would
        // end the arrival that just replaced it.
        layer.play { [weak self, weak effect] _ in
            guard let effect else { return }
            self?.finish(key, only: effect)
        }
    }

    /// The square an effect plays in, centred on the chip's emoji. Discord's
    /// is 7.5 times its 20-pixel emoji; this is 7.5 times this chip's.
    static func box(around center: CGPoint) -> CGRect {
        let side = SuperReactionEffect.boxToEmoji * TimelineMetrics.reactionGlyphSide
        return CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    /// Scales the animation's 300-unit composition into the layer's box.
    ///
    /// **By hand, because the layer does not.** The aspect fit a
    /// `LottieAnimationView` performs lives in the view — `layoutAnimation` —
    /// and a bare layer leaves its root at the composition's own size,
    /// anchored wherever the engine put it.
    private static func fit(_ layer: LottieAnimationLayer) {
        guard let root = layer.animationLayer, let animation = layer.animation,
              animation.size.width > 0
        else { return }
        let bounds = layer.bounds
        root.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let scale = bounds.width / animation.size.width
        root.transform = CATransform3DMakeScale(scale, scale, 1)
    }

    // MARK: Following the rows

    /// When a playing reaction's chip appeared, or nil while none is showing.
    func shownAt(_ key: Key) -> Double? {
        effects[key]?.shownAt
    }

    /// This message's reactions with an effect on screen.
    func showing(on messageID: MessageID) -> [ReactionEmojiKey: Double] {
        var result: [ReactionEmojiKey: Double] = [:]
        for (key, effect) in effects where key.messageID == messageID {
            if let shownAt = effect.shownAt { result[key.emoji] = shownAt }
        }
        return result
    }

    /// Whether any chip is in its shake at `time` — the canvas keeps its clock
    /// subscription for exactly as long as one is.
    func isShaking(at time: Double) -> Bool {
        effects.values.contains { effect in
            guard let shownAt = effect.shownAt else { return false }
            return time - shownAt < SuperReactionShake.duration
        }
    }

    /// The chips shaking at `time`.
    func shaking(at time: Double) -> [Key] {
        effects.compactMap { key, effect in
            guard let shownAt = effect.shownAt, time - shownAt < SuperReactionShake.duration
            else { return nil }
            return key
        }
    }

    var isEmpty: Bool { effects.isEmpty }

    /// Puts every playing effect back over its chip after the rows moved, and
    /// ends any whose chip is gone.
    func follow() {
        guard !effects.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for key in order {
            guard let layer = effects[key]?.layer else { continue }
            if let center = locate(key) {
                let box = Self.box(around: center)
                if layer.frame != box { layer.frame = box }
            } else {
                finish(key)
            }
        }
        CATransaction.commit()
    }

    /// Ends every effect. The canvas is leaving its window, or showing a
    /// different channel.
    func stopAll() {
        for key in order { finish(key) }
    }

    /// Ends the effect for `key` — or, given `only`, ends it only if it is
    /// still that effect.
    private func finish(_ key: Key, only expected: Effect? = nil) {
        if let expected, effects[key] !== expected { return }
        guard let effect = effects.removeValue(forKey: key) else { return }
        order.removeAll { $0 == key }
        effect.loading?.cancel()
        if let layer = effect.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeFromSuperlayer()
            CATransaction.commit()
        }
        if effect.shownAt != nil { onChange(key) }
    }
}

/// Where a super reaction arriving live is announced to whatever is drawing
/// the message it landed on.
///
/// **A broadcast rather than store state.** An arrival is an event, not a
/// value: nothing should re-evaluate because of it, and a property the
/// transcript's container observed would invalidate the container for a
/// reaction on a message it may not even have loaded. Each drawn transcript
/// subscribes while it is in a window and decides for itself whether the
/// message is one of its rows.
@MainActor
final class SuperReactionStage {
    static let shared = SuperReactionStage()

    private var listeners: [ObjectIdentifier: (MessageID, EmojiRef) -> Void] = [:]

    func subscribe(_ token: ObjectIdentifier, _ listener: @escaping (MessageID, EmojiRef) -> Void) {
        listeners[token] = listener
    }

    func unsubscribe(_ token: ObjectIdentifier) {
        listeners[token] = nil
    }

    /// A super reaction landed. Discord plays its effect only for one that is
    /// not the reader's own optimistic write — the echo of that write is what
    /// plays it — and only with animated emoji on and Reduce Motion off.
    func arrived(_ emoji: EmojiRef, on messageID: MessageID) {
        guard AnimationClock.playsAnimatedEmoji else { return }
        for listener in listeners.values { listener(messageID, emoji) }
    }
}
