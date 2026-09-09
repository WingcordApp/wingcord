import Foundation

/// Finds the coded frames in a WebM file.
///
/// **A demuxer, and nothing else.** It reads EBML, walks Matroska's element
/// tree, and hands back the byte ranges of the frames plus the timeline they sit
/// on. It decodes nothing and knows nothing about VP9 beyond the four letters of
/// a codec id — `VP9Decoder` turns the bytes into pixels and `WebMFilmstrip`
/// turns those into the same `AnimatedImage` every other moving picture in this
/// app is.
///
/// It exists because **AVFoundation cannot open a WebM on any Apple platform**,
/// and Discord serves every animated nameplate as one: `…/asset.webm`, VP9 with
/// alpha. `CGImageSource` cannot read it either, so without this the plate a
/// reader paid for is a still.
///
/// ## The alpha is a second video stream, not a fourth channel
///
/// VP9 has no alpha. WebM carries it as a **separate, complete VP9 bitstream**
/// beside each frame — the `BlockAdditional` under `BlockAddID` 1 — whose luma
/// plane *is* the alpha channel. That is why every frame here has two byte
/// ranges, and why the track's `hasAlpha` is read off `AlphaMode` in the video
/// element rather than guessed from the codec.
///
/// A block carrying additions cannot be a `SimpleBlock` — additions live in a
/// `BlockGroup` — so an asset with alpha is all `BlockGroup`s and one without is
/// all `SimpleBlock`s. Both are read here; a nameplate is the first shape.
///
/// ## What it deliberately does not read
///
/// **Lacing is refused rather than parsed.** WebM forbids lacing on a video
/// track, so a laced video block is a file this demuxer has no ground truth for;
/// guessing at it would produce frames that decode into garbage rather than a
/// clean failure. Cues, tags, chapters and the seek head are skipped by their
/// own size: nothing here seeks, and a three-second loop is read whole.
nonisolated enum WebMDemuxer {

    /// The video track, as its `TrackEntry` describes it.
    struct Track: Equatable, Sendable {
        /// Matroska's own id, matched against each block's.
        var number: UInt64
        /// `V_VP9`, `V_VP8`, `V_AV1`… — reported as sent, checked by the caller.
        var codecID: String
        var width: Int
        var height: Int
        /// The authored interval between frames, in seconds. Present on almost
        /// every file and used only for the **last** frame's span, which has no
        /// following timestamp to be measured against.
        var frameDuration: Double?
        /// `AlphaMode` — whether every block carries a second bitstream.
        var hasAlpha: Bool
    }

    /// One coded frame, and the alpha frame that belongs to it.
    struct Sample: Equatable, Sendable {
        /// Presentation time from the start of the file, in seconds.
        var time: Double
        var data: Data
        /// The alpha bitstream, when the track has one.
        var alpha: Data?
    }

    struct Movie: Equatable, Sendable {
        var track: Track
        /// In presentation order, which for a track with no B-frames — every
        /// VP9 file Discord serves — is the order they are muxed in.
        var samples: [Sample]
        /// One full cycle, in seconds.
        var duration: Double
    }

    /// Reads a WebM, or returns nil when it is not one this can play.
    ///
    /// Nil rather than a thrown error for the reason `ImageStore.image(for:)`
    /// returns one: the only caller's answer to every failure is the same — draw
    /// the still — and an error type here would be discarded at the one place
    /// that checks it.
    static func demux(_ data: Data) -> Movie? {
        guard !data.isEmpty else { return nil }
        // Parsed against a raw pointer and reported as offsets, then sliced
        // afterwards. `Data`'s own subscript is a function call per byte, and a
        // 250 KB asset is a quarter of a million of them for a file whose
        // structure is a few hundred elements.
        let parsed: Parse? = data.withUnsafeBytes { raw in
            var parser = Parser(bytes: raw)
            return parser.run()
        }
        guard let parsed, !parsed.frames.isEmpty else { return nil }

        let base = data.startIndex
        func slice(_ range: Range<Int>) -> Data {
            data[base + range.lowerBound..<base + range.upperBound]
        }

        var samples: [Sample] = []
        samples.reserveCapacity(parsed.frames.count)
        for frame in parsed.frames {
            samples.append(
                Sample(
                    time: Double(frame.time) * parsed.secondsPerTick,
                    data: slice(frame.data),
                    alpha: frame.alpha.map(slice)
                )
            )
        }
        // **In time order, not muxed order.** They arrive in order in every file
        // this reads, and sorting a sorted array costs nothing — but a filmstrip
        // built from an out-of-order list has a negative frame span in it, which
        // is a loop that jumps rather than a decode that fails.
        samples.sort { $0.time < $1.time }

        let last = samples[samples.count - 1].time
        // The segment's own duration where it has one and it is past the last
        // frame; otherwise that frame gets the authored interval, and failing
        // that the interval before it. A last frame with no span at all is a
        // filmstrip whose final picture never shows.
        let tail = parsed.track.frameDuration
            ?? (samples.count > 1 ? last - samples[samples.count - 2].time : 0)
        let duration = parsed.duration.map { $0 * parsed.secondsPerTick } ?? 0
        return Movie(
            track: parsed.track,
            samples: samples,
            duration: duration > last ? duration : last + tail
        )
    }

    // MARK: The element tree

    /// Every element this reads. Anything else is skipped by its size, which is
    /// what makes an unread element cost four bytes rather than a branch.
    private enum ID {
        static let ebml: UInt32 = 0x1A45_DFA3
        static let segment: UInt32 = 0x1853_8067
        static let info: UInt32 = 0x1549_A966
        static let timestampScale: UInt32 = 0x2AD7_B1
        static let duration: UInt32 = 0x4489
        static let tracks: UInt32 = 0x1654_AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7
        static let trackType: UInt32 = 0x83
        static let codecID: UInt32 = 0x86
        static let defaultDuration: UInt32 = 0x23E3_83
        static let video: UInt32 = 0xE0
        static let pixelWidth: UInt32 = 0xB0
        static let pixelHeight: UInt32 = 0xBA
        static let alphaMode: UInt32 = 0x53C0
        static let cluster: UInt32 = 0x1F43_B675
        static let timestamp: UInt32 = 0xE7
        static let simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1
        static let blockAdditions: UInt32 = 0x75A1
        static let blockMore: UInt32 = 0xA6
        static let blockAddID: UInt32 = 0xEE
        static let blockAdditional: UInt32 = 0xA5

        /// EBML's two **global** elements, legal inside any master at any depth.
        ///
        /// **They must never be what ends an unknown-size master**, and this is
        /// not a theoretical case: a muxer writing to a pipe cannot go back and
        /// fill in its seek head, so ffmpeg reserves the room with a hundred and
        /// four bytes of `Void` — the very first thing inside the segment. A
        /// reader that stops at an element it does not recognise stops there,
        /// before the track table, and finds no video at all.
        static let globals: Set<UInt32> = [
            0xEC,  // Void
            0xBF,  // CRC-32
        ]

        /// What may appear directly inside a `Segment`.
        ///
        /// Needed only for the **unknown-size** case: a muxer writing to a pipe
        /// cannot know how long its segment will be and writes all-ones instead,
        /// so the segment ends where an element that cannot be its child begins.
        /// Discord's own assets carry real sizes; a re-mux through a pipe does
        /// not, and the difference is eight bytes in a header nobody looks at.
        static let segmentChildren: Set<UInt32> = [
            0x114D_9B74,  // SeekHead
            info, tracks, cluster,
            0x1C53_BB6B,  // Cues
            0x1254_C367,  // Tags
            0x1043_A770,  // Chapters
            0x1941_A469,  // Attachments
        ]

        /// What may appear directly inside a `Cluster`, for the same reason.
        static let clusterChildren: Set<UInt32> = [
            timestamp, simpleBlock, blockGroup,
            0xA7,    // Position
            0xAB,    // PrevSize
            0x5854,  // SilentTracks
        ]
    }

    /// Where one frame's bytes are, before they are sliced out.
    private struct Frame {
        /// In `TimestampScale` ticks from the start of the file.
        var time: Int64
        var data: Range<Int>
        var alpha: Range<Int>?
    }

    private struct Parse {
        var track: Track
        var frames: [Frame]
        /// One tick, in seconds — `TimestampScale` nanoseconds.
        var secondsPerTick: Double
        /// In ticks, from `Info`. Absent in a file muxed to a pipe.
        var duration: Double?
    }

    // MARK: The parser

    /// A cursor over the bytes, with one method per element it descends into.
    ///
    /// A struct over a raw buffer rather than a class over `Data`: the whole
    /// parse is index arithmetic, and every read below is a load rather than a
    /// retain, a bounds check and a function call.
    private struct Parser {
        let bytes: UnsafeRawBufferPointer
        var offset = 0

        /// Matroska's default, used when `Info` omits the element — one
        /// millisecond per tick.
        var timestampScale: UInt64 = 1_000_000
        var duration: Double?
        var track: Track?
        var frames: [Frame] = []

        init(bytes: UnsafeRawBufferPointer) { self.bytes = bytes }

        // MARK: Primitives

        /// The next variable-length integer.
        ///
        /// **An id keeps its length marker and a size drops it**, which is the
        /// one asymmetry in EBML that a reader has to get right: `0xA3` is the
        /// id `0xA3`, while `0xA3` as a size means 0x23. Passing the wrong one
        /// on turns every element in the file into a different element.
        mutating func vint(keepingMarker: Bool) -> (value: UInt64, isUnknown: Bool)? {
            guard offset < bytes.count else { return nil }
            let first = bytes[offset]
            guard first != 0 else { return nil }
            var mask: UInt8 = 0x80
            var length = 1
            while first & mask == 0 {
                mask >>= 1
                length += 1
            }
            guard offset + length <= bytes.count else { return nil }
            var value = UInt64(keepingMarker ? first : first & (mask &- 1))
            var payload = UInt64(first & (mask &- 1))
            for index in 1..<length {
                let byte = UInt64(bytes[offset + index])
                value = value << 8 | byte
                payload = payload << 8 | byte
            }
            offset += length
            // All payload bits set is EBML's "size not yet known", written by a
            // muxer that cannot seek back to fill it in.
            let capacity = (UInt64(1) << (7 * length)) &- 1
            return (value, payload == capacity)
        }

        /// An unsigned integer element's value, big-endian over its own length.
        mutating func integer(length: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<min(length, 8) { value = value << 8 | UInt64(bytes[offset + index]) }
            offset += length
            return value
        }

        /// A float element's value. EBML allows four bytes or eight; a
        /// zero-length float is legal and means zero.
        mutating func float(length: Int) -> Double {
            defer { offset += length }
            switch length {
            case 4: return Double(Float(bitPattern: UInt32(loadBigEndian(length: 4))))
            case 8: return Double(bitPattern: loadBigEndian(length: 8))
            default: return 0
            }
        }

        private func loadBigEndian(length: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<length { value = value << 8 | UInt64(bytes[offset + index]) }
            return value
        }

        mutating func string(length: Int) -> String {
            defer { offset += length }
            let raw = UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + length])
            // Matroska pads a string element with trailing zeroes rather than
            // shortening it, and a codec id with a NUL in it matches nothing.
            let trimmed = raw.prefix { $0 != 0 }
            return String(decoding: trimmed, as: UTF8.self)
        }

        // MARK: The walk

        /// Reads the next element's header, returning where its body ends.
        ///
        /// `end` is the parent's, so an element claiming to run past its parent
        /// is clamped rather than trusted — a truncated download is the ordinary
        /// case, not a hostile one, and it should cost the frames after the cut
        /// rather than a read out of bounds.
        mutating func header(within end: Int) -> (id: UInt32, body: Range<Int>, isUnknown: Bool)? {
            guard offset < end, let id = vint(keepingMarker: true), id.value <= UInt64(UInt32.max),
                  let size = vint(keepingMarker: false)
            else { return nil }
            let start = offset
            let stop = size.isUnknown ? end : min(end, start &+ Int(clamping: size.value))
            guard stop >= start else { return nil }
            return (UInt32(id.value), start..<stop, size.isUnknown)
        }

        mutating func run() -> Parse? {
            while let element = header(within: bytes.count) {
                // **One segment, and the walk stops after it.** Matroska allows
                // several; a second one would carry its own timestamp scale and
                // its own track table, and folding its frames into the first
                // one's timeline is how a loop ends up with two clocks in it.
                // No file this reads has more than one.
                guard element.id != ID.segment else {
                    segment(element.body, isUnknown: element.isUnknown)
                    break
                }
                offset = element.body.upperBound
            }
            guard let track, track.width > 0, track.height > 0 else { return nil }
            return Parse(
                track: track,
                frames: frames,
                secondsPerTick: Double(timestampScale) / 1_000_000_000,
                duration: duration
            )
        }

        mutating func segment(_ body: Range<Int>, isUnknown: Bool) {
            offset = body.lowerBound
            while offset < body.upperBound {
                let mark = offset
                guard let element = header(within: body.upperBound) else { break }
                if isUnknown, !ID.segmentChildren.contains(element.id),
                   !ID.globals.contains(element.id)
                {
                    offset = mark
                    break
                }
                // Snapped to the element's end rather than left wherever the
                // descent stopped: a master with padding after its last child
                // would otherwise resume this walk mid-element, and every
                // element after it in the file is then a different one.
                //
                // **A cluster of unknown size is the exception**, and it has to
                // be: its "end" is the segment's, so snapping to it would throw
                // away every cluster after the first. That one ends where its
                // own walk stopped, which is the first element that cannot be
                // its child.
                switch element.id {
                case ID.info:
                    info(element.body)
                    offset = element.body.upperBound
                case ID.tracks:
                    tracks(element.body)
                    offset = element.body.upperBound
                case ID.cluster:
                    cluster(element.body, isUnknown: element.isUnknown)
                    if !element.isUnknown { offset = element.body.upperBound }
                default:
                    offset = element.body.upperBound
                }
            }
        }

        mutating func info(_ body: Range<Int>) {
            offset = body.lowerBound
            while let element = header(within: body.upperBound) {
                switch element.id {
                case ID.timestampScale:
                    let value = integer(length: element.body.count)
                    if value > 0 { timestampScale = value }
                case ID.duration:
                    duration = float(length: element.body.count)
                default: break
                }
                offset = element.body.upperBound
            }
        }

        mutating func tracks(_ body: Range<Int>) {
            offset = body.lowerBound
            while let element = header(within: body.upperBound) {
                if element.id == ID.trackEntry { trackEntry(element.body) }
                offset = element.body.upperBound
            }
        }

        /// **The first video track wins and the rest are skipped.** Discord's
        /// assets carry exactly one; a file with two would be a choice this has
        /// no basis to make, and taking the first is what every player does.
        mutating func trackEntry(_ body: Range<Int>) {
            offset = body.lowerBound
            var number: UInt64 = 0
            var kind: UInt64 = 0
            var codec = ""
            var frameDuration: Double?
            var width = 0
            var height = 0
            var hasAlpha = false

            while let element = header(within: body.upperBound) {
                switch element.id {
                case ID.trackNumber: number = integer(length: element.body.count)
                case ID.trackType: kind = integer(length: element.body.count)
                case ID.codecID: codec = string(length: element.body.count)
                case ID.defaultDuration:
                    // Nanoseconds, and its own field rather than a tick count.
                    let value = integer(length: element.body.count)
                    if value > 0 { frameDuration = Double(value) / 1_000_000_000 }
                case ID.video:
                    offset = element.body.lowerBound
                    while let inner = header(within: element.body.upperBound) {
                        switch inner.id {
                        case ID.pixelWidth: width = Int(integer(length: inner.body.count))
                        case ID.pixelHeight: height = Int(integer(length: inner.body.count))
                        case ID.alphaMode: hasAlpha = integer(length: inner.body.count) != 0
                        default: break
                        }
                        offset = inner.body.upperBound
                    }
                    offset = element.body.upperBound
                default: offset = element.body.upperBound
                }
            }
            // Track type 1 is video. Everything else in a nameplate — there is
            // nothing else — would be an audio or subtitle track.
            guard track == nil, kind == 1, number > 0 else { return }
            track = Track(
                number: number,
                codecID: codec,
                width: width,
                height: height,
                frameDuration: frameDuration,
                hasAlpha: hasAlpha
            )
        }

        mutating func cluster(_ body: Range<Int>, isUnknown: Bool) {
            offset = body.lowerBound
            var time: Int64 = 0
            while offset < body.upperBound {
                let mark = offset
                guard let element = header(within: body.upperBound) else { break }
                if isUnknown, !ID.clusterChildren.contains(element.id),
                   !ID.globals.contains(element.id)
                {
                    offset = mark
                    break
                }
                switch element.id {
                case ID.timestamp:
                    time = Int64(bitPattern: integer(length: element.body.count))
                case ID.simpleBlock:
                    appendBlock(element.body, clusterTime: time, alpha: nil)
                    offset = element.body.upperBound
                case ID.blockGroup:
                    blockGroup(element.body, clusterTime: time)
                default: offset = element.body.upperBound
                }
            }
        }

        /// A block and its additions, which is the only shape alpha arrives in.
        ///
        /// The additions are read **before** the block is appended, because a
        /// `BlockAdditions` may be muxed either side of its `Block` — ffmpeg
        /// writes it first — and a frame appended on sight would take the
        /// previous group's alpha or none at all.
        mutating func blockGroup(_ body: Range<Int>, clusterTime: Int64) {
            defer { offset = body.upperBound }
            offset = body.lowerBound
            var block: Range<Int>?
            var alpha: Range<Int>?

            while let element = header(within: body.upperBound) {
                switch element.id {
                case ID.block:
                    block = element.body
                    offset = element.body.upperBound
                case ID.blockAdditions:
                    offset = element.body.lowerBound
                    while let more = header(within: element.body.upperBound) {
                        guard more.id == ID.blockMore else {
                            offset = more.body.upperBound
                            continue
                        }
                        offset = more.body.lowerBound
                        // **Id 1 is the alpha channel**, and it is the default:
                        // `BlockAddID` is optional and means 1 when absent.
                        // Every other id is somebody else's side data.
                        var addID: UInt64 = 1
                        var payload: Range<Int>?
                        while let field = header(within: more.body.upperBound) {
                            switch field.id {
                            case ID.blockAddID: addID = integer(length: field.body.count)
                            case ID.blockAdditional: payload = field.body
                            default: break
                            }
                            offset = field.body.upperBound
                        }
                        if addID == 1, let payload { alpha = payload }
                        offset = more.body.upperBound
                    }
                    offset = element.body.upperBound
                default: offset = element.body.upperBound
                }
            }
            guard let block else { return }
            appendBlock(block, clusterTime: clusterTime, alpha: alpha)
        }

        /// The header a `Block` and a `SimpleBlock` share: a track number, a
        /// signed offset from the cluster's timestamp, and one flags byte.
        mutating func appendBlock(_ body: Range<Int>, clusterTime: Int64, alpha: Range<Int>?) {
            offset = body.lowerBound
            guard let number = vint(keepingMarker: false), offset + 3 <= body.upperBound else { return }
            let relative = Int16(bitPattern: UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
            let flags = bytes[offset + 2]
            offset += 3
            guard number.value == track?.number else { return }
            // See the note at the top: WebM forbids lacing on a video track, so
            // a laced block is a file with no ground truth behind it.
            guard flags & 0x06 == 0 else { return }
            frames.append(
                Frame(time: clusterTime + Int64(relative), data: offset..<body.upperBound, alpha: alpha)
            )
        }
    }
}
