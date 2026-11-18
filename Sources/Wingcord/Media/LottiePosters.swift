import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Lottie
import QuartzCore
import Synchronization
import UniformTypeIdentifiers

/// A Lottie sticker's still picture: one frame, made once, kept in memory and
/// on disk.
///
/// **The CDN has no bitmap for a Lottie sticker** — it serves the JSON and
/// nothing else — so every still of one is drawn here: a picker cell before its
/// film is up or with animation off, a pack's icon on the rail, a heading's
/// badge, the hover row's picture. It used to be the first of the twenty-four
/// frames `LottieFilmstrip` rasterises on the main actor, so each of the nine
/// Lottie packs' rail icons cost a whole filmstrip, every launch (Alex,
/// 2026-11-18: "a ton of stock sticker packs refuse to load").
///
/// Now **one frame**, rendered in its own turn of the run loop
/// (`LottieTurns`), and **written to Caches as a PNG**: once a pack has been
/// seen, a launch draws all of it from disk.
nonisolated final class LottiePosters: @unchecked Sendable {
    static let shared = LottiePosters()

    struct Key: Hashable, Sendable {
        var url: URL
        /// The longest side, in pixels.
        var pixels: Int
    }

    private final class Box: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    /// A poster is a few dozen kilobytes at a cell's size; this holds every
    /// standard sticker at two sizes with room left.
    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    private let inflight = Mutex<[Key: Task<CGImage?, Never>]>([:])
    /// Documents that parsed but drew nothing at any of the frames tried — a
    /// fault in the file, which asking again cannot fix.
    private let blank = Mutex<Set<Key>>([])

    /// `~/Library/Caches/<bundle id>/LottiePosters`, beside the image cache.
    static var folder: URL {
        ImageStore.cacheDirectory
            .deletingLastPathComponent()
            .appending(path: "LottiePosters", directoryHint: .isDirectory)
    }

    private init() {}

    /// A synchronous peek, for a draw that cannot wait.
    func cached(_ key: Key) -> CGImage? {
        cache.object(forKey: key.cacheKey)?.image
    }

    /// The poster from memory, then disk, then drawn.
    func poster(for key: Key) async -> CGImage? {
        if let hit = cached(key) { return hit }
        if blank.withLock({ $0.contains(key) }) { return nil }
        let (task, isOwner) = inflight.withLock { table -> (Task<CGImage?, Never>, Bool) in
            if let existing = table[key] { return (existing, false) }
            let created = Task<CGImage?, Never> { [weak self] in
                await self?.load(key)
            }
            table[key] = created
            return (created, true)
        }
        let result = await task.value
        // Cleared by the creator after awaiting — see `ImageStore.image(for:)`.
        if isOwner { inflight.withLock { $0[key] = nil } }
        return result
    }

    private func load(_ key: Key) async -> CGImage? {
        let file = Self.folder.appending(path: key.fileName)
        if let stored = Self.read(file) {
            remember(stored, for: key)
            return stored
        }
        // A missing or unreadable document is LottieDocuments' to remember;
        // a fetch that failed for now is tried again on the next prefetch.
        guard let animation = await LottieDocuments.shared.animation(for: key.url) else { return nil }
        guard let drawn = await Self.render(animation, pixels: key.pixels) else {
            blank.withLock { _ = $0.insert(key) }
            return nil
        }
        remember(drawn, for: key)
        Self.write(drawn, to: file)
        return drawn
    }

    private func remember(_ image: CGImage, for key: Key) {
        cache.setObject(Box(image), forKey: key.cacheKey, cost: image.bytesPerRow * image.height)
    }

    // MARK: Drawing

    /// Draws a frame worth showing, in one turn of the run loop.
    ///
    /// **On the main actor, as `LottieFilmstrip` explains**: Lottie's
    /// main-thread engine mutates a `CAShapeLayer` tree, and doing that off the
    /// main thread races Core Animation's own commits. One frame is a few
    /// milliseconds, so a turn each is never a dropped frame.
    ///
    /// **The first frame, unless it is empty**: a sticker that enters from
    /// nothing would be a blank cell, so the middle of the loop and its
    /// quarters are tried before giving up.
    @MainActor
    static func render(_ animation: LottieAnimation, pixels: Int) async -> CGImage? {
        await LottieTurns.next()
        let size = animation.size
        guard size.width > 0, size.height > 0 else { return nil }
        let layer = LottieAnimationLayer(
            animation: animation,
            configuration: LottieConfiguration(renderingEngine: .mainThread)
        )
        layer.frame = CGRect(origin: .zero, size: size)
        layer.contentsScale = 1
        layer.layoutIfNeeded()
        // Placed by hand — `LottieFilmstrip`'s third detail: the sizing a view
        // would do lives in the view, and headless the root lands cropped.
        if let root = layer.sublayers?.first {
            root.anchorPoint = .zero
            root.position = .zero
            root.transform = CATransform3DIdentity
            root.bounds = CGRect(origin: .zero, size: size)
        }
        let scale = Double(max(pixels, 1)) / max(size.width, size.height)
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }

        for progress in [0.0, 0.5, 0.25, 0.75] {
            layer.currentProgress = progress
            layer.forceDisplayUpdate()
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            ) else { return nil }
            // Flipped: a layer renders top-left down, a context bottom-up.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            layer.render(in: context)
            guard let image = context.makeImage() else { return nil }
            if hasInk(context) { return image }
        }
        return nil
    }

    /// Whether at least one part in a hundred of the picture is drawn.
    ///
    /// Alpha leads each pixel (`premultipliedFirst`, big-endian), and every
    /// third pixel of every third row is plenty to tell a sticker from nothing.
    private static func hasInk(_ context: CGContext) -> Bool {
        guard let data = context.data else { return true }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let rowBytes = context.bytesPerRow
        var inked = 0
        var sampled = 0
        for y in stride(from: 0, to: context.height, by: 3) {
            for x in stride(from: 0, to: context.width, by: 3) {
                sampled += 1
                if bytes[y * rowBytes + x * 4] > 16 { inked += 1 }
            }
        }
        return sampled > 0 && inked * 100 >= sampled
    }

    // MARK: Disk

    private static func read(_ file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        // Decoded here, off the main actor, rather than on its first draw.
        return CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        )
    }

    private static func write(_ image: CGImage, to file: URL) {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            file as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

extension LottiePosters.Key {
    nonisolated var cacheKey: NSString { "\(pixels)|\(url.absoluteString)" as NSString }

    /// The URL hashed, so a CDN path never has to be a file name.
    nonisolated var fileName: String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(hex)-\(pixels).png"
    }
}

/// Lottie's main-thread work, one piece per turn of the run loop.
///
/// Rendering a poster or building a sticker's layer tree is a few
/// milliseconds; a picker scrolled onto a pack of thirty asks for all of them
/// at once, and thirty in a row is a stall. Each caller waits for those before
/// it and one yield more, so the run loop gets its turn between them.
@MainActor
enum LottieTurns {
    private static var tail: Task<Void, Never>?

    static func next() async {
        let previous = tail
        let turn = Task { @MainActor in
            _ = await previous?.value
            await Task.yield()
        }
        tail = turn
        await turn.value
    }
}
