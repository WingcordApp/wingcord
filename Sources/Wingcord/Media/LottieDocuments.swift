import Foundation
import Lottie
import Synchronization

/// Lottie documents, fetched and parsed once and shared by everything that
/// plays one.
///
/// **Parsed off the main actor, played on the render server.** Turning the
/// JSON into a model is ordinary `Codable` work and runs detached. What plays
/// the model is a `LottieAnimationLayer` on the Core Animation engine — see
/// `LottieStickerLayer` — which builds its `CAAnimation`s once and hands them to
/// the render server, so a sticker costs this process nothing per frame, at the
/// file's own 60 fps and sharp at any size.
///
/// Keyed by URL alone, because a vector document has no pixel size: the same
/// parse serves a 48-point card and a 160-point message.
nonisolated final class LottieDocuments: @unchecked Sendable {
    static let shared = LottieDocuments()

    private final class Box: Sendable {
        let animation: LottieAnimation
        init(_ animation: LottieAnimation) { self.animation = animation }
    }

    /// Parsed documents. A stock sticker is 70–350 KB of JSON and its model is
    /// a small multiple of that, so the cost is charged at three times the
    /// bytes and the ceiling holds a screenful of distinct stickers with room
    /// to spare.
    private let cache: NSCache<NSURL, Box> = {
        let cache = NSCache<NSURL, Box>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private let inflight = Mutex<[URL: Task<LottieAnimation?, Never>]>([:])
    /// Documents the server has answered 4xx for, so a missing one is asked
    /// about once rather than on every appearance.
    private let refused = Mutex<Set<URL>>([])

    private init() {}

    /// A synchronous peek, so a sticker scrolled back into view plays on the
    /// frame it appears rather than after a hop.
    func cached(_ url: URL) -> LottieAnimation? {
        cache.object(forKey: url as NSURL)?.animation
    }

    /// Fetches and parses, or returns what is cached. Nil for a document that
    /// could not be fetched or is not a Lottie animation.
    func animation(for url: URL) async -> LottieAnimation? {
        if let hit = cached(url) { return hit }
        if refused.withLock({ $0.contains(url) }) { return nil }

        let (task, isOwner) = inflight.withLock { table -> (Task<LottieAnimation?, Never>, Bool) in
            if let existing = table[url] { return (existing, false) }
            let created = Task<LottieAnimation?, Never> { [weak self] in
                await self?.load(url)
            }
            table[url] = created
            return (created, true)
        }
        let result = await task.value
        // Cleared by the creator after awaiting, never from inside the task —
        // see `ImageStore.image(for:)`.
        if isOwner { inflight.withLock { $0[url] = nil } }
        return result
    }

    private func load(_ url: URL) async -> LottieAnimation? {
        let data: Data
        do {
            data = try await ImageStore.shared.data(for: url)
        } catch {
            if case ImageStore.Failure.status(let code) = error, (400..<500).contains(code) {
                refused.withLock { _ = $0.insert(url) }
            }
            return nil
        }
        let parsed = await Task.detached(priority: .userInitiated) {
            try? LottieAnimation.from(data: data)
        }.value
        guard let parsed else { return nil }
        cache.setObject(Box(parsed), forKey: url as NSURL, cost: data.count * 3)
        return parsed
    }

    /// Drops every parsed document, on real memory pressure.
    func purge() {
        cache.removeAllObjects()
    }
}
