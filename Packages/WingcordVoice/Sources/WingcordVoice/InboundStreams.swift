import CoreMedia
import Foundation
import Synchronization

// MARK: - Everybody else
//
// One object holding every stream arriving on the socket: who owns which SSRC,
// a jitter buffer and a decoder per speaker, a reassembler and a sample builder
// per camera.
//
// **Packets are processed on the socket's own queue, synchronously.** There is
// no queue between the network and the jitter buffer, and that is deliberate:
// a hop there re-orders bursts, which is the exact fault the jitter buffer
// downstream exists to repair. Decryption is a hardware AES call and
// reassembly is a copy; neither is worth a thread hand-off.

/// One decoded frame on its way to the layer that will draw it.
///
/// `@unchecked Sendable` so it can leave `withLock`'s region: a `CMSampleBuffer`
/// is a CoreMedia object and those are thread-safe by construction, and each
/// one here is created inside the call that hands it on and referenced nowhere
/// else. Without the wrapper the compiler merges the buffer's region with the
/// locked state's and — correctly, given a bare tuple — refuses to let either
/// out.
private struct VideoDelivery: @unchecked Sendable {
    let sink: @Sendable (CMSampleBuffer) -> Void
    let sample: CMSampleBuffer
}

final class InboundStreams: Sendable {

    /// One person's audio.
    private final class AudioStream {
        let buffer = JitterBuffer()
        let decoder: OpusDecoder?
        var pcm = [Int16](repeating: 0, count: OpusFormat.interleavedCount)
        var volume: Float = 1
        var isSpeaking = false
        /// Frames since the last audible one. Speaking goes false on a quarter
        /// second of silence rather than on the first quiet frame, or a ring
        /// flickers on every syllable.
        var quietFrames = 0

        init() { decoder = try? OpusDecoder() }
    }

    /// One person's camera or screen.
    private final class VideoStream {
        let depacketizer = H264Depacketizer()
        let builder = H264SampleBuilder()
        var lastSequence: UInt16?
        var baseTimestamp: UInt32?
    }

    private let state = Mutex(State())

    private struct State {
        /// The call's per-sender end-to-end transforms, when it has any, and
        /// whether the session is meant to be using them.
        ///
        /// **`isDAVEActive` without a decryptor means drop.** A frame from a
        /// member whose ratchet has not arrived yet is not media this client may
        /// play; treating it as plaintext would turn a missing key into an
        /// unencrypted call nobody was told about.
        var decryptors: [UInt64: DAVEDecryptor] = [:]
        var isDAVEActive = false
        var sealer: VoiceSealer?
        var audioBySSRC: [UInt32: AudioStream] = [:]
        var userBySSRC: [UInt32: UInt64] = [:]
        var ssrcByUser: [UInt64: UInt32] = [:]
        var videoBySSRC: [UInt32: VideoStream] = [:]
        var videoUserBySSRC: [UInt32: UInt64] = [:]
        var videoSSRCByUser: [UInt64: UInt32] = [:]
        var sinks: [UInt64: @Sendable (CMSampleBuffer) -> Void] = [:]
        var mixScratch = [Float](repeating: 0, count: OpusFormat.interleavedCount)
        var frameScratch = [Float](repeating: 0, count: OpusFormat.interleavedCount)
        var packetsReceived = 0
        /// Every datagram the socket handed over, before anything judged it.
        /// The difference between this and `packetsReceived` is the whole
        /// question of whether media is arriving but unreadable, or not
        /// arriving at all.
        var datagramsReceived = 0
        var isDeafened = false
        /// Sounds the app is playing itself — soundboard clips, and the blips
        /// a call makes when somebody joins or a switch moves. Mixed here
        /// rather than played through a second engine so they go out of the
        /// same device and sit **inside the echo canceller's reference**, which
        /// is what stops the far end hearing them back through your microphone.
        ///
        /// **A list, not a slot.** Two people pressing a sound in the same
        /// second is ordinary, and a single slot makes the second press cut the
        /// first off mid-clip.
        var localClips: [LocalClip] = []
    }

    /// One clip being played into the mix.
    private struct LocalClip {
        var samples: [Float]
        var cursor = 0
        var volume: Float
    }

    init() {}

    // MARK: Wiring

    func setSealer(_ sealer: VoiceSealer?) {
        state.withLock { $0.sealer = sealer }
    }

    var isDeafened: Bool {
        get { state.withLock { $0.isDeafened } }
        set { state.withLock { $0.isDeafened = newValue } }
    }

    /// Replaces the per-sender transforms after an epoch change.
    func setDAVE(decryptors: [UInt64: DAVEDecryptor], active: Bool) {
        state.withLock { state in
            state.decryptors = decryptors
            state.isDAVEActive = active
        }
    }

    func bind(ssrc: UInt32, to userID: UInt64) {
        guard ssrc != 0 else { return }
        state.withLock { state in
            // A person's SSRC changes when they reconnect. The old stream has
            // to go with it, or their jitter buffer keeps concealing a sequence
            // space that ended.
            if let previous = state.ssrcByUser[userID], previous != ssrc {
                state.audioBySSRC[previous] = nil
                state.userBySSRC[previous] = nil
            }
            state.ssrcByUser[userID] = ssrc
            state.userBySSRC[ssrc] = userID
            if state.audioBySSRC[ssrc] == nil { state.audioBySSRC[ssrc] = AudioStream() }
        }
    }

    func bindVideo(ssrc: UInt32, to userID: UInt64) {
        guard ssrc != 0 else { return }
        state.withLock { state in
            if let previous = state.videoSSRCByUser[userID], previous != ssrc {
                state.videoBySSRC[previous] = nil
                state.videoUserBySSRC[previous] = nil
            }
            state.videoSSRCByUser[userID] = ssrc
            state.videoUserBySSRC[ssrc] = userID
            if state.videoBySSRC[ssrc] == nil { state.videoBySSRC[ssrc] = VideoStream() }
        }
    }

    func unbindVideo(for userID: UInt64) {
        state.withLock { state in
            guard let ssrc = state.videoSSRCByUser.removeValue(forKey: userID) else { return }
            state.videoBySSRC[ssrc] = nil
            state.videoUserBySSRC[ssrc] = nil
        }
    }

    func remove(userID: UInt64) {
        state.withLock { state in
            if let ssrc = state.ssrcByUser.removeValue(forKey: userID) {
                state.audioBySSRC[ssrc] = nil
                state.userBySSRC[ssrc] = nil
            }
            if let ssrc = state.videoSSRCByUser.removeValue(forKey: userID) {
                state.videoBySSRC[ssrc] = nil
                state.videoUserBySSRC[ssrc] = nil
            }
            state.sinks[userID] = nil
        }
    }

    /// Where a person's decoded video goes. Set by the tile that is drawing
    /// them; cleared when it goes away, which is what stops a display layer
    /// being fed after it has left the window.
    func setVideoSink(_ sink: (@Sendable (CMSampleBuffer) -> Void)?, for userID: UInt64) {
        state.withLock { state in
            state.sinks[userID] = sink
            // A tile that has just appeared has no parameter sets and no
            // keyframe, so it would show nothing until the sender's next one —
            // up to two seconds. Resetting the reassembler makes it ask.
            if let ssrc = state.videoSSRCByUser[userID] {
                state.videoBySSRC[ssrc]?.depacketizer.reset()
                state.videoBySSRC[ssrc]?.builder.reset()
            }
        }
    }

    func setVolume(_ volume: Float, for userID: UInt64) {
        state.withLock { state in
            guard let ssrc = state.ssrcByUser[userID] else { return }
            state.audioBySSRC[ssrc]?.volume = max(0, min(2, volume))
        }
    }

    func reset() {
        state.withLock { state in
            state.audioBySSRC.removeAll()
            state.videoBySSRC.removeAll()
            state.userBySSRC.removeAll()
            state.ssrcByUser.removeAll()
            state.videoUserBySSRC.removeAll()
            state.videoSSRCByUser.removeAll()
            state.sinks.removeAll()
            state.sealer = nil
            state.localClips.removeAll()
        }
    }

    // MARK: Arrival

    /// Called on the socket's queue, once per datagram.
    func accept(_ packet: [UInt8], arrival: TimeInterval) {
        // Carried out of the lock rather than delivered inside it: a display
        // layer's enqueue reaches into the window server, and holding the
        // stream lock across it would stall every arriving packet behind a
        // compositor.
        var deliveries: [VideoDelivery] = []

        state.withLock { state in
            state.datagramsReceived += 1
            guard let header = RTPHeader(parsing: packet), let sealer = state.sealer else {
                // No sealer yet is ordinary — media can beat opcode 4 in. A
                // header that will not parse is not, and both were silent.
                if state.sealer != nil { VoiceTrace.note(.transportUnparsed) }
                return
            }
            guard var payload = sealer.open(packet, headerLength: header.clearPrefixLength) else {
                VoiceTrace.note(.transportRefused)
                return
            }
            state.packetsReceived += 1
            // **The extension elements were encrypted, so they are at the front
            // of the plaintext rather than in the header.** The media starts
            // after them. A receiver that forgets this decrypts perfectly well
            // and then hands the decoder four bytes of RFC 8285 preamble.
            // **Padding first, from the back.** Its count is the final octet
            // and includes itself, so it has to come off before anything reads
            // the end of the frame — which is exactly where the DAVE footer
            // lives. Trimming the tail is free; the head costs one short move.
            if header.hasPadding {
                guard let count = payload.last.map(Int.init),
                      count > 0, count <= payload.count
                else { return }
                payload.removeLast(count)
            }
            if header.extensionBodyLength > 0 {
                guard payload.count >= header.extensionBodyLength else { return }
                payload.removeFirst(header.extensionBodyLength)
            }
            guard !payload.isEmpty else { return }

            switch header.payloadType {
            case RTP.PayloadType.opus:
                // Deafened is enforced here rather than at the mixer: a client
                // that decodes everything and multiplies by zero has paid the
                // whole cost of listening.
                guard !state.isDeafened else { return }
                guard let sender = state.userBySSRC[header.ssrc] else { return }
                guard let frame = Self.open(
                    payload, from: sender, isAudio: true, state: state
                ) else { return }
                state.audioBySSRC[header.ssrc]?.buffer.accept(
                    sequence: header.sequence,
                    timestamp: header.timestamp,
                    payload: frame,
                    arrival: arrival
                )

            case RTP.PayloadType.h264:
                guard let stream = state.videoBySSRC[header.ssrc],
                      let userID = state.videoUserBySSRC[header.ssrc],
                      let sink = state.sinks[userID]
                else { return }

                let isContiguous = stream.lastSequence.map {
                    header.sequence == $0 &+ 1
                } ?? true
                stream.lastSequence = header.sequence

                guard let frame = stream.depacketizer.accept(
                    payload: payload,
                    sequence: header.sequence,
                    marker: header.marker,
                    isContiguous: isContiguous
                ) else { return }

                // DAVE covers the whole access unit, so it is rebuilt in the
                // arrival order the sender used — parameter sets and SEI
                // included — opened, and split again. `frame.units` is the
                // classified list and is the wrong input: it has already
                // dropped bytes the sender authenticated.
                var units = frame.units
                if state.isDAVEActive || state.decryptors[userID] != nil {
                    guard let opened = Self.open(
                        H264.annexB(units: frame.ordered),
                        from: userID, isAudio: false, state: state
                    ) else { return }
                    let all = H264.splitAnnexB(opened)
                    units = all.filter {
                        let type = ($0.first ?? 0) & 0x1F
                        return type != H264.NALType.sps.rawValue
                            && type != H264.NALType.pps.rawValue
                            && type != H264.NALType.sei.rawValue
                    }
                    guard !units.isEmpty else { return }
                }

                stream.builder.updateParameterSets(stream.depacketizer.parameterSets)
                if stream.baseTimestamp == nil { stream.baseTimestamp = header.timestamp }
                let elapsed = Double(header.timestamp &- (stream.baseTimestamp ?? 0)) / 90_000
                guard let sample = stream.builder.sampleBuffer(
                    units: units,
                    presentationTime: CMTime(seconds: elapsed, preferredTimescale: 90_000),
                    isKeyframe: frame.isKeyframe
                ) else { return }
                // Delivered outside the lock. A display layer's enqueue reaches
                // into the window server, and holding the stream lock across it
                // would stall every arriving packet behind a compositor.
                deliveries.append(VideoDelivery(sink: sink, sample: sample))

            default:
                break
            }
        }

        for delivery in deliveries { delivery.sink(delivery.sample) }
    }

    /// Applies the end-to-end transform for one sender.
    ///
    /// Returns `nil` when the call is end-to-end encrypted and this frame
    /// cannot be opened — a missing ratchet, a replay, or a forgery. Dropping is
    /// the only answer: playing it would be playing media the call cannot
    /// vouch for.
    private static func open(
        _ frame: [UInt8], from sender: UInt64, isAudio: Bool, state: State
    ) -> [UInt8]? {
        guard state.isDAVEActive else { return frame }
        guard let decryptor = state.decryptors[sender] else {
            VoiceTrace.note(.receiveUnkeyed)
            return nil
        }
        // The decryptor counts its own failures, and splits them by cause.
        return decryptor.decrypt(frame, isAudio: isAudio)
    }

    // MARK: Playing

    struct MixedFrame: Sendable {
        var samples: [Float]
        /// Who started or stopped talking on this frame.
        var speakingChanges: [(userID: UInt64, isSpeaking: Bool)]
        /// True when nothing at all was audible, so the caller can skip the
        /// write rather than queue 20 ms of zeroes.
        var isSilent: Bool
    }

    /// Pulls one 20 ms frame from every stream and mixes them.
    ///
    /// The mix is a plain sum with per-person gain and a soft clip at the end.
    /// **Not an average**: dividing by the number of speakers makes everybody
    /// quieter as more people join, which is the one thing a conference mixer
    /// must not do. A sum can clip, which is what the limiter is for.
    func mixNextFrame() -> MixedFrame {
        state.withLock { state in
            var changes: [(userID: UInt64, isSpeaking: Bool)] = []
            var contributors = 0

            for index in state.mixScratch.indices { state.mixScratch[index] = 0 }

            for (ssrc, stream) in state.audioBySSRC {
                let frame = stream.buffer.pull()
                let decoded: Bool
                switch frame {
                case .packet(let payload):
                    decoded = (try? stream.decoder?.decode(
                        payload, into: &stream.pcm
                    )) != nil
                case .forwardCorrection(let successor):
                    // The redundant copy inside the NEXT packet. This is the
                    // path that makes a lost packet inaudible rather than
                    // merely smoothed.
                    decoded = (try? stream.decoder?.decode(
                        successor, recoverFromFEC: true, into: &stream.pcm
                    )) != nil
                case .conceal:
                    decoded = (try? stream.decoder?.decode(nil, into: &stream.pcm)) != nil
                case .idle:
                    decoded = false
                }

                guard decoded else {
                    if stream.isSpeaking {
                        stream.quietFrames += 1
                        if stream.quietFrames > 12 {
                            stream.isSpeaking = false
                            if let userID = state.userBySSRC[ssrc] {
                                changes.append((userID, false))
                            }
                        }
                    }
                    continue
                }

                var energy: Float = 0
                let gain = stream.volume
                for index in 0..<OpusFormat.interleavedCount {
                    let sample = Float(stream.pcm[index]) / 32_768 * gain
                    state.mixScratch[index] += sample
                    energy += sample * sample
                }
                contributors += 1

                let level = (energy / Float(OpusFormat.interleavedCount)).squareRoot()
                let isAudible = level > 0.004
                if isAudible {
                    stream.quietFrames = 0
                    if !stream.isSpeaking {
                        stream.isSpeaking = true
                        if let userID = state.userBySSRC[ssrc] { changes.append((userID, true)) }
                    }
                } else if stream.isSpeaking {
                    stream.quietFrames += 1
                    if stream.quietFrames > 12 {
                        stream.isSpeaking = false
                        if let userID = state.userBySSRC[ssrc] { changes.append((userID, false)) }
                    }
                }
            }

            // Anything the app is playing itself joins the same mix, so it goes
            // out of the same device, at the same volume, and inside the
            // canceller's reference.
            if !state.localClips.isEmpty {
                for index in state.localClips.indices {
                    let clip = state.localClips[index]
                    let remaining = clip.samples.count - clip.cursor
                    guard remaining > 0 else { continue }
                    let take = min(OpusFormat.interleavedCount, remaining)
                    for offset in 0..<take {
                        state.mixScratch[offset] +=
                            clip.samples[clip.cursor + offset] * clip.volume
                    }
                    state.localClips[index].cursor += take
                    contributors += 1
                }
                state.localClips.removeAll { $0.cursor >= $0.samples.count }
            }

            guard contributors > 0 else {
                return MixedFrame(samples: [], speakingChanges: changes, isSilent: true)
            }

            // A soft knee rather than a hard clamp. Two people at full scale
            // sum past 1.0 for a handful of samples, and clamping those to the
            // rail is audible as a crackle where `tanh`-shaped limiting is not.
            for index in state.mixScratch.indices {
                let value = state.mixScratch[index]
                state.frameScratch[index] = value > 1 || value < -1
                    ? tanhf(value)
                    : value
            }
            return MixedFrame(
                samples: state.frameScratch,
                speakingChanges: changes,
                isSilent: false
            )
        }
    }

    /// Adds a locally-played clip to the mix, alongside anything already
    /// playing.
    ///
    /// Bounded: past a handful of overlapping clips the result is noise rather
    /// than sounds, and a channel where everybody presses at once must not be
    /// able to make the mixer do unbounded work per frame.
    func playLocal(_ samples: [Float], volume: Float) {
        state.withLock { state in
            if state.localClips.count >= 6 { state.localClips.removeFirst() }
            state.localClips.append(
                LocalClip(samples: samples, volume: max(0, min(2, volume)))
            )
        }
    }

    // MARK: Reporting

    struct Summary: Sendable, Equatable {
        var received = 0
        var datagrams = 0
        var lossPercent = 0
        var jitterMilliseconds: Double = 0
    }

    func statistics() -> Summary {
        state.withLock { state in
            let datagrams = state.datagramsReceived
            var worstLoss = 0
            var worstJitter: Double = 0
            for stream in state.audioBySSRC.values {
                let snapshot = stream.buffer.snapshot
                worstLoss = max(worstLoss, snapshot.lossPercent)
                worstJitter = max(
                    worstJitter,
                    snapshot.jitter / Double(OpusFormat.sampleRate) * 1_000
                )
            }
            return Summary(
                received: state.packetsReceived,
                datagrams: datagrams,
                lossPercent: worstLoss,
                jitterMilliseconds: worstJitter
            )
        }
    }

    func speakingUserIDs() -> Set<UInt64> {
        state.withLock { state in
            var result: Set<UInt64> = []
            for (ssrc, stream) in state.audioBySSRC where stream.isSpeaking {
                if let userID = state.userBySSRC[ssrc] { result.insert(userID) }
            }
            return result
        }
    }
}
