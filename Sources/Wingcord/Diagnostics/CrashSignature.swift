import CryptoKit
import Foundation

/// Where a crash or a freeze happened, in the shape the reports service folds
/// by (docs/BUG-REPORTING.md §9): the signal, the top frames, and a
/// **fingerprint that is equal for the same crash in the same build** and
/// different otherwise.
///
/// **No address goes into it.** Every launch loads the app somewhere else, so
/// the same crash twice has different addresses; what stays put is the
/// binary's own uuid, the app's frames as symbol and offset (a stripped build
/// names its frames by offset alone), and a system library's frames by symbol
/// — without the offset, which moves with every macOS update.
nonisolated struct CrashSignature: Equatable, Sendable {
    enum Kind: String, Sendable {
        case crash
        case hang
    }

    var kind: Kind
    /// `SIGSEGV`; nil for a freeze, or a crash whose signal is not written.
    var signal: String?
    /// 32 hex characters.
    var fingerprint: String
    /// The top frames, without addresses: `Wingcord $s8Wingcord15Voice… + 160`.
    var frames: [String]

    /// How many frames are sent to be read.
    static let framesShown = 8
    /// How many frames decide which crash it is.
    static let framesFingerprinted = 6
    /// The service's limit for one frame (`ReportsWorker/src/validate.ts`).
    static let frameLength = 200

    /// Reads a crash report (`crash-*.txt`) or a freeze marker (`hang-*.txt`);
    /// nil when it holds no stack.
    static func read(_ text: String, kind: Kind, mainImage: String = mainImageName) -> CrashSignature? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let frames = kind == .crash ? crashFrames(lines) : hangFrames(lines)
        guard !frames.isEmpty else { return nil }

        // The binary's own id, so two builds never fold into one report.
        let build = lines.lazy.compactMap(buildID).first ?? "unknown"
        let identity = frames.prefix(framesFingerprinted).map { $0.identity(mainImage: mainImage) }
        let digest = SHA256.hash(data: Data(([build] + identity).joined(separator: "\n").utf8))

        return CrashSignature(
            kind: kind,
            signal: kind == .crash ? lines.lazy.compactMap(signalName).first : nil,
            fingerprint: digest.map { String(format: "%02x", $0) }.joined().prefix(32).description,
            frames: frames.prefix(framesShown).map(\.shown)
        )
    }

    /// The app's executable, whose frames are told apart by offset.
    static let mainImageName: String = Bundle.main.executableURL?.lastPathComponent ?? "Wingcord"

    // MARK: Frames

    struct Frame: Equatable {
        var image: String
        /// A function's name, or the app's offset for a stripped frame.
        var symbol: String
        /// Bytes into `symbol`; nil where the line has none.
        var offset: String?

        func identity(mainImage: String) -> String {
            // The app's frames need their offset: stripped, their "symbol" is
            // only the nearest exported name. A system frame's offset moves
            // with the system, and its name alone says enough.
            image == mainImage || image == "?"
                ? "\(image) \(symbol)\(offset.map { " + \($0)" } ?? "")"
                : "\(image) \(symbol)"
        }

        var shown: String {
            let text = "\(image) \(symbol)\(offset.map { " + \($0)" } ?? "")"
            // Printable ASCII only, as the service takes it.
            let ascii = String(String.UnicodeScalarView(text.unicodeScalars.map {
                (0x20...0x7e).contains($0.value) ? $0 : "?"
            }))
            return ascii.count > frameLength ? String(ascii.prefix(frameLength - 3)) + "..." : ascii
        }
    }

    /// `backtrace_symbols` lines: `7   Wingcord   0x0000000104162ecc symbol + 160`.
    private static var crashLine: Regex<(Substring, Substring, Substring, Substring)> { /^\s*\d+\s+(\S+)\s+0x[0-9a-fA-F]+\s+(.+?)\s+\+\s+(\d+)\s*$/ }

    /// What the crash handler and the way down to it put on top of every
    /// stack: dropped, so the first frame is where it went wrong.
    private static let machinery: Set<String> = [
        "__pthread_kill", "pthread_kill", "abort", "__abort", "raise",
        "__exceptionPreprocess", "objc_exception_throw",
    ]

    private static func crashFrames(_ lines: [String]) -> [Frame] {
        // An uncaught exception's own stack says where it was thrown; the
        // signal that follows it only says that it ended the run.
        let header = lines.contains("--- call stack ---") ? "--- call stack ---" : "--- backtrace ---"
        guard let start = lines.firstIndex(of: header) else { return [] }
        var frames: [Frame] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("===") || line.hasPrefix("---") { break }
            guard let match = line.wholeMatch(of: crashLine) else { continue }
            frames.append(Frame(image: String(match.1), symbol: String(match.2), offset: String(match.3)))
        }
        // Everything up to the signal trampoline is the handler writing this.
        if let trampoline = frames.firstIndex(where: { $0.symbol == "_sigtramp" }) {
            frames.removeFirst(trampoline + 1)
        }
        while let first = frames.first, machinery.contains(first.symbol) { frames.removeFirst() }
        return frames
    }

    /// The watchdog's lines: `3 SwiftUI ViewGraph.updateOutputs + 112`,
    /// `7 Wingcord +0x1a2b3c`, `9 ? 0x1a2b3c`.
    private static var hangLine: Regex<(Substring, Substring, Substring, Substring)> { /^(\d+) (\S+) (.+)$/ }
    private static var symbolAndOffset: Regex<(Substring, Substring, Substring)> { /^(.+?) \+ (\d+)$/ }

    private static func hangFrames(_ lines: [String]) -> [Frame] {
        guard let start = lines.firstIndex(where: { $0.hasPrefix("--- main thread, two seconds in") }) else { return [] }
        var frames: [Frame] = []
        for line in lines[(start + 1)...] {
            if line.isEmpty || line.hasPrefix("---") { break }
            guard let match = line.wholeMatch(of: hangLine) else { continue }
            let rest = String(match.3)
            if let split = rest.wholeMatch(of: symbolAndOffset) {
                frames.append(Frame(image: String(match.2), symbol: String(split.1), offset: String(split.2)))
            } else {
                frames.append(Frame(image: String(match.2), symbol: rest, offset: nil))
            }
        }
        return frames
    }

    // MARK: Lines

    /// `image-base 0x102d90000 uuid 06A5A33A-…` → the uuid.
    private static func buildID(_ line: String) -> String? {
        guard line.hasPrefix("image-base "), let range = line.range(of: " uuid ") else { return nil }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// `=== SIGNAL 11 ===` → `SIGSEGV`.
    private static func signalName(_ line: String) -> String? {
        guard let match = line.wholeMatch(of: /=== SIGNAL (\d+) ===/), let number = Int(match.1) else { return nil }
        return signals[number]
    }

    private static let signals: [Int: String] = [
        1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 7: "SIGEMT",
        8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 12: "SIGSYS", 13: "SIGPIPE",
        14: "SIGALRM", 15: "SIGTERM",
    ]
}
