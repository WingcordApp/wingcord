import CZlib
import Foundation

/// A streaming zlib inflater with one context for the life of a connection.
///
/// The gateway's `zlib-stream` transport is not "each frame is a zlib document".
/// It is **one** zlib stream cut into WebSocket frames, with the compressor's
/// dictionary carried across them — which is most of why it compresses well, and
/// entirely why a fresh inflater per frame produces garbage after the first one.
/// A frame ends a logical message when its last four bytes are `00 00 FF FF`,
/// zlib's sync-flush marker.
///
/// Not `Sendable`: it owns a C context with interior state, so it belongs to one
/// consumer. The gateway's receive loop is that consumer.
final class ZlibInflater {
    enum Failure: Error {
        case initializationFailed(Int32)
        case inflateFailed(Int32)
        case messageTooLarge(Int)
    }

    /// The sync-flush marker that ends one logical message.
    private static let flushMarker: [UInt8] = [0x00, 0x00, 0xFF, 0xFF]

    /// A hard ceiling on one inflated message.
    ///
    /// **This is a safety bound, not a tuning knob.** Compressed input is
    /// attacker-influenced — anything in a message anyone can send reaches this
    /// path — and an inflate loop with no output bound will happily expand a few
    /// kilobytes into all available memory. 64 MB is comfortably above the
    /// largest real READY and far below anything that matters.
    private static let maximumMessageBytes = 64 * 1024 * 1024

    private var stream = z_stream()
    /// Compressed bytes accumulated since the last flush marker.
    private var pending: [UInt8] = []
    /// Reused scratch for the inflate loop, so a busy channel does not allocate
    /// a 32 KB buffer per frame.
    private var scratch = [UInt8](repeating: 0, count: 32 * 1024)

    init() throws {
        // 15 is the maximum window size; zlib's default header handling applies
        // because the value is positive (negative would mean raw DEFLATE, which
        // is what this transport is not).
        let status = inflateInit2_(
            &stream, 15,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw Failure.initializationFailed(status) }
        pending.reserveCapacity(64 * 1024)
    }

    deinit {
        inflateEnd(&stream)
    }

    /// Feeds one WebSocket frame.
    ///
    /// Returns the inflated message when the frame completed one, and nil while a
    /// message is still being assembled — a large READY arrives across several
    /// frames and only the last carries the marker.
    func push(_ frame: Data) throws -> Data? {
        pending.append(contentsOf: frame)
        guard pending.count >= 4 else { return nil }

        let tail = pending.suffix(4)
        guard Array(tail) == Self.flushMarker else { return nil }

        defer { pending.removeAll(keepingCapacity: true) }
        return try inflate(pending)
    }

    /// Whether a partially assembled message is in flight. The reconnect path
    /// asks, because a socket that dies mid-message must not carry the fragment
    /// into the next connection.
    var hasPartialMessage: Bool { !pending.isEmpty }

    func reset() {
        pending.removeAll(keepingCapacity: true)
        inflateReset(&stream)
    }

    private func inflate(_ input: [UInt8]) throws -> Data {
        var output = Data()
        // A conservative first guess. Discord's gateway traffic compresses
        // around 4:1, so this usually avoids every reallocation on small frames
        // and one or two on large ones.
        output.reserveCapacity(input.count * 4)

        var result: Int32 = Z_OK
        try input.withUnsafeBufferPointer { inputBuffer in
            guard let base = inputBuffer.baseAddress else { return }
            // zlib's `next_in` is non-const in the C API but is not written to.
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(inputBuffer.count)

            repeat {
                let produced: Int = try scratch.withUnsafeMutableBufferPointer { scratchBuffer in
                    stream.next_out = scratchBuffer.baseAddress
                    stream.avail_out = uInt(scratchBuffer.count)
                    result = CZlib.inflate(&stream, Z_SYNC_FLUSH)
                    switch result {
                    case Z_OK, Z_BUF_ERROR, Z_STREAM_END:
                        break
                    default:
                        throw Failure.inflateFailed(result)
                    }
                    return scratchBuffer.count - Int(stream.avail_out)
                }
                if produced > 0 {
                    guard output.count + produced <= Self.maximumMessageBytes else {
                        throw Failure.messageTooLarge(output.count + produced)
                    }
                    output.append(contentsOf: scratch[0..<produced])
                }
                // `Z_BUF_ERROR` with nothing produced means there is no more
                // output to be had from this input, which is the normal way a
                // sync-flushed message ends.
                if produced == 0, result == Z_BUF_ERROR { break }
            } while stream.avail_out == 0 || stream.avail_in > 0

            stream.next_in = nil
            stream.avail_in = 0
            stream.next_out = nil
            stream.avail_out = 0
        }

        return output
    }
}
