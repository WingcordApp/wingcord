import CoreGraphics
import Foundation

/// Builds a `CGPath` from the three commands `BrandMark`'s outlines use.
///
/// **Not a general SVG parser, deliberately.** Arcs, quadratics and every
/// shorthand form were resolved to absolute cubics when the artwork was
/// authored, so there is no code here that could get one of them wrong — and no
/// code here that has to be trusted about elliptical-arc parameterisation, which
/// is where a hand-written path parser is always wrong first.
///
/// It scans UTF-8 bytes rather than `Character`s. A `Character` is a grapheme
/// cluster and comparing one is a Unicode operation; this input is guaranteed
/// ASCII by construction, and the whole scan is then a byte loop.
nonisolated enum VectorPath {
    private static let move = UInt8(ascii: "M")
    private static let line = UInt8(ascii: "L")
    private static let curve = UInt8(ascii: "C")
    private static let close = UInt8(ascii: "Z")

    /// Nil on anything malformed — an outline that is half-parsed is worse than
    /// no mark at all, because it draws.
    static func parse(_ source: String) -> CGPath? {
        var scanner = Scanner(source)
        // `CGMutablePath` tracks its own current point and its own subpath
        // start, so neither is kept here — a second copy of either is a second
        // thing that can disagree with the path being built.
        let path = CGMutablePath()
        var didMove = false

        while let command = scanner.command() {
            switch command {
            case move:
                guard let point = scanner.point() else { return nil }
                path.move(to: point)
                didMove = true
            case line:
                guard didMove, let point = scanner.point() else { return nil }
                path.addLine(to: point)
            case curve:
                guard didMove,
                      let control1 = scanner.point(),
                      let control2 = scanner.point(),
                      let end = scanner.point()
                else { return nil }
                path.addCurve(to: end, control1: control1, control2: control2)
            case close:
                guard didMove else { return nil }
                path.closeSubpath()
            default:
                return nil
            }
        }
        return didMove ? path.copy() : nil
    }

    /// A cursor over the outline's bytes.
    private struct Scanner {
        private let bytes: ContiguousArray<UInt8>
        private var index = 0

        init(_ source: String) {
            bytes = ContiguousArray(source.utf8)
        }

        /// The next command byte, skipping separators.
        mutating func command() -> UInt8? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            index += 1
            return byte
        }

        mutating func point() -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: x, y: y)
        }

        /// A decimal with an optional sign and fraction. No exponents: the
        /// authored data is bounded by the 24-unit grid and rounded to two
        /// places, so one cannot occur.
        private mutating func number() -> CGFloat? {
            skipSeparators()
            guard index < bytes.count else { return nil }

            var sign: CGFloat = 1
            if bytes[index] == UInt8(ascii: "-") {
                sign = -1
                index += 1
            } else if bytes[index] == UInt8(ascii: "+") {
                index += 1
            }

            var value: CGFloat = 0
            var digits = 0
            while index < bytes.count, let digit = Self.digit(bytes[index]) {
                value = value * 10 + CGFloat(digit)
                digits += 1
                index += 1
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                var scale: CGFloat = 0.1
                while index < bytes.count, let digit = Self.digit(bytes[index]) {
                    value += CGFloat(digit) * scale
                    scale *= 0.1
                    digits += 1
                    index += 1
                }
            }
            return digits > 0 ? sign * value : nil
        }

        private mutating func skipSeparators() {
            while index < bytes.count {
                let byte = bytes[index]
                guard byte == UInt8(ascii: " ") || byte == UInt8(ascii: ",") else { return }
                index += 1
            }
        }

        private static func digit(_ byte: UInt8) -> Int? {
            let zero = UInt8(ascii: "0")
            guard byte >= zero, byte <= UInt8(ascii: "9") else { return nil }
            return Int(byte - zero)
        }
    }
}
