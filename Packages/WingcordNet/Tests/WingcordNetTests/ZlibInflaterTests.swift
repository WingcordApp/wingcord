import CZlib
import Foundation
import Testing
@testable import WingcordNet

/// The inflater's contract.
///
/// It is the single point of failure for the whole gateway: every frame passes
/// through it, and if it produces nothing the socket looks alive and silent —
/// connected, heartbeating, and never delivering a HELLO. That failure is
/// indistinguishable from a network problem from the outside, which is exactly
/// why it needs a test that does not involve a network.
@Suite("Zlib inflater")
struct ZlibInflaterTests {

    /// Compresses with a shared context and a sync flush after each message,
    /// which is what Discord's `zlib-stream` transport does.
    private final class StreamCompressor {
        private var stream = z_stream()

        init() {
            _ = deflateInit_(
                &stream,
                Z_DEFAULT_COMPRESSION,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
        }

        deinit { deflateEnd(&stream) }

        func compress(_ text: String) -> Data {
            var input = Array(text.utf8)
            var output = Data()
            var scratch = [UInt8](repeating: 0, count: 64 * 1024)

            input.withUnsafeMutableBufferPointer { inputBuffer in
                stream.next_in = inputBuffer.baseAddress
                stream.avail_in = uInt(inputBuffer.count)
                repeat {
                    let produced: Int = scratch.withUnsafeMutableBufferPointer { scratchBuffer in
                        stream.next_out = scratchBuffer.baseAddress
                        stream.avail_out = uInt(scratchBuffer.count)
                        _ = deflate(&stream, Z_SYNC_FLUSH)
                        return scratchBuffer.count - Int(stream.avail_out)
                    }
                    if produced > 0 { output.append(contentsOf: scratch[0..<produced]) }
                } while stream.avail_out == 0
                stream.next_in = nil
                stream.avail_in = 0
                stream.next_out = nil
                stream.avail_out = 0
            }
            return output
        }
    }

    @Test("One message round-trips")
    func singleMessage() throws {
        let compressor = StreamCompressor()
        let inflater = try ZlibInflater()
        let payload = #"{"op":10,"d":{"heartbeat_interval":41250}}"#

        let frame = compressor.compress(payload)
        let result = try inflater.push(frame)
        #expect(result != nil)
        #expect(String(data: result ?? Data(), encoding: .utf8) == payload)
    }

    /// The property the whole transport depends on.
    @Test("The dictionary carries across messages")
    func sharedDictionary() throws {
        let compressor = StreamCompressor()
        let inflater = try ZlibInflater()
        // Deliberately repetitive: later messages compress against the earlier
        // ones, so a fresh inflater per frame produces garbage from the second
        // message onward rather than failing outright.
        let messages = (0..<12).map {
            #"{"op":0,"t":"MESSAGE_CREATE","s":\#($0),"d":{"content":"the sidebar column is painted with nothing"}}"#
        }
        for message in messages {
            let result = try inflater.push(compressor.compress(message))
            #expect(String(data: result ?? Data(), encoding: .utf8) == message)
        }
    }

    @Test("A message split across frames yields nothing until the marker arrives")
    func partialFrames() throws {
        let compressor = StreamCompressor()
        let inflater = try ZlibInflater()
        let payload = String(repeating: "the viewport-sized backing is the whole trick. ", count: 400)
        let compressed = compressor.compress(payload)
        #expect(compressed.count > 32)

        // Split before the trailing marker.
        let split = compressed.count - 8
        let head = compressed.prefix(split)
        let tail = compressed.suffix(from: compressed.startIndex + split)

        #expect(try inflater.push(head) == nil)
        #expect(inflater.hasPartialMessage)
        let result = try inflater.push(tail)
        #expect(String(data: result ?? Data(), encoding: .utf8) == payload)
        #expect(!inflater.hasPartialMessage)
    }

    @Test("A large message inflates in full")
    func largeMessage() throws {
        let compressor = StreamCompressor()
        let inflater = try ZlibInflater()
        // Bigger than the 32 KB scratch buffer, so the inflate loop has to run
        // several times — the case a single-pass implementation truncates.
        let payload = String(repeating: "0123456789abcdef", count: 40_000)
        let result = try inflater.push(compressor.compress(payload))
        #expect(result?.count == payload.utf8.count)
        #expect(String(data: result ?? Data(), encoding: .utf8) == payload)
    }

    @Test("Reset clears a partial message")
    func resetClearsPartial() throws {
        let compressor = StreamCompressor()
        let inflater = try ZlibInflater()
        let compressed = compressor.compress("hello")
        _ = try inflater.push(compressed.prefix(compressed.count - 4))
        #expect(inflater.hasPartialMessage)
        inflater.reset()
        #expect(!inflater.hasPartialMessage)
    }
}
