import CoreGraphics
import Foundation

// MARK: - What the editor did to a clip
//
// docs/CLIPS-PRESENCE.md, D14 / Phase 4.3. **Edits are metadata; the file is
// never rewritten** — Discord's own rule (its `editMetadata {start, end,
// applicationAudio, voiceAudio, soundboardAudio, crop: {preset}}` and text
// `tracks`), kept in the clip's sidecar and applied only when the clip is
// exported or shared. A trim costs nothing and is undone by dragging back.

public struct ClipEdits: Codable, Hashable, Sendable {
    /// Seconds into the file the clip starts and ends at; nil end is the end.
    public var start: Double
    public var end: Double?
    public var crop: CropPreset
    /// Where the crop box sits along the axis it can move on, 0…1 — centred
    /// by default; the editor drags it.
    public var cropPosition: Double
    /// Audio tracks left out, by their place among the file's stems (the
    /// manifest's `tracks` order) — Discord's per-row switches.
    public var mutedTracks: Set<Int>
    public var texts: [TextOverlay]
    public var images: [ImageOverlay]
    /// A recording's camera, where its bubble sits — nil leaves it out.
    public var camera: CameraPlacement?

    // MARK: Editor v2 (Phase 5) — see `ClipSequence` and `ClipEffects`.

    /// The kept stretches, in order, each at its speed. Empty is the v1 trim:
    /// one stretch from `start` to `end` at 1×.
    public var segments: [ClipSegment]
    public var zooms: [ZoomBlock]
    /// How a recording's logged cursor is drawn again.
    public var cursor: CursorStyle
    public var canvas: ClipCanvas
    public var blurs: [BlurRegion]
    public var captions: [Caption]
    public var captionStyle: CaptionStyle
    public var showsCaptions: Bool
    /// Stems played through voice clean-up, by their place among the file's
    /// audio tracks.
    public var cleanedStems: Set<Int>
    /// D15's export option: the speaking faces drawn into the picture.
    public var burnsInSpeaking: Bool

    public init(
        start: Double = 0, end: Double? = nil, crop: CropPreset = .original, cropPosition: Double = 0.5,
        mutedTracks: Set<Int> = [], texts: [TextOverlay] = [], images: [ImageOverlay] = [],
        camera: CameraPlacement? = nil, segments: [ClipSegment] = [], zooms: [ZoomBlock] = [],
        cursor: CursorStyle = CursorStyle(), canvas: ClipCanvas = .plain, blurs: [BlurRegion] = [],
        captions: [Caption] = [], captionStyle: CaptionStyle = CaptionStyle(), showsCaptions: Bool = true,
        cleanedStems: Set<Int> = [], burnsInSpeaking: Bool = false
    ) {
        self.start = start
        self.end = end
        self.crop = crop
        self.cropPosition = cropPosition
        self.mutedTracks = mutedTracks
        self.texts = texts
        self.images = images
        self.camera = camera
        self.segments = segments
        self.zooms = zooms
        self.cursor = cursor
        self.canvas = canvas
        self.blurs = blurs
        self.captions = captions
        self.captionStyle = captionStyle
        self.showsCaptions = showsCaptions
        self.cleanedStems = cleanedStems
        self.burnsInSpeaking = burnsInSpeaking
    }

    private enum CodingKeys: String, CodingKey {
        case start, end, crop, cropPosition, mutedTracks, texts, images, camera
        case segments, zooms, cursor, canvas, blurs, captions, captionStyle, showsCaptions, cleanedStems, burnsInSpeaking
    }

    /// Lenient: a v1 sidecar has none of v2's keys, and a key this build does
    /// not know costs only itself.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end)
        crop = (try? c.decodeIfPresent(CropPreset.self, forKey: .crop)) ?? .original
        cropPosition = try c.decodeIfPresent(Double.self, forKey: .cropPosition) ?? 0.5
        mutedTracks = (try? c.decodeIfPresent(Set<Int>.self, forKey: .mutedTracks)) ?? []
        texts = (try? c.decodeIfPresent([TextOverlay].self, forKey: .texts)) ?? []
        images = (try? c.decodeIfPresent([ImageOverlay].self, forKey: .images)) ?? []
        camera = try? c.decodeIfPresent(CameraPlacement.self, forKey: .camera)
        segments = (try? c.decodeIfPresent([ClipSegment].self, forKey: .segments)) ?? []
        zooms = (try? c.decodeIfPresent([ZoomBlock].self, forKey: .zooms)) ?? []
        cursor = (try? c.decodeIfPresent(CursorStyle.self, forKey: .cursor)) ?? CursorStyle()
        canvas = (try? c.decodeIfPresent(ClipCanvas.self, forKey: .canvas)) ?? .plain
        blurs = (try? c.decodeIfPresent([BlurRegion].self, forKey: .blurs)) ?? []
        captions = (try? c.decodeIfPresent([Caption].self, forKey: .captions)) ?? []
        captionStyle = (try? c.decodeIfPresent(CaptionStyle.self, forKey: .captionStyle)) ?? CaptionStyle()
        showsCaptions = (try? c.decodeIfPresent(Bool.self, forKey: .showsCaptions)) ?? true
        cleanedStems = (try? c.decodeIfPresent(Set<Int>.self, forKey: .cleanedStems)) ?? []
        burnsInSpeaking = (try? c.decodeIfPresent(Bool.self, forKey: .burnsInSpeaking)) ?? false
    }

    /// Whether anything was changed at all — an untouched clip is shared as
    /// the file it is.
    public var isEmpty: Bool { self == ClipEdits() }

    /// The kept stretch, inside a file of `duration` seconds.
    public func range(in duration: Double) -> ClosedRange<Double> {
        let lower = min(max(0, start), duration)
        let upper = min(max(lower, end ?? duration), duration)
        return lower...upper
    }
}

/// Discord's crop presets (`CujCES` Original, `ywAdnD` 16:9, `34PW6m` 9:16).
public enum CropPreset: String, Codable, Hashable, Sendable, CaseIterable {
    case original
    case landscape
    case portrait

    public var title: String {
        switch self {
        case .original: "Original"
        case .landscape: "16:9"
        case .portrait: "9:16"
        }
    }

    /// The box this preset cuts out of a picture of `size`, the movable axis
    /// placed at `position` (0…1). In the picture's own pixels, top-left
    /// origin.
    public func rect(in size: CGSize, position: Double) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let ratio: CGFloat
        switch self {
        case .original: return CGRect(origin: .zero, size: size)
        case .landscape: ratio = 16.0 / 9.0
        case .portrait: ratio = 9.0 / 16.0
        }
        let clamped = CGFloat(min(1, max(0, position)))
        if size.width / size.height > ratio {
            // Wider than the box: full height, slide sideways.
            let width = (size.height * ratio).rounded(.down)
            return CGRect(x: ((size.width - width) * clamped).rounded(), y: 0, width: width, height: size.height)
        } else {
            let height = (size.width / ratio).rounded(.down)
            return CGRect(x: 0, y: ((size.height - height) * clamped).rounded(), width: size.width, height: height)
        }
    }
}

/// Discord's three sizes, and its stroke widths with None.
public enum OverlaySize: String, Codable, Hashable, Sendable, CaseIterable {
    case small, medium, large

    public var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

public enum StrokeWidth: String, Codable, Hashable, Sendable, CaseIterable {
    case none, small, medium, large

    public var title: String {
        switch self {
        case .none: "None"
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

/// Words over the picture for a stretch of the clip — Discord's text track.
public struct TextOverlay: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var start: Double
    public var end: Double
    /// The centre, in the cropped picture's 0…1 frame.
    public var x: Double
    public var y: Double
    public var size: OverlaySize
    /// sRGB, 0xRRGGBB.
    public var color: UInt32
    public var strokeColor: UInt32
    public var strokeWidth: StrokeWidth

    public init(
        id: UUID = UUID(), text: String, start: Double, end: Double, x: Double = 0.5, y: Double = 0.5,
        size: OverlaySize = .medium, color: UInt32 = 0xFF_FF_FF, strokeColor: UInt32 = 0x00_00_00,
        strokeWidth: StrokeWidth = .medium
    ) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.x = x
        self.y = y
        self.size = size
        self.color = color
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
    }

    /// Points per 1080 pixels of picture height — scaled with the picture.
    public var fontSize: Double {
        switch size {
        case .small: 48
        case .medium: 72
        case .large: 108
        }
    }

    /// The outline, as a share of the font size.
    public var strokeFraction: Double {
        switch strokeWidth {
        case .none: 0
        case .small: 0.04
        case .medium: 0.08
        case .large: 0.13
        }
    }
}

/// A picture over the clip — Discord's image track (PNG, JPEG or WebP, with
/// a shadow and its colour, in three sizes).
public struct ImageOverlay: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// The copy kept beside the clip (`.wingcord/assets/<file>`), by name.
    public var fileName: String
    public var start: Double
    public var end: Double
    public var x: Double
    public var y: Double
    public var size: OverlaySize
    public var hasShadow: Bool
    public var shadowColor: UInt32

    public init(
        id: UUID = UUID(), fileName: String, start: Double, end: Double, x: Double = 0.5, y: Double = 0.5,
        size: OverlaySize = .medium, hasShadow: Bool = true, shadowColor: UInt32 = 0x00_00_00
    ) {
        self.id = id
        self.fileName = fileName
        self.start = start
        self.end = end
        self.x = x
        self.y = y
        self.size = size
        self.hasShadow = hasShadow
        self.shadowColor = shadowColor
    }

    /// The overlay's width as a share of the picture's width.
    public var widthFraction: Double {
        switch size {
        case .small: 0.18
        case .medium: 0.3
        case .large: 0.45
        }
    }
}

/// A recording's camera bubble: its centre and diameter in the picture's 0…1
/// frame (diameter as a share of the picture's height).
public struct CameraPlacement: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var diameter: Double

    public init(x: Double = 0.86, y: Double = 0.8, diameter: Double = 0.3) {
        self.x = x
        self.y = y
        self.diameter = diameter
    }
}

extension ClipManifest {
    /// The timeline as it stands after a trim — Discord's `lz` measures from
    /// the edit's start and keeps what falls inside it, with the speakers at
    /// the start carried in at 0.
    public func timeline(trimmedTo range: ClosedRange<Double>) -> [ClipTimelineEvent] {
        var speaking: [ClipTimeline.SpeakingChange] = []
        var games: [ClipTimeline.GameMoment] = []
        var emotions: [ClipTimeline.EmotionMoment] = []
        for entry in timeline {
            let time = Double(entry.timestampMS) / 1_000
            switch entry.event {
            case .speaking(let userID, let flags):
                speaking.append(.init(time: time, userID: userID, flags: flags))
            case .game(let type, let name):
                games.append(.init(time: time, type: type, name: name))
            case .emotion(let emotion):
                emotions.append(.init(time: time, emotion: emotion))
            }
        }
        return ClipTimeline.events(
            start: range.lowerBound, end: range.upperBound,
            speaking: speaking, games: games, emotions: emotions
        )
    }
}
