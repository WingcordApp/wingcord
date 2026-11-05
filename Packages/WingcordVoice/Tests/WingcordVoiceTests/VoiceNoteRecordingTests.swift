import AVFoundation
import Foundation
import Testing
@testable import WingcordVoice

@Suite("Voice notes")
struct VoiceNoteRecordingTests {

    /// A voice-like sound: a tone that swells and falls away, so a waveform has
    /// something to show and a file with holes in it would sound shorter.
    private func frames(seconds: Double) -> [[Int16]] {
        let count = Int(seconds * 50)
        return (0..<count).map { frame in
            let swell = 0.5 + 0.5 * sin(Double(frame) / 12)
            return (0..<Int(OpusFormat.frameSize)).map { sample in
                let position = Double(frame * Int(OpusFormat.frameSize) + sample)
                return Int16(sin(2 * .pi * 220 * position / 48_000) * 12_000 * swell)
            }
        }
    }

    private func level(_ frame: [Int16]) -> Float {
        let sum = frame.reduce(0.0) { $0 + pow(Double($1) / 32_768, 2) }
        return Float((sum / Double(frame.count)).squareRoot())
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ogg")
    }

    private func record(seconds: Double, to url: URL) throws -> VoiceNoteFile {
        let recording = try VoiceNoteRecording(url: url)
        for frame in frames(seconds: seconds) {
            frame.withUnsafeBufferPointer { recording.ingest($0.baseAddress!, level: level(frame)) }
        }
        return try recording.finish()
    }

    // MARK: The file

    @Test func theFileReadsBackThroughOurOwnReader() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try record(seconds: 3, to: url)

        let decoded = try #require(OggOpusReader.decode(try Data(contentsOf: url)))
        // Stereo, as the reader always gives. All of it there, less the pre-skip.
        let expected = Int(3.0 * 48_000)
        let got = decoded.count / 2
        #expect(abs(got - expected) <= 960)
        #expect(file.durationSeconds == 3)
        #expect(file.samples.count == 150)
    }

    /// **The test that matters**: what actually plays it is the system's reader, and
    /// it's the one that would reject a bad checksum or a wrong granule.
    @Test func theSystemReadsItAndGetsTheRightLength() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try record(seconds: 4, to: url)

        let reader = try AVAudioFile(forReading: url)
        #expect(reader.processingFormat.channelCount == 1)
        #expect(reader.fileFormat.sampleRate == 48_000)
        let seconds = Double(reader.length) / reader.processingFormat.sampleRate
        #expect(abs(seconds - 4) < 0.05)

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: AVAudioFrameCount(reader.length)))
        try reader.read(into: buffer)
        // And it isn't silence.
        let samples = try #require(buffer.floatChannelData?[0])
        let peak = (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(samples[$1])) }
        #expect(peak > 0.1)
    }

    /// A long pause stays as long as it was: DTX would have skipped those frames, and
    /// a file played back without them runs through every pause.
    @Test func silenceTakesItsFullLength() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let recording = try VoiceNoteRecording(url: url)
        let silence = [Int16](repeating: 0, count: Int(OpusFormat.frameSize))
        for _ in 0..<250 {
            silence.withUnsafeBufferPointer { recording.ingest($0.baseAddress!, level: 0) }
        }
        let file = try recording.finish()

        #expect(file.durationSeconds == 5)
        #expect(file.samples.allSatisfy { $0 == 0 })
        let reader = try AVAudioFile(forReading: url)
        #expect(abs(Double(reader.length) / reader.processingFormat.sampleRate - 5) < 0.05)
    }

    /// Twenty minutes fits Discord's smallest upload limit, which is the reason for
    /// the bitrate. A second of speech-like sound is measured and multiplied, since
    /// twenty minutes of encoding is no test to wait for.
    @Test func twentyMinutesFitsTheUploadLimit() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try record(seconds: 10, to: url)

        let perSecond = Double(file.byteCount) / file.durationSeconds
        #expect(perSecond * 1_199.5 < 10 * 1_024 * 1_024)
    }

    @Test func aPageNeverOutgrowsItsSegmentTable() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try OggOpusWriter(url: url, preSkip: 312)
        // Packets this big take three segments each, so 50 of them would take 150,
        // and 120 of them would overflow without the writer closing the page early.
        let big = [UInt8](repeating: 7, count: 600)
        for _ in 0..<400 {
            try big.withUnsafeBufferPointer { try writer.append($0, samples: 960) }
        }
        // And one whose length is an exact multiple, which ends on a zero segment.
        let exact = [UInt8](repeating: 9, count: 510)
        try exact.withUnsafeBufferPointer { try writer.append($0, samples: 960) }
        try writer.finish()

        let pages = Self.pages(of: try Data(contentsOf: url))
        #expect(pages.allSatisfy { $0.segments <= 255 })
        #expect(pages.last?.isLast == true)
        #expect(pages.filter(\.isLast).count == 1)
        #expect(pages.first?.isFirst == true)
        #expect(pages.filter(\.isFirst).count == 1)
        #expect(pages.map(\.sequence) == Array(0..<UInt32(pages.count)))
        // Every packet is accounted for: the granule counts them all, plus the skip.
        #expect(pages.last?.granule == Int64(312 + 401 * 960))
    }

    /// RFC 7845 §3: the first page's own packet is `OpusHead`, with the numbers a
    /// decoder takes on trust, and the second is `OpusTags`.
    @Test func theHeadersSayWhatTheyShould() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try record(seconds: 1, to: url)
        let bytes = [UInt8](try Data(contentsOf: url))
        let pages = Self.pages(of: Data(bytes))
        #expect(file.byteCount == bytes.count)

        let head = Array(bytes[pages[0].bodyStart..<(pages[0].bodyStart + 19)])
        #expect(String(decoding: head[0..<8], as: UTF8.self) == "OpusHead")
        #expect(head[8] == 1)
        #expect(head[9] == 1)
        let skip = UInt16(head[10]) | UInt16(head[11]) << 8
        #expect(skip > 0)
        let rate = UInt32(head[12]) | UInt32(head[13]) << 8 | UInt32(head[14]) << 16 | UInt32(head[15]) << 24
        #expect(rate == 48_000)
        #expect(pages[0].granule == 0)
        #expect(pages[1].granule == 0)
        #expect(String(decoding: bytes[pages[1].bodyStart..<(pages[1].bodyStart + 8)], as: UTF8.self) == "OpusTags")
    }

    /// The checksum's known answer: RFC 3533's polynomial over "123456789", as Ogg
    /// computes it (init 0, no reflection, no final inversion).
    @Test func theChecksumIsOggsOwn() {
        #expect(OggOpusWriter.checksum(Array("123456789".utf8)) == 0x89A1_897F)
    }

    // MARK: Ending

    @Test func cancellingLeavesNothingBehind() throws {
        let url = temporaryFile()
        let recording = try VoiceNoteRecording(url: url)
        let frame = frames(seconds: 0.1)[0]
        frame.withUnsafeBufferPointer { recording.ingest($0.baseAddress!, level: 0.5) }
        #expect(FileManager.default.fileExists(atPath: url.path))

        recording.cancel()

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func framesAfterTheEndAreDropped() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let recording = try VoiceNoteRecording(url: url)
        let frame = frames(seconds: 0.1)[0]
        frame.withUnsafeBufferPointer { recording.ingest($0.baseAddress!, level: 0.5) }
        let file = try recording.finish()
        frame.withUnsafeBufferPointer { recording.ingest($0.baseAddress!, level: 0.5) }

        #expect(file.samples.count == 1)
        #expect(recording.elapsedSeconds == 0.02)
    }

    @Test func theTimerIsWhatWasCaptured() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let recording = try VoiceNoteRecording(url: url)
        #expect(recording.elapsedSeconds == 0)
        let frame = frames(seconds: 0.1)[0]
        for _ in 0..<50 {
            frame.withUnsafeBufferPointer { recording.ingest($0.baseAddress!, level: 0.25) }
        }
        #expect(recording.elapsedSeconds == 1)
        #expect(recording.level == 0.25)
        recording.cancel()
    }

    // MARK: Reading pages

    private struct Page {
        var isFirst: Bool
        var isLast: Bool
        var granule: Int64
        var sequence: UInt32
        var segments: Int
        var bodyStart: Int
    }

    private static func pages(of data: Data) -> [Page] {
        let bytes = [UInt8](data)
        var pages: [Page] = []
        var offset = 0
        while offset + 27 <= bytes.count {
            #expect(String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self) == "OggS")
            var granule: UInt64 = 0
            for index in 0..<8 { granule |= UInt64(bytes[offset + 6 + index]) << (8 * UInt64(index)) }
            var sequence: UInt32 = 0
            for index in 0..<4 { sequence |= UInt32(bytes[offset + 18 + index]) << (8 * UInt32(index)) }
            let segments = Int(bytes[offset + 26])
            let table = bytes[(offset + 27)..<(offset + 27 + segments)]
            let length = table.reduce(0) { $0 + Int($1) }
            pages.append(Page(
                isFirst: bytes[offset + 5] & 0x02 != 0,
                isLast: bytes[offset + 5] & 0x04 != 0,
                granule: Int64(bitPattern: granule),
                sequence: sequence,
                segments: segments,
                bodyStart: offset + 27 + segments
            ))
            offset += 27 + segments + length
        }
        return pages
    }
}
