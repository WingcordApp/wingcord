import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import OSLog
import Synchronization
import UniformTypeIdentifiers
import WingcordCore

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
        /// **Three screens of them**: the transcript asks a screen ahead of the
        /// reader either way (REDESIGN.md D12), and a laptop window's worth of
        /// 2× thumbnails is around ten megabytes — at 32 MB the look-ahead
        /// evicted what the reader had just scrolled past, which came back as
        /// placeholders on the way up.
        static let attachments = 64 * 1024 * 1024
        /// Banners and profile art. Small in count, large each.
        static let artwork = 16 * 1024 * 1024
        /// The media viewer's renditions — the picture on stage, its
        /// neighbours, a close-up — emptied when the viewer closes (D14).
        static let stage = 96 * 1024 * 1024

        static var total: Int { thumbnails + attachments + artwork + stage }
    }

    /// Which bucket an image belongs to.
    ///
    /// Separate caches rather than one, because their eviction pressures are
    /// opposite: a single fling through an image channel would otherwise evict
    /// every avatar in the roster to make room for photographs nobody will look
    /// at again.
    ///
    /// **The viewer is a bucket of its own**, and the transcript's cannot be
    /// evicted by it. Sharing `attachment`, a gallery of three at 2048 pixels
    /// was 31 MB of a 32 MB bucket and one 12-megapixel close-up was 50 MB —
    /// every thumbnail in the transcript went, and the picture flew home onto
    /// a placeholder that then flashed back in.
    enum Bucket: Sendable {
        case thumbnail
        case attachment
        case artwork
        case stage
    }

    private let thumbnails = NSCache<NSString, Entry>()
    private let attachments = NSCache<NSString, Entry>()
    private let artwork = NSCache<NSString, Entry>()
    private let stage = NSCache<NSString, Entry>()

    private let session: URLSession
    /// Bounds how many decodes are in flight.
    ///
    /// **Without this, peak memory is set by scroll speed.** A fast fling
    /// through an image channel starts a request per row it passes; each holds
    /// its compressed bytes and its decode buffer, and the peak is however many
    /// the gesture touched. malloc does not hand those pages back, so the peak
    /// becomes the floor.
    ///
    /// **It gates the decode, not the download** (REDESIGN.md D13). The
    /// download used to run inside it as well, so six slow photographs held
    /// all six places and every avatar and emoji queued behind them for as
    /// long as the network took. A download holds compressed bytes — a tenth
    /// of what it decodes to — and how many run at once is bounded by what is
    /// wanted: the transcript asks for a screen around the reader and never
    /// under a fling (`TimelineView.schedulePrefetch`), and the session keeps
    /// its own connections per host.
    private let decodeGate = ConcurrencyGate(limit: 6)
    /// In-flight requests, so twelve rows showing the same avatar make one
    /// request rather than twelve.
    private let inflight = Mutex<[Key: Task<CGImage?, Never>]>([:])

    /// `~/Library/Caches/<bundle id>/Images`, created on demand.
    ///
    /// Under the bundle identifier rather than a bare folder, so an app that is
    /// later sandboxed finds the same path inside its container and a user
    /// clearing caches by hand finds one directory rather than several.
    nonisolated static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        let identifier = Bundle.main.bundleIdentifier ?? "dev.wingcord.Wingcord"
        return base
            .appending(path: identifier, directoryHint: .isDirectory)
            .appending(path: "Images", directoryHint: .isDirectory)
    }

    private init() {
        thumbnails.totalCostLimit = Budget.thumbnails
        attachments.totalCostLimit = Budget.attachments
        artwork.totalCostLimit = Budget.artwork
        stage.totalCostLimit = Budget.stage

        let configuration = URLSessionConfiguration.default
        // A disk cache is what makes a relaunch cheap and a re-decode after an
        // eviction a decode rather than a download. It is deliberately outside
        // the resident budget above: the 512 MB disk half is not memory.
        // **An explicit directory, not a `diskPath` name.** The `diskPath:`
        // initialiser resolves a bare relative name against the process's
        // WORKING DIRECTORY on macOS — so a half-gigabyte cache landed wherever
        // the app happened to be launched from, which for a development build is
        // the source tree. The symptom was 45 MB of `wingcord-images/` in the
        // repository; the first fix was a `.gitignore` entry, which hid it
        // without moving it. This is the cause.
        configuration.urlCache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            directory: Self.cacheDirectory
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
        //
        // **The entry is cleared by whoever CREATED it, after awaiting — never
        // from inside the task body.** Clearing it from inside is a race the
        // wrong way round: the body can reach its cleanup before
        // `table[key] = created` has run, so the removal happens first and the
        // *finished* task is then installed permanently. Every later request for
        // that key joins a completed task and gets its result forever — and if
        // that result was a failure, the picture is replaced by a monogram for
        // the life of the process. That is the "some avatars just never load"
        // shape: not a slow fetch, a cached nil.
        let (task, isOwner) = inflight.withLock { table -> (Task<CGImage?, Never>, Bool) in
            if let existing = table[key] { return (existing, false) }
            let created = Task<CGImage?, Never> { [weak self] in
                guard let self else { return nil }
                return await self.load(key: key, bucket: bucket)
            }
            table[key] = created
            return (created, true)
        }
        let result = await task.value
        if isOwner { inflight.withLock { $0[key] = nil } }
        return result
    }

    private func load(key: Key, bucket: Bucket) async -> CGImage? {
        // One retry, and only for a *transport* failure.
        //
        // A view has no second chance at this: `RemoteImage` asks once from
        // `.task(id:)`, and the canvas asks once per viewport change. So a
        // dropped connection during a roster's avatar burst — which is exactly
        // when many connections are open at once — leaves a monogram where a
        // face should be until something unrelated happens to ask again.
        //
        // A 404 or a 403 is not retried: the answer will not change, and asking
        // twice for every deleted avatar on a large server doubles that traffic
        // for nothing.
        for attempt in 0..<2 {
            let outcome = await attemptLoad(key: key, bucket: bucket)
            switch outcome {
            case .image(let image):
                return image
            case .permanentFailure:
                return nil
            case .transientFailure:
                guard attempt == 0 else { return nil }
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled { return nil }
            }
        }
        return nil
    }

    private enum LoadOutcome {
        case image(CGImage)
        /// Worth asking again — a dropped connection, a timeout, a 5xx.
        case transientFailure
        /// Not worth asking again — a 404, a 403, or bytes that are not an image.
        case permanentFailure
    }

    private func attemptLoad(key: Key, bucket: Bucket) async -> LoadOutcome {
        // **A clip on this Mac is its own poster** — a `--demo` fixture, whose
        // files Discord's proxy never sees, so no `format=webp` still exists
        // for it. Its first frame, at the size asked for.
        if key.url.isFileURL, Self.isVideoFile(key.url) {
            guard let frame = await Self.posterFrame(of: key.url, maximumPixelSize: key.maximumPixelSize) else {
                return .permanentFailure
            }
            cache(for: bucket).setObject(Entry(image: frame), forKey: key.cacheKey, cost: frame.height * frame.bytesPerRow)
            return .image(frame)
        }
        // **An upload's link may have run out**: fetch with a freshly signed
        // one, and cache under the link the caller holds — see
        // `AttachmentLinks`. Anything that is not a signed upload skips the hop.
        let isSigned = AttachmentLink.isSigned(key.url)
        let url = isSigned ? await AttachmentLinks.shared.usable(key.url) : key.url
        let data: Data
        do {
            var (bytes, response) = try await session.data(from: url)
            // A refusal of a signed link is asked once more with a fresh
            // signature — the expiry it carried may simply be wrong.
            if isSigned, Self.isRefusal(response),
               let retry = await AttachmentLinks.shared.retrying(key.url)
            {
                (bytes, response) = try await session.data(from: retry)
            }
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode)
            {
                return http.statusCode >= 500 || http.statusCode == 429
                    ? .transientFailure
                    : .permanentFailure
            }
            data = bytes
        } catch is CancellationError {
            return .permanentFailure
        } catch {
            Self.log.debug("image load failed: \(key.url.absoluteString, privacy: .public)")
            return .transientFailure
        }
        // Only the decode waits for a place — see `decodeGate`.
        let maximumPixelSize = key.maximumPixelSize
        guard let image = await decodeGate.run({ Self.decode(data, maximumPixelSize: maximumPixelSize) }) else {
            // Bytes arrived and were not a picture. Asking again gets the
            // same bytes.
            return .permanentFailure
        }
        cache(for: bucket).setObject(
            Entry(image: image),
            forKey: key.cacheKey,
            cost: image.height * image.bytesPerRow
        )
        return .image(image)
    }

    nonisolated static func isVideoFile(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v", "webm", "mkv"].contains(url.pathExtension.lowercased())
    }

    /// A video file's first frame, fitted inside `maximumPixelSize`.
    nonisolated static func posterFrame(of url: URL, maximumPixelSize: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
        return try? await generator.image(at: .zero).image
    }

    /// Fetches bytes through this store's session.
    ///
    /// Exposed so `AnimatedImageStore` shares the connection pool AND the disk
    /// cache rather than standing up a second `URLSession` beside it. Two
    /// sessions pointed at one `diskPath` is a corrupt cache; two pointed at
    /// different ones means a decoration is downloaded twice — once as a still
    /// and once as a filmstrip — for the same bytes.
    func data(for url: URL) async throws -> Data {
        let isSigned = AttachmentLink.isSigned(url)
        var (data, response) = try await session.data(
            from: isSigned ? await AttachmentLinks.shared.usable(url) : url
        )
        if isSigned, Self.isRefusal(response), let retry = await AttachmentLinks.shared.retrying(url) {
            (data, response) = try await session.data(from: retry)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.status(http.statusCode)
        }
        return data
    }

    /// The start of a text file, and what the answer says about the rest —
    /// Discord's preview fetch (`684519.eC`): the first 50,001 bytes, asked
    /// for as `text/plain`, through the same signed-link handling as every
    /// other attachment here.
    func textPreview(_ url: URL) async throws -> TextPreviewResponse {
        // A file on this Mac — only ever a `--demo` fixture (`DemoMedia`),
        // whose attachments are files — answered as the CDN answers the
        // ranged GET: the first 50,001 bytes and the whole file's length.
        if url.isFileURL {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 50_001) ?? Data()
            let total = try handle.seekToEnd()
            return TextPreviewResponse(
                data: data,
                contentType: "text/plain; charset=utf-8",
                contentRange: "bytes 0-\(max(0, data.count - 1))/\(total)",
                contentLength: "\(data.count)"
            )
        }
        func request(_ url: URL) -> URLRequest {
            var request = URLRequest(url: url)
            request.setValue(PlaintextPreview.rangeHeader, forHTTPHeaderField: "Range")
            request.setValue("text/plain", forHTTPHeaderField: "Accept")
            return request
        }
        let isSigned = AttachmentLink.isSigned(url)
        var (data, response) = try await session.data(
            for: request(isSigned ? await AttachmentLinks.shared.usable(url) : url)
        )
        if isSigned, Self.isRefusal(response), let retry = await AttachmentLinks.shared.retrying(url) {
            (data, response) = try await session.data(for: request(retry))
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.status(0) }
        guard (200..<300).contains(http.statusCode) else { throw Failure.status(http.statusCode) }
        return TextPreviewResponse(
            data: data,
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            contentLength: http.value(forHTTPHeaderField: "Content-Length")
        )
    }

    /// The answers a signed link gives once its signature has run out.
    private static func isRefusal(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 404 || http.statusCode == 403
    }

    /// Streams an asset to a temporary file, reporting progress as it goes.
    ///
    /// **A download, not `data(for:)`.** A video attachment can be hundreds of
    /// megabytes and `data` holds every byte of it in memory before anything can
    /// be written; `URLSessionDownloadTask` streams to disk and peaks at a
    /// buffer. Through this store's session, so a save reuses the connection
    /// pool rather than standing up a second one.
    ///
    /// The returned file lives in the system's temporary directory and is the
    /// caller's the moment this returns — move it, do not copy it, and do not
    /// leave it.
    func download(
        _ url: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        let isSigned = AttachmentLink.isSigned(url)
        var (file, response) = try await session.download(
            from: isSigned ? await AttachmentLinks.shared.usable(url) : url,
            delegate: delegate
        )
        if isSigned, Self.isRefusal(response), let retry = await AttachmentLinks.shared.retrying(url) {
            try? FileManager.default.removeItem(at: file)
            (file, response) = try await session.download(from: retry, delegate: delegate)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.status(http.statusCode)
        }
        return file
    }

    enum Failure: Error {
        case status(Int)
    }

    /// A text preview's bytes and the three headers Discord reads.
    struct TextPreviewResponse: Sendable {
        var data: Data
        var contentType: String?
        var contentRange: String?
        var contentLength: String?
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
        else { return vector(data, maximumPixelSize: maximumPixelSize) }

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
            ?? vector(data, maximumPixelSize: maximumPixelSize)
    }

    /// The same thing for an **SVG**, which `CGImageSource` cannot open at all.
    ///
    /// Discord ships the tenure badge artwork — and a good deal of its
    /// illustration — as SVG under `/assets/`, and a client that only knows
    /// `CGImageSource` draws nothing for any of it. AppKit does know the format:
    /// `NSImage(data:)` answers with an `_NSSVGImageRep`, which rasterises
    /// cleanly at whatever size it is drawn into.
    ///
    /// **Rasterised HERE at the drawn size**, for the reason the caller above
    /// gives: a vector rep re-evaluates its paths on every draw, so leaving it
    /// as an `NSImage` moves the cost into the display pass and repeats it every
    /// frame. One bitmap, decoded off the main thread, on the same terms as
    /// every other picture in the app.
    ///
    /// **Off the main actor, unlike `LottieFilmstrip`**, and the difference is
    /// real rather than a bet: that rasteriser drives a `CALayer` tree, which
    /// races Core Animation's own transactions and killed the app for it. This
    /// draws an image rep into a private bitmap context through a per-thread
    /// `NSGraphicsContext` — no layer tree, nothing shared with the render
    /// server, and the pattern Apple documents for exactly this.
    ///
    /// Tried only when `CGImageSource` has already refused, so it costs nothing
    /// on the common path.
    private static func vector(_ data: Data, maximumPixelSize: Int) -> CGImage? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0
        else { return nil }
        // Fitted, so a non-square drawing keeps its aspect — the same contract
        // `kCGImageSourceThumbnailMaxPixelSize` has.
        let scale = Double(maximumPixelSize) / max(image.size.width, image.size.height)
        let width = Int((image.size.width * scale).rounded())
        let height = Int((image.size.height * scale).rounded())
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current = previous
        return context.makeImage()
    }

    // MARK: Storage
    //
    // What the settings window can honestly report and act on.
    //
    // **The resident caches are deliberately NOT reported.** `NSCache` publishes
    // its cost *limit* and never its current cost, and there is no supported way
    // to ask. A figure derived by walking the keys would be a guess presented as
    // a measurement, which is worse than the budget on its own — so the pane
    // shows what each cache is allowed and what the process actually occupies,
    // and says nothing it cannot know.

    /// What that cache is allowed. The disk half is not memory — see `init`.
    nonisolated var downloadCacheCapacity: Int {
        session.configuration.urlCache?.diskCapacity ?? 0
    }

    /// Every decoded image the caches are allowed to hold at once.
    nonisolated var residentBudget: Int { Budget.total }

    /// Empties the on-disk half.
    ///
    /// Distinct from `purge()`, and the difference is what the two rows in the
    /// settings pane are for: purging frees *memory* and costs a decode, while
    /// this frees *disk* and costs a download. Someone reclaiming space wants
    /// this one; someone whose Mac is under pressure wants the other.
    nonisolated func clearDownloadCache() {
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    // MARK: Pressure

    /// Drops everything. Called on a real memory-pressure signal, and on the
    /// window going out of sight for long enough that the caches are holding
    /// pictures nobody can see.
    func purge() {
        thumbnails.removeAllObjects()
        attachments.removeAllObjects()
        artwork.removeAllObjects()
        stage.removeAllObjects()
    }

    /// Drops the buckets whose contents are cheapest to re-fetch, keeping the
    /// avatars a roster is about to re-draw.
    func shedLargeImages() {
        attachments.removeAllObjects()
        artwork.removeAllObjects()
        stage.removeAllObjects()
    }

    /// Drops the media viewer's renditions — called as it closes. A picture
    /// opened again comes back from the disk cache, a decode rather than a
    /// download; held, they would be ninety-odd megabytes nobody is looking at.
    func emptyStage() {
        stage.removeAllObjects()
    }

    /// Which cache a bucket is — for the tests that hold the viewer's bucket
    /// apart from the transcript's. Two buckets with one identity share a
    /// budget, and the larger can empty the smaller.
    func cacheIdentity(for bucket: Bucket) -> ObjectIdentifier {
        ObjectIdentifier(cache(for: bucket))
    }

    private func cache(for bucket: Bucket) -> NSCache<NSString, Entry> {
        switch bucket {
        case .thumbnail: thumbnails
        case .attachment: attachments
        case .artwork: artwork
        case .stage: stage
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

/// Reports a download's progress.
///
/// A task-scoped delegate rather than one on the session: it lives exactly as
/// long as the one save it was created for, so there is no shared state to
/// key by task and nothing to unregister.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // A server that sends no length reports -1 here, and dividing by it
        // gives a bar that runs backwards.
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    /// Required by the protocol. The async `download(from:delegate:)` owns the
    /// file and hands it back through its return value, so there is nothing to
    /// do here.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
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
