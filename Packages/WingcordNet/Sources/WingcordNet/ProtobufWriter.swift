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

    mutating func string(field: Int, _ value: String) {
        message(field: field, Data(value.utf8))
    }

    var base64: String { data.base64EncodedString() }
}
