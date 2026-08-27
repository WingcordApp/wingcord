import CoreGraphics
import Foundation
import OSLog
import Synchronization

/// Fetches and decodes animated assets, and holds a bounded number of them.
///
/// Separate from `ImageStore` because the two hold different things at different
/// scales: a still avatar is one 33 KB bitmap and a filmstrip is up to
/// forty-eight of them. Sharing one budget would let a handful of decorations
/// evict an entire roster's faces, which is the eviction asymmetry
/// `ImageStore`'s own buckets already exist to prevent.
///
/// It shares that store's `URLSession`, so the bytes come off the same
/// connection pool and the same disk cache — a decoration fetched as a still and
/// again as a filmstrip is one download, not two.
nonisolated final class AnimatedImageStore: @unchecked Sendable {
    static let shared = AnimatedImageStore()

    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Animation")

    /// The resident ceiling for decoded filmstrips.
    ///
    /// Sized from the measurement rather than chosen: 33 KB per frame at 92 px,
    /// forty-eight frames at most, so one decoration is at most ~1.6 MB and this
    /// holds roughly a dozen of the largest. A member list shows more decorated
    /// people than that, which is the point — the ones off screen are evicted
    /// and re-decoded when they come back, and re-decoding is 0.65 ms a frame
    /// off the main thread.
    static let budget = 64 * 1024 * 1024

    struct Key: Hashable, Sendable {
        var url: URL
        var maximumPixelSize: Int
        /// The ceiling this strip was sampled to fit.
        ///
        /// Part of the identity, not a parameter beside it: a strip decoded to
        /// fit 6 MB has fewer frames than the same asset decoded to fit 20, so
        /// they are genuinely different answers and must not share a slot.
        var byteBudget: Int = AnimatedImage.byteBudget
    }

    private final class Box: @unchecked Sendable {
        let image: AnimatedImage
        init(_ image: AnimatedImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()
    /// Assets already found to be single-frame. Remembering them is what stops
    /// every still avatar being re-fetched and re-inspected forever by a view
    /// that keeps asking whether it can animate.
    private let stills = Mutex<Set<Key>>([])
    private let inflight = Mutex<[Key: Task<AnimatedImage?, Never>]>([:])
    /// Decoding a filmstrip is dozens of image decodes. Two at a time is enough
    /// to keep a scroll fed without letting a decorated roster start forty.
    private let gate = ConcurrencyGate(limit: 2)

    private init() {
        cache.totalCostLimit = Self.budget
    }

    /// A synchronous, non-isolated peek.
    ///
    /// Synchronous because the draw path needs it: a view that must `await` to
    /// learn its current frame draws a placeholder and re-renders, once per
    /// frame, forever.
    func cached(_ key: Key) -> AnimatedImage? {
        cache.object(forKey: key.cacheKey)?.image
    }

    /// Whether this asset is already known to be a still, so nobody asks again.
    func isKnownStill(_ key: Key) -> Bool {
        stills.withLock { $0.contains(key) }
    }

    /// Fetches and decodes, or returns what is cached.
    ///
    /// Nil means "not animated" — a single-frame asset, or one that could not be
    /// read. Both answers are final for the caller, which then uses the ordinary
    /// still path and never subscribes to the clock.
    func image(for key: Key) async -> AnimatedImage? {
        if let hit = cached(key) { return hit }
        if isKnownStill(key) { return nil }

        let (task, isOwner) = inflight.withLock { table -> (Task<AnimatedImage?, Never>, Bool) in
            if let existing = table[key] { return (existing, false) }
            let created = Task<AnimatedImage?, Never> { [weak self] in
                guard let self else { return nil }
                return await self.load(key)
            }
            table[key] = created
            return (created, true)
        }
        let result = await task.value
        // Cleared by the creator after awaiting, never from inside the task —
        // see `ImageStore.image(for:)` for why the other order permanently
        // caches a failure.
        if isOwner { inflight.withLock { $0[key] = nil } }
        return result
    }

    private func load(_ key: Key) async -> AnimatedImage? {
        await gate.run {
            do {
                let data = try await ImageStore.shared.data(for: key.url)
                // Lottie is the one asset `CGImageSource` cannot open: it is
                // vector JSON, not a container of bitmaps, so it is rasterised
                // into the same filmstrip shape instead. Everything past this
                // point — the cache, the cost, the clock, the draw — is
                // identical for all three kinds.
                let decoded: AnimatedImage?
                if LottieFilmstrip.handles(key.url) {
                    // On the main actor by necessity — see `LottieFilmstrip` —
                    // and time-sliced there so it costs turns rather than
                    // frames.
                    decoded = await LottieFilmstrip.decode(
                        data, maximumPixelSize: key.maximumPixelSize
                    )
                } else {
                    decoded = AnimatedImage.decode(
                        data,
                        maximumPixelSize: key.maximumPixelSize,
                        byteBudget: key.byteBudget
                    )
                }
                guard let decoded else {
                    // Single-frame, and permanently so. Recorded rather than
                    // re-derived: without this every still decoration is
                    // re-downloaded and re-inspected on every appearance.
                    stills.withLock { _ = $0.insert(key) }
                    return nil
                }
                cache.setObject(Box(decoded), forKey: key.cacheKey, cost: decoded.cost)
                return decoded
            } catch {
                Self.log.debug(
                    "animated load failed: \(key.url.absoluteString, privacy: .public)"
                )
                return nil
            }
        }
    }

    /// Drops every filmstrip. Called on real memory pressure — these are the
    /// most expensive and least essential pixels the app holds.
    func purge() {
        cache.removeAllObjects()
        stills.withLock { $0.removeAll(keepingCapacity: false) }
    }

    /// Drops one strip.
    ///
    /// Used by the profile effect player the moment a non-looping layer has
    /// finished: an intro is ~19 MB of decoded frames and can never be needed
    /// again until the card is reopened, so holding it for as long as the loop
    /// runs is the single largest avoidable allocation in the app.
    func evict(_ key: Key) {
        cache.removeObject(forKey: key.cacheKey)
    }
}

extension AnimatedImageStore.Key {
    /// `nonisolated`, because the app target defaults to main-actor isolation
    /// and the decode path that needs this runs off it. Without the annotation
    /// the whole store compiles only by hopping to the main actor to build a
    /// cache key — which is the defect this file exists to avoid.
    nonisolated var cacheKey: NSString {
        "\(maximumPixelSize)|\(byteBudget)|\(url.absoluteString)" as NSString
    }
}
