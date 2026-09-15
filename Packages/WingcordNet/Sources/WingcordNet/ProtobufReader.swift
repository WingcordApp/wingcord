import Foundation

/// Just enough protobuf to read Discord's settings blob.
///
/// **Discord retired `user_settings` on READY and replaced it with
/// `user_settings_proto`, a base64 `PreloadedUserSettings`.** Captured from a
/// live account on 2026-08-26: `user_settings` ABSENT, `user_settings_proto`
/// present at 7,996 base64 characters. So a client that only reads the JSON
/// form gets no guild folders, no rail order and no status — silently, because
/// every field there is optional by design.
///
/// This is a *reader*, not a protobuf implementation: no descriptors, no code
/// generation, no dependency. It walks the wire format, hands back the fields
/// asked for by number, and skips everything else — which is the whole contract
/// protobuf's wire format offers and the reason an unknown field is harmless.
///
/// It is a `struct` over a `Data` slice and never copies: every nested message
/// is another reader over a sub-range of the same buffer.
struct ProtobufReader {
    private let bytes: [UInt8]
    private var index: Int
    private let end: Int

    init(_ data: Data) {
        bytes = [UInt8](data)
        index = 0
        end = bytes.count
    }

    private init(bytes: [UInt8], from: Int, to: Int) {
        self.bytes = bytes
        index = from
        end = to
    }

    /// One field, as read off the wire.
    struct Field {
        var number: Int
        var wireType: Int
        /// Set for varint, fixed32 and fixed64.
        var value: UInt64 = 0
        /// Set for length-delimited fields.
        var range: Range<Int> = 0..<0
        /// Where the field's own tag began, and where the whole field ended.
        ///
        /// **The framing, not the payload**, and it exists so a message can be
        /// rewritten one field at a time without re-serialising the fields this
        /// client cannot name — see `ActivityPrivacyProto.replacing`. A writer
        /// that rebuilds a message it only partly understands does not fail
        /// loudly; it deletes what it could not read.
        var wholeRange: Range<Int> = 0..<0
    }

    var isAtEnd: Bool { index >= end }

    /// Reads the next field, or nil at the end / on malformed input.
    ///
    /// A malformed blob ends iteration rather than throwing. Discord adds fields
    /// to this message constantly, and the failure this must never have is
    /// "one unrecognised byte and the account has no servers".
    mutating func next() -> Field? {
        let start = index
        guard index < end, let key = varint() else { return nil }
        let wireType = Int(key & 7)
        let number = Int(key >> 3)
        guard number > 0 else { return nil }

        switch wireType {
        case 0:
            guard let value = varint() else { return nil }
            return Field(
                number: number, wireType: wireType, value: value, wholeRange: start..<index
            )
        case 1:
            guard let value = fixed(8) else { return nil }
            return Field(
                number: number, wireType: wireType, value: value, wholeRange: start..<index
            )
        case 5:
            guard let value = fixed(4) else { return nil }
            return Field(
                number: number, wireType: wireType, value: value, wholeRange: start..<index
            )
        case 2:
            guard let length = varint(), let count = Int(exactly: length),
                  count >= 0, index + count <= end
            else { return nil }
            let range = index..<(index + count)
            index += count
            return Field(
                number: number, wireType: wireType, range: range, wholeRange: start..<index
            )
        default:
            // Groups (3, 4) are long dead and anything else is corruption.
            return nil
        }
    }

    /// One field's complete bytes — its tag, its length and its payload.
    ///
    /// The unit a partial rewrite moves around. See `Field.wholeRange`.
    func rawField(_ field: Field) -> Data? {
        guard field.wholeRange.lowerBound >= 0, field.wholeRange.upperBound <= bytes.count
        else { return nil }
        return Data(bytes[field.wholeRange])
    }

    /// A reader over a length-delimited field's contents.
    func reader(for field: Field) -> ProtobufReader {
        ProtobufReader(bytes: bytes, from: field.range.lowerBound, to: field.range.upperBound)
    }

    /// The raw bytes of a length-delimited field, framing excluded.
    ///
    /// **What makes a partial rewrite safe.** Discord's settings message is
    /// re-serialised whole when one entry in it changes, and this reader knows
    /// five of a favourite's fields — so an entry rebuilt from what it
    /// understands loses whatever it does not. Keeping each entry's own bytes
    /// and re-emitting them verbatim means only the entry that actually changed
    /// is ever rewritten. See `FrecencyProto.favoriteGIFEntries`.
    func data(for field: Field) -> Data? {
        guard field.wireType == 2 else { return nil }
        return Data(bytes[field.range])
    }

    func string(for field: Field) -> String? {
        guard field.wireType == 2 else { return nil }
        return String(decoding: bytes[field.range], as: UTF8.self)
    }

    /// A packed `repeated fixed64`, which is how every id list in this blob is
    /// encoded. A length that is not a multiple of eight is not one.
    func packedFixed64(for field: Field) -> [UInt64] {
        guard field.wireType == 2, field.range.count % 8 == 0 else { return [] }
        var result: [UInt64] = []
        result.reserveCapacity(field.range.count / 8)
        var cursor = field.range.lowerBound
        while cursor + 8 <= field.range.upperBound {
            var value: UInt64 = 0
            for offset in (0..<8).reversed() {
                value = (value << 8) | UInt64(bytes[cursor + offset])
            }
            result.append(value)
            cursor += 8
        }
        return result
    }

    /// Reads a `google.protobuf.*Value` wrapper — a message whose only field is
    /// its value at number 1. Discord uses them everywhere in this blob so that
    /// "unset" and "zero" stay distinguishable, which for a folder colour is a
    /// real difference.
    func wrappedValue(for field: Field) -> UInt64? {
        guard field.wireType == 2 else { return nil }
        var inner = reader(for: field)
        while let entry = inner.next() {
            if entry.number == 1, entry.wireType != 2 { return entry.value }
        }
        return nil
    }

    func wrappedString(for field: Field) -> String? {
        guard field.wireType == 2 else { return nil }
        var inner = reader(for: field)
        while let entry = inner.next() {
            if entry.number == 1, entry.wireType == 2 { return inner.string(for: entry) }
        }
        return nil
    }

    /// The next varint in a *packed* field's body, where there are no keys —
    /// only values back to back. Nil at the end, and nil on a malformed byte.
    mutating func nextVarint() -> UInt64? {
        guard index < end else { return nil }
        return varint()
    }

    // MARK: Primitives

    private mutating func varint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < end {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    private mutating func fixed(_ width: Int) -> UInt64? {
        guard index + width <= end else { return nil }
        var value: UInt64 = 0
        for offset in (0..<width).reversed() {
            value = (value << 8) | UInt64(bytes[index + offset])
        }
        index += width
        return value
    }
}
