import Foundation

/// Just enough protobuf to write one field of Discord's settings blob back.
///
/// **A writer is a far more dangerous thing than a reader, and the design is
/// what makes it safe.** A reader that misses a field skips it; a writer that
/// misses one *deletes* it, and the field it deleted is somebody's emoji
/// frecency or their favourite GIFs. So this never re-encodes a message it only
/// partly understands: the caller hands it bytes that came off the wire, and it
/// re-frames them. The one thing it builds from scratch is a single new map
/// entry, whose shape is captured in `gif favorite unfavorite.har`.
///
/// The other half of the safety is the route. `PATCH
/// /users/@me/settings-proto/2` takes a *partial* message — Discord's own client
/// sends only the field it changed, and the capture proves the rest survives —
/// so nothing here ever has to serialise the fields it cannot read.
struct ProtobufWriter {
    private(set) var data = Data()

    /// A varint. The only integer encoding this needs.
    mutating func varint(_ value: UInt64) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            data.append(byte)
        } while remaining != 0
    }

    mutating func tag(field: Int, wireType: Int) {
        varint(UInt64(field << 3 | wireType))
    }

    mutating func varint(field: Int, _ value: UInt64) {
        tag(field: field, wireType: 0)
        varint(value)
    }

    /// A length-delimited field carrying `payload` verbatim.
    mutating func message(field: Int, _ payload: Data) {
        tag(field: field, wireType: 2)
        varint(UInt64(payload.count))
        data.append(payload)
    }

    /// A `fixed64` — wire type 1, eight little-endian bytes.
    ///
    /// **Not a varint, and the difference is silent.** A snowflake or a
    /// millisecond clock written as a varint is a well-formed message that
    /// decodes to something else entirely; Discord's own descriptor marks
    /// `emoji_id` and `expires_at_ms` as `T:6`, which is `fixed64`.
    mutating func fixed64(field: Int, _ value: UInt64) {
        tag(field: field, wireType: 1)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// A `float` — wire type 5, four little-endian bytes. Discord's
    /// descriptor marks the volumes `T:2`.
    mutating func float(field: Int, _ value: Float) {
        tag(field: field, wireType: 5)
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func string(field: Int, _ value: String) {
        message(field: field, Data(value.utf8))
    }

    /// A packed `repeated fixed64`: one length-delimited field holding the
    /// values back to back, eight little-endian bytes each — how proto3 writes
    /// a repeated scalar, and how the folder list's guild ids arrive.
    mutating func packedFixed64(field: Int, _ values: [UInt64]) {
        var payload = Data(capacity: values.count * 8)
        for value in values {
            withUnsafeBytes(of: value.littleEndian) { payload.append(contentsOf: $0) }
        }
        message(field: field, payload)
    }

    /// A packed `repeated` varint — how a frecency item's millisecond uses
    /// are written (`ProtobufReader.packedVarints` reads them back).
    mutating func packedVarints(field: Int, _ values: [UInt64]) {
        var payload = ProtobufWriter()
        for value in values { payload.varint(value) }
        message(field: field, payload.data)
    }

    var base64: String { data.base64EncodedString() }
}
