import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import WingcordCore

// MARK: - The library's pictures
//
// A card's picture: a clip's first second, a recording's screen, a
// screenshot itself — made once at the card's size and kept, in memory for
// the session and on disk in Caches beside the replay buffer's cache, keyed by
// the file and when it last changed so an edited or replaced file is drawn
// anew.

actor ClipThumbnails {
    static let shared = ClipThumbnails()

    /// The longest side a card's picture needs — a 2× card at its widest.
    static let side = 640

    private let memory = NSCache<NSString, CGImageBox>()
    private let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundle = Bundle.main.bundleIdentifier ?? "dev.wingcord.Wingcord"
        return caches.appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("ClipThumbnails", isDirectory: true)
    }()

    final class CGImageBox: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    func thumbnail(for url: URL, kind: ClipLibraryItem.Kind) async -> CGImage? {
        let key = Self.key(for: url)
        if let cached = memory.object(forKey: key as NSString) { return cached.image }
        let file = folder.appendingPathComponent(key).appendingPathExtension("jpg")
        if let image = Self.read(file) {
            memory.setObject(CGImageBox(image), forKey: key as NSString)
            return image
        }
        let made: CGImage? = switch kind {
        case .screenshot: Self.downsample(url)
        case .clip: await Self.frame(of: url)
        case .recording: await Self.frame(of: url.appendingPathComponent(TakeManifest.screenFile))
        }
        guard let made else { return nil }
        memory.setObject(CGImageBox(made), forKey: key as NSString)
        Self.write(made, to: file)
        return made
    }

    /// The file and its last change, as one name.
    private static func key(for url: URL) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        var hasher = FNV1a()
        hasher.combine(url.path)
        hasher.combine(String(modified))
        return String(hasher.value, radix: 16)
    }

    private static func frame(of url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: side, height: side)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        // A second in, past a fade from black; the middle of a short one.
        let time = CMTime(seconds: min(1, max(0, duration / 2)), preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    private static func downsample(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func read(_ file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func write(_ image: CGImage, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}

/// Fowler–Noll–Vo, 64-bit: a stable name for a cache file. `Hasher` is
/// seeded per launch, which is the opposite of what a file name needs.
nonisolated struct FNV1a {
    private(set) var value: UInt64 = 0xCBF2_9CE4_8422_2325

    mutating func combine(_ text: String) {
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value &*= 0x0000_0100_0000_01B3
        }
    }
}
