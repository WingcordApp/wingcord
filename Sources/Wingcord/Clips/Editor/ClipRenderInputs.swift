import AVFoundation
import AppKit
import Foundation
import WingcordCore
import WingcordVoice

// MARK: - An item and its edits, as the renderer takes them
//
// docs/CLIPS-PRESENCE.md, Phase 5. One place turns what the library holds —
// a clip and its sidecar, or a recording's package — and its edits into
// `ClipRenderInput`, so the editor's preview, Export… and Share draw the same
// thing: the source and its camera, the cuts, the crop and canvas, zooms,
// blurs, the cursor drawn again with the system's own cursors, the sound with
// any cleaned voice in place of its stem, and every word, picture, caption
// and face drawn on the canvas.

enum ClipRenderInputs {

    /// The picture's file: a clip itself, a recording's screen.
    static func sourceURL(of item: ClipLibraryItem) -> URL {
        item.kind == .recording ? item.url.appendingPathComponent(TakeManifest.screenFile) : item.url
    }

    static func cameraURL(of item: ClipLibraryItem) -> URL? {
        guard item.kind == .recording, item.clip.take?.hasCamera == true else { return nil }
        return item.url.appendingPathComponent(TakeManifest.cameraFile)
    }

    static func assetsFolder(of item: ClipLibraryItem) -> URL {
        item.url.deletingLastPathComponent()
            .appendingPathComponent(".wingcord", isDirectory: true)
            .appendingPathComponent("assets", isDirectory: true)
    }

    /// Where a cleaned voice for stem `index` is kept, beside the clip.
    static func cleanedStemURL(of item: ClipLibraryItem, stem index: Int) -> URL {
        item.url.deletingLastPathComponent()
            .appendingPathComponent(".wingcord", isDirectory: true)
            .appendingPathComponent("derived", isDirectory: true)
            .appendingPathComponent("\(item.url.lastPathComponent)-stem\(index)-clean.m4a")
    }

    /// A recording's cursor, as it was logged.
    static func cursorLog(of item: ClipLibraryItem) -> CursorLog? {
        guard item.kind == .recording, item.clip.take?.hasCursorLog == true,
              let data = try? Data(contentsOf: item.url.appendingPathComponent(TakeManifest.cursorFile))
        else { return nil }
        return try? JSONDecoder().decode(CursorLog.self, from: data)
    }

    /// The audio tracks heard: the clip's mix while nothing is switched off or
    /// cleaned, its stems otherwise; a recording's own tracks.
    static func audioTracks(of item: ClipLibraryItem, edits: ClipEdits, count: Int) -> [Int]? {
        if let tracks = item.clip.manifest?.tracks, tracks.count == count, tracks.first?.role == .mix {
            if edits.mutedTracks.isEmpty, edits.cleanedStems.isEmpty { return [0] }
            return (1..<max(count, 1)).filter { !edits.mutedTracks.contains($0) }
        }
        guard !edits.mutedTracks.isEmpty else { return nil }
        return (0..<count).filter { !edits.mutedTracks.contains($0) }
    }

    /// Everything the renderer needs for `item` drawn with `edits`.
    static func input(
        for item: ClipLibraryItem, edits: ClipEdits, settings: ClipExportSettings? = nil, includesOverlays: Bool = true
    ) async -> ClipRenderInput {
        let source = sourceURL(of: item)
        let asset = AVURLAsset(url: source)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let size = (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? .zero
        let audioCount = (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
        let crop = edits.crop.rect(in: size, position: edits.cropPosition)
        let contentAspect = crop.height > 0 ? Double(crop.width / crop.height) : 16.0 / 9.0
        let canvasAspect = edits.canvas.layout(contentAspect: contentAspect).canvasAspect

        var replaced: [Int: URL] = [:]
        for stem in edits.cleanedStems {
            let url = cleanedStemURL(of: item, stem: stem)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { replaced[stem] = url }
        }
        let log = cursorLog(of: item)

        return ClipRenderInput(
            source: source,
            camera: cameraURL(of: item),
            cameraOffset: item.clip.take?.cameraOffset ?? 0,
            segments: edits.resolvedSegments(in: duration),
            crop: edits.crop == .original ? nil : crop,
            canvas: edits.canvas,
            zooms: edits.zooms,
            blurs: edits.blurs,
            cursorLog: log,
            cursorStyle: edits.cursor,
            cursorSprites: log == nil ? [:] : CursorSprites.all,
            cameraPlacement: edits.camera.map { ($0.x, $0.y, $0.diameter) },
            audioTracks: audioTracks(of: item, edits: edits, count: audioCount),
            replacedAudio: replaced,
            overlays: includesOverlays ? overlays(for: item, edits: edits, canvasAspect: canvasAspect) : [],
            shortSide: settings?.resolution.shortSide,
            framerate: settings.flatMap { $0.framerate == .source ? nil : Double($0.framerate.rawValue) }
        )
    }

    /// Words, pictures, captions and — when asked — the speaking faces, each
    /// drawn for the canvas and timed on the source's clock.
    static func overlays(for item: ClipLibraryItem, edits: ClipEdits, canvasAspect: Double) -> [RenderedOverlay] {
        let aspect = CGFloat(canvasAspect)
        var overlays: [RenderedOverlay] = []
        for text in edits.texts {
            guard let drawn = ClipOverlayRenderer.render(text, aspect: aspect) else { continue }
            overlays.append(RenderedOverlay(image: drawn.image, frame: drawn.frame, start: text.start, end: text.end))
        }
        for image in edits.images {
            guard let drawn = ClipOverlayRenderer.render(image, assets: assetsFolder(of: item), aspect: aspect) else { continue }
            overlays.append(RenderedOverlay(image: drawn.image, frame: drawn.frame, start: image.start, end: image.end))
        }
        if edits.showsCaptions {
            for caption in edits.captions {
                guard let drawn = ClipOverlayRenderer.render(caption, style: edits.captionStyle, aspect: aspect) else { continue }
                overlays.append(RenderedOverlay(image: drawn.image, frame: drawn.frame, start: caption.start, end: caption.end))
            }
        }
        if edits.burnsInSpeaking, let manifest = item.clip.manifest {
            overlays += ClipOverlayRenderer.speakingFaces(manifest: manifest, aspect: aspect)
        }
        return overlays
    }
}

// MARK: - The system's cursors

/// The cursors a recording logged, drawn again from `NSCursor`'s own images
/// at twice their points — the artwork stays Apple's, taken at run time
/// (D9), never copied into the app.
enum CursorSprites {
    static var all: [CursorLog.Kind: CursorSprite] {
        if let cached { return cached }
        var sprites: [CursorLog.Kind: CursorSprite] = [:]
        let cursors: [(CursorLog.Kind, NSCursor)] = [
            (.arrow, .arrow), (.iBeam, .iBeam), (.pointingHand, .pointingHand), (.openHand, .openHand),
            (.closedHand, .closedHand), (.crosshair, .crosshair), (.resizeLeftRight, .columnResize),
            (.resizeUpDown, .rowResize), (.notAllowed, .operationNotAllowed), (.other, .arrow),
        ]
        for (kind, cursor) in cursors {
            if let sprite = sprite(cursor) { sprites[kind] = sprite }
        }
        // Never an empty cache: a process with no window server yet gets no
        // cursor pictures, and should not keep that answer.
        if !sprites.isEmpty { cached = sprites }
        return sprites
    }

    private static var cached: [CursorLog.Kind: CursorSprite]?

    private static func sprite(_ cursor: NSCursor) -> CursorSprite? {
        let image = cursor.image
        let points = image.size
        guard points.width > 0, points.height > 0 else { return nil }
        let scale: CGFloat = 2
        let width = Int((points.width * scale).rounded(.up))
        let height = Int((points.height * scale).rounded(.up))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSGraphicsContext.restoreGraphicsState()
        guard let picture = context.makeImage() else { return nil }
        return CursorSprite(
            image: picture,
            hotspot: CGPoint(x: cursor.hotSpot.x * scale, y: cursor.hotSpot.y * scale),
            pointSize: points
        )
    }
}
