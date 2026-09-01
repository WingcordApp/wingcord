import AVFoundation
import COpus
import Foundation

// MARK: - Turning a soundboard clip into samples
//
// **macOS cannot decode a soundboard sound.** Discord serves them as Ogg Opus,
// and AudioToolbox supports neither the container nor the codec — every format
// CoreAudio ships is a different one. So the clip is demuxed here and decoded
// through the same libopus the call itself uses.
//
// Anything that is *not* Ogg goes to `AVAudioFile`, which covers the handful of
// MP3s among Discord's own defaults and anything they add later in a format the
// platform does know.

public enum SoundboardDecoder {

    /// 48 kHz stereo interleaved float — the format the mixer takes, so nothing
    /// downstream converts anything.
    public static func decode(_ data: Data) async -> [Float]? {
        await Task.detached(priority: .utility) {
            if data.starts(with: Array("OggS".utf8)) {
                return OggOpusReader.decode(data)
            }
            return decodeThroughAVFoundation(data)
        }.value
    }

    /// The fallback path.
    ///
    /// `AVAudioFile` takes a URL and there is no in-memory form of it, so the
    /// bytes go to a temporary file. That is the whole reason this is a
    /// fallback rather than the main path: a few hundred kilobytes through the
    /// filesystem per clip is worth paying only for the formats the platform
    /// actually decodes.
    private static func decodeThroughAVFoundation(_ data: Data) -> [Float]? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil else { return nil }

        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(OpusFormat.sampleRate),
            channels: AVAudioChannelCount(OpusFormat.channels),
            interleaved: true
        ) else { return nil }

        guard let source = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { return nil }
        guard (try? file.read(into: source)) != nil else { return nil }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            return nil
        }
        let capacity = AVAudioFrameCount(
            Double(source.frameLength) * target.sampleRate / file.processingFormat.sampleRate
        ) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        guard error == nil, let samples = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(
            start: samples,
            count: Int(output.frameLength) * Int(OpusFormat.channels)
        ))
    }
}

// MARK: - Ogg

/// The smallest Ogg reader that can hold an Opus stream.
///
/// RFC 3533 for the container, RFC 7845 for the mapping. Three details are the
/// whole of it, and each is quietly fatal to skip:
///
///   * **A packet can span pages.** Segments of exactly 255 bytes continue into
///     the next segment, and a run that ends on a page boundary continues into
///     the next page. A reader that treats each page as a packet feeds the
///     decoder truncated frames.
///   * **The first two packets are headers, not audio.** `OpusHead` carries the
///     channel count and the pre-skip; `OpusTags` carries metadata. Decoding
///     them as audio produces a burst of noise at the start of every clip.
///   * **Pre-skip is real and must be dropped.** The encoder's own latency is
///     encoded into the stream, and playing it back is a few milliseconds of
///     the previous nothing at the head of the sound.
///
/// The CRC is deliberately not checked: this is a clip fetched over TLS from a
/// CDN, and a corrupt one produces a bad noise rather than a security problem.
enum OggOpusReader {

    static func decode(_ data: Data) -> [Float]? {
        let bytes = [UInt8](data)
        var packets: [[UInt8]] = []
        var partial: [UInt8] = []
        var offset = 0
        var preSkip = 0
        var channels = 2
        var headersSeen = 0

        while offset + 27 <= bytes.count {
            guard bytes[offset] == 0x4F, bytes[offset + 1] == 0x67,
                  bytes[offset + 2] == 0x67, bytes[offset + 3] == 0x53 else { break }
            let segmentCount = Int(bytes[offset + 26])
            let tableStart = offset + 27
            guard tableStart + segmentCount <= bytes.count else { break }

            var payload = tableStart + segmentCount
            for index in 0..<segmentCount {
                let length = Int(bytes[tableStart + index])
                guard payload + length <= bytes.count else { return nil }
                partial.append(contentsOf: bytes[payload..<(payload + length)])
                payload += length
                // Anything short of 255 terminates the packet. A run of 255s
                // continues, across the page boundary if it has to.
                if length < 255 {
                    if headersSeen == 0, partial.starts(with: Array("OpusHead".utf8)) {
                        if partial.count >= 12 {
                            channels = Int(partial[9])
                            preSkip = Int(partial[10]) | Int(partial[11]) << 8
                        }
                        headersSeen = 1
                    } else if headersSeen == 1, partial.starts(with: Array("OpusTags".utf8)) {
                        headersSeen = 2
                    } else if headersSeen >= 1 {
                        packets.append(partial)
                    }
                    partial.removeAll(keepingCapacity: true)
                }
            }
            offset = payload
        }

        guard !packets.isEmpty, let decoder = try? OpusDecoder() else { return nil }

        // Decoded as stereo whatever the file is: `opus_decode` up-mixes a mono
        // stream for free, and the mixer downstream takes one format.
        _ = channels
        var output: [Float] = []
        output.reserveCapacity(packets.count * OpusFormat.interleavedCount)
        var frame = [Int16](repeating: 0, count: OpusFormat.interleavedCount)

        for packet in packets {
            guard let produced = try? decoder.decode(packet, into: &frame), produced > 0 else {
                continue
            }
            for index in 0..<(produced * Int(OpusFormat.channels)) {
                output.append(Float(frame[index]) / 32_768)
            }
        }

        let skip = preSkip * Int(OpusFormat.channels)
        guard output.count > skip else { return nil }
        return Array(output.dropFirst(skip))
    }
}
