import CoreGraphics
import Foundation

// MARK: - What editor v2 lays on a clip (docs/CLIPS-PRESENCE.md, D14 / 5.1)
//
// Slice's tools (§2.5), our own: zooms (Smart Zoom suggests them from the
// clicks a recording logged), the cursor drawn again from its log, a canvas
// the picture sits on, blurred regions, captions. What belongs to the screen
// is timed in the source's seconds and placed in the source picture's 0…1
// frame (top-left origin), so it stays on what it marks through cuts, speed,
// crops and zooms.

// MARK: Zoom

/// The picture zoomed in on a point for a stretch of the source.
public struct ZoomBlock: Codable, Hashable, Sendable, Identifiable {
    public static let scales: ClosedRange<Double> = 1.1...4
    /// How long the zoom takes to arrive and to leave, inside its stretch.
    public static let transition = 0.45

    public var id: UUID
    public var start: Double
    public var end: Double
    public var scale: Double
    /// Where it looks, in the source picture's 0…1 frame.
    public var x: Double
    public var y: Double
    /// Looks where the cursor is instead, when a recording logged one.
    public var followsCursor: Bool
    /// Suggested by Smart Zoom rather than placed by hand.
    public var isSuggested: Bool

    public init(
        id: UUID = UUID(), start: Double, end: Double, scale: Double = 2, x: Double = 0.5, y: Double = 0.5,
        followsCursor: Bool = false, isSuggested: Bool = false
    ) {
        self.id = id
        self.start = start
        self.end = max(start, end)
        self.scale = min(max(scale, Self.scales.lowerBound), Self.scales.upperBound)
        self.x = x
        self.y = y
        self.followsCursor = followsCursor
        self.isSuggested = isSuggested
    }

    /// 0 before and after, 1 through the middle, eased in between.
    public func weight(at time: Double) -> Double {
        guard time >= start, time <= end else { return 0 }
        let ramp = min(Self.transition, (end - start) / 2)
        guard ramp > 0 else { return 1 }
        let edge = min(time - start, end - time)
        guard edge < ramp else { return 1 }
        let t = edge / ramp
        return t * t * (3 - 2 * t)
    }
}

/// The zoom at one moment: how far in, on which point of the source.
public struct ZoomState: Hashable, Sendable {
    public var scale: Double
    public var x: Double
    public var y: Double

    public static let none = ZoomState(scale: 1, x: 0.5, y: 0.5)

    public init(scale: Double, x: Double, y: Double) {
        self.scale = scale
        self.x = x
        self.y = y
    }

    /// The source's box on screen at this zoom, in its 0…1 frame — the point
    /// held as near the middle as the edges allow.
    public var visibleRect: CGRect {
        let side = 1 / max(scale, 1)
        let x = min(max(0, self.x - side / 2), 1 - side)
        let y = min(max(0, self.y - side / 2), 1 - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }
}

extension Array where Element == ZoomBlock {
    /// The zoom at `time`: the strongest block there, eased from the whole
    /// picture.
    public func state(at time: Double, cursor: CGPoint? = nil) -> ZoomState {
        var best: (weight: Double, block: ZoomBlock)?
        for block in self {
            let weight = block.weight(at: time)
            guard weight > 0 else { continue }
            if best == nil || block.scale * weight > best!.block.scale * best!.weight { best = (weight, block) }
        }
        guard let best else { return .none }
        let target = best.block.followsCursor && cursor != nil
            ? (x: Double(cursor!.x), y: Double(cursor!.y))
            : (x: best.block.x, y: best.block.y)
        let w = best.weight
        return ZoomState(
            scale: 1 + (best.block.scale - 1) * w,
            x: 0.5 + (target.x - 0.5) * w,
            y: 0.5 + (target.y - 0.5) * w
        )
    }
}

public enum SmartZoom {
    /// Clicks closer together than this make one zoom.
    public static let gap = 2.5

    /// Zooms on where a recording was clicked: each run of clicks, from a
    /// moment before the first to a moment after the last, centred on them.
    public static func suggestions(from log: CursorLog, duration: Double, scale: Double = 1.8) -> [ZoomBlock] {
        let presses = log.clicks.filter { $0.isDown && $0.button == 0 && $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }
            .sorted { $0.t < $1.t }
        var runs: [[CursorLog.Click]] = []
        for press in presses {
            if let last = runs.last?.last, press.t - last.t <= gap {
                runs[runs.count - 1].append(press)
            } else {
                runs.append([press])
            }
        }
        var blocks: [ZoomBlock] = []
        for run in runs {
            guard let first = run.first, let last = run.last else { continue }
            var start = max(0, first.t - 0.6)
            var end = min(duration, last.t + 1.6)
            if end - start < 1.6 {
                let middle = (start + end) / 2
                start = max(0, middle - 0.8)
                end = min(duration, middle + 0.8)
            }
            let x = run.map(\.x).reduce(0, +) / Double(run.count)
            let y = run.map(\.y).reduce(0, +) / Double(run.count)
            if var previous = blocks.last, start <= previous.end {
                previous.end = max(previous.end, end)
                previous.x = (previous.x + x) / 2
                previous.y = (previous.y + y) / 2
                blocks[blocks.count - 1] = previous
            } else {
                blocks.append(ZoomBlock(start: start, end: end, scale: scale, x: x, y: y, isSuggested: true))
            }
        }
        return blocks
    }
}

// MARK: Cursor

/// How a recording's cursor is drawn again.
public struct CursorStyle: Codable, Hashable, Sendable {
    public static let sizes: ClosedRange<Double> = 0.5...3

    public var isVisible: Bool
    /// Times the system cursor's size.
    public var size: Double
    /// 0 follows every sample; 1 glides.
    public var smoothing: Double
    /// A ring where each click lands.
    public var showsClicks: Bool

    public init(isVisible: Bool = true, size: Double = 1.5, smoothing: Double = 0.5, showsClicks: Bool = true) {
        self.isVisible = isVisible
        self.size = min(max(size, Self.sizes.lowerBound), Self.sizes.upperBound)
        self.smoothing = min(max(smoothing, 0), 1)
        self.showsClicks = showsClicks
    }

    /// How long a click's ring lasts.
    public static let clickRing = 0.45
}

extension CursorLog {
    /// Where the cursor was at `time`, eased over a window that grows with
    /// `smoothing` — nil before the first sample or while it was outside.
    public func position(at time: Double, smoothing: Double) -> CGPoint? {
        let window = 0.02 + 0.3 * min(max(smoothing, 0), 1)
        let nearby = samples.filter { abs($0.t - time) <= window && !$0.isOutside }
        guard !nearby.isEmpty else { return position(at: time).map { CGPoint(x: $0.x, y: $0.y) } }
        var total = 0.0
        var x = 0.0
        var y = 0.0
        for sample in nearby {
            let weight = 1 - abs(sample.t - time) / (window * 1.0001)
            total += weight
            x += sample.x * weight
            y += sample.y * weight
        }
        guard total > 0 else { return nil }
        return CGPoint(x: x / total, y: y / total)
    }

    /// The cursor's shape at `time`.
    public func kind(at time: Double) -> Kind {
        samples.last { $0.t <= time }?.kind ?? samples.first?.kind ?? .arrow
    }

    /// Clicks whose ring is showing at `time`, with how far along each is.
    public func rings(at time: Double) -> [(click: Click, progress: Double)] {
        clicks.compactMap { click in
            guard click.isDown, time >= click.t, time < click.t + CursorStyle.clickRing else { return nil }
            return (click, (time - click.t) / CursorStyle.clickRing)
        }
    }
}

// MARK: Canvas

/// The shape the result is, and what the picture sits on.
public struct ClipCanvas: Codable, Hashable, Sendable {
    public enum Aspect: String, Codable, Hashable, Sendable, CaseIterable {
        case auto, landscape, portrait, square, standard

        public var title: String {
            switch self {
            case .auto: "Auto"
            case .landscape: "16:9"
            case .portrait: "9:16"
            case .square: "1:1"
            case .standard: "4:3"
            }
        }

        public var ratio: Double? {
            switch self {
            case .auto: nil
            case .landscape: 16.0 / 9.0
            case .portrait: 9.0 / 16.0
            case .square: 1
            case .standard: 4.0 / 3.0
            }
        }
    }

    public enum Background: Codable, Hashable, Sendable {
        case none
        case solid(UInt32)
        case gradient(UInt32, UInt32, angle: Double)
    }

    public var aspect: Aspect
    public var background: Background
    /// Space round the picture, as a share of the canvas's shorter side.
    public var padding: Double
    /// The picture's corners, as a share of its shorter side.
    public var cornerRadius: Double
    /// 0 none … 1 deep.
    public var shadow: Double

    public init(aspect: Aspect = .auto, background: Background = .none, padding: Double = 0, cornerRadius: Double = 0, shadow: Double = 0) {
        self.aspect = aspect
        self.background = background
        self.padding = min(max(padding, 0), 0.3)
        self.cornerRadius = min(max(cornerRadius, 0), 0.15)
        self.shadow = min(max(shadow, 0), 1)
    }

    public static let plain = ClipCanvas()

    /// Nothing to draw: the result is the (cropped) picture itself.
    public var isPlain: Bool { aspect == .auto && background == .none && padding == 0 && cornerRadius == 0 }

    /// Ready-made looks, Slice-like: a background and a frame together.
    public static let presets: [(name: String, canvas: ClipCanvas)] = [
        ("Dusk", ClipCanvas(background: .gradient(0x2E_1A_47, 0xF4_A2_61, angle: 135), padding: 0.06, cornerRadius: 0.025, shadow: 0.6)),
        ("Ocean", ClipCanvas(background: .gradient(0x0F_2A_3D, 0x56_C2_C9, angle: 90), padding: 0.06, cornerRadius: 0.025, shadow: 0.6)),
        ("Blurple", ClipCanvas(background: .gradient(0x58_65_F2, 0xEB_45_9E, angle: 45), padding: 0.06, cornerRadius: 0.025, shadow: 0.6)),
        ("Graphite", ClipCanvas(background: .solid(0x1E_1F_22), padding: 0.05, cornerRadius: 0.02, shadow: 0.5)),
    ]

    /// Where the picture sits on the canvas, in the canvas's 0…1 frame, and
    /// the canvas's width over height — for a picture `content` wide over tall.
    public func layout(contentAspect content: Double) -> (canvasAspect: Double, content: CGRect) {
        let ratio = max(content, 0.01)
        guard let canvas = aspect.ratio else {
            // Auto: the picture's own shape with the padding round it.
            let pad = padding
            // In content-height units: the canvas is (ratio + 2p) × (1 + 2p).
            let canvasAspect = (ratio + 2 * pad) / (1 + 2 * pad)
            let width = ratio / (ratio + 2 * pad)
            let height = 1 / (1 + 2 * pad)
            return (canvasAspect, CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height))
        }
        // A fixed shape: the picture fitted inside what the padding leaves.
        let shorter = min(canvas, 1)
        let insetX = padding * shorter / canvas
        let insetY = padding * shorter
        let availableWidth = max(0.05, 1 - 2 * insetX)
        let availableHeight = max(0.05, 1 - 2 * insetY)
        var width = availableWidth
        var height = width * canvas / ratio
        if height > availableHeight {
            height = availableHeight
            width = height * ratio / canvas
        }
        return (canvas, CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height))
    }
}

// MARK: Blur

/// Part of the screen hidden for a stretch — a name, a number, a message.
public struct BlurRegion: Codable, Hashable, Sendable, Identifiable {
    public enum Style: String, Codable, Hashable, Sendable, CaseIterable {
        case blur, pixelate

        public var title: String { self == .blur ? "Blur" : "Pixelate" }
    }

    public var id: UUID
    public var start: Double
    public var end: Double
    /// In the source picture's 0…1 frame.
    public var rect: CGRect
    public var style: Style
    /// 0…1.
    public var strength: Double

    public init(id: UUID = UUID(), start: Double, end: Double, rect: CGRect = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.2),
                style: Style = .blur, strength: Double = 0.6) {
        self.id = id
        self.start = start
        self.end = max(start, end)
        self.rect = rect
        self.style = style
        self.strength = min(max(strength, 0), 1)
    }
}

// MARK: Captions

/// One line of what was said, for a stretch of the source.
public struct Caption: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var text: String

    public init(id: UUID = UUID(), start: Double, end: Double, text: String) {
        self.id = id
        self.start = start
        self.end = max(start, end)
        self.text = text
    }

    /// One recognised word and when it was said.
    public struct Word: Hashable, Sendable {
        public var text: String
        public var start: Double
        public var end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// Words gathered into lines a reader can take in at a glance: a line
    /// ends at a pause, past `maxCharacters`, or past `maxDuration`.
    public static func lines(
        from words: [Word], maxCharacters: Int = 42, maxDuration: Double = 3.5, pause: Double = 0.7
    ) -> [Caption] {
        var lines: [Caption] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
                .replacingOccurrences(of: " ,", with: ",").replacingOccurrences(of: " .", with: ".")
            lines.append(Caption(start: first.start, end: last.end, text: text))
            current = []
        }
        for word in words where !word.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if let first = current.first, let last = current.last {
                let length = current.map(\.text.count).reduce(0, +) + current.count + word.text.count
                if word.start - last.end > pause || length > maxCharacters || word.end - first.start > maxDuration {
                    flush()
                }
            }
            current.append(Word(text: word.text.trimmingCharacters(in: .whitespaces), start: word.start, end: word.end))
        }
        flush()
        return lines
    }
}

/// How captions are drawn.
public struct CaptionStyle: Codable, Hashable, Sendable {
    public enum Placement: String, Codable, Hashable, Sendable, CaseIterable {
        case bottom, top

        public var title: String { self == .bottom ? "Bottom" : "Top" }
    }

    public var size: OverlaySize
    public var placement: Placement
    /// A dark box behind the words.
    public var hasBackground: Bool

    public init(size: OverlaySize = .medium, placement: Placement = .bottom, hasBackground: Bool = true) {
        self.size = size
        self.placement = placement
        self.hasBackground = hasBackground
    }

    /// Points per 1080 pixels of canvas height.
    public var fontSize: Double {
        switch size {
        case .small: 34
        case .medium: 46
        case .large: 62
        }
    }
}

// MARK: Export

/// What an export is written as — the editor's Export sheet.
public struct ClipExportSettings: Codable, Hashable, Sendable {
    public enum Format: String, Codable, Hashable, Sendable, CaseIterable {
        case mp4, gif

        public var title: String { self == .mp4 ? "MP4" : "GIF" }
    }

    public enum Resolution: String, Codable, Hashable, Sendable, CaseIterable {
        case original, p720, p1080, p1440, p2160

        public var title: String {
            switch self {
            case .original: "Original"
            case .p720: "720p"
            case .p1080: "1080p"
            case .p1440: "1440p"
            case .p2160: "4K"
            }
        }

        /// The tallest the picture is written at — the shorter side for a
        /// portrait canvas.
        public var shortSide: Int? {
            switch self {
            case .original: nil
            case .p720: 720
            case .p1080: 1_080
            case .p1440: 1_440
            case .p2160: 2_160
            }
        }
    }

    public enum Framerate: Int, Codable, Hashable, Sendable, CaseIterable {
        case source = 0, thirty = 30, sixty = 60

        public var title: String {
            switch self {
            case .source: "Same as Source"
            case .thirty: "30 fps"
            case .sixty: "60 fps"
            }
        }
    }

    public var format: Format
    public var resolution: Resolution
    public var framerate: Framerate

    public init(format: Format = .mp4, resolution: Resolution = .p1080, framerate: Framerate = .source) {
        self.format = format
        self.resolution = resolution
        self.framerate = framerate
    }

    /// A GIF's own ceilings: small, few frames, so it stays a GIF and not a
    /// file nobody can open.
    public static let gifShortSide = 480
    public static let gifFramerate = 15.0
}
