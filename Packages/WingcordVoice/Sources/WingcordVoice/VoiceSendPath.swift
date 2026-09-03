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

    /// The level this gate is measuring against, or `nil` for a mode that does
    /// not measure one. Reported when nothing is being sent, because a gate
    /// that never opens and a microphone that never works look identical from
    /// every other counter.
    var threshold: Float? {
        if case .voiceActivity(let threshold) = mode { threshold } else { nil }
    }

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

    /// What this path did since the last drain.
    ///
    /// **It carries the gate as well as the packet count**, because `out=0` on
    /// its own is not a diagnosis: a shut gate, a muted microphone and a dead
    /// encoder all produce it, and they are three different things to fix.
    struct Report {
        var packets = 0
        var bytes = 0
        /// Frames the capture tap offered. Zero means the microphone stopped,
        /// not that the gate is shut.
        var offered = 0
        /// The loudest of them, 0…1.
        var peak: Float = 0
        var isGateOpen = false
        var isMuted = false
        var threshold: Float?
    }

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
        var transportSequenceExtensionID: UInt8?
        /// Shared with the video path, because the counter is transport-wide.
        var transportSequence: TransportSequence?
        var packetsSent = 0
        var bytesSent = 0
        /// Frames the tap offered since the last drain, and the loudest of
        /// them. The two numbers that tell a shut gate from a dead microphone.
        var framesOffered = 0
        var peakLevel: Float = 0
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
        sendTimeExtensionID: UInt8?,
        transportSequenceExtensionID: UInt8?,
        transportSequence: TransportSequence?
    ) {
        state.withLock { state in
            state.sealer = sealer
            state.transport = transport
            state.writer = RTPWriter(ssrc: ssrc, payloadType: RTP.PayloadType.opus)
            state.encoder = try? OpusEncoder(bitrate: Int32(bitrate))
            state.audioLevelExtensionID = audioLevelExtensionID
            state.sendTimeExtensionID = sendTimeExtensionID
            state.transportSequenceExtensionID = transportSequenceExtensionID
            state.transportSequence = transportSequence
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

    /// The running packet count, the bytes since the last drain, and what the
    /// gate was doing while they happened.
    func drainCounters() -> Report {
        state.withLock { state in
            let report = Report(
                packets: state.packetsSent,
                bytes: state.bytesSent,
                offered: state.framesOffered,
                peak: state.peakLevel,
                isGateOpen: state.gate.isOpen,
                isMuted: state.isMuted,
                threshold: state.gate.threshold
            )
            state.bytesSent = 0
            state.framesOffered = 0
            state.peakLevel = 0
            return report
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
            state.framesOffered += 1
            state.peakLevel = max(state.peakLevel, level)

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
            if let id = state.transportSequenceExtensionID,
               let sequence = state.transportSequence?.next() {
                extensions += RTPExtension.transportSequence(id: id, sequence: sequence)
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

    /// What this path did since the last drain.
    ///
    /// **The same bargain `AudioSendPath.Report` makes, and for the same
    /// reason.** §1.5 says `out=0` must carry the reason it is zero, and until
    /// this existed only the audio half kept it: a black screen share and a
    /// black camera and a camera that was never turned on all produced one
    /// number, and the four stages that each produce it — never activated, no
    /// frame arriving from the capture, a transform refusing the frame, a
    /// packetiser emitting nothing — were indistinguishable from outside.
    ///
    /// Measured: a screen share reported `out=` a healthy audio count and no
    /// video term at all, on a call where nothing of the screen ever left.
    struct Report {
        var packets = 0
        var bytes = 0
        /// Access units the encoder handed over. Zero with `isActive` true
        /// means the capture or the encoder stopped, not the transform.
        var offered = 0
        /// Of those, the ones the end-to-end transform refused. **Dropped, never
        /// sent in the clear** — §1.5 — so a non-zero here is frames the far end
        /// will never see and the only place that says so.
        var refused = 0
        /// Frames held back because the stream has not opened with a keyframe
        /// yet. See `hasSentKeyframe`: a handful at the start of every stream
        /// is correct and expected; a count that never stops climbing is an
        /// encoder that is not answering the keyframe request.
        var unstartable = 0
        /// Whether anything was allowed to send at all.
        var isActive = false
    }

    private struct State {
        var sealer: VoiceSealer?
        var dave: DAVEEncryptor?
        var transport: VoiceTransport?
        var writer: RTPWriter?
        var sendTimeExtensionID: UInt8?
        var transportSequenceExtensionID: UInt8?
        /// The connection's packet counter, shared with the audio path so the
        /// numbers are transport-wide. See `TransportSequence`.
        var transportSequence: TransportSequence?
        /// Which session's video this is, for the trace. A call and a share
        /// each own one of these and both wrote the same line.
        var label = ""
        var isActive = false
        var packetsSent = 0
        var bytesSent = 0
        var framesOffered = 0
        var framesRefused = 0
        var framesUnstartable = 0
        /// Set when the far end needs a fresh keyframe — at start, and after a
        /// receiver reports it lost one.
        var needsKeyframe = true
        /// Whether a keyframe has actually reached the wire on this stream.
        ///
        /// **A stream's first transmitted access unit has to be a keyframe, and
        /// nothing above this can guarantee it.** The encoder's IDR is produced
        /// the moment the capture starts — half a second before the MLS group
        /// exists — so it is refused, correctly, and dropped; what follows is a
        /// run of P-slices under a working key that no decoder on earth can
        /// start from. Measured twice, in two sessions, as `video first frame
        /// in=[1:17455]` against the `in=[7:20 8:4 5:101265]` the same code
        /// produced on a run where the group happened to win the race.
        ///
        /// Both earlier fixes were orderings — start the capture last, ask for
        /// a keyframe when the keys arrive — and an ordering is a race that has
        /// been arranged to usually come out right. This is the invariant
        /// itself: until a keyframe has left, nothing else may.
        var hasSentKeyframe = false
        /// Whether the first access unit of this stream has described itself.
        /// **Once per stream** — this runs up to sixty times a second.
        var hasDescribedFrame = false
    }

    /// What one access unit looked like on the way out, in one line.
    ///
    /// **The encoder and the packetiser are the only part of the video path
    /// nothing has ever checked against another implementation.** The DAVE
    /// transform is pinned against `libdave` line by line and the receive side
    /// is proved by decoding somebody else's camera; what is left is whether
    /// what leaves here is what a WebRTC depacketiser reassembles. A round trip
    /// through this client's own reassembler cannot answer that — it uses the
    /// same split in both directions, so an error in it cancels out.
    private static func describe(
        units: [[UInt8]], parameterSets: [[UInt8]], sealed: [UInt8], payloads: [[UInt8]]
    ) -> String {
        func naming(_ list: [[UInt8]]) -> String {
            list.map { "\($0.first.map { $0 & 0x1F } ?? 0):\($0.count)" }.joined(separator: " ")
        }
        return "video first frame in=[\(naming(parameterSets + units))] "
            + "sealed=\(sealed.count)B split=[\(naming(H264.splitAnnexB(sealed)))] "
            + "packets=[\(naming(payloads))]"
    }

    init() {}

    func configure(
        sealer: VoiceSealer,
        transport: VoiceTransport,
        ssrc: UInt32,
        sendTimeExtensionID: UInt8?,
        transportSequenceExtensionID: UInt8?,
        transportSequence: TransportSequence?,
        label: String
    ) {
        state.withLock { state in
            state.sealer = sealer
            state.transport = transport
            state.writer = RTPWriter(ssrc: ssrc, payloadType: RTP.PayloadType.h264)
            state.sendTimeExtensionID = sendTimeExtensionID
            state.transportSequenceExtensionID = transportSequenceExtensionID
            state.transportSequence = transportSequence
            state.label = label
        }
    }

    func setDAVE(_ encryptor: DAVEEncryptor?) {
        state.withLock { $0.dave = encryptor }
    }

    var isActive: Bool {
        get { state.withLock { $0.isActive } }
        set { state.withLock { state in
            state.isActive = newValue
            if newValue {
                state.needsKeyframe = true
                state.hasSentKeyframe = false
                state.hasDescribedFrame = false
            }
        } }
    }


    /// Asks the encoder for a keyframe on its next frame.
    ///
    /// **A receiver cannot start on anything else.** A viewer who presses watch
    /// halfway through a share has no parameter sets and no reference frame,
    /// and nothing this client sends until the next keyframe means anything to
    /// them — which is a black rectangle for however long that is.
    func requestKeyframe() {
        state.withLock { $0.needsKeyframe = true }
    }

    func takeKeyframeRequest() -> Bool {
        state.withLock { state in
            defer { state.needsKeyframe = false }
            return state.needsKeyframe
        }
    }

    func drainCounters() -> Report {
        state.withLock { state in
            let report = Report(
                packets: state.packetsSent,
                bytes: state.bytesSent,
                offered: state.framesOffered,
                refused: state.framesRefused,
                unstartable: state.framesUnstartable,
                isActive: state.isActive
            )
            state.bytesSent = 0
            state.framesOffered = 0
            state.framesRefused = 0
            state.framesUnstartable = 0
            return report
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
    func send(
        units: [[UInt8]],
        parameterSets: [[UInt8]],
        isKeyframe: Bool,
        presentationTime: Double
    ) {
        state.withLock { state in
            // Counted before the guard, so a frame arriving at a path that is
            // not active is distinguishable from no frame arriving at all.
            state.framesOffered += 1
            guard state.isActive,
                  let sealer = state.sealer,
                  let transport = state.transport
            else { return }

            // **Nothing leaves before a keyframe has.** See `hasSentKeyframe`.
            // Asking again rather than only dropping: the request is spent on
            // the capture's next frame, so a stream that starts mid-GOP opens
            // one frame later instead of waiting out the encoder's own two
            // second cadence.
            guard state.hasSentKeyframe || isKeyframe else {
                state.needsKeyframe = true
                state.framesUnstartable += 1
                return
            }

            // **DAVE transforms the whole access unit, not each NAL.** The
            // frame is rebuilt in Annex B — parameter sets first, then the
            // units, each behind a four-byte start code — transformed, and
            // split again. That is the exact shape WebRTC's depacketizer
            // reconstructs at the far end, which is what the transform's
            // authenticated bytes are computed over.
            let payloads: [[UInt8]]
            if let dave = state.dave {
                let frame = H264.annexB(units: parameterSets + units)
                guard let sealed = dave.encrypt(frame, codec: .h264) else {
                    state.framesRefused += 1
                    // A refused keyframe leaves the far end with nothing to
                    // start from, so the stream has to open again — which is
                    // exactly the window the group establishing in the middle
                    // of the first second opens.
                    state.hasSentKeyframe = false
                    state.needsKeyframe = true
                    return
                }
                payloads = H264.packetize(
                    nalUnits: H264.splitAnnexB(sealed), parameterSets: []
                )
                if VoiceTrace.isOn, !state.hasDescribedFrame {
                    state.hasDescribedFrame = true
                    VoiceTrace.write(state.label + " " + Self.describe(
                        units: units, parameterSets: parameterSets,
                        sealed: sealed, payloads: payloads
                    ))
                }
            } else {
                payloads = H264.packetize(nalUnits: units, parameterSets: parameterSets)
            }
            guard !payloads.isEmpty else {
                state.framesRefused += 1
                state.hasSentKeyframe = false
                state.needsKeyframe = true
                return
            }
            if isKeyframe { state.hasSentKeyframe = true }
            let timestamp = UInt32(
                truncatingIfNeeded: Int64((presentationTime * 90_000).rounded())
            )
            // **The whole access unit moves to its timestamp before any of it
            // is sent.** `next` writes the clock it holds and advances after,
            // so advancing on the first packet left that packet — the leading
            // NAL, which on a keyframe is a parameter set — carrying the
            // *previous* frame's value. A receiver groups packets by timestamp,
            // so every frame arrived missing its first unit and no keyframe
            // ever assembled: the far end showed a spinner and then "failed to
            // start camera", with a perfectly healthy packet count leaving here.
            let clock = state.writer?.timestamp ?? 0
            state.writer?.advanceClock(by: timestamp &- clock)

            for (index, payload) in payloads.enumerated() {
                // **Both, on every packet, because that is what a stream the
                // far end draws carries.** These are the two measurements an
                // SFU makes of a publisher's path, and this client sent
                // neither: `RTPExtension.DefaultID` has the capture.
                var extensions: [UInt8] = []
                if let id = state.sendTimeExtensionID {
                    extensions += RTPExtension.absoluteSendTime(
                        id: id, seconds: AudioSendPath.sendClock()
                    )
                }
                if let id = state.transportSequenceExtensionID,
                   let sequence = state.transportSequence?.next() {
                    extensions += RTPExtension.transportSequence(id: id, sequence: sequence)
                }
                // **Every packet of one frame carries the SAME timestamp, and
                // the last one carries the marker.** That pair is how a receiver
                // knows where an access unit ends; a packetiser that advances
                // the clock per packet produces a stream that decodes to one
                // frame per NAL and plays at fifty times the intended rate.
                let isLast = index == payloads.count - 1
                let header = state.writer?.next(
                    advancingClockBy: 0,
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
        /// Frames the capture handed over since the last drain, and how many of
        /// them there was no encoder to take.
        var submitted = 0
        var unencodable = 0
    }

    init() {}

    /// Frames in since the last drain, and the ones that arrived with no
    /// encoder behind them.
    ///
    /// **The stage above `VideoSendPath.Report`, and the one that separates a
    /// capture that stopped from a transform that refused.** ScreenCaptureKit
    /// delivers on every tick whether the screen changed or not, so a share
    /// whose count is zero is a dead capture and nothing else — there is no
    /// still-picture case to explain it away.
    func drainCounters() -> (submitted: Int, unencodable: Int) {
        state.withLock { state in
            let value = (state.submitted, state.unencodable)
            state.submitted = 0
            state.unencodable = 0
            return value
        }
    }

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
            state.submitted += 1
            guard let encoder = state.encoder else {
                state.unencodable += 1
                return
            }
            let elapsed = CACurrentMediaTime() - state.start
            encoder.encode(
                frame.pixels,
                at: CMTime(seconds: elapsed, preferredTimescale: 90_000),
                forceKeyframe: forceKeyframe
            )
        }
    }
}
