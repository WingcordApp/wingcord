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

/// Discord's voice gate: whether the microphone is open right now.
///
/// What the reader chose — muted, push to talk, always open — and, for voice
/// activity, whether there is a voice: a frame's level in dBFS against a line,
/// either the reader's (Discord's slider, −100…0, −60 by default) or the one
/// the gate learns from the room ("Automatically determine input
/// sensitivity", on by default as Discord's desktop app has it).
///
/// **Five frames lead and twenty-five trail** — Discord's `vadLeading` and
/// `vadTrailing`. A gate that opens on the frame that crossed the line has
/// already lost the consonant before it, and one that shuts on the first quiet
/// frame clips the end of every word: the five frames before are sent ahead of
/// the one that opened it (`AudioSendPath`'s lead-in), and it stays open half a
/// second after the last frame over the line.
///
/// **The automatic line is this client's, not Discord's.** Discord decides with
/// a native voice detector it does not ship to the web; this one listens for
/// the room instead — a floor that falls with the quietest frames and rises a
/// decibel a second while nobody speaks — and opens eighteen decibels above it.
struct TransmitGate {
    static let leadingFrames = 5
    static let trailingFrames = 25

    var mode: MediaSession.InputMode = .voiceActivity(MediaSession.VoiceActivity())
    var isPushToTalkHeld = false
    /// Discord's Push to Talk (Priority), held: the microphone is open
    /// whatever the mode, as Discord's opens it in both.
    var isPriorityHeld = false
    private(set) var isOpen = false
    private var hangover = 0
    /// The room, in dBFS, as the automatic line hears it.
    private var noiseFloor: Float = -60

    /// The line a frame is measured against, in dBFS, or `nil` for a mode that
    /// measures none. Reported when nothing is being sent, because a gate that
    /// never opens and a microphone that never works look identical from every
    /// other counter.
    var threshold: Float? {
        guard case .voiceActivity(let activity) = mode else { return nil }
        return activity.isAutomatic ? min(max(noiseFloor + 18, -70), -24) : activity.threshold
    }

    /// Whether this mode sends the frames before the one that opened it.
    var leads: Bool {
        if case .voiceActivity = mode { true } else { false }
    }

    /// - Parameter level: the frame's level, in dBFS.
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
        // Not a voice the room's line should learn from either.
        guard !isPriorityHeld else {
            isOpen = true
            return (true, !wasOpen)
        }
        switch mode {
        case .open:
            isOpen = true
        case .pushToTalk:
            isOpen = isPushToTalkHeld
        case .voiceActivity:
            let line = threshold ?? 0
            if level >= line {
                hangover = Self.trailingFrames
                isOpen = true
            } else if hangover > 0 {
                hangover -= 1
                isOpen = true
            } else {
                isOpen = false
            }
            // The room is learned from what is not a voice: a quieter frame
            // pulls the floor down at once, and the floor creeps back up only
            // while the gate is shut, so speech never teaches it.
            if level < noiseFloor {
                noiseFloor += (level - noiseFloor) * 0.25
            } else if !isOpen {
                noiseFloor = min(noiseFloor + 0.02, level)
            }
        }
        return (isOpen, isOpen != wasOpen)
    }

    /// A linear level, 0…1, in dBFS — the scale Discord's slider is on. Digital
    /// silence is −100, its bottom.
    static func decibels(_ level: Float) -> Float {
        level > 0.000_01 ? max(-100, 20 * log10(level)) : -100
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

/// The microphone's half — and, on a Go Live session, the stream's own sound.
///
/// **One path for both, because only the encoder and the gate differ.** The
/// clock, the extensions, the end-to-end transform, the seal and the counts a
/// sender report is built from are the same for a voice and for a film's
/// soundtrack; what changes is that a stream's sound is two channels in Opus's
/// music mode with the gate held open, sent whether or not anything is
/// audible.
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
        /// The loudest of them, in dBFS.
        var peak: Float = -100
        var isGateOpen = false
        var isMuted = false
        /// The line they were measured against, in dBFS.
        var threshold: Float?
    }

    private let state: Mutex<State>

    private struct State {
        let signal: OpusEncoder.Signal
        /// Interleaved samples in one 20 ms frame: 960 for a voice, 1,920 for
        /// a stream's stereo.
        let frameCount: Int
        var sealer: VoiceSealer?
        /// The call's end-to-end transform, when the session has one. Nothing
        /// leaves this path unprotected while it is set — see `send`.
        var dave: DAVEEncryptor?
        var encoder: OpusEncoder?
        var transport: VoiceTransport?
        var writer: RTPWriter?
        /// The RTP clock, which moves with every captured frame **whether or
        /// not it is sent** — a receiver measures a pause by it, and a clock
        /// that stood still across a silence would tell it the next word
        /// followed the last one at once.
        var clock: UInt32 = 0
        var scratch = [UInt8](repeating: 0, count: OpusFormat.maximumPacketBytes)
        var gate = TransmitGate()
        /// The frames before the gate opened, oldest first once read in order
        /// from `leadStart` — sent ahead of the frame that opened it.
        var lead: [Int16]
        var leadTimestamps = [UInt32](repeating: 0, count: TransmitGate.leadingFrames)
        var leadCount = 0
        var leadStart = 0
        var isMuted = false
        var audioLevelExtensionID: UInt8?
        var sendTimeExtensionID: UInt8?
        var transportSequenceExtensionID: UInt8?
        /// Shared with the video path, because the counter is transport-wide.
        var transportSequence: TransportSequence?
        var packetsSent = 0
        var bytesSent = 0
        /// Every byte of media sent, for the sender report's octet count.
        var octetsSent = 0
        /// Frames the tap offered since the last drain, and the loudest of
        /// them. The two numbers that tell a shut gate from a dead microphone.
        var framesOffered = 0
        var peakLevel: Float = -100
        /// Sent once when the gate closes, so a receiver's decoder is told the
        /// stream stopped rather than left to conceal indefinitely. Opus's own
        /// three-byte silence frame, five times, is what every client sends.
        var silenceFramesRemaining = 0
        /// Where this path's frames go for clips, when clips are on — the
        /// microphone's into the call's tap, a stream's sound into its clip.
        var clipSink: (@Sendable (TimedAudioFrame) -> Void)?

        init(signal: OpusEncoder.Signal) {
            self.signal = signal
            frameCount = Int(OpusFormat.frameSize * signal.channels)
            lead = [Int16](repeating: 0, count: frameCount * TransmitGate.leadingFrames)
        }
    }

    /// Told when the gate opens or closes, so the gateway's speaking state and
    /// the local tile can follow the audio rather than a timer.
    let onGateChanged = Mutex<(@Sendable (Bool) -> Void)?>(nil)

    init(signal: OpusEncoder.Signal = .voice) {
        state = Mutex(State(signal: signal))
    }

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
            let writer = RTPWriter(ssrc: ssrc, payloadType: RTP.PayloadType.opus)
            state.sealer = sealer
            state.transport = transport
            state.writer = writer
            state.clock = writer.timestamp
            state.encoder = try? OpusEncoder(bitrate: Int32(bitrate), signal: state.signal)
            state.audioLevelExtensionID = audioLevelExtensionID
            state.sendTimeExtensionID = sendTimeExtensionID
            state.transportSequenceExtensionID = transportSequenceExtensionID
            state.transportSequence = transportSequence
        }
    }

    /// Where this path's frames go for clips, or nil for nowhere.
    func setClipSink(_ sink: (@Sendable (TimedAudioFrame) -> Void)?) {
        state.withLock { $0.clipSink = sink }
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

    var inputMode: MediaSession.InputMode {
        get { state.withLock { $0.gate.mode } }
        set { state.withLock { $0.gate.mode = newValue } }
    }

    var isPushToTalkHeld: Bool {
        get { state.withLock { $0.gate.isPushToTalkHeld } }
        set { state.withLock { $0.gate.isPushToTalkHeld = newValue } }
    }

    var isPriorityHeld: Bool {
        get { state.withLock { $0.gate.isPriorityHeld } }
        set { state.withLock { $0.gate.isPriorityHeld = newValue } }
    }

    /// The share of our packets the far end says it is losing, which is what
    /// Opus spends redundancy against. See `OpusEncoder.updateExpectedLoss`.
    func updateExpectedLoss(percent: Int) {
        state.withLock { $0.encoder?.updateExpectedLoss(percent: percent) }
    }

    /// What has been sent, for the session's sender report: the running packet
    /// and byte counts, and where the RTP clock stands.
    var senderCounts: (packets: Int, octets: Int, clock: UInt32) {
        state.withLock { ($0.packetsSent, $0.octetsSent, $0.clock) }
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
            state.peakLevel = -100
            return report
        }
    }

    /// One 20 ms frame — 960 mono samples from the microphone's tap, or 1,920
    /// interleaved stereo from a share's capture — and its linear level. Runs
    /// on the thread that produced it.
    func send(_ samples: UnsafePointer<Int16>, level: Float) {
        var gateChange: Bool?
        // **The pointer is deliberately taken out of the caller's region.**
        // `withLock` hands its state over as `inout sending`, so a raw pointer
        // captured from the caller merges the two and the compiler — correctly
        // — will not then prove the state is disconnected afterwards. The
        // samples are read and encoded before this call returns and are never
        // stored anywhere, which is exactly the promise the wrapper makes.
        let input = CapturedFrame(base: samples)
        let decibels = TransmitGate.decibels(level)

        state.withLock { state in
            state.framesOffered += 1
            state.peakLevel = max(state.peakLevel, decibels)
            let timestamp = state.clock
            state.clock &+= OpusFormat.clockAdvance

            let decision = state.gate.admit(level: decibels, isMuted: state.isMuted)
            if decision.changed {
                gateChange = state.gate.isOpen
                // Closing sends five Opus silence frames. Without them the far
                // end's concealer has nothing telling it the stream ended and
                // extrapolates the last vowel into a quarter second of tone.
                if !state.gate.isOpen { state.silenceFramesRemaining = 5 }
            }

            guard decision.send else {
                let isMuted = state.isMuted
                Self.hold(input.base, at: timestamp, muted: isMuted, in: &state)
                guard state.silenceFramesRemaining > 0 else { return }
                state.silenceFramesRemaining -= 1
                // Encrypted like any other frame rather than sent bare. The
                // receiver's passthrough for this exact byte sequence exists
                // for silence the *server* synthesises; ours is media, and
                // media this client sends is protected without exception.
                Self.transmit([0xF8, 0xFF, 0xFE], at: timestamp, level: decibels, marker: false, in: &state)
                return
            }
            state.silenceFramesRemaining = 0

            // **The frames before the one that opened the gate go first**, on
            // their own timestamps, and the first of them carries the marker
            // that tells a receiver a talkspurt began.
            var marker = decision.changed
            if decision.changed, state.gate.leads {
                let width = state.frameCount
                for index in 0..<state.leadCount {
                    let slot = (state.leadStart + index) % TransmitGate.leadingFrames
                    let lead = state.lead
                    lead.withUnsafeBufferPointer { buffer in
                        let frame = buffer.baseAddress! + slot * width
                        Self.encodeAndTransmit(
                            frame, at: state.leadTimestamps[slot], level: decibels,
                            marker: marker, in: &state
                        )
                    }
                    marker = false
                }
            }
            state.leadCount = 0
            Self.encodeAndTransmit(input.base, at: timestamp, level: decibels, marker: marker, in: &state)
        }

        if let gateChange { onGateChanged.withLock { $0 }?(gateChange) }
    }

    /// Keeps the last few frames while the gate is shut, for the lead-in.
    /// A muted microphone keeps none: unmuting must not send what was said
    /// while muted.
    private static func hold(
        _ samples: UnsafePointer<Int16>, at timestamp: UInt32, muted: Bool, in state: inout State
    ) {
        guard !muted else {
            state.leadCount = 0
            return
        }
        let slot = (state.leadStart + state.leadCount) % TransmitGate.leadingFrames
        let width = state.frameCount
        state.lead.withUnsafeMutableBufferPointer { buffer in
            (buffer.baseAddress! + slot * width).update(from: samples, count: width)
        }
        state.leadTimestamps[slot] = timestamp
        if state.leadCount < TransmitGate.leadingFrames {
            state.leadCount += 1
        } else {
            state.leadStart = (state.leadStart + 1) % TransmitGate.leadingFrames
        }
    }

    private static func encodeAndTransmit(
        _ samples: UnsafePointer<Int16>, at timestamp: UInt32, level: Float, marker: Bool,
        in state: inout State
    ) {
        guard let encoder = state.encoder,
              let length = try? encoder.encode(samples, into: &state.scratch),
              length > 0
        else { return }
        let encoded = Array(state.scratch[0..<length])
        if let sink = state.clipSink {
            // Stamped with when it was said: the frame that just finished is
            // 20 ms old at its start, and a lead-in frame is older by how far
            // the RTP clock has moved past it.
            let behind = Double(state.clock &- OpusFormat.clockAdvance &- timestamp) / Double(OpusFormat.sampleRate)
            sink(TimedAudioFrame(time: CACurrentMediaTime() - OpusFrame.duration - behind, payload: .opus(encoded)))
        }
        transmit(encoded, at: timestamp, level: level, marker: marker, in: &state)
    }

    /// Seals and sends one encoded frame at its own place on the clock.
    private static func transmit(
        _ encoded: [UInt8], at timestamp: UInt32, level: Float, marker: Bool,
        in state: inout State
    ) {
        guard let sealer = state.sealer, let transport = state.transport,
              var writer = state.writer
        else { return }
        var extensions: [UInt8] = []
        if let id = state.audioLevelExtensionID {
            // RFC 6464's level is POSITIVE dBov: 0 is full scale, 127 is
            // silence. Sending the natural reading inverts every speaking ring
            // in the call. Its voice flag is a claim about speech, which a
            // stream's soundtrack does not make.
            extensions += RTPExtension.audioLevel(
                id: id, dBov: UInt8(min(127, max(0, (-level).rounded()))),
                isVoice: state.signal == .voice
            )
        }
        if let id = state.sendTimeExtensionID {
            extensions += RTPExtension.absoluteSendTime(id: id, seconds: sendClock())
        }
        if let id = state.transportSequenceExtensionID,
           let sequence = state.transportSequence?.next() {
            extensions += RTPExtension.transportSequence(id: id, sequence: sequence)
        }
        let header = RTPWriter.header(
            ssrc: writer.ssrc, payloadType: writer.payloadType,
            sequence: writer.claim().sequence, timestamp: timestamp,
            marker: marker, extensions: extensions
        )
        state.writer = writer
        // **End-to-end first, transport second.** DAVE protects the encoded
        // frame; the transport cipher then protects the packet carrying it. A
        // frame the transform will not produce is dropped rather than sent,
        // because sending it would mean sending media the call has told the
        // person it is end-to-end encrypting.
        let frame: [UInt8]
        if let dave = state.dave {
            guard let sealed = dave.encrypt(encoded, codec: .opus) else { return }
            frame = sealed
        } else {
            frame = encoded
        }
        guard let packet = try? frame.withUnsafeBytes({ try sealer.seal(payload: $0, header: header) })
        else { return }
        transport.send(packet)
        state.packetsSent += 1
        state.bytesSent += packet.count
        state.octetsSent += frame.count
    }

    /// Wall clock seconds, wrapped to the 64-second window abs-send-time uses.
    static func sendClock() -> Double {
        Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 64)
    }
}

/// The camera's and the screen's half.
///
/// One path for both, because only one of them is the video stream of a given
/// session: a call's video is its camera and a share's is its screen, each on
/// its own session. This holds the frame-level rules — nothing leaves before a
/// keyframe, nothing leaves unencrypted — and gives each packet its place in
/// the stream; `PacedSender` decides when it leaves.
final class VideoSendPath: Sendable {
    private let state = Mutex(State())
    /// Where the packets go: spread across time, sealed as they leave, and kept
    /// a few seconds for resending.
    private let sender = PacedSender(bitrate: 2_500_000)

    /// What this path did since the last drain.
    ///
    /// **The same bargain `AudioSendPath.Report` makes, and for the same
    /// reason.** §1.5 says `out=0` must carry the reason it is zero: a black
    /// screen share, a black camera and a camera that was never turned on all
    /// produce one number, and the stages that each produce it — never
    /// activated, no frame arriving, a transform refusing the frame, a
    /// packetiser emitting nothing — are indistinguishable from outside without
    /// these.
    struct Report {
        /// Packets sent, the running total.
        var packets = 0
        var bytes = 0
        /// Of those, resent because a receiver said they never arrived.
        var retransmitted = 0
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
        var dave: DAVEEncryptor?
        var writer: RTPWriter?
        var isActive = false
        var framesOffered = 0
        var framesRefused = 0
        var framesUnstartable = 0
        /// Set when the far end needs a fresh keyframe — at start, and after a
        /// receiver reports it cannot decode.
        var needsKeyframe = true
        /// Whether a keyframe has actually left on this stream.
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
    }

    init() {}

    func configure(
        sealer: VoiceSealer,
        transport: VoiceTransport,
        ssrc: UInt32,
        retransmissionSSRC: UInt32,
        sendTimeExtensionID: UInt8?,
        transportSequenceExtensionID: UInt8?,
        transportSequence: TransportSequence?
    ) {
        state.withLock { $0.writer = RTPWriter(ssrc: ssrc, payloadType: RTP.PayloadType.h264) }
        sender.configure(PacedSender.Configuration(
            sealer: sealer,
            transport: transport,
            ssrc: ssrc,
            retransmissionSSRC: retransmissionSSRC,
            sendTimeExtensionID: sendTimeExtensionID,
            transportSequenceExtensionID: transportSequenceExtensionID,
            transportSequence: transportSequence
        ))
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
            }
        } }
    }

    /// The rate the encoder is aiming for, which the pacer drains at a
    /// multiple of.
    func setBitrate(_ bitrate: Int) {
        sender.setBitrate(bitrate)
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

    /// Whether somebody is waiting for a keyframe, without answering them.
    var wantsKeyframe: Bool { state.withLock { $0.needsKeyframe } }

    /// What has been sent, for the session's sender report.
    var senderCounts: (packets: Int, octets: Int) {
        let report = sender.peekReport()
        return (report.packets, report.octets)
    }

    /// Resends what a receiver says never arrived on `ssrc`, if that is ours.
    /// From the socket's queue.
    ///
    /// **The SSRC is checked because the history is not keyed by it.** A NACK
    /// names its stream, and sequence numbers mean nothing outside one: a
    /// request about somebody else's — or about our audio — answered from this
    /// history would resend whichever of our packets happened to share the
    /// numbers.
    func retransmit(_ sequences: [UInt16], of ssrc: UInt32) {
        guard state.withLock({ $0.writer?.ssrc }) == ssrc else { return }
        sender.retransmit(sequences)
    }

    func drainCounters() -> Report {
        let sent = sender.drainReport()
        return state.withLock { state in
            let report = Report(
                packets: sent.packets,
                bytes: sent.bytes,
                retransmitted: sent.retransmitted,
                offered: state.framesOffered,
                refused: state.framesRefused,
                unstartable: state.framesUnstartable,
                isActive: state.isActive
            )
            state.framesOffered = 0
            state.framesRefused = 0
            state.framesUnstartable = 0
            return report
        }
    }

    func teardown() {
        state.withLock { state in
            state.dave = nil
            state.writer = nil
            state.isActive = false
        }
        sender.teardown()
    }

    /// One encoded access unit, from VideoToolbox's callback thread.
    ///
    /// - Parameter captureTime: when the picture was taken, in seconds on the
    ///   host clock. **The capture's clock, never the encoder's**: a keyframe
    ///   takes longer to encode than the frames around it, and stamping frames
    ///   as they leave the encoder tells a receiver's playout that the camera
    ///   stuttered whenever the encoder did.
    func send(
        units: [[UInt8]],
        parameterSets: [[UInt8]],
        isKeyframe: Bool,
        captureTime: Double
    ) {
        let packets = state.withLock { state -> [PacedSender.Packet] in
            // Counted before the guard, so a frame arriving at a path that is
            // not active is distinguishable from no frame arriving at all.
            state.framesOffered += 1
            guard state.isActive, var writer = state.writer else { return [] }

            // **Nothing leaves before a keyframe has.** See `hasSentKeyframe`.
            // Asking again rather than only dropping: the request is spent on
            // the capture's next frame, so a stream that starts mid-GOP opens
            // one frame later instead of waiting out the encoder's own two
            // second cadence.
            guard state.hasSentKeyframe || isKeyframe else {
                state.needsKeyframe = true
                state.framesUnstartable += 1
                return []
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
                    return []
                }
                payloads = H264.packetize(
                    nalUnits: H264.splitAnnexB(sealed), parameterSets: []
                )
            } else {
                payloads = H264.packetize(nalUnits: units, parameterSets: parameterSets)
            }
            guard !payloads.isEmpty else {
                state.framesRefused += 1
                state.hasSentKeyframe = false
                state.needsKeyframe = true
                return []
            }
            if isKeyframe { state.hasSentKeyframe = true }

            // **Every packet of one frame carries the SAME timestamp, and the
            // last one carries the marker.** That pair is how a receiver knows
            // where an access unit ends; a packetiser that advances the clock
            // per packet produces a stream that decodes to one frame per NAL.
            // The 90 kHz clock is H.264's whatever the frame rate.
            let timestamp = UInt32(truncatingIfNeeded: Int64((captureTime * 90_000).rounded()))
            let packets = payloads.enumerated().map { index, payload in
                PacedSender.Packet(
                    sequence: writer.claim().sequence,
                    timestamp: timestamp,
                    marker: index == payloads.count - 1,
                    payload: payload
                )
            }
            state.writer = writer
            return packets
        }
        sender.enqueue(packets)
    }
}

// MARK: - The video encoder, reachable from the capture thread

/// Owns the compression session, and decides which captured frames it gets.
///
/// Separate from `VideoSendPath` because it sits on the *other* side of
/// VideoToolbox: the capture queue pushes frames in and the encoder's own
/// callback thread pushes packets out, and the two must not queue behind each
/// other. Separate from `MediaSession` because a camera frame arriving cannot
/// afford an actor hop — thirty a second, each one behind whatever the control
/// plane happens to be doing.
final class VideoEncodePath: Sendable {
    /// One camera or screen frame and when it was taken, promised not to
    /// outlive the call.
    ///
    /// The same wrapper as `CapturedFrame` and for the same reason: a
    /// `CVPixelBuffer` is not `Sendable`, it is IOSurface-backed and safe to
    /// hand to VideoToolbox from any thread, and it is submitted synchronously
    /// and never stored.
    struct Frame: @unchecked Sendable {
        let pixels: CVPixelBuffer
        /// The capture's own timestamp, on the host clock.
        let time: CMTime
    }

    private let state = Mutex(State())

    private struct State {
        var encoder: H264Encoder?
        /// The most frames a second the encoder is given. Below the capture's
        /// rate when Discord's quality says so — see `MediaSession`'s framerate
        /// reducer.
        var framerate = 30
        /// When the next frame may go to the encoder.
        var nextDue: CMTime?
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
    /// delivers on every change, so a share whose count is zero while the
    /// screen moves is a dead capture and nothing else.
    func drainCounters() -> (submitted: Int, unencodable: Int) {
        state.withLock { state in
            let value = (state.submitted, state.unencodable)
            state.submitted = 0
            state.unencodable = 0
            return value
        }
    }

    func begin(_ encoder: H264Encoder, framerate: Int) {
        state.withLock { state in
            state.encoder?.teardown()
            state.encoder = encoder
            state.framerate = framerate
            state.nextDue = nil
        }
    }

    func end() {
        state.withLock { state in
            state.encoder?.teardown()
            state.encoder = nil
        }
    }

    /// A new size, rate or bitrate for the session already running.
    func reconfigure(_ configuration: H264Encoder.Configuration) {
        state.withLock { state in
            state.framerate = configuration.framerate
            state.encoder?.reconfigure(configuration)
        }
    }

    /// Only the bitrate. A property write on the running session.
    func setBitrate(_ bitrate: Int) {
        state.withLock { $0.encoder?.setBitrate(bitrate) }
    }

    /// Called on the capture queue, once per frame.
    ///
    /// **Thinned to the frame rate, never by every other frame.** Twenty from a
    /// thirty-frame camera is two frames in three; a rule of "skip anything
    /// sooner than one interval" keeps one in two and delivers fifteen. So the
    /// next frame is due one interval after the last one was *due*, and a
    /// frame that carries a keyframe request is never the one thinned out —
    /// the request was spent the moment it was asked for.
    func submit(_ frame: Frame, forceKeyframe: Bool) {
        state.withLock { state in
            state.submitted += 1
            guard let encoder = state.encoder else {
                state.unencodable += 1
                return
            }
            let interval = CMTime(value: 1, timescale: CMTimeScale(max(state.framerate, 1)))
            // Two milliseconds of slack, because a capture's timestamps wander
            // by about that much either side of its nominal rate.
            let slack = CMTime(value: 2, timescale: 1_000)
            if let due = state.nextDue, !forceKeyframe, frame.time + slack < due { return }
            // A capture that paused restarts the schedule from now rather than
            // catching up on the frames it did not deliver.
            if let due = state.nextDue, frame.time - due <= interval {
                state.nextDue = due + interval
            } else {
                state.nextDue = frame.time + interval
            }
            encoder.encode(frame.pixels, at: frame.time, forceKeyframe: forceKeyframe)
        }
    }
}
