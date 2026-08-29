import CoreGraphics
import Foundation

/// A profile effect: the layered animation drawn over someone's profile card.
///
/// **Captured from a live response, not inferred.** `user_profile.profile_effect`
/// carries a `sku_id` — not an asset id — and the artwork is resolved through
/// `GET /collectibles-products/{sku}`. That response describes a *timeline* of
/// layers rather than one picture, which is the fact the whole playback rests
/// on: Kawaii Clouds is an intro that plays once over three seconds, followed by
/// a loop that runs forever, each 36 frames at 12 fps.
public struct ProfileEffect: Hashable, Sendable {
    public var skuID: String
    public var title: String
    /// What the effect looks like, in words. The accessibility label, and the
    /// only description a reader who cannot see it will ever get.
    public var accessibilityLabel: String?
    /// A single still. Used when Reduce Motion is on.
    public var reducedMotionURL: URL?
    public var layers: [Layer]

    public init(
        skuID: String,
        title: String,
        accessibilityLabel: String?,
        reducedMotionURL: URL?,
        layers: [Layer]
    ) {
        self.skuID = skuID
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.reducedMotionURL = reducedMotionURL
        self.layers = layers.sorted { $0.zIndex < $1.zIndex }
    }

    /// One layer of the composition.
    public struct Layer: Hashable, Sendable {
        public var url: URL
        /// When this layer begins, in seconds from the card opening.
        public var start: Double
        /// How long one pass takes, in seconds.
        public var duration: Double
        /// Whether it repeats after that pass.
        public var loops: Bool
        /// The gap between one pass and the next, in seconds.
        ///
        /// **Zero for most effects and emphatically not for all of them.**
        /// Nevermore (White) sends `duration: 3000` with `loopDelay: 4000`, so
        /// its birds cross the card every seven seconds; a player that ignores
        /// this runs them every three and turns an occasional flight into
        /// constant traffic over somebody's name.
        public var loopDelay: Double
        /// Paint order. Discord numbers these from 100 up, above the card.
        public var zIndex: Int
        /// The authored size, which sets the aspect the layer is drawn at.
        public var size: CGSize

        public init(
            url: URL,
            start: Double,
            duration: Double,
            loops: Bool,
            loopDelay: Double = 0,
            zIndex: Int,
            size: CGSize
        ) {
            self.url = url
            self.start = start
            self.duration = duration
            self.loops = loops
            self.loopDelay = loopDelay
            self.zIndex = zIndex
            self.size = size
        }

        /// Whether this layer is showing at `time`, and where in its own
        /// playback it is.
        ///
        /// **A non-looping layer stops existing after its pass**, which is what
        /// makes the whole effect affordable: the intro is 36 frames at 450x880
        /// — about 15 MB decoded — and it is never needed again after its three
        /// seconds are up. Knowing that lets the player release it rather than
        /// hold two full strips for as long as the card is open.
        public func phase(at time: Double) -> Double? {
            let local = time - start
            guard local >= 0 else { return nil }
            guard duration > 0 else { return 0 }
            if loops {
                // One cycle is the pass plus the gap after it, and a layer
                // sitting in that gap shows NOTHING rather than freezing on its
                // last frame — which is the difference between birds that fly
                // past every seven seconds and a bird parked over a name.
                let cycle = duration + max(loopDelay, 0)
                let position = local.truncatingRemainder(dividingBy: cycle)
                return position < duration ? position : nil
            }
            return local < duration ? local : nil
        }

        /// Whether this layer can never show again at or after `time`.
        public func isFinished(at time: Double) -> Bool {
            !loops && time >= start + duration
        }
    }

    /// Whether anything is still to come at `time` — false once every
    /// non-looping layer has finished and there are no looping ones.
    public var loopsForever: Bool { layers.contains { $0.loops } }
}
