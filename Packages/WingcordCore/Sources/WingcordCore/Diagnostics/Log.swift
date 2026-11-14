import Darwin
import Foundation
import Synchronization

// MARK: - The log
//
// docs/BUG-REPORTING.md D18: always on, small, local, and safe to send.
//
//     Log.info(.gateway, "READY guilds=\(count) dms=\(dms)")
//     Log.fault(.voice, "DAVE would not establish after \(attempts) tries")
//     Log.debug(.rest, "GET \(public: route) \(status)")      // detailed only
//
// - **Faults and info are always written; debug only while detailed logging is
//   on** (D23's switch, or a developer's `traceSession`). A call below the
//   threshold costs one atomic load: the message is an autoclosure, never built.
// - **Nothing logs per frame or per packet.** Those paths count, and write one
//   summary line every few seconds (`VoiceTrace.flushDrops`, the call stats).
// - **A line accepts only values the code chose to print** (`LogMessage`), and
//   is scrubbed as it is written (`LogScrubber`).
// - Written into three memory-mapped rings (`LogRing`), about 4 MB in all:
//   calls in their own, so an hour on a call cannot push out the morning, and
//   faults in their own, so they outlive both.

public enum Log {
    public enum Level: UInt8, Sendable, Comparable {
        case debug, info, fault

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        var letter: String {
            switch self {
            case .debug: "D"
            case .info: "I"
            case .fault: "F"
            }
        }
    }

    /// What a line is about. Also which ring it is written into.
    public enum Area: String, Sendable, CaseIterable {
        case app, ui, perf, settings, auth, gateway, rest, media, notify
        case voice, video, share
        case games, clips, overlay, rpc, spotify, demo

        /// Eight wide, so the messages line up in a file read by eye.
        var padded: String {
            rawValue.count >= 8 ? rawValue : rawValue + String(repeating: " ", count: 8 - rawValue.count)
        }

        var ring: LogStore.Ring {
            switch self {
            case .voice, .video, .share: .calls
            default: .general
            }
        }
    }

    private static let detailed = Atomic<Bool>(false)
    private static let installed = Mutex<LogStore?>(nil)

    /// Whether debug lines are written — "Detailed logging for 10 minutes".
    public static var isDetailed: Bool { detailed.load(ordering: .relaxed) }

    public static func setDetailed(_ isOn: Bool) {
        detailed.store(isOn, ordering: .relaxed)
    }

    /// Where lines go from now on. The app installs one store at launch; until
    /// then — and in a test that installs none — a line goes nowhere.
    public static func install(_ store: LogStore?) {
        installed.withLock { $0 = store }
    }

    public static var store: LogStore? { installed.withLock { $0 } }

    // MARK: Writing

    public static func fault(_ area: Area, _ message: @autoclosure () -> LogMessage) {
        guard let store else { return }
        store.write(.fault, area, message().text)
    }

    public static func info(_ area: Area, _ message: @autoclosure () -> LogMessage) {
        guard let store else { return }
        store.write(.info, area, message().text)
    }

    public static func debug(_ area: Area, _ message: @autoclosure () -> LogMessage) {
        guard isDetailed, let store else { return }
        store.write(.debug, area, message().text)
    }

    /// A snowflake as this install's short hash — what `\(id)` prints.
    public static func hash(_ raw: UInt64) -> String {
        (store?.scrubber ?? fallbackScrubber).hash(raw)
    }

    /// For a line written before the store is installed: a salt nobody keeps,
    /// so an id is never printed as itself.
    private static let fallbackScrubber = LogScrubber.ephemeral()
}

// MARK: - A message

/// One line's words, built only from values the code chose to print.
///
/// **A string interpolated without a label is redacted to its length.** Its
/// shape says nothing about whether it is a name, a message's words or a file
/// name, and none of those may be written — so the safe answer is the default,
/// and the code says `\(public: x)` where it knows `x` is its own vocabulary
/// (a case name, a codec, a route). Ids print as this install's hash. Numbers,
/// truth values, durations and a `String` raw-valued enum print as themselves.
/// A type with no rule here does not compile until the call site picks one.
public struct LogMessage: Sendable, ExpressibleByStringInterpolation {
    public let text: String

    public init(stringLiteral value: String) {
        text = value
    }

    public init(stringInterpolation: Interpolation) {
        text = stringInterpolation.text
    }

    private init(raw: String) {
        text = raw
    }

    /// A line made where the typed form cannot reach — a package's trace sink,
    /// a protocol dump in detailed logging. Scrubbed like every other line; what
    /// the scrubber cannot recognise (a name) must not be in it.
    public static func raw(_ text: String) -> LogMessage {
        LogMessage(raw: text)
    }

    /// Two halves of one line, for a line too long for one line of source.
    /// Each half was built under the same rules.
    public static func + (lhs: LogMessage, rhs: LogMessage) -> LogMessage {
        LogMessage(raw: lhs.text + rhs.text)
    }

    public struct Interpolation: StringInterpolationProtocol, Sendable {
        var text = ""

        public init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity + interpolationCount * 10)
        }

        public mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        public mutating func appendInterpolation<Number: BinaryInteger>(_ value: Number) {
            text += String(value)
        }

        public mutating func appendInterpolation(_ value: Double, digits: Int = 1) {
            text += String(format: "%.\(max(0, min(digits, 6)))f", value)
        }

        public mutating func appendInterpolation(_ value: Bool) {
            text += value ? "true" : "false"
        }

        public mutating func appendInterpolation<Tag>(_ id: Snowflake<Tag>) {
            text += Log.hash(id.rawValue)
        }

        public mutating func appendInterpolation<Tag>(_ id: Snowflake<Tag>?) {
            text += id.map { Log.hash($0.rawValue) } ?? "-"
        }

        public mutating func appendInterpolation(_ duration: Duration) {
            text += LogMessage.describe(duration)
        }

        /// A case name: the code's own vocabulary.
        public mutating func appendInterpolation<Word: RawRepresentable>(_ value: Word)
        where Word.RawValue == String {
            text += value.rawValue
        }

        /// A value the call site vouches for: a codec, a route, a format.
        /// Still scrubbed when the line is written.
        public mutating func appendInterpolation(public value: some CustomStringConvertible) {
            text += value.description
        }

        public mutating func appendInterpolation(public value: (some CustomStringConvertible)?) {
            text += value.map(\.description) ?? "-"
        }

        public mutating func appendInterpolation(_ error: any Error) {
            text += LogMessage.describe(error)
        }

        /// A size in bytes, as a person reads one.
        public mutating func appendInterpolation(bytes: some BinaryInteger) {
            text += LogMessage.describe(bytes: Int64(bytes))
        }

        /// Anything else that is a string: its length, never its words.
        public mutating func appendInterpolation(_ value: String) {
            text += "<\(value.count) chars>"
        }

        public mutating func appendInterpolation(_ value: Substring) {
            text += "<\(value.count) chars>"
        }
    }

    // MARK: Words for values

    /// An error in the fewest words that still say which one.
    ///
    /// **An `NSError` as its domain, code and sentence**, not its description,
    /// which is a dump of its user info; a Swift error as its case and what it
    /// carries.
    public static func describe(_ error: any Error) -> String {
        if type(of: error) is NSError.Type {
            let bridged = error as NSError
            return "\(bridged.domain) \(bridged.code) \(bridged.localizedDescription)"
        }
        return String(describing: error)
    }

    public static func describe(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        let milliseconds = Double(seconds) * 1000 + Double(attoseconds) / 1e15
        if milliseconds < 10_000 { return "\(Int(milliseconds.rounded()))ms" }
        return String(format: "%.1fs", milliseconds / 1000)
    }

    public static func describe(bytes: Int64) -> String {
        let value = Double(bytes)
        switch bytes {
        case 1 << 30 ..< Int64.max: return String(format: "%.2f GB", value / Double(1 << 30))
        case 1 << 20 ..< 1 << 30: return String(format: "%.1f MB", value / Double(1 << 20))
        case 1 << 10 ..< 1 << 20: return String(format: "%.0f KB", value / Double(1 << 10))
        default: return "\(bytes) B"
        }
    }
}

// MARK: - The store

/// The three rings and the scrubber that guards them.
public final class LogStore: Sendable {
    public enum Ring: String, CaseIterable, Sendable {
        /// Everything that is not a call: the app, the connection, the windows.
        case general
        /// Voice, video and screen share — the busiest area, kept apart.
        case calls
        /// Every fault and stall, from anywhere, kept longest.
        case faults

        /// About 4 MB together (D18).
        public var capacity: Int {
            switch self {
            case .general: 2 << 20
            case .calls: 3 << 19
            case .faults: 1 << 19
            }
        }

        var fileName: String { "\(rawValue).wclog" }
    }

    /// A line longer than this keeps its head and says so. A protocol dump in
    /// detailed logging is the only thing that reaches it.
    public static let longestLine = 2_048

    public let scrubber: LogScrubber
    /// The folder the rings are in, or nil for rings in memory.
    public let directory: URL?
    private let rings: [Ring: LogRing]
    /// Where every written line is also handed, as written — a developer's
    /// `session.log` to `tail -f` while reproducing something. Boxed: a bare
    /// closure in a `Mutex` grows two thunks deeper with every read, and this one
    /// is read per line (`LockedClosure`; the crashes of 13 November).
    private let mirror = Mutex<LockedClosure<@Sendable (String) -> Void>?>(nil)

    public init(rings: [Ring: LogRing], scrubber: LogScrubber, directory: URL?) {
        precondition(Set(rings.keys) == Set(Ring.allCases), "a store needs all three rings")
        self.rings = rings
        self.scrubber = scrubber
        self.directory = directory
    }

    /// Rings in memory, for tests and for a copy whose files are all taken.
    public static func inMemory(scrubber: LogScrubber, capacity: ((Ring) -> Int)? = nil) -> LogStore {
        var rings: [Ring: LogRing] = [:]
        for ring in Ring.allCases {
            rings[ring] = LogRing(inMemoryCapacity: capacity?(ring) ?? ring.capacity)
        }
        return LogStore(rings: rings, scrubber: scrubber, directory: nil)
    }

    /// Opens the rings under `directory`, in `Logs`.
    ///
    /// **A second copy of the app with the same bundle identifier finds them
    /// taken** — the stable build and a perf build open side by side — and
    /// uses `Logs.1`, then `Logs.2`, so neither cuts the other's lines in half.
    /// Past that, memory.
    public static func open(in directory: URL, scrubber: LogScrubber) -> LogStore {
        for slot in 0..<3 {
            let folder = directory.appending(
                path: slot == 0 ? "Logs" : "Logs.\(slot)", directoryHint: .isDirectory
            )
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var rings: [Ring: LogRing] = [:]
            do {
                for ring in Ring.allCases {
                    rings[ring] = try LogRing(url: folder.appending(path: ring.fileName), capacity: ring.capacity)
                }
                return LogStore(rings: rings, scrubber: scrubber, directory: folder)
            } catch {
                // The rings opened so far let go of their locks as they go.
                continue
            }
        }
        return inMemory(scrubber: scrubber)
    }

    // MARK: Writing

    public func write(_ level: Log.Level, _ area: Log.Area, _ text: String, at date: Date = Date()) {
        let ring = level == .fault ? Ring.faults : area.ring
        let record = Self.record(level, area, scrubber.scrub(text), at: date)
        rings[ring]?.append(record)
        mirror.withLock { $0 }?.call(record)
    }

    /// Hands every line written from now on to `sink` too, or stops.
    public func setMirror(_ sink: (@Sendable (String) -> Void)?) {
        mirror.withLock { $0 = sink.map(LockedClosure.init) }
    }

    /// One line: `2026-11-12T10:15:03.123Z I gateway  READY guilds=12`.
    ///
    /// UTC and fixed width, so lines from the three rings sort by their first
    /// 24 bytes and a report from another time zone reads the same.
    static func record(_ level: Log.Level, _ area: Log.Area, _ text: String, at date: Date) -> String {
        var body = text
        if body.contains(where: \.isNewline) {
            body = body
                .replacingOccurrences(of: "\r\n", with: "\\n")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\n")
        }
        if body.utf8.count > longestLine {
            body = String(decoding: body.utf8.prefix(longestLine), as: UTF8.self) + "… (cut)"
        }
        return timestamp(date) + " " + level.letter + " " + area.padded + " " + body + "\n"
    }

    /// `YYYY-MM-DDTHH:MM:SS.mmmZ`, written by hand: a `DateFormatter` on every
    /// line would cost more than everything else a line does.
    static func timestamp(_ date: Date) -> String {
        // Through whole milliseconds, so `.123` stays `.123` rather than
        // becoming `.122` in a double's last bit.
        let total = Int64((date.timeIntervalSince1970 * 1000).rounded())
        var seconds = time_t(total.quotientAndRemainder(dividingBy: 1000).quotient)
        let milliseconds = Int(total - Int64(seconds) * 1000)
        var parts = tm()
        gmtime_r(&seconds, &parts)
        var bytes = [UInt8](repeating: 0, count: 24)
        func put(_ value: Int, at offset: Int, width: Int) {
            var remaining = value
            for position in stride(from: offset + width - 1, through: offset, by: -1) {
                bytes[position] = UInt8(48 + remaining % 10)
                remaining /= 10
            }
        }
        put(Int(parts.tm_year) + 1900, at: 0, width: 4)
        bytes[4] = UInt8(ascii: "-")
        put(Int(parts.tm_mon) + 1, at: 5, width: 2)
        bytes[7] = UInt8(ascii: "-")
        put(Int(parts.tm_mday), at: 8, width: 2)
        bytes[10] = UInt8(ascii: "T")
        put(Int(parts.tm_hour), at: 11, width: 2)
        bytes[13] = UInt8(ascii: ":")
        put(Int(parts.tm_min), at: 14, width: 2)
        bytes[16] = UInt8(ascii: ":")
        put(Int(parts.tm_sec), at: 17, width: 2)
        bytes[19] = UInt8(ascii: ".")
        put(milliseconds, at: 20, width: 3)
        bytes[23] = UInt8(ascii: "Z")
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Reading

    /// The raw lines of one ring, oldest first.
    public func contents(of ring: Ring) -> String {
        String(decoding: rings[ring]?.contents() ?? Data(), as: UTF8.self)
    }

    /// Every ring's lines in one list, oldest first — what a report carries.
    ///
    /// A merge rather than a sort: each ring is already in order, so this is
    /// one pass over the three. A line without a timestamp (the tail of a line
    /// torn by a crash) sorts where its ring put it.
    public func export() -> String {
        let lists = Ring.allCases.map { ring in
            contents(of: ring).split(separator: "\n", omittingEmptySubsequences: true)
        }
        var cursors = [Int](repeating: 0, count: lists.count)
        var keys = [Substring](repeating: "", count: lists.count)
        var output = ""
        output.reserveCapacity(lists.reduce(0) { $0 + $1.reduce(0) { $0 + $1.utf8.count + 1 } })
        while true {
            var best: Int?
            for index in lists.indices where cursors[index] < lists[index].count {
                let line = lists[index][cursors[index]]
                let key = Self.hasTimestamp(line) ? line.prefix(24) : keys[index]
                if let current = best {
                    let currentLine = lists[current][cursors[current]]
                    let currentKey = Self.hasTimestamp(currentLine) ? currentLine.prefix(24) : keys[current]
                    if key < currentKey { best = index }
                } else {
                    best = index
                }
            }
            guard let best else { break }
            let line = lists[best][cursors[best]]
            if Self.hasTimestamp(line) { keys[best] = line.prefix(24) }
            output += line
            output += "\n"
            cursors[best] += 1
        }
        return output
    }

    /// Empties every ring — after a report is saved with "and clear the log",
    /// and in tests.
    public func clear() {
        for ring in rings.values { ring.clear() }
    }

    static func hasTimestamp(_ line: Substring) -> Bool {
        let bytes = line.utf8
        guard bytes.count >= 24 else { return false }
        let start = bytes.startIndex
        return bytes[bytes.index(start, offsetBy: 4)] == UInt8(ascii: "-")
            && bytes[bytes.index(start, offsetBy: 10)] == UInt8(ascii: "T")
            && bytes[bytes.index(start, offsetBy: 23)] == UInt8(ascii: "Z")
    }
}
