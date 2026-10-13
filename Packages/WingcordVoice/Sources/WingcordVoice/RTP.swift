import Foundation
import Synchronization

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

    /// Moves the clock on **without** emitting a packet.
    ///
    /// **This is how an access unit gets one timestamp.** `next` writes the
    /// clock it holds and advances afterwards, which is right for audio — one
    /// packet is one frame — and wrong for video, where a frame is several
    /// packets that must all carry the same value. Advancing inside the loop
    /// put the first packet of every frame on the *previous* frame's timestamp,
    /// and a receiver groups packets by timestamp: the leading NAL — the
    /// parameter set on a keyframe — went into the frame before it, so no
    /// keyframe ever assembled and the far end sat on a spinner until it gave
    /// up. So the clock moves once, here, before the frame's first packet.
    public mutating func advanceClock(by samples: UInt32) {
        timestamp &+= samples
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
        let place = claim(advancingClockBy: samples)
        return Self.header(
            ssrc: ssrc, payloadType: payloadType, sequence: place.sequence,
            timestamp: place.timestamp, marker: marker, extensions: extensions
        )
    }

    /// A packet's place in the stream — its sequence number and timestamp —
    /// taken now, with the header written later by `header(…)`.
    ///
    /// **For a packet that leaves later than it is made.** Its order and its
    /// clock are decided when the frame is packetised; its send time and its
    /// transport-wide sequence are facts about leaving, and a pacer that wrote
    /// them at packetisation would tell the far end's estimator the burst it
    /// exists to avoid.
    public mutating func claim(advancingClockBy samples: UInt32 = 0)
        -> (sequence: UInt16, timestamp: UInt32)
    {
        defer {
            sequence &+= 1
            timestamp &+= samples
        }
        return (sequence, timestamp)
    }

    /// One header, for a packet whose place in its stream is already decided.
    public static func header(
        ssrc: UInt32,
        payloadType: UInt8,
        sequence: UInt16,
        timestamp: UInt32,
        marker: Bool,
        extensions: [UInt8]
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
        return RTPHeaderBytes(clear: header, encrypted: body)
    }

    private static func append32(_ value: UInt32, to bytes: inout [UInt8]) {
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

    /// The URIs the server names ids for, when it names any.
    public enum URI {
        public static let audioLevel = "urn:ietf:params:rtp-hdrext:ssrc-audio-level"
        public static let absoluteSendTime =
            "http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time"
        public static let transportSequence =
            "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"
    }

    /// The ids to use when READY names none — **read off a stream that
    /// renders**, not chosen.
    ///
    /// Discord's READY carries no `header_extensions` at all: measured on a
    /// call and on a Go Live session, three sessions running. So the code that
    /// writes extensions had nothing to key on and wrote none, and this client
    /// has been sending video packets with no extension block while every
    /// packet of a Go Live stream that Discord draws carries two:
    ///
    /// ```
    /// video ssrc=1596 seq=2826 … ext=[3:bcbbac 5:0047]
    /// video ssrc=1596 seq=2827 … ext=[3:bcbbb1 5:0048]
    /// video ssrc=1596 seq=2828 … ext=[3:bcbbb5 5:0049]
    /// ```
    ///
    /// Three bytes on id 3 climbing with the clock is the absolute send time;
    /// two bytes on id 5 climbing by exactly one per packet is the
    /// transport-wide sequence number. Both are what an SFU measures a
    /// publisher's path with, and neither was being sent.
    ///
    /// A named id still wins — see §"An empty field in READY is an absence".
    public enum DefaultID {
        public static let absoluteSendTime: UInt8 = 3
        public static let transportSequence: UInt8 = 5
    }

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

    /// `http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01`.
    ///
    /// Two bytes: a counter that advances **once per packet across every stream
    /// on the connection**, which is what makes it transport-wide. A per-stream
    /// counter looks to the receiver like a path losing every other packet, so
    /// the sequence is owned by the session and shared by the audio and video
    /// paths — see `TransportSequence`.
    public static func transportSequence(id: UInt8, sequence: UInt16) -> [UInt8] {
        [
            id << 4 | 1,
            UInt8(truncatingIfNeeded: sequence >> 8),
            UInt8(truncatingIfNeeded: sequence),
        ]
    }

}

// MARK: - The connection's packet counter

/// The transport-wide sequence number, shared by every stream on one socket.
///
/// A reference type holding the atomic, for the reason `VoiceAudioEngine.Levels`
/// is one: `Atomic` is non-copyable, so a `@Sendable` closure cannot capture one
/// out of an enclosing type without consuming it. Read from the microphone's
/// thread and the encoder's callback thread, which is why it is atomic rather
/// than a plain counter.
public final class TransportSequence: Sendable {
    private let value = Atomic<UInt32>(0)

    public init() {}

    /// The next number, wrapping at sixteen bits as the extension does.
    public func next() -> UInt16 {
        UInt16(truncatingIfNeeded: value.add(1, ordering: .relaxed).oldValue)
    }
}
