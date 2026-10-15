import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

// MARK: - Decoding a wallpaper

/// Turns a wallpaper's file into the bitmaps the window draws: the picture
/// itself, and a heavily blurred copy the bubbles' frost samples.
///
/// **Off the main thread, decoded once, small where blur allows.** The same
/// three decisions the backdrop renderer made (`Backdrop.swift`): a blurred
/// rendition throws away the detail a large decode paid for, so it is decoded at
/// a fraction of the size.
nonisolated enum WallpaperMedia {
    /// The longest edge a sharp picture is decoded to — enough to fill a retina
    /// window without visible softening.
    static let sharpPixelSize = 2560
    /// The longest edge a blurred one is decoded to.
    static let blurredPixelSize = 768

    /// The still a source draws: the image, or a video's first frame.
    static func poster(of source: WallpaperSource, blur: Double) async -> CGImage? {
        guard let url = source.fileURL else { return nil }
        let size = blur > 0.001 ? blurredPixelSize : sharpPixelSize
        let still: CGImage? = if source.isVideo {
            await videoFrame(at: url, maximumPixelSize: size)
        } else {
            image(at: url, maximumPixelSize: size)
        }
        guard let still else { return nil }
        return blur > 0.001 ? blurred(still, fraction: blur * 0.035) : still
    }

    /// The frost the bubbles show: the same picture, decoded small and blurred
    /// hard, so a bubble reads as frosted glass over its own patch of the
    /// wallpaper (REDESIGN.md R6).
    static func frost(of source: WallpaperSource) async -> CGImage? {
        guard let url = source.fileURL else { return nil }
        let still: CGImage? = if source.isVideo {
            await videoFrame(at: url, maximumPixelSize: blurredPixelSize)
        } else {
            image(at: url, maximumPixelSize: blurredPixelSize)
        }
        return still.flatMap { blurred($0, fraction: frostFraction) }
    }

    /// The frost's blur, as a fraction of the picture's width — about what a
    /// thin material blurs by at the window's size.
    static let frostFraction = 0.06

    /// The frost's brightest and darkest patches, read from a small copy — it
    /// is blurred so hard that 64 pixels across keep every patch a bubble
    /// could sit on.
    static func levels(of frost: CGImage) -> FrostLevels {
        let width = 64, height = 40
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return .unknown }
        context.draw(frost, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return .unknown }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var brightest = 0.0, darkest = 1.0
        for pixel in 0..<(width * height) {
            let luminance = 0.2126 * linear(pixels[pixel * 4])
                + 0.7152 * linear(pixels[pixel * 4 + 1])
                + 0.0722 * linear(pixels[pixel * 4 + 2])
            brightest = max(brightest, luminance)
            darkest = min(darkest, luminance)
        }
        return FrostLevels(brightest: brightest, darkest: darkest)
    }

    private static func linear(_ component: UInt8) -> Double {
        let value = Double(component) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// Decodes a still at a bounded size. Nil for anything ImageIO cannot read.
    static func image(at url: URL, maximumPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A video's first frame, at a bounded size.
    static func videoFrame(at url: URL, maximumPixelSize: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
        return try? await generator.image(at: .zero).image
    }

    /// A gaussian blur, clamped first so the edges do not fade to transparency
    /// (`BackdropRenderer.render`'s note).
    static func blurred(_ image: CGImage, fraction: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(Double(image.width) * fraction)
        guard let output = filter.outputImage else { return image }
        return context.createCGImage(output, from: input.extent)
    }

    private static let context = CIContext(options: [.useSoftwareRenderer: false])
}

/// How light a frost's brightest patch is and how dark its darkest, as
/// relative luminance (0 black, 1 white) — what `BubbleTint` sizes its smoke
/// and its milk by, so the words on a bubble hold wherever it sits.
nonisolated struct FrostLevels: Sendable, Equatable {
    var brightest: Double
    var darkest: Double

    /// A frost that could not be read: assume both extremes.
    static let unknown = FrostLevels(brightest: 1, darkest: 0)
}

// MARK: - macOS's own wallpapers

/// One of the wallpapers macOS already has on this Mac.
nonisolated struct SystemWallpaper: Hashable, Sendable, Identifiable {
    var name: String
    var url: URL
    var thumbnailURL: URL?
    var isVideo: Bool

    var id: URL { url }

    /// Every system wallpaper whose picture is on disk now.
    ///
    /// Adapted from Noodle's `SystemWallpaper` (Apache-2.0, © its authors; see
    /// THIRD-PARTY-NOTICES.md): the catalogue in /System/Library/Desktop
    /// Pictures lists `.madesktop` descriptors whose image exists only once
    /// System Settings has downloaded it (`mobileAssetID` → a HEIC in
    /// com.apple.mobileAssetDesktop); a hidden `.wallpapers` folder holds more;
    /// downloaded aerials are videos with a manifest of names. Anything not yet
    /// downloaded is left out.
    static func available() -> [SystemWallpaper] {
        (stills() + hidden() + aerials())
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The name macOS gives the wallpaper at `path` — an aerial's file is a
    /// UUID, and its name lives in the manifest `available()` reads. Read once
    /// and kept; nil for a path the catalogue does not list.
    static func name(forPath path: String) -> String? {
        names.withLock { cache in
            if cache == nil {
                cache = Dictionary(available().map { ($0.url.path, $0.name) }, uniquingKeysWith: { first, _ in first })
            }
            return cache?[path]
        }
    }

    private static let names = Mutex<[String: String]?>(nil)

    private static let catalogue = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)

    private static func applicationSupport(_ folder: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Application Support/\(folder)", directoryHint: .isDirectory)
    }

    private static func stills() -> [SystemWallpaper] {
        let manager = FileManager.default
        let downloads = applicationSupport("com.apple.mobileAssetDesktop")
        let entries = (try? manager.contentsOfDirectory(at: catalogue, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let downloaded = (try? manager.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var seen = Set<String>()
        return (entries + downloaded).compactMap { entry in
            let name = entry.deletingPathExtension().lastPathComponent
            let image: URL
            if entry.pathExtension.lowercased() == "madesktop" {
                guard let data = try? Data(contentsOf: entry),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let identifier = plist["mobileAssetID"] as? String,
                      !identifier.isEmpty, !identifier.hasPrefix("."), !identifier.contains("/")
                else { return nil }
                image = downloads.appending(path: "\(identifier).heic")
            } else {
                image = entry
            }
            guard isReadableImage(image), seen.insert(image.standardizedFileURL.path).inserted else { return nil }
            let thumbnail = catalogue.appending(path: ".thumbnails/\(name).heic")
            return SystemWallpaper(
                name: name,
                url: image,
                thumbnailURL: manager.isReadableFile(atPath: thumbnail.path) ? thumbnail : nil,
                isVideo: false
            )
        }
    }

    private static func hidden() -> [SystemWallpaper] {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(
            at: catalogue.appending(path: ".wallpapers"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return folders.flatMap { folder -> [SystemWallpaper] in
            let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return files.compactMap { file in
                let name = file.deletingPathExtension().lastPathComponent
                guard !name.contains("Thumbnail") else { return nil }
                let isVideo = isPlayableVideo(file)
                guard isVideo || isReadableImage(file) else { return nil }
                let thumbnail = folder.appending(path: "\(name) Thumbnail@2x.png")
                return SystemWallpaper(
                    name: name,
                    url: file,
                    thumbnailURL: manager.isReadableFile(atPath: thumbnail.path) ? thumbnail : nil,
                    isVideo: isVideo
                )
            }
        }
    }

    private static func aerials() -> [SystemWallpaper] {
        let manager = FileManager.default
        let root = applicationSupport("com.apple.wallpaper/aerials")
        let videos = (try? manager.contentsOfDirectory(
            at: root.appending(path: "videos"), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]
        )) ?? []
        guard !videos.isEmpty else { return [] }
        struct Manifest: Decodable {
            struct Asset: Decodable {
                let id: String
                let accessibilityLabel: String?
                /// The key of the name System Settings shows, in the strings
                /// table beside the manifest.
                let localizedNameKey: String?
            }
            let assets: [Asset]
        }
        let manifest = (try? Data(contentsOf: root.appending(path: "manifest/entries.json")))
            .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        // **The localized name first.** The accessibility label is sometimes
        // the shot's production name — "GG_A_DAY_BLUFFS_C35_V25_HFR_HEVC" — where
        // System Settings says "Golden Gate Day".
        let strings = aerialNames(in: root.appending(path: "manifest/TVIdleScreenStrings.bundle"))
        let assets = Dictionary(
            (manifest?.assets ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let found: [(video: URL, identifier: String, name: String?, label: String?)] = videos.compactMap { video in
            guard isPlayableVideo(video) else { return nil }
            let identifier = video.deletingPathExtension().lastPathComponent
            let asset = assets[identifier]
            return (video, identifier, asset?.localizedNameKey.flatMap { strings[$0] }, asset?.accessibilityLabel)
        }
        // A name several downloads share — macOS's own dynamic wallpapers are
        // all "Light" or "Dark" — takes the readable label in front of it, as
        // "macOS Light"; a production name ("GG_A_DAY_…") is never that label.
        let shared = Dictionary(grouping: found.compactMap(\.name), by: { $0 }).filter { $0.value.count > 1 }.keys
        var seen = Set<String>()
        return found.compactMap { entry in
            var name = entry.name ?? entry.label ?? "Aerial"
            if let localized = entry.name, shared.contains(localized),
               let label = entry.label, !label.contains("_"), label != localized {
                name = label + " " + localized
            }
            // The same wallpaper in two files is one choice.
            guard seen.insert(name).inserted else { return nil }
            let thumbnail = root.appending(path: "thumbnails/\(entry.identifier).png")
            return SystemWallpaper(
                name: name,
                url: entry.video,
                thumbnailURL: manager.isReadableFile(atPath: thumbnail.path) ? thumbnail : nil,
                isVideo: true
            )
        }
    }

    /// The aerials' names in the reader's language: macOS's own table, one
    /// dictionary per language (`Localizable.nocache.loctable`), the reader's
    /// first preferred language that it has, else English.
    private static func aerialNames(in bundle: URL) -> [String: String] {
        let table = bundle.appending(path: "Contents/Resources/Localizable.nocache.loctable")
        guard let data = try? Data(contentsOf: table),
              let languages = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        var candidates: [String] = []
        for preferred in Locale.preferredLanguages {
            let identifier = preferred.replacingOccurrences(of: "-", with: "_")
            candidates.append(identifier)
            if let language = identifier.split(separator: "_").first { candidates.append(String(language)) }
        }
        candidates.append("en")
        for candidate in candidates {
            if let names = languages[candidate] as? [String: String], !names.isEmpty { return names }
        }
        return [:]
    }

    private static func isPlayableVideo(_ url: URL) -> Bool {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }

    /// Reads only the header, so a partial download is left out.
    private static func isReadableImage(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source) as String?,
              UTType(identifier)?.conforms(to: .image) == true
        else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}
