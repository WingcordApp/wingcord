import CoreGraphics
import Foundation

// MARK: - A recording from the capture bar
//
// docs/CLIPS-PRESENCE.md, D12 / Phase 3.7. **A take is separate files**, put
// together only when it is played or exported — the shape Slice taught (§2.5),
// in Wingcord's own words: the screen with the cursor left out, the camera,
// the microphone and the system's sound as tracks of their own, and a log of
// where the cursor went. An editor can then move the camera, smooth the
// cursor or drop the microphone without anything having been burnt in.
//
//     <name>.wingcordtake/
//         take.json      this
//         screen.mov     the picture, the system's sound, the microphone
//         camera.mov     the camera, when it was on
//         cursor.json    `CursorLog`

public struct TakeManifest: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let fileName = "take.json"
    public static let screenFile = "screen.mov"
    public static let cameraFile = "camera.mov"
    public static let cursorFile = "cursor.json"
    /// The package's extension.
    public static let pathExtension = "wingcordtake"

    /// What was recorded.
    public enum Source: Codable, Hashable, Sendable {
        case display(name: String)
        case window(title: String, application: String)
        /// Part of a display, in that display's points from its top left.
        case area(display: String, rect: CGRect)
    }

    public var version: Int
    public var id: UUID
    public var createdAt: Date
    /// Seconds of screen.
    public var duration: Double
    public var source: Source
    /// The screen's picture, in pixels.
    public var width: Int
    public var height: Int
    public var framerate: Int
    public var hasSystemAudio: Bool
    public var hasMicrophone: Bool
    public var hasCamera: Bool
    /// Seconds the camera's first frame comes after the screen's — the two
    /// files start a moment apart.
    public var cameraOffset: Double
    public var hasCursorLog: Bool
    /// What the editor did — nil for a take nobody has opened.
    public var edits: ClipEdits?

    public init(
        id: UUID = UUID(), createdAt: Date, duration: Double, source: Source, width: Int, height: Int,
        framerate: Int, hasSystemAudio: Bool, hasMicrophone: Bool, hasCamera: Bool,
        cameraOffset: Double = 0, hasCursorLog: Bool
    ) {
        version = Self.currentVersion
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.source = source
        self.width = width
        self.height = height
        self.framerate = framerate
        self.hasSystemAudio = hasSystemAudio
        self.hasMicrophone = hasMicrophone
        self.hasCamera = hasCamera
        self.cameraOffset = cameraOffset
        self.hasCursorLog = hasCursorLog
    }

    /// A line for a list: what, how long.
    public var summary: String {
        let what: String = switch source {
        case .display(let name): name
        case .window(let title, let application): title.isEmpty ? application : "\(application) — \(title)"
        case .area: "Part of the screen"
        }
        return what
    }
}

// MARK: - Where the cursor went

/// The cursor through a take, **in the recorded picture's own frame**: 0…1
/// from its top left, so it lands right however the picture is scaled.
///
/// Sampled at sixty a second while it moves, with every click and scroll
/// exact — enough for an editor to draw a cursor of its own over a picture
/// recorded without one, smoothed, enlarged or hidden, and to zoom towards
/// where somebody clicked.
public struct CursorLog: Codable, Hashable, Sendable {
    /// What the cursor looked like — the system cursors an editor can draw
    /// again by name. `other` is anything an app drew for itself.
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case arrow, iBeam, pointingHand, openHand, closedHand, crosshair
        case resizeLeftRight, resizeUpDown, notAllowed, other
    }

    public struct Sample: Codable, Hashable, Sendable {
        /// Seconds from the take's start.
        public var t: Double
        public var x: Double
        public var y: Double
        public var kind: Kind
        /// Outside the recorded picture — a window's capture with the cursor
        /// off it.
        public var isOutside: Bool

        public init(t: Double, x: Double, y: Double, kind: Kind, isOutside: Bool = false) {
            self.t = t
            self.x = x
            self.y = y
            self.kind = kind
            self.isOutside = isOutside
        }
    }

    public struct Click: Codable, Hashable, Sendable {
        public var t: Double
        public var x: Double
        public var y: Double
        /// 0 primary, 1 secondary, 2 and on the others.
        public var button: Int
        public var isDown: Bool

        public init(t: Double, x: Double, y: Double, button: Int, isDown: Bool) {
            self.t = t
            self.x = x
            self.y = y
            self.button = button
            self.isDown = isDown
        }
    }

    public struct Scroll: Codable, Hashable, Sendable {
        public var t: Double
        public var dx: Double
        public var dy: Double

        public init(t: Double, dx: Double, dy: Double) {
            self.t = t
            self.dx = dx
            self.dy = dy
        }
    }

    public var samples: [Sample] = []
    public var clicks: [Click] = []
    public var scrolls: [Scroll] = []

    public init() {}

    /// A point in global screen space (points, top-left origin) as a place in
    /// `frame`, the recorded picture's own frame in the same space.
    public static func normalise(_ point: CGPoint, in frame: CGRect) -> (x: Double, y: Double, isOutside: Bool) {
        guard frame.width > 0, frame.height > 0 else { return (0, 0, true) }
        let x = Double((point.x - frame.minX) / frame.width)
        let y = Double((point.y - frame.minY) / frame.height)
        return (x, y, x < 0 || x > 1 || y < 0 || y > 1)
    }

    /// Where the cursor was at `time`, between the samples around it.
    public func position(at time: Double) -> (x: Double, y: Double)? {
        guard let after = samples.firstIndex(where: { $0.t >= time }) else {
            return samples.last.map { ($0.x, $0.y) }
        }
        guard after > 0 else { return (samples[0].x, samples[0].y) }
        let a = samples[after - 1], b = samples[after]
        let span = b.t - a.t
        let progress = span > 0 ? (time - a.t) / span : 1
        return (a.x + (b.x - a.x) * progress, a.y + (b.y - a.y) * progress)
    }
}
