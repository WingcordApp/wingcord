import Foundation

// MARK: - RTP
//
// The wire format under every audio and video packet on this connection. It is
// tiny, it is fixed by RFC 3550, and two details in it decide whether the
// encryption above works at all:
//
//   1. The **clear prefix** is computed from the packet's own bits, never
//      assumed. See `VoiceCrypto`.
//   2. A one-byte header extension (RFC 8285) is what Discord uses to carry the
//      audio level and the send time, and its `length` field counts **32-bit
//      words after the four-byte extension header**, not bytes.

public enum RTP {
    public static let headerLength = 12
    public static let version: UInt8 = 2

    /// Discord's payload types, as published in the voice READY's codec list.
    /// Named rather than looked up: the list has been stable for years and the
    /// negotiated value is checked against these at connect time, so a change
    /// shows up as a refusal to send rather than as a stream nobody can decode.
    public enum PayloadType {
        public static let opus: UInt8 = 120
        public static let h264: UInt8 = 101
        public static let h264RTX: UInt8 = 102
    }

    /// RFC 8285's one-byte extension profile.
    public static let oneByteExtensionProfile: UInt16 = 0xBEDE
}

/// Everything a receiver needs from a packet before it decrypts it.
public struct RTPHeader: Sendable, Equatable {
    public var payloadType: UInt8
    public var marker: Bool
    public var sequence: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32
    /// How many bytes at the front of the packet are in the clear. This is the
    /// AAD, and computing it wrong is the difference between a stream and
    /// silence.
    ///
    /// **It stops at the extension PREAMBLE.** Twelve bytes, plus four per
    /// CSRC, plus the four-byte `0xBEDE`-and-length preamble when the X bit is
    /// set — and *not* the extension body after it. That is a deliberate
    /// departure from SRTP, which leaves every extension in the clear:
    /// Discord begins encrypting immediately after the preamble, so the
    /// extension elements are ciphertext. Authenticating them as though they
    /// were clear fails every packet that carries an extension, which is all
    /// of them.
    public var clearPrefixLength: Int
    /// The extension elements, which are encrypted and therefore arrive at the
    /// front of the decrypted plaintext rather than in the header.
    public var extensionBodyLength: Int
    /// Whether the payload ends in padding whose final octet counts it.
    ///
    /// **§5.1, and skipping it costs the whole call.** Discord pads audio, and
    /// the padding sits *inside* the encrypted region — so it decrypts
    /// perfectly and then sits between the media and the end of the buffer,
    /// where a receiver looking for a footer finds filler instead. Measured:
    /// a frame arriving as 174 bytes ending in twelve `0x75`s, which is 117
    /// bytes of padding announcing itself in its own last octet.
    public var hasPadding: Bool

    /// Reads a header without copying the packet.
    ///
    /// Returns nil for anything that is not RTP version 2 or is too short to
    /// hold what its own bits claim — a UDP socket receives whatever is sent to
    /// it, including the voice server's own keepalives and anything else that
    /// finds the port.
    public init?(parsing packet: [UInt8]) {
        guard packet.count >= RTP.headerLength else { return nil }
        guard packet[0] >> 6 == RTP.version else { return nil }

        let csrcCount = Int(packet[0] & 0x0F)
        let hasExtension = packet[0] & 0x10 != 0
        hasPadding = packet[0] & 0x20 != 0
        var prefix = RTP.headerLength + csrcCount * 4
        guard packet.count >= prefix else { return nil }

        var extensionBody = 0
        if hasExtension {
            guard packet.count >= prefix + 4 else { return nil }
            // Words, not bytes — and the four-byte preamble is not counted in
            // them. The preamble joins the clear prefix; the words do not.
            let words = Int(packet[prefix + 2]) << 8 | Int(packet[prefix + 3])
            prefix += 4
            extensionBody = words * 4
            guard packet.count >= prefix + extensionBody else { return nil }
        }

        payloadType = packet[1] & 0x7F
        marker = packet[1] & 0x80 != 0
        sequence = UInt16(packet[2]) << 8 | UInt16(packet[3])
        timestamp = UInt32(packet[4]) << 24 | UInt32(packet[5]) << 16
            | UInt32(packet[6]) << 8 | UInt32(packet[7])
        ssrc = UInt32(packet[8]) << 24 | UInt32(packet[9]) << 16
            | UInt32(packet[10]) << 8 | UInt32(packet[11])
        clearPrefixLength = prefix
        extensionBodyLength = extensionBody
    }
}

/// One outgoing header, split where Discord splits it.
///
/// **The two halves are not interchangeable and the split is the protocol.**
/// `clear` is written to the wire untouched and authenticated as the AAD;
/// `encrypted` is the extension body, which goes *inside* the ciphertext ahead
/// of the media. Returning them as one array is what made every packet this
/// client sent unreadable to Discord, so they are returned as two.
public struct RTPHeaderBytes: Sendable {
    public var clear: [UInt8] = []
    public var encrypted: [UInt8] = []

    public init(clear: [UInt8] = [], encrypted: [UInt8] = []) {
        self.clear = clear
        self.encrypted = encrypted
    }
}

/// Builds outgoing headers for one stream.
///
/// One writer per SSRC, and it owns that stream's sequence number and
/// timestamp — the two pieces of state a receiver's jitter buffer is built on.
/// Sharing a writer between the microphone and the camera would interleave two
/// sequence spaces into one and make both undecodable.
public struct RTPWriter: Sendable {
    public let ssrc: UInt32
    public let payloadType: UInt8
    private(set) public var sequence: UInt16
    private(set) public var timestamp: UInt32

    public init(ssrc: UInt32, payloadType: UInt8) {
        self.ssrc = ssrc
        self.payloadType = payloadType
        // A stream that always starts at zero is a stream whose first packets
        // collide with the previous session's in any receiver that has not
        // timed the old SSRC out. RFC 3550 asks for random starts for exactly
        // that reason.
        sequence = UInt16.random(in: 0...UInt16.max)
        timestamp = UInt32.random(in: 0...UInt32.max)
    }

    /// The next header, advancing the sequence by one and the clock by
    /// `samples`.
    ///
    /// `extensions` is the RFC 8285 body — id/length-prefixed elements, already
    /// packed. Empty means no extension block and no X bit, which is what an
    /// audio packet with nothing to say about itself should send.
    public mutating func next(
        advancingClockBy samples: UInt32,
        marker: Bool = false,
        extensions: [UInt8] = []
    ) -> RTPHeaderBytes {
        var header = [UInt8]()
        header.reserveCapacity(RTP.headerLength + (extensions.isEmpty ? 0 : 4))

        let hasExtension = !extensions.isEmpty
        header.append(RTP.version << 6 | (hasExtension ? 0x10 : 0))
        header.append(payloadType | (marker ? 0x80 : 0))
        header.append(UInt8(truncatingIfNeeded: sequence >> 8))
        header.append(UInt8(truncatingIfNeeded: sequence))
        append32(timestamp, to: &header)
        append32(ssrc, to: &header)

        var body = [UInt8]()
        if hasExtension {
            // Padded to a word boundary with zeroes, which RFC 8285 defines as
            // the no-op element id. A receiver that stops at the first zero
            // reads exactly the elements that were written.
            let padded = (extensions.count + 3) / 4 * 4
            header.append(UInt8(truncatingIfNeeded: RTP.oneByteExtensionProfile >> 8))
            header.append(UInt8(truncatingIfNeeded: RTP.oneByteExtensionProfile))
            header.append(UInt8(truncatingIfNeeded: (padded / 4) >> 8))
            header.append(UInt8(truncatingIfNeeded: padded / 4))
            body.reserveCapacity(padded)
            body.append(contentsOf: extensions)
            body.append(contentsOf: repeatElement(0, count: padded - extensions.count))
        }

        sequence &+= 1
        timestamp &+= samples
        return RTPHeaderBytes(clear: header, encrypted: body)
    }

    private func append32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }
}

// MARK: - Header extensions

/// The RFC 8285 elements this client writes.
///
/// **Both of these are the difference between a stream the reference client
/// renders and one it ignores.** Discord's server negotiates extension ids in
/// the voice READY's `header_extensions`, and the two that matter are the audio
/// level — which is what drives the speaking ring around somebody's tile in
/// every other client — and the absolute send time, which is what its bandwidth
/// estimator uses to decide the video bitrate it will ask you for. A video
/// stream sent without abs-send-time is a stream the far end never raises the
/// quality of, because it has nothing to measure the path with.
public enum RTPExtension {
    /// `urn:ietf:params:rtp-hdrext:ssrc-audio-level` — RFC 6464.
    ///
    /// One byte: the voice-activity bit, then the level as **positive dBov**,
    /// so 0 is full scale and 127 is silence. Sent inverted from the natural
    /// reading, which is the trap in the RFC.
    public static func audioLevel(id: UInt8, dBov: UInt8, isVoice: Bool) -> [UInt8] {
        [id << 4 | 0, (isVoice ? 0x80 : 0) | min(dBov, 127)]
    }

    /// `http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time`.
    ///
    /// Three bytes: seconds in 6.18 fixed point, wrapping every 64 seconds.
    /// Taken from the wall clock at the moment the packet leaves, never from
    /// the media clock — the whole point is that it measures the *network*.
    public static func absoluteSendTime(id: UInt8, seconds: Double) -> [UInt8] {
        let fixed = UInt32((seconds * 262_144.0).rounded()) & 0x00FF_FFFF
        return [
            id << 4 | 2,
            UInt8(truncatingIfNeeded: fixed >> 16),
            UInt8(truncatingIfNeeded: fixed >> 8),
            UInt8(truncatingIfNeeded: fixed),
        ]
    }

    /// Reads one element out of an extension block. Used to recover a speaker's
    /// level from an incoming packet, which is what lights their tile without
    /// waiting for the gateway's own speaking event.
    public static func firstElement(id wanted: UInt8, in packet: [UInt8]) -> [UInt8]? {
        guard packet.count > RTP.headerLength, packet[0] & 0x10 != 0 else { return nil }
        var index = RTP.headerLength + Int(packet[0] & 0x0F) * 4
        guard packet.count >= index + 4 else { return nil }
        guard packet[index] == 0xBE, packet[index + 1] == 0xDE else { return nil }
        let words = Int(packet[index + 2]) << 8 | Int(packet[index + 3])
        let end = index + 4 + words * 4
        guard packet.count >= end else { return nil }
        index += 4

        while index < end {
            let byte = packet[index]
            if byte == 0 { index += 1; continue }   // padding
            let id = byte >> 4
            let length = Int(byte & 0x0F) + 1
            guard index + 1 + length <= end else { return nil }
            if id == wanted { return Array(packet[(index + 1)..<(index + 1 + length)]) }
            index += 1 + length
        }
        return nil
    }
}
