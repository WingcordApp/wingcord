import Foundation

// MARK: - The TLS presentation language, as MLS extends it
//
// RFC 9420 is written in RFC 8446's presentation language with one addition:
// **variable-size vector length headers** (§2.1.2). Every `<V>` in the spec is
// a length prefix of one, two or four bytes, and the prefix's top two bits say
// which:
//
//     00xxxxxx                            →  6-bit length,  0 … 63
//     01xxxxxx xxxxxxxx                   → 14-bit length, 64 … 16383
//     10xxxxxx xxxxxxxx xxxxxxxx xxxxxxxx → 30-bit length, 16384 … 2^30-1
//     11……                                → invalid, and must be rejected
//
// **The encoding has to be minimal in both directions.** A 30-bit header
// carrying the value 5 is a legal-looking frame that a permissive reader
// accepts and a signature check then fails on, because the bytes that were
// signed are not the bytes that arrived. RFC 9420 makes minimality a MUST for
// exactly that reason and the deserialization test vectors probe it, so
// `readVarint` rejects a non-minimal header rather than tolerating it.
//
// Everything else is RFC 8446: fixed-width integers are big-endian, an
// `optional<T>` is a presence byte followed by the value, and a struct is its
// fields back to back with nothing between them.

enum TLSError: Error, CustomStringConvertible {
    case truncated
    case invalidLengthHeader
    case nonMinimalLength
    case valueTooLarge
    case unexpectedValue(String)
    case trailingBytes

    var description: String {
        switch self {
        case .truncated: "TLS: ran off the end of the buffer"
        case .invalidLengthHeader: "TLS: reserved length-header prefix"
        case .nonMinimalLength: "TLS: length header is not minimally encoded"
        case .valueTooLarge: "TLS: value exceeds the 30-bit vector ceiling"
        case .unexpectedValue(let what): "TLS: \(what)"
        case .trailingBytes: "TLS: bytes left over after the value"
        }
    }
}

// MARK: - Writing

/// An append-only byte buffer with the presentation language's shapes on it.
///
/// A struct over a `[UInt8]` rather than a class: every serialisation here is a
/// short-lived local build with no sharing, and the value semantics let a
/// caller measure a sub-structure by writing it into its own writer without
/// reaching for a second allocation strategy.
struct TLSWriter {
    private(set) var bytes: [UInt8] = []

    init(reserving capacity: Int = 128) {
        bytes.reserveCapacity(capacity)
    }

    mutating func write(_ value: UInt8) { bytes.append(value) }

    mutating func write(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func write(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func write(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    /// Raw bytes with no length prefix. For a field the spec declares as a
    /// fixed-size opaque, and for splicing an already-serialised structure.
    mutating func writeRaw(_ value: [UInt8]) { bytes.append(contentsOf: value) }

    /// A `<V>` length header. See the note at the top for why this is minimal.
    mutating func writeVarint(_ length: Int) throws {
        switch length {
        case 0..<0x40:
            bytes.append(UInt8(length))
        case 0x40..<0x4000:
            bytes.append(UInt8(0x40 | (length >> 8)))
            bytes.append(UInt8(truncatingIfNeeded: length))
        case 0x4000..<0x4000_0000:
            bytes.append(UInt8(0x80 | (length >> 24)))
            bytes.append(UInt8(truncatingIfNeeded: length >> 16))
            bytes.append(UInt8(truncatingIfNeeded: length >> 8))
            bytes.append(UInt8(truncatingIfNeeded: length))
        default:
            throw TLSError.valueTooLarge
        }
    }

    /// `opaque x<V>` — a length header and then the bytes.
    mutating func writeOpaque(_ value: [UInt8]) throws {
        try writeVarint(value.count)
        bytes.append(contentsOf: value)
    }

    mutating func writeOpaque(_ value: ArraySlice<UInt8>) throws {
        try writeVarint(value.count)
        bytes.append(contentsOf: value)
    }

    /// `T x<V>` — the length is in **bytes**, not elements, so the vector is
    /// built into a nested writer and spliced.
    mutating func writeVector<T: TLSEncodable>(_ values: [T]) throws {
        var inner = TLSWriter(reserving: 64 * max(values.count, 1))
        for value in values { try value.encode(into: &inner) }
        try writeVarint(inner.bytes.count)
        bytes.append(contentsOf: inner.bytes)
    }

    /// `optional<T>` — a presence byte, then the value if there is one.
    mutating func writeOptional<T: TLSEncodable>(_ value: T?) throws {
        guard let value else { bytes.append(0); return }
        bytes.append(1)
        try value.encode(into: &self)
    }
}

// MARK: - Reading

/// A cursor over a byte buffer.
///
/// Holds an `ArraySlice` rather than a copy so a nested structure can be
/// re-read without slicing an array out of the middle of another one — the
/// hot path here is a welcome message being parsed field by field, and the
/// parse should cost one allocation, not one per field.
struct TLSReader {
    private let buffer: ArraySlice<UInt8>
    private var index: Int

    init(_ bytes: [UInt8]) {
        buffer = bytes[...]
        index = buffer.startIndex
    }

    init(_ slice: ArraySlice<UInt8>) {
        buffer = slice
        index = slice.startIndex
    }

    var isAtEnd: Bool { index >= buffer.endIndex }
    var remaining: Int { buffer.endIndex - index }

    mutating func finish() throws {
        guard isAtEnd else { throw TLSError.trailingBytes }
    }

    mutating func readByte() throws -> UInt8 {
        guard index < buffer.endIndex else { throw TLSError.truncated }
        defer { index += 1 }
        return buffer[index]
    }

    mutating func readUInt16() throws -> UInt16 {
        guard remaining >= 2 else { throw TLSError.truncated }
        defer { index += 2 }
        return UInt16(buffer[index]) << 8 | UInt16(buffer[index + 1])
    }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw TLSError.truncated }
        defer { index += 4 }
        var value: UInt32 = 0
        for offset in 0..<4 { value = value << 8 | UInt32(buffer[index + offset]) }
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        guard remaining >= 8 else { throw TLSError.truncated }
        defer { index += 8 }
        var value: UInt64 = 0
        for offset in 0..<8 { value = value << 8 | UInt64(buffer[index + offset]) }
        return value
    }

    mutating func readRaw(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, remaining >= count else { throw TLSError.truncated }
        defer { index += count }
        return buffer[index..<(index + count)]
    }

    /// A `<V>` length header, rejecting both reserved and non-minimal forms.
    mutating func readVarint() throws -> Int {
        let first = try readByte()
        switch first >> 6 {
        case 0:
            return Int(first)
        case 1:
            let value = Int(first & 0x3F) << 8 | Int(try readByte())
            guard value >= 0x40 else { throw TLSError.nonMinimalLength }
            return value
        case 2:
            var value = Int(first & 0x3F)
            for _ in 0..<3 { value = value << 8 | Int(try readByte()) }
            guard value >= 0x4000 else { throw TLSError.nonMinimalLength }
            return value
        default:
            throw TLSError.invalidLengthHeader
        }
    }

    mutating func readOpaque() throws -> [UInt8] {
        Array(try readRaw(try readVarint()))
    }

    /// A `<V>` vector, read by handing a sub-reader to the element decoder
    /// until the declared byte count is used up. An element that overruns the
    /// vector is a malformed message, not a short read of the next field.
    mutating func readVector<T: TLSDecodable>(_ type: T.Type) throws -> [T] {
        let length = try readVarint()
        let slice = try readRaw(length)
        var inner = TLSReader(slice)
        var values: [T] = []
        while !inner.isAtEnd { values.append(try T(from: &inner)) }
        return values
    }

    mutating func readOptional<T: TLSDecodable>(_ type: T.Type) throws -> T? {
        switch try readByte() {
        case 0: return nil
        case 1: return try T(from: &self)
        default: throw TLSError.unexpectedValue("an optional presence byte that is neither 0 nor 1")
        }
    }
}

// MARK: - Conformances

protocol TLSEncodable {
    func encode(into writer: inout TLSWriter) throws
}

protocol TLSDecodable {
    init(from reader: inout TLSReader) throws
}

typealias TLSCodable = TLSEncodable & TLSDecodable

extension TLSEncodable {
    /// The whole value as bytes. Named for RFC 9420's own verb.
    func marshalled() throws -> [UInt8] {
        var writer = TLSWriter()
        try encode(into: &writer)
        return writer.bytes
    }
}

extension TLSDecodable {
    /// Parses a complete buffer, and rejects one with anything left over.
    ///
    /// **Trailing bytes are rejected on purpose.** A signature covers the bytes
    /// that were signed; accepting a message with a tail means accepting one
    /// whose serialisation is not what the signer produced.
    init(unmarshalling bytes: [UInt8]) throws {
        var reader = TLSReader(bytes)
        self = try Self(from: &reader)
        try reader.finish()
    }

    init(unmarshalling slice: ArraySlice<UInt8>) throws {
        var reader = TLSReader(slice)
        self = try Self(from: &reader)
        try reader.finish()
    }
}

/// `opaque x<V>` as a standalone value, so `[[UInt8]]` can go through
/// `writeVector` like any other element type.
struct TLSOpaque: TLSCodable, Equatable {
    var bytes: [UInt8]

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    init(from reader: inout TLSReader) throws { bytes = try reader.readOpaque() }

    func encode(into writer: inout TLSWriter) throws { try writer.writeOpaque(bytes) }
}

extension UInt32: TLSCodable {
    init(from reader: inout TLSReader) throws { self = try reader.readUInt32() }
    func encode(into writer: inout TLSWriter) throws { writer.write(self) }
}

extension UInt16: TLSCodable {
    init(from reader: inout TLSReader) throws { self = try reader.readUInt16() }
    func encode(into writer: inout TLSWriter) throws { writer.write(self) }
}
