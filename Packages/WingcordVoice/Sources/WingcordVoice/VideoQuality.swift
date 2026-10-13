import Foundation

// MARK: - What a publisher's subscribers want, and what that buys
//
// **The server says how much of our picture it wants, and a client that never
// reads it encodes for nobody in particular.** Voice opcode 15 carries a want
// per SSRC — 0…100 — and the pixel count each SSRC's viewers draw it at.
// Discord's client turns a want into a rung on a fixed ladder and the rung into
// an encode size and a bitrate band; this file is that, ported from its web
// bundle (modules 4511, 466376, 429430 and the constants in 731854), so a
// camera here sends what a Discord camera would send to the same room.

/// Voice opcode 15, as the server sends it to a publisher.
///
/// Measured shapes: `{"any":0,"95747":100}` on a call, and
/// `{"pixelCounts":{"91568":0},"any":100}` on a share. Every key that is not
/// `any` or `pixelCounts` is an SSRC.
public struct MediaSinkWants: Sendable, Equatable, Codable, CustomStringConvertible {
    /// The want for any stream not named, 0…100.
    var any: Int?
    /// The want for each named SSRC, 0…100.
    var bySSRC: [UInt32: Int] = [:]
    /// How many pixels each SSRC's viewers will draw it at.
    var pixelCounts: [UInt32: Int] = [:]

    init(any: Int? = nil, bySSRC: [UInt32: Int] = [:], pixelCounts: [UInt32: Int] = [:]) {
        self.any = any
        self.bySSRC = bySSRC
        self.pixelCounts = pixelCounts
    }

    /// As the wire said it, for the trace: `any=100 95747=100 px95747=921600`.
    public var description: String {
        var parts: [String] = any.map { ["any=\($0)"] } ?? []
        parts += bySSRC.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        parts += pixelCounts.sorted { $0.key < $1.key }.map { "px\($0.key)=\($0.value)" }
        return parts.joined(separator: " ")
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// **Numbers as doubles, and anything else skipped.** A want is a small
    /// integer and a pixel count a large one, and JSON says neither; a key this
    /// reader does not know is the server adding something, which is no reason
    /// to throw the wants away.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        for key in container.allKeys {
            switch key.stringValue {
            case "any":
                any = (try? container.decode(Double.self, forKey: key)).map { Int($0) }
            case "pixelCounts":
                guard let counts = try? container.nestedContainer(keyedBy: Key.self, forKey: key)
                else { continue }
                for ssrc in counts.allKeys {
                    guard let id = UInt32(ssrc.stringValue),
                          let value = try? counts.decode(Double.self, forKey: ssrc)
                    else { continue }
                    pixelCounts[id] = Int(value)
                }
            default:
                guard let id = UInt32(key.stringValue),
                      let value = try? container.decode(Double.self, forKey: key)
                else { continue }
                bySSRC[id] = Int(value)
            }
        }
    }

    /// As this end sends it — Discord's desktop shape: `any`, then each named
    /// SSRC as a string key. Pixel counts are the server's to say.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        if let any { try container.encode(any, forKey: Key(stringValue: "any")) }
        for (ssrc, want) in bySSRC {
            try container.encode(want, forKey: Key(stringValue: String(ssrc)))
        }
    }
}

/// What our encoder should produce, and the bitrate band it may move in.
struct VideoQuality: Sendable, Equatable {
    var width: Int
    var height: Int
    var framerate: Int
    var bitrateMin: Int
    var bitrateMax: Int
}

/// Discord's numbers for both, from its constants module.
enum VideoQualityPolicy {
    /// What a camera captures at, and the budget its ladder divides.
    static let capture = (width: 1_280, height: 720, framerate: 30)
    static let cameraBitrate = (min: 150_000, max: 2_500_000)
    /// No stream is ever asked for less than this.
    static let bitrateFloor = 150_000
    /// A share's default band: 720p30, from 500 kbit/s up to 3.5 Mbit/s.
    ///
    /// **It starts at the top, where Discord's starts at 600 kbit/s.** Discord's
    /// engine probes the path and climbs in a second or two; this one has only
    /// receiver reports to climb on, at eight per cent a second, and a share
    /// that opened at 600 kbit/s would be unreadable text for the twenty
    /// seconds that takes. So it opens at the ceiling and comes down on loss —
    /// as a camera does in Discord's own.
    static let shareBitrate = (min: 500_000, max: 3_500_000)
    /// A share's ceiling above 720p30: Discord's `setDesktopEncodingOptions`
    /// gives 9 Mbit/s to anything taller than 720, faster than 30 frames a
    /// second, or at Source resolution from ten frames a second up — and
    /// 3.5 Mbit/s to the rest.
    static let shareBitrateHigh = 9_000_000

    /// The band for a share in a box of this height at this rate.
    ///
    /// **The box, not the picture fitted inside it.** Source is a box this
    /// client caps at 2160 lines, so a small window shared at Source still
    /// gets Source's ceiling — as Discord's, which asks whether the choice was
    /// Source rather than how big the window is.
    static func shareBand(boxHeight: Int, framerate: Int) -> (min: Int, max: Int) {
        let isHigh = boxHeight > 720 || framerate > 30
        return (shareBitrate.min, isHigh ? shareBitrateHigh : shareBitrate.max)
    }
    /// The least a viewer-scaled share may spend: two hundredths of a bit per
    /// pixel per frame.
    static let shareBitsPerPixelFrame = 0.02
    /// The want of a stream at full quality, and what op 12 calls quality 100.
    static let fullWant = 100

    /// How much of our stream the server wants — Discord's `getLocalWant`.
    ///
    /// The want named for the SSRC if it is above zero; otherwise `any` if that
    /// is; otherwise a hundred. **Zero is never the answer for a stream at
    /// quality 100**, which is every stream this client announces: a server
    /// that says `"any":0` beside a named want of a hundred is asking for the
    /// named one, and one that names nothing is asking for all of it.
    static func want(for ssrc: UInt32, in wants: MediaSinkWants?) -> Int {
        if let named = wants?.bySSRC[ssrc], named > 0 { return named }
        if let any = wants?.any, any > 0 { return any }
        return fullWant
    }

    /// A camera's quality for a want — Discord's `getVideoQuality`.
    ///
    /// - Parameters:
    ///   - isMuted: the framerate reducer's verdict; see `FramerateReducer`.
    ///   - isFull: the channel's "720p" video quality, which fixes the encode
    ///     size and leaves the bitrate band to the want, exactly as Discord's
    ///     override does.
    static func camera(want: Int, isMuted: Bool, isFull: Bool) -> VideoQuality {
        let rung = VideoLadder.rung(for: want)
        return VideoQuality(
            width: isFull ? capture.width : rung.width,
            height: isFull ? capture.height : rung.height,
            framerate: isMuted ? rung.mutedFramerate : rung.framerate,
            bitrateMin: max(Int(Double(cameraBitrate.min) * rung.budgetPortion), bitrateFloor),
            bitrateMax: max(Int(Double(cameraBitrate.max) * rung.budgetPortion), bitrateFloor)
        )
    }

    /// A share's quality for the pixels its viewers draw — Discord's
    /// `getGoliveQuality`.
    ///
    /// **The picture keeps its size; the bitrate follows the viewers.** When
    /// everybody watching draws the share smaller than it is encoded, the band
    /// is scaled down by the same proportion — but never below what the
    /// picture needs at two hundredths of a bit per pixel per frame, nor below
    /// the floor. A pixel count of zero is a server saying nothing about its
    /// viewers, and buys the whole band.
    static func share(maximum: VideoQuality, viewerPixels: Int) -> VideoQuality {
        let encoded = maximum.width * maximum.height
        guard viewerPixels > 0, viewerPixels < encoded else { return maximum }
        func scaled(_ value: Int) -> Int {
            Int((Double(value) * Double(viewerPixels) / Double(encoded)).rounded(.up))
        }
        let needed = min(
            Int(shareBitsPerPixelFrame * Double(encoded * maximum.framerate)),
            maximum.bitrateMax
        )
        var quality = maximum
        quality.bitrateMin = max(scaled(maximum.bitrateMin), bitrateFloor)
        quality.bitrateMax = max(scaled(maximum.bitrateMax), needed)
        return quality
    }
}

/// Discord's camera ladder: which picture each want buys.
///
/// Every 16:9 size whose sides are whole macroblocks give or take the
/// alignment Discord allows (a remainder of 0, 4, 8 or 10 on both), and for one
/// to twenty-five streams sharing a 1280×720 budget, the largest that fits.
/// Each time the answer changes it takes the next want down from a hundred, in
/// tens:
///
/// | want | size | share of the budget |
/// |---|---|---|
/// | 100 | 1280×720 | 1 |
/// | 90 | 896×504 | 0.49 |
/// | 80 | 672×378 | 0.28 |
/// | 70 | 640×360 | 0.25 |
/// | 60 | 512×288 | 0.16 |
/// | 50 | 416×234 | 0.11 |
/// | 40 | 384×216 | 0.09 |
/// | 30 | 320×180 | 0.06 |
/// | 20 | 256×144 | 0.04 |
enum VideoLadder {
    struct Rung: Sendable, Equatable {
        var want: Int
        var width: Int
        var height: Int
        var budgetPortion: Double
        /// The rate when the framerate reducer says nobody needs more: twelve
        /// at the bottom two rungs' worth of want, twenty above.
        var mutedFramerate: Int
        var framerate: Int
    }

    /// Ascending by want.
    static let rungs: [Rung] = build(budget: VideoQualityPolicy.capture.width * VideoQualityPolicy.capture.height)

    /// The highest rung whose want is at most `want`, or the lowest rung for a
    /// want below every rung.
    static func rung(for want: Int) -> Rung {
        rungs.last { $0.want <= want } ?? rungs[0]
    }

    /// What this end asks of one stream when `streams` are being received —
    /// Discord's `getMaxSinkValue` (module 4511): the largest rung that fits
    /// `streams` times into the budget, or, when the picture is drawn at
    /// `drawnPixels`, the first rung bigger than that.
    ///
    /// | streams | want | | streams | want |
    /// |---|---|---|---|---|
    /// | 0–1 | 100 | | 7–9 | 50 |
    /// | 2 | 90 | | 10–11 | 40 |
    /// | 3 | 80 | | 12–16 | 30 |
    /// | 4 | 70 | | 17 and more | 20 |
    /// | 5–6 | 60 | | | |
    static func maxSinkValue(streams: Int, drawnPixels: Int = 0) -> Int {
        let budget = VideoQualityPolicy.capture.width * VideoQualityPolicy.capture.height
        var want = rungs[0].want
        for rung in rungs {
            let pixels = rung.width * rung.height
            if drawnPixels > 0, drawnPixels < pixels { return rung.want }
            if pixels * max(0, streams) > budget { break }
            want = rung.want
        }
        return want
    }

    private static func build(budget: Int) -> [Rung] {
        let aligned: Set<Int> = [0, 4, 8, 10]
        var sizes: [(width: Int, height: Int)] = []
        for height in 1..<4_096 where (16 * height) % 9 == 0 {
            let width = 16 * height / 9
            guard aligned.contains(width % 16), aligned.contains(height % 16) else { continue }
            sizes.append((width, height))
        }
        var rungs: [Rung] = []
        var want = VideoQualityPolicy.fullWant
        var previousWidth = 0
        for streams in 1...25 {
            guard let size = sizes.last(where: { $0.width * $0.height * streams <= budget })
            else { continue }
            guard size.width != previousWidth else { continue }
            previousWidth = size.width
            rungs.append(Rung(
                want: want,
                width: size.width,
                height: size.height,
                budgetPortion: Double(size.width * size.height) / Double(budget),
                mutedFramerate: want <= 20 ? 12 : 20,
                framerate: VideoQualityPolicy.capture.framerate
            ))
            want -= 10
        }
        return rungs.reversed()
    }
}

/// Discord's framerate reducer: a camera whose owner has not spoken for
/// fifteen seconds drops to its rung's muted rate, and comes back the moment
/// they speak.
///
/// **Muting does it at once.** Somebody who mutes has said they are not about
/// to talk, and the reducer takes them at their word; unmuting restores the
/// rate without starting the clock again, which starts on the next silence.
/// A share never reduces: a screen at rest is still a screen somebody is
/// reading.
struct FramerateReducer: Sendable {
    static let delay: Duration = .seconds(15)

    private(set) var isMuted = false
    private var silentSince: ContinuousClock.Instant?

    init(now: ContinuousClock.Instant) {
        // Discord's own starts as though the speaker just fell silent.
        silentSince = now
    }

    /// Our own gate opened or closed. Returns whether the verdict changed.
    mutating func speaking(_ isSpeaking: Bool, at now: ContinuousClock.Instant) -> Bool {
        if isSpeaking {
            silentSince = nil
            return set(false)
        }
        silentSince = now
        return false
    }

    /// The microphone was muted or unmuted.
    mutating func selfMuted(_ muted: Bool) -> Bool {
        silentSince = nil
        return set(muted)
    }

    /// Asked on the session's tick: has the silence lasted long enough?
    mutating func tick(at now: ContinuousClock.Instant) -> Bool {
        guard let since = silentSince, now - since >= Self.delay else { return false }
        silentSince = nil
        return set(true)
    }

    private mutating func set(_ muted: Bool) -> Bool {
        guard muted != isMuted else { return false }
        isMuted = muted
        return true
    }
}
