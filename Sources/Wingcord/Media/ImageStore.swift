import AppKit
import CoreGraphics
import Foundation
import ImageIO
import OSLog
import Synchronization
import UniformTypeIdentifiers

/// The one place a remote image is fetched, decoded and cached.
///
/// Three properties decide whether an image-heavy channel scrolls, and all three
/// are here rather than at any call site:
///
/// **1. The decode happens off the main thread, at the drawn size.**
/// `NSImage(data:)` does not decode — it defers the work to the first draw,
/// which happens on the main thread inside a display pass, so a burst of avatars
/// arriving together overruns a frame. `CGImageSourceCreateThumbnailAtIndex`
/// with `kCGImageSourceShouldCacheImmediately` forces the decode here, on a
/// background task, and `kCGImageSourceThumbnailMaxPixelSize` decodes straight
/// to the size the pixel will be drawn at rather than at the source's twelve
/// megapixels.
///
/// **2. The cache key carries the pixel size.** Without it, a row's 64px
/// downsampled copy is handed to a profile card that wanted 256 and drawn
/// blurry. With it, the two are different entries.
///
/// **3. The hit path is synchronous and `nonisolated`.** A cache reachable only
/// with `await` costs a placeholder frame per row: the row draws its monogram,
/// the hop completes, the row re-renders. `cached(_:)` is a plain function that
/// a view body may call, backed by `NSCache`, which is thread-safe.
/// **`nonisolated` on the type, and it is load-bearing rather than tidy.** The
/// app target defaults to main-actor isolation, so without this the whole store
/// — including `decode` — is main-actor, and every image in the app is decoded
/// on the main thread inside a display pass. That is precisely the defect the
/// file exists to prevent, and it compiles perfectly.
///
/// Opting out on the type rather than member by member also means the next
/// method added inherits the right answer instead of the wrong one.
nonisolated final class ImageStore: @unchecked Sendable {
    static let shared = ImageStore()

    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Images")

    /// A decoded image plus the byte cost it actually occupies, so `NSCache`'s
    /// limit means something. Costing entries by `1` and setting a count limit
    /// is how a cache evicts a roster while forty megabytes sit free.
    final class Entry: @unchecked Sendable {
        let image: CGImage
        let cost: Int

        init(image: CGImage) {
            self.image = image
            // Height × bytes-per-row is the real allocation, not width × height
            // × 4: a decoded row is padded to a stride the framework chooses.
            cost = image.height * image.bytesPerRow
        }
    }

    /// Cache key: the URL and the size it was decoded for.
    struct Key: Hashable, Sendable {
        var url: URL
        var maximumPixelSize: Int
    }

    // MARK: Budgets
    //
    // ONE table, and the total is derived rather than written down twice. A
    // hand-kept sum drifts, and a drifted sum is the premise of a wrong
    // conclusion about whether the budgets are a lever at all.

    enum Budget {
        /// Avatars, guild icons, emoji — small, numerous, re-shown constantly.
        static let thumbnails = 48 * 1024 * 1024
        /// Chat attachments and embed artwork — large, seen once, scrolled past.
        static let attachments = 32 * 1024 * 1024
        /// Banners and profile art. Small in count, large each.
        static let artwork = 16 * 1024 * 1024

        static var total: Int { thumbnails + attachments + artwork }
    }

    /// Which bucket an image belongs to.
    ///
    /// Separate caches rather than one, because their eviction pressures are
    /// opposite: a single fling through an image channel would otherwise evict
    /// every avatar in the roster to make room for photographs nobody will look
    /// at again.
    enum Bucket: Sendable {
        case thumbnail
        case attachment
        case artwork
    }

    private let thumbnails = NSCache<NSString, Entry>()
    private let attachments = NSCache<NSString, Entry>()
    private let artwork = NSCache<NSString, Entry>()

    private let session: URLSession
    /// Bounds how many decodes are in flight.
    ///
    /// **Without this, peak memory is set by scroll speed.** A fast fling
    /// through an image channel starts a request per row it passes; each holds
    /// its compressed bytes and its decode buffer, and the peak is however many
    /// the gesture touched. malloc does not hand those pages back, so the peak
    /// becomes the floor.
    private let decodeGate = ConcurrencyGate(limit: 6)
    /// In-flight requests, so twelve rows showing the same avatar make one
    /// request rather than twelve.
    private let inflight = Mutex<[Key: Task<CGImage?, Never>]>([:])

    private init() {
        thumbnails.totalCostLimit = Budget.thumbnails
        attachments.totalCostLimit = Budget.attachments
        artwork.totalCostLimit = Budget.artwork

        let configuration = URLSessionConfiguration.default
        // A disk cache is what makes a relaunch cheap and a re-decode after an
        // eviction a decode rather than a download. It is deliberately outside
        // the resident budget above: the 512 MB disk half is not memory.
        configuration.urlCache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            diskPath: "wingcord-images"
        )
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }

    // MARK: Reading

    /// A synchronous, non-isolated cache peek. Safe to call from a view body or
    /// from a canvas painter running off the main actor.
    func cached(_ key: Key, bucket: Bucket = .thumbnail) -> CGImage? {
        cache(for: bucket).object(forKey: key.cacheKey)?.image
    }

    /// Fetches and decodes, or returns the cached image.
    ///
    /// Returns nil rather than throwing: a missing avatar is a monogram, not an
    /// error anyone can act on, and an error type here would be checked and
    /// discarded at every one of a hundred call sites.
    func image(for key: Key, bucket: Bucket = .thumbnail) async -> CGImage? {
        if let hit = cached(key, bucket: bucket) { return hit }

        // Join an in-flight request for the same key rather than starting a
        // second one.
        let task: Task<CGImage?, Never> = inflight.withLock { table in
            if let existing = table[key] { return existing }
            let created = Task<CGImage?, Never> { [weak self] in
                guard let self else { return nil }
                let result = await self.load(key: key, bucket: bucket)
                self.inflight.withLock { $0[key] = nil }
                return result
            }
            table[key] = created
            return created
        }
        return await task.value
    }

    private func load(key: Key, bucket: Bucket) async -> CGImage? {
        await decodeGate.run {
            do {
                let (data, response) = try await session.data(from: key.url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return nil
                }
                guard let image = Self.decode(data, maximumPixelSize: key.maximumPixelSize) else {
                    return nil
                }
                cache(for: bucket).setObject(
                    Entry(image: image),
                    forKey: key.cacheKey,
                    cost: image.height * image.bytesPerRow
                )
                return image
            } catch is CancellationError {
                return nil
            } catch {
                Self.log.debug("image load failed: \(key.url.absoluteString, privacy: .public)")
                return nil
            }
        }
    }

    /// Decodes at the drawn size.
    ///
    /// `nonisolated` and `static` so it can be called from a painter or a test
    /// without the store.
    static func decode(_ data: Data, maximumPixelSize: Int) -> CGImage? {
        let sourceOptions: [CFString: Any] = [
            // Nothing here needs the full image cached alongside the thumbnail.
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary)
        else { return nil }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            // Forces the decode HERE, off the main thread, instead of deferring
            // it to the first draw. This one line is the difference between an
            // avatar batch costing 3 ms and costing 61 ms of a display pass.
            kCGImageSourceShouldCacheImmediately: true,
            // Honours EXIF orientation, so a phone photo is not sideways.
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }

    // MARK: Pressure

    /// Drops everything. Called on a real memory-pressure signal, and on the
    /// window going out of sight for long enough that the caches are holding
    /// pictures nobody can see.
    func purge() {
        thumbnails.removeAllObjects()
        attachments.removeAllObjects()
        artwork.removeAllObjects()
    }

    /// Drops the two buckets whose contents are cheapest to re-fetch, keeping
    /// the avatars a roster is about to re-draw.
    func shedLargeImages() {
        attachments.removeAllObjects()
        artwork.removeAllObjects()
    }

    private func cache(for bucket: Bucket) -> NSCache<NSString, Entry> {
        switch bucket {
        case .thumbnail: thumbnails
        case .attachment: attachments
        case .artwork: artwork
        }
    }
}

extension ImageStore.Key {
    /// One string, built once per lookup.
    ///
    /// Interpolating a URL into a `String` and bridging it to `NSString` per row
    /// per evaluation is a real cost at roster scale, which is why the peek is
    /// latched on the resolved URL at the call site rather than repeated.
    nonisolated var cacheKey: NSString {
        "\(maximumPixelSize)|\(url.absoluteString)" as NSString
    }
}

/// Bounds how many operations run at once, without a semaphore blocking a
/// cooperative-pool thread.
///
/// A `DispatchSemaphore.wait()` inside an async function parks a thread the
/// concurrency runtime believes is available, and enough of them deadlock the
/// pool. This suspends instead.
actor ConcurrencyGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await work()
    }

    private func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        active += 1
    }

    private func release() {
        active -= 1
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}
