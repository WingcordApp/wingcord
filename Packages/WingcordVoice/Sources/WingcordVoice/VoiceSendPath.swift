import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import Synchronization

// MARK: - Outbound media
//
// Two paths, one socket, one key. They are separate objects because they run on
// separate threads with separate clocks — the microphone's tap fires every 20 ms
// on the audio device's thread, VideoToolbox's callback fires per frame on its
// own queue — and a single lock over both would put the encoder's completion in
// line behind a microphone frame fifty times a second.
//
// Neither is an actor. Both are called from a real-time or near-real-time
// context that cannot suspend, and an `await` between the microphone and the
// socket is jitter this client would be adding to a path that already has some.

/// Whether the microphone is open right now.
///
/// Two gates in one: what the reader chose — muted, push-to-talk, always open —
/// and, for voice activity, whether there is a voice. The **hangover** is the
/// part that is easy to leave out and impossible to unhear: a gate that closes
/// the instant the level drops clips the end of every word, so it stays open for
/// a quarter of a second after the last frame that cleared the threshold.
struct TransmitGate {
    var mode: VoiceEngine.InputMode = .voiceActivity(threshold: 0.03)
    var isPushToTalkHeld = false
    private var hangover = 0
    /// 12 frames at 20 ms. Shorter clips words; longer and the gate never
    /// closes in a room with any noise in it, which is the whole point of one.
    private static let hangoverFrames = 12

    private(set) var isOpen = false

    /// - Returns: whether this frame should be sent, and whether the open state
    ///   changed — the caller reports the change so a speaking ring lights on
    ///   the same frame the audio starts.
    mutating func admit(level: Float, isMuted: Bool) -> (send: Bool, changed: Bool) {
        let wasOpen = isOpen
        guard !isMuted else {
            hangover = 0
            isOpen = false
            return (false, wasOpen)
        }
        switch mode {
        case .open:
            isOpen = true
        case .pushToTalk:
            isOpen = isPushToTalkHeld
        case .voiceActivity(let threshold):
            if level >= threshold {
                hangover = Self.hangoverFrames
                isOpen = true
            } else if hangover > 0 {
                hangover -= 1
                isOpen = true
            } else {
                isOpen = false
            }
        }
        return (isOpen, isOpen != wasOpen)
    }
}

/// One tap buffer, promised not to outlive the call it was handed to.
///
/// A pointer is not `Sendable`, and a raw one captured into a `withLock`
/// closure merges the caller's region with the lock's — after which the
/// compiler cannot prove the locked state is disconnected when the closure
/// returns, and refuses. This is the promise made explicit: the frame is read
/// synchronously inside the lock and nothing keeps it.
private struct CapturedFrame: @unchecked Sendable {
    let base: UnsafePointer<Int16>
}

/// The microphone's half.
final class AudioSendPath: Sendable {
    private let state = Mutex(State())

    private struct State {
        var sealer: VoiceSealer?
        /// The call's end-to-end transform, when the session has one. Nothing
        /// leaves this path unprotected while it is set — see `send`.
        var dave: DAVEEncryptor?
        var encoder: OpusEncoder?
        var transport: VoiceTransport?
        var writer: RTPWriter?
        var scratch = [UInt8](repeating: 0, count: OpusFormat.maximumPacketBytes)
        var gate = TransmitGate()
        var isMuted = false
        var audioLevelExtensionID: UInt8?
        var sendTimeExtensionID: UInt8?
        var packetsSent = 0
        var bytesSent = 0
        /// Sent once when the gate closes, so a receiver's decoder is told the
        /// stream stopped rather than left to conceal indefinitely. Opus's own
        /// three-byte silence frame, five times, is what every client sends.
        var silenceFramesRemaining = 0
    }

    /// Told when the gate opens or closes, so the gateway's speaking state and
    /// the local tile can follow the audio rather than a timer.
    let onGateChanged = Mutex<(@Sendable (Bool) -> Void)?>(nil)

    init() {}

    func configure(
        sealer: VoiceSealer,
        transport: VoiceTransport,
        ssrc: UInt32,
        bitrate: Int,
        audioLevelExtensionID: UInt8?,
        sendTimeExtensionID: UInt8?
    ) {
        state.withLock { state in
            state.sealer = sealer
            state.transport = transport
            state.writer = RTPWriter(ssrc: ssrc, payloadType: RTP.PayloadType.opus)
            state.encoder = try? OpusEncoder(bitrate: Int32(bitrate))
            state.audioLevelExtensionID = audioLevelExtensionID
            state.sendTimeExtensionID = sendTimeExtensionID
        }
    }

    /// Installs the call's end-to-end transform, or clears it for a session
    /// the server said needs none.
    func setDAVE(_ encryptor: DAVEEncryptor?) {
        state.withLock { $0.dave = encryptor }
    }

    func teardown() {
        state.withLock { state in
            state.sealer = nil
            state.dave = nil
            state.encoder = nil
            state.transport = nil
            state.writer = nil
        }
    }

    var isMuted: Bool {
        get { state.withLock { $0.isMuted } }
        set { state.withLock { $0.isMuted = newValue } }
    }

    var inputMode: VoiceEngine.InputMode {
        get { state.withLock { $0.gate.mode } }
        set { state.withLock { $0.gate.mode = newValue } }
    }

    var isPushToTalkHeld: Bool {
        get { state.withLock { $0.gate.isPushToTalkHeld } }
        set { state.withLock { $0.gate.isPushToTalkHeld = newValue } }
    }

    var isOpen: Bool { state.withLock { $0.gate.isOpen } }

    func updateExpectedLoss(percent: Int) {
        state.withLock { $0.encoder?.updateExpectedLoss(percent: percent) }
    }

    func setBitrate(_ bitrate: Int) {
        state.withLock { $0.encoder?.setBitrate(Int32(bitrate)) }
    }

    /// Bytes sent since the last call, and the running packet count.
    func drainCounters() -> (packets: Int, bytes: Int) {
        state.withLock { state in
            let value = (state.packetsSent, state.bytesSent)
            state.bytesSent = 0
            return value
        }
    }

    /// One 20 ms frame from the capture tap. Runs on the audio device's thread.
    func send(_ samples: UnsafePointer<Int16>, level: Float) {
        var gateChange: Bool?
        // **The pointer is deliberately taken out of the caller's region.**
        // `withLock` hands its state over as `inout sending`, so a raw pointer
        // captured from the caller merges the two and the compiler — correctly
        // — will not then prove the state is disconnected afterwards. The
        // samples are read and encoded before this call returns and are never
        // stored anywhere, which is exactly the promise the wrapper makes.
        let input = CapturedFrame(base: samples)

        state.withLock { state in
            let decision = state.gate.admit(level: level, isMuted: state.isMuted)
            if decision.changed {
                gateChange = state.gate.isOpen
                // Closing sends five Opus silence frames. Without them the far
                // end's concealer has nothing telling it the stream ended and
                // extrapolates the last vowel into a quarter second of tone.
                if !state.gate.isOpen { state.silenceFramesRemaining = 5 }
            }

            guard let sealer = state.sealer, let transport = state.transport else { return }

            if !decision.send {
                guard state.silenceFramesRemaining > 0 else { return }
                state.silenceFramesRemaining -= 1
                let header = state.writer?.next(advancingClockBy: OpusFormat.clockAdvance) ?? RTPHeaderBytes()
                let silence: [UInt8] = [0xF8, 0xFF, 0xFE]
                // Encrypted like any other frame rather than sent bare. The
                // receiver's passthrough for this exact byte sequence exists
                // for silence the *server* synthesises; ours is media, and
                // media this client sends is protected without exception.
                guard let frame = Self.transform(silence, state: state) else { return }
                if let packet = try? frame.withUnsafeBytes({
                    try sealer.seal(payload: $0, header: header)
                }) {
                    transport.send(packet)
                    state.packetsSent += 1
                    state.bytesSent += packet.count
                }
                return
            }
            state.silenceFramesRemaining = 0

            guard let encoder = state.encoder,
                  let length = try? encoder.encode(input.base, into: &state.scratch),
                  length > 0
            else { return }

            var extensions: [UInt8] = []
            if let id = state.audioLevelExtensionID {
                // RFC 6464's level is POSITIVE dBov: 0 is full scale, 127 is
                // silence. Sending the natural reading inverts every speaking
                // ring in the call.
                let dBov = level > 0.0001
                    ? UInt8(min(127, max(0, (-20 * log10(level)).rounded())))
                    : 127
                extensions += RTPExtension.audioLevel(id: id, dBov: dBov, isVoice: true)
            }
            if let id = state.sendTimeExtensionID {
                extensions += RTPExtension.absoluteSendTime(id: id, seconds: Self.sendClock())
            }

            let header = state.writer?.next(
                advancingClockBy: OpusFormat.clockAdvance,
                extensions: extensions
            ) ?? RTPHeaderBytes()
            // **End-to-end first, transport second.** DAVE protects the encoded
            // frame; the transport cipher then protects the packet carrying it.
            // A frame the transform will not produce is dropped rather than
            // sent, because sending it would mean sending media the call has
            // told the person it is end-to-end encrypting.
            guard let frame = Self.transform(
                Array(state.scratch[0..<length]), state: state
            ) else { return }
            guard let packet = try? frame.withUnsafeBytes({ buffer in
                try sealer.seal(payload: buffer, header: header)
            }) else { return }
            transport.send(packet)
            state.packetsSent += 1
            state.bytesSent += packet.count
        }

        if let gateChange { onGateChanged.withLock { $0 }?(gateChange) }
    }

    /// Applies the end-to-end transform when there is one, and refuses to fall
    /// back to plaintext when there is one and it fails.
    private static func transform(_ frame: [UInt8], state: State) -> [UInt8]? {
        guard let dave = state.dave else { return frame }
        return dave.encrypt(frame, codec: .opus)
    }

    /// Wall clock seconds, wrapped to the 64-second window abs-send-time uses.
    static func sendClock() -> Double {
        Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 64)
    }
}

/// The camera's and the screen's half.
///
/// One path for both, because only one of them can be the video stream at a
/// time from the protocol's point of view: Discord carries a screen share as a
/// second *stream* on a second connection, and a camera as this one. What
/// changes between them is the encoder's size and rate, which is a
/// reconfiguration rather than a second socket.
final class VideoSendPath: Sendable {
    private let state = Mutex(State())

    private struct State {
        var sealer: VoiceSealer?
        var dave: DAVEEncryptor?
        var transport: VoiceTransport?
        var writer: RTPWriter?
        var sendTimeExtensionID: UInt8?
        var isActive = false
        var packetsSent = 0
        var bytesSent = 0
        /// Set when the far end needs a fresh keyframe — at start, and after a
        /// receiver reports it lost one.
        var needsKeyframe = true
    }

    init() {}

    func configure(
        sealer: VoiceSealer,
        transport: VoiceTransport,
        ssrc: UInt32,
        sendTimeExtensionID: UInt8?
    ) {
        state.withLock { state in
            state.sealer = sealer
            state.transport = transport
            state.writer = RTPWriter(ssrc: ssrc, payloadType: RTP.PayloadType.h264)
            state.sendTimeExtensionID = sendTimeExtensionID
        }
    }

    func setDAVE(_ encryptor: DAVEEncryptor?) {
        state.withLock { $0.dave = encryptor }
    }

    var isActive: Bool {
        get { state.withLock { $0.isActive } }
        set { state.withLock { state in
            state.isActive = newValue
            if newValue { state.needsKeyframe = true }
        } }
    }

    func requestKeyframe() { state.withLock { $0.needsKeyframe = true } }

    func takeKeyframeRequest() -> Bool {
        state.withLock { state in
            defer { state.needsKeyframe = false }
            return state.needsKeyframe
        }
    }

    func drainCounters() -> (packets: Int, bytes: Int) {
        state.withLock { state in
            let value = (state.packetsSent, state.bytesSent)
            state.bytesSent = 0
            return value
        }
    }

    func teardown() {
        state.withLock { state in
            state.sealer = nil
            state.dave = nil
            state.transport = nil
            state.writer = nil
            state.isActive = false
        }
    }

    /// One encoded access unit, from VideoToolbox's callback thread.
    ///
    /// **The 90 kHz clock is the video clock and it is not the audio one.** RTP
    /// timestamps for H.264 advance at 90,000 ticks a second regardless of the
    /// frame rate; using the frame index, or the audio's 48 kHz, produces a
    /// stream whose playout rate every receiver computes wrongly.
    func send(units: [[UInt8]], parameterSets: [[UInt8]], presentationTime: Double) {
        state.withLock { state in
            guard state.isActive,
                  let sealer = state.sealer,
                  let transport = state.transport
            else { return }

            // **DAVE transforms the whole access unit, not each NAL.** The
            // frame is rebuilt in Annex B — parameter sets first, then the
            // units, each behind a four-byte start code — transformed, and
            // split again. That is the exact shape WebRTC's depacketizer
            // reconstructs at the far end, which is what the transform's
            // authenticated bytes are computed over.
            let payloads: [[UInt8]]
            if let dave = state.dave {
                let frame = H264.annexB(units: parameterSets + units)
                guard let sealed = dave.encrypt(frame, codec: .h264) else { return }
                payloads = H264.packetize(
                    nalUnits: H264.splitAnnexB(sealed), parameterSets: []
                )
            } else {
                payloads = H264.packetize(nalUnits: units, parameterSets: parameterSets)
            }
            guard !payloads.isEmpty else { return }
            let timestamp = UInt32(
                truncatingIfNeeded: Int64((presentationTime * 90_000).rounded())
            )
            let clock = state.writer?.timestamp ?? 0
            let advance = timestamp &- clock

            for (index, payload) in payloads.enumerated() {
                var extensions: [UInt8] = []
                if let id = state.sendTimeExtensionID {
                    extensions += RTPExtension.absoluteSendTime(
                        id: id, seconds: AudioSendPath.sendClock()
                    )
                }
                // **Every packet of one frame carries the SAME timestamp, and
                // the last one carries the marker.** That pair is how a receiver
                // knows where an access unit ends; a packetiser that advances
                // the clock per packet produces a stream that decodes to one
                // frame per NAL and plays at fifty times the intended rate.
                let isLast = index == payloads.count - 1
                let header = state.writer?.next(
                    advancingClockBy: index == 0 ? advance : 0,
                    marker: isLast,
                    extensions: extensions
                ) ?? RTPHeaderBytes()
                guard let packet = try? payload.withUnsafeBytes({
                    try sealer.seal(payload: $0, header: header)
                }) else { continue }
                transport.send(packet)
                state.packetsSent += 1
                state.bytesSent += packet.count
            }
        }
    }
}

// MARK: - The video encoder, reachable from the capture thread

/// Owns the compression session and the stream's clock.
///
/// Separate from `VideoSendPath` because it sits on the *other* side of
/// VideoToolbox: the capture queue pushes frames in and the encoder's own
/// callback thread pushes packets out, and the two must not queue behind each
/// other. Separate from `VoiceEngine` because a camera frame arriving cannot
/// afford an actor hop — thirty a second, each one behind whatever the control
/// plane happens to be doing.
final class VideoEncodePath: Sendable {
    /// One camera or screen frame, promised not to outlive the call.
    ///
    /// The same wrapper as `CapturedFrame` and for the same reason: a
    /// `CVPixelBuffer` is not `Sendable`, it is IOSurface-backed and safe to
    /// hand to VideoToolbox from any thread, and it is submitted synchronously
    /// and never stored.
    struct Frame: @unchecked Sendable {
        let pixels: CVPixelBuffer
    }

    private let state = Mutex(State())

    private struct State {
        var encoder: H264Encoder?
        var start: CFTimeInterval = 0
    }

    init() {}

    func begin(_ encoder: H264Encoder) {
        state.withLock { state in
            state.encoder?.teardown()
            state.encoder = encoder
            state.start = CACurrentMediaTime()
        }
    }

    func end() {
        state.withLock { state in
            state.encoder?.teardown()
            state.encoder = nil
        }
    }

    func reconfigure(_ configuration: H264Encoder.Configuration) {
        state.withLock { $0.encoder?.reconfigure(configuration) }
    }

    /// Called on the capture queue, once per frame.
    func submit(_ frame: Frame, forceKeyframe: Bool) {
        state.withLock { state in
            guard let encoder = state.encoder else { return }
            let elapsed = CACurrentMediaTime() - state.start
            encoder.encode(
                frame.pixels,
                at: CMTime(seconds: elapsed, preferredTimescale: 90_000),
                forceKeyframe: forceKeyframe
            )
        }
    }
}
