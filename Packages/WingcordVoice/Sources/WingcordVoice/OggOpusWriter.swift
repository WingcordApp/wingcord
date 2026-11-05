import Foundation

// MARK: - An Ogg Opus file, a page at a time
//
// **macOS reads this format and won't write it.** `AVAudioFile` opens Ogg Opus on
// macOS 27 and refuses to create it (`fmt?`, probed, docs/VOICE-MESSAGES.md), and a
// voice message has to be one. So the container is written here, to RFC 3533 and
// RFC 7845, around packets libopus has already encoded.
//
// **To disk as it goes.** Twenty minutes of voice held in memory until Stop is what
// a crash, or a machine going to sleep, would lose.

public final class OggOpusWriter {
    public enum Failure: Error, Sendable {
        case cannotCreate
    }

    /// A page closes after this many packets: a second of 20 ms frames, which is
    /// what a player seeking through the file wants to find, and well inside a
    /// page's 255 segments at any bitrate here.
    static let packetsPerPage = 50

    private let handle: FileHandle
    private let serial: UInt32
    private let channels: UInt8
    private let preSkip: UInt16
    private var nextPageSequence: UInt32 = 0
    /// Samples at 48 kHz, counted from the first the decoder produces: the pre-skip
    /// is in it, as RFC 7845 §4 has it.
    private var granule: Int64
    private var lacing: [UInt8] = []
    private var body: [UInt8] = []
    private var packetsInPage = 0
    private var isFinished = false
    /// What's been written so far.
    public private(set) var bytesWritten = 0

    /// - Parameters:
    ///   - channels: 1 for a voice.
    ///   - preSkip: what the encoder's lookahead put in front of the sound.
    public init(url: URL, channels: UInt8 = 1, preSkip: UInt16, serial: UInt32 = .random(in: .min ... .max)) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else { throw Failure.cannotCreate }
        self.handle = handle
        self.serial = serial
        self.channels = channels
        self.preSkip = preSkip
        granule = Int64(preSkip)
        try writeHeaders()
    }

    deinit { try? handle.close() }

    /// Adds one encoded packet.
    ///
    /// - Parameter samples: how much sound it holds, at 48 kHz.
    public func append(_ packet: UnsafeBufferPointer<UInt8>, samples: Int) throws {
        // A segment table has 255 entries, and a packet takes one per 255 bytes and
        // one more to end it.
        let needed = packet.count / 255 + 1
        if packetsInPage >= Self.packetsPerPage || lacing.count + needed > 255 {
            try flush(endOfStream: false)
        }
        Self.lace(packet.count, into: &lacing)
        body.append(contentsOf: packet)
        granule += Int64(samples)
        packetsInPage += 1
    }

    /// Writes what's left, marked as the end. The last page holds at least one packet
    /// wherever there was sound, because a page only closes when another packet
    /// arrives.
    public func finish() throws {
        guard !isFinished else { return }
        isFinished = true
        try flush(endOfStream: true)
        try handle.close()
    }

    private func flush(endOfStream: Bool) throws {
        try writePage(flags: endOfStream ? 0x04 : 0, granule: granule, lacing: lacing, body: body)
        lacing.removeAll(keepingCapacity: true)
        body.removeAll(keepingCapacity: true)
        packetsInPage = 0
    }

    // MARK: Headers

    /// RFC 7845 §5: `OpusHead` alone on the first page, and `OpusTags` alone on the
    /// next, both at granule 0.
    private func writeHeaders() throws {
        var head = Array("OpusHead".utf8)
        head.append(1)
        head.append(channels)
        Self.appendLittleEndian(preSkip, to: &head)
        Self.appendLittleEndian(UInt32(48_000), to: &head)
        Self.appendLittleEndian(UInt16(0), to: &head)
        // Mapping family 0: one or two channels, in the only order there is.
        head.append(0)
        var lacing: [UInt8] = []
        Self.lace(head.count, into: &lacing)
        try writePage(flags: 0x02, granule: 0, lacing: lacing, body: head)

        var tags = Array("OpusTags".utf8)
        let vendor = Array("Wingcord".utf8)
        Self.appendLittleEndian(UInt32(vendor.count), to: &tags)
        tags.append(contentsOf: vendor)
        Self.appendLittleEndian(UInt32(0), to: &tags)
        lacing.removeAll()
        Self.lace(tags.count, into: &lacing)
        try writePage(flags: 0, granule: 0, lacing: lacing, body: tags)
    }

    // MARK: Pages

    /// RFC 3533 §6: a fixed header, the segment table, then the data, with the CRC
    /// taken over all of it with its own field zeroed.
    private func writePage(flags: UInt8, granule: Int64, lacing: [UInt8], body: [UInt8]) throws {
        var page = Array("OggS".utf8)
        page.reserveCapacity(27 + lacing.count + body.count)
        page.append(0)
        page.append(flags)
        Self.appendLittleEndian(UInt64(bitPattern: granule), to: &page)
        Self.appendLittleEndian(serial, to: &page)
        Self.appendLittleEndian(nextPageSequence, to: &page)
        let crcOffset = page.count
        Self.appendLittleEndian(UInt32(0), to: &page)
        page.append(UInt8(lacing.count))
        page.append(contentsOf: lacing)
        page.append(contentsOf: body)
        let crc = Self.checksum(page)
        withUnsafeBytes(of: crc.littleEndian) { bytes in
            for (offset, byte) in bytes.enumerated() { page[crcOffset + offset] = byte }
        }
        try handle.write(contentsOf: page)
        bytesWritten += page.count
        nextPageSequence &+= 1
    }

    /// A packet's length as segments: 255s, then whatever's left, which is what says
    /// it has ended. A packet that's an exact multiple ends on a zero.
    private static func lace(_ length: Int, into table: inout [UInt8]) {
        table.append(contentsOf: repeatElement(255, count: length / 255))
        table.append(UInt8(length % 255))
    }

    private static func appendLittleEndian(_ value: some FixedWidthInteger, to bytes: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    // MARK: The checksum

    /// Ogg's own CRC: polynomial 0x04C11DB7, most significant bit first, starting at
    /// zero and with nothing done to the result. Not the common CRC-32, whose answer
    /// a player would reject.
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0
        for byte in bytes {
            crc = (crc << 8) ^ checksumTable[Int((crc >> 24) ^ UInt32(byte))]
        }
        return crc
    }

    private static let checksumTable: [UInt32] = (0..<256).map { index in
        var entry = UInt32(index) << 24
        for _ in 0..<8 {
            entry = entry & 0x8000_0000 != 0 ? (entry << 1) ^ 0x04C1_1DB7 : entry << 1
        }
        return entry
    }
}
