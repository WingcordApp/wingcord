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
        /// How many arriving packets are still to be printed as themselves.
        ///
        /// **Audio is the only packet a call always carries**, and the header
        /// extensions on it are the only statement this client can read of what
        /// ids a *call* server expects. Discord names none of them in READY, so
        /// without this the call's ids are unknowable and the temptation is to
        /// borrow a Go Live stream's — which is how a camera that worked
        /// stopped working. Four packets, once per speaker.
        var probesRemaining = VoiceTrace.isOn ? 4 : 0

        init() { decoder = try? OpusDecoder() }
    }

    /// One person's camera or screen.
    private final class VideoStream {
        let depacketizer = H264Depacketizer()
        let builder = H264SampleBuilder()
        var lastSequence: UInt16?
        var baseTimestamp: UInt32?
        /// Whether anything has ever arrived on this SSRC.
        ///
        /// **A binding is a claim; this is the evidence for it.** The gateway
        /// names an SSRC as soon as somebody has a stream — which for a Go Live
        /// share is a stream on a media session this client has not joined, so
        /// not one packet of it will ever arrive here. Two things depend on
        /// telling those apart: nothing may be adopted over a binding that is
        /// working, and nothing may be asked for on a binding that has never
        /// carried anything.
        var hasSeenPacket = false
        /// How many arriving packets are still to be written out one by one.
        ///
        /// **A video stream that draws nothing produces no counter at all**
        /// between the depacketiser and the decoder — a frame that never
        /// completes is indistinguishable from a frame that completes and is
        /// refused, and both look like a bound SSRC with healthy packet counts.
        /// So the first few packets of every stream are printed as they arrive,
        /// which is the only reading that does not depend on a theory about
        /// which stage failed.
        var probesRemaining = VoiceTrace.isOn ? 20 : 0
        /// The same, for whole access units — far fewer, because one line
        /// naming every NAL in a frame is worth twenty naming packets.
        var frameProbesRemaining = VoiceTrace.isOn ? 4 : 0

        /// Records this packet's place in the SSRC's sequence space, and says
        /// whether it followed the previous one.
        ///
        /// **Every packet on the SSRC has to pass through here, including the
        /// ones carrying no media.** A padding-only probe packet — which an SFU
        /// sends to measure the path, and which trims to nothing — still
        /// consumes a sequence number, so a receiver that returns early without
        /// recording it judges the *next* real packet non-contiguous and throws
        /// the frame in progress away. At a few probes a second that is every
        /// frame, for ever, with no drop counted anywhere.
        func track(sequence: UInt16) -> Bool {
            defer { lastSequence = sequence }
            return lastSequence.map { sequence == $0 &+ 1 } ?? true
        }
    }

    /// What became of a stream's video between the socket and the screen.
    ///
    /// **Six numbers, because there are six ways a bound video stream draws
    /// nothing and they are six different faults.** Until this existed the whole
    /// stage was one blind spot: `read=` counts packets past the transport
    /// cipher and the drop counters cover the end-to-end transform, and between
    /// them sit the routing table, the reassembler, the sink and the format
    /// description — four gates that each fail silently and produce the same
    /// black rectangle.
    struct VideoCensus: Sendable, Equatable {
        /// Packets on an SSRC bound to somebody.
        var packets = 0
        /// Packets whose SSRC nobody claimed. Non-zero means the routing table
        /// disagrees with the wire, and the arrival census names the SSRC.
        var unrouted = 0
        /// Access units the reassembler completed. Zero with `packets` climbing
        /// is a marker bit, a sequence gap, or a stream that has sent no
        /// keyframe since we started listening.
        var frames = 0
        /// Packets that arrived with nowhere to draw.
        var sinkless = 0
        /// Frames opened and reassembled that no sample buffer could be built
        /// from — which means no parameter sets, and therefore no format
        /// description, have been seen yet.
        var undrawable = 0
        /// Samples handed to a display layer. The only number that means a
        /// picture.
        var drawn = 0

        var isEmpty: Bool {
            packets == 0 && unrouted == 0 && frames == 0
                && sinkless == 0 && undrawable == 0 && drawn == 0
        }
    }

    private let state = Mutex(State())

    /// The far end's own account of what it received. Shares this socket, and
    /// is read here because this is the object every datagram passes through.
    private let rtcp = RTCPListener()

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
        /// Everybody whose video has actually started arriving.
        ///
        /// **Announced and arriving are not the same fact**, and the tile may
        /// only be told the second one — see `onFirstVideoFrame`. "Arriving"
        /// means a packet on a **bound** video SSRC that opened, which is a
        /// stream this client is genuinely receiving; it deliberately does not
        /// mean a decoded frame, because a decoded frame needs a sink and a
        /// sink needs the tile to already believe there is a picture.
        var deliveringVideo: Set<UInt64> = []
        var mixScratch = [Float](repeating: 0, count: OpusFormat.interleavedCount)
        var frameScratch = [Float](repeating: 0, count: OpusFormat.interleavedCount)
        var packetsReceived = 0
        /// Whether the post-mortem below has already run. Once a call, because
        /// it is a copy of the payload and a handful of AES calls on a path
        /// that handles fifty frames a second.
        var hasProbedRefusal = false
        /// Every datagram the socket handed over, before anything judged it.
        /// The difference between this and `packetsReceived` is the whole
        /// question of whether media is arriving but unreadable, or not
        /// arriving at all.
        var datagramsReceived = 0
        /// Every (SSRC, payload type) that opened, and how many times.
        ///
        /// **The reading that says whether media is arriving somewhere nobody
        /// is listening.** A routing table is a claim about the wire, and until
        /// this existed nothing compared the two: video forwarded on an SSRC
        /// the gateway never named, or under a payload type this client does
        /// not decode, is dropped by a `guard` that counts nothing and reads
        /// exactly like a stream that was never sent.
        var arrivals: [UInt64: Int] = [:]
        /// What became of the video since the last report.
        var video = VideoCensus()
        /// The one person whose video this session carries, when there is one.
        ///
        /// **A Go Live session has exactly one publisher, and that is a fact
        /// about the session rather than a guess about a packet.** A viewer
        /// asks for one person's stream, gets a socket of its own, and every
        /// picture on it is theirs — so H.264 arriving on an SSRC the gateway
        /// has not described belongs to them, and binding it is reading the
        /// wire rather than trusting a field name. `nil` in a call, where
        /// several people publish and only the gateway can say which is which.
        var soleVideoOwner: UInt64?
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
        rtcp.setSealer(sealer)
    }

    /// What the far end said since the last call. See `RTCP`.
    func drainFeedback() -> (feedback: RTCP.Feedback, unreadable: Int) {
        let report = rtcp.drain()
        return (report.feedback, report.unreadable)
    }

    /// Asks every sender whose picture cannot start for a keyframe.
    ///
    /// **A receiver that only waits waits for ever.** A stream joined
    /// mid-picture has no parameter sets and no reference frame, so every frame
    /// until the sender's next keyframe is refused — correctly, because a delta
    /// frame with no reference decodes to rubbish. The sender has no way to
    /// know that unless it is told, and on an encoder that produces keyframes
    /// only on request there is no next one to wait for.
    func askForKeyframes(on transport: VoiceTransport, from sender: UInt32) {
        let wanted = state.withLock { state in
            // **Only where media is actually arriving.** An announced stream on
            // a media session this client never joined delivers nothing and
            // wants a keyframe for ever; asking for one is a packet a second,
            // to a server that has nothing to forward it to.
            state.videoBySSRC.compactMap { ssrc, stream in
                stream.hasSeenPacket && stream.depacketizer.needsKeyframe ? ssrc : nil
            }
        }
        rtcp.askForKeyframes(on: transport, from: sender, about: wanted)
    }

    /// Declares that every picture on this socket belongs to one person.
    ///
    /// Set by a session that watches somebody's Go Live stream, and by nothing
    /// else. See `State.soleVideoOwner`.
    func setSoleVideoOwner(_ userID: UInt64?) {
        state.withLock { $0.soleVideoOwner = userID }
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
        state.withLock { Self.bindVideo(ssrc: ssrc, to: userID, in: &$0) }
    }

    /// The same binding, for a caller that already holds the lock.
    private static func bindVideo(ssrc: UInt32, to userID: UInt64, in state: inout State) {
        // A person's SSRC changes when they reconnect, and the stream that was
        // reassembling the old one has to go with it.
        if let previous = state.videoSSRCByUser[userID], previous != ssrc {
            state.videoBySSRC[previous] = nil
            state.videoUserBySSRC[previous] = nil
        }
        state.videoSSRCByUser[userID] = ssrc
        state.videoUserBySSRC[ssrc] = userID
        if state.videoBySSRC[ssrc] == nil { state.videoBySSRC[ssrc] = VideoStream() }
    }

    func unbindVideo(for userID: UInt64) {
        state.withLock { state in
            guard let ssrc = state.videoSSRCByUser.removeValue(forKey: userID) else { return }
            state.videoBySSRC[ssrc] = nil
            state.videoUserBySSRC[ssrc] = nil
            state.deliveringVideo.remove(userID)
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
            state.deliveringVideo.remove(userID)
        }
    }

    /// Told the first time a sender's video actually starts arriving.
    ///
    /// **Announced is not arriving, and a tile may only be told the second
    /// one.** The voice gateway names somebody's video SSRC as soon as they
    /// have a stream — which for a Go Live share is a stream on a *different*
    /// media session this client has not joined, so not one packet of it will
    /// ever reach here. A tile switched to video on the announcement paints its
    /// ground black and waits for a frame that cannot come: measured live as a
    /// black rectangle over somebody's avatar while they were sharing their
    /// screen perfectly well.
    ///
    /// So the announcement binds the SSRC — packets must still be routed if any
    /// do arrive — and this is what tells the app there is a picture.
    let onFirstVideoFrame = Mutex<(@Sendable (UInt64) -> Void)?>(nil)

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
            state.deliveringVideo.removeAll()
            state.sealer = nil
            state.localClips.removeAll()
            state.arrivals.removeAll()
            state.video = VideoCensus()
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
        /// Senders whose first frame this datagram completed. Reported after
        /// the lock, for the same reason the frames themselves are.
        var arrived: [UInt64] = []

        // **Reports first, and they are not media.** RTCP shares the port and
        // the version number with RTP and is told apart by a payload type RTP
        // reserves for the purpose; a receiver that misses the distinction
        // hands every report to the transport cipher with an RTP-sized prefix,
        // fails to open it, and counts the far end's answer as noise. Measured
        // as a steady two to four `transport would not open` every two seconds
        // on every call this client has ever made.
        if RTCP.isRTCP(packet) {
            rtcp.accept(packet)
            state.withLock { $0.datagramsReceived += 1 }
            return
        }

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
            state.arrivals[
                UInt64(header.ssrc) << 8 | UInt64(header.payloadType), default: 0
            ] += 1

            // **A stream session's video binds itself.** See
            // `State.soleVideoOwner`: on a socket with one publisher, H.264 on
            // an unclaimed SSRC is that publisher's, and reading it off the
            // wire cannot disagree with the wire the way a gateway field can.
            //
            // **Only over a binding that has never carried anything.** A
            // publisher offering two simulcast layers would otherwise have each
            // arriving packet unbind the other one, and the reassembler would
            // be reset between every pair of fragments.
            if header.payloadType == RTP.PayloadType.h264,
               state.videoBySSRC[header.ssrc] == nil,
               let owner = state.soleVideoOwner,
               state.videoSSRCByUser[owner]
                   .flatMap({ state.videoBySSRC[$0]?.hasSeenPacket }) != true {
                VoiceTrace.write(
                    "video adopted ssrc=\(header.ssrc) as the only publisher's"
                )
                Self.bindVideo(ssrc: header.ssrc, to: owner, in: &state)
            }

            // **Tracked before anything can drop the packet, and for every
            // packet on the SSRC.** See `VideoStream.track`.
            let isContiguous = state.videoBySSRC[header.ssrc]?
                .track(sequence: header.sequence) ?? true

            // **The extension elements were encrypted, so they are at the front
            // of the plaintext rather than in the header.** The media starts
            // after them. A receiver that forgets this decrypts perfectly well
            // and then hands the decoder four bytes of RFC 8285 preamble.
            // **Padding first, from the back.** Its count is the final octet
            // and includes itself, so it has to come off before anything reads
            // the end of the frame — which is exactly where the DAVE footer
            // lives. Trimming the tail is free; the head costs one short move.
            //
            // Both trims are remembered, and the untrimmed payload with them,
            // for the post-mortem in `DAVEProbe` — which is the one thing left
            // that can explain a frame that parses and will not open. Nothing
            // is kept unless a trace is running and the probe has yet to fire,
            // so the copy costs a healthy call nothing at all.
            let untrimmed = header.payloadType == RTP.PayloadType.opus
                && state.isDAVEActive && !state.hasProbedRefusal && VoiceTrace.isOn
                ? payload : nil
            var tail = 0
            if header.hasPadding {
                guard let count = payload.last.map(Int.init),
                      count > 0, count <= payload.count
                else { return }
                payload.removeLast(count)
                tail = count
            }
            let head = header.extensionBodyLength
            // **Kept, because it is the one part of somebody else's packet this
            // client has never looked at.** The elements are encrypted, so they
            // arrive here rather than in the header, and every one of them is
            // something the sending client thought the SFU needed — a RID, a
            // send time, a transport sequence — negotiated by ids this server
            // does not publish in READY. Reading them off a working stream is
            // the only way to learn what they are. Nothing is copied unless a
            // probe is still to be printed.
            var extensionBody: ArraySlice<UInt8> = []
            if head > 0 {
                guard payload.count >= head else { return }
                if VoiceTrace.isOn { extensionBody = payload.prefix(head) }
                payload.removeFirst(head)
            }
            guard !payload.isEmpty else { return }

            switch header.payloadType {
            case RTP.PayloadType.opus:
                // Deafened is enforced here rather than at the mixer: a client
                // that decodes everything and multiplies by zero has paid the
                // whole cost of listening.
                guard !state.isDeafened else { return }
                guard let sender = state.userBySSRC[header.ssrc] else { return }
                if let stream = state.audioBySSRC[header.ssrc], stream.probesRemaining > 0 {
                    stream.probesRemaining -= 1
                    VoiceTrace.write(
                        "audio ssrc=\(header.ssrc) seq=\(header.sequence) "
                        + "len=\(payload.count) pad=\(header.hasPadding ? 1 : 0) "
                        + "ext=[\(RTPExtension.describe(extensionBody))]"
                    )
                }
                guard let frame = Self.open(
                    payload, from: sender, isAudio: true, state: state
                ) else {
                    if let untrimmed, let decryptor = state.decryptors[sender] {
                        state.hasProbedRefusal = true
                        DAVEProbe.explain(
                            payload: untrimmed, head: head, tail: tail, with: decryptor
                        )
                    }
                    return
                }
                state.audioBySSRC[header.ssrc]?.buffer.accept(
                    sequence: header.sequence,
                    timestamp: header.timestamp,
                    payload: frame,
                    arrival: arrival
                )

            case RTP.PayloadType.h264:
                guard let stream = state.videoBySSRC[header.ssrc],
                      let userID = state.videoUserBySSRC[header.ssrc]
                else {
                    state.video.unrouted += 1
                    return
                }
                state.video.packets += 1
                stream.hasSeenPacket = true
                if stream.probesRemaining > 0 {
                    stream.probesRemaining -= 1
                    VoiceTrace.write(Self.describe(
                        packet: payload, header: header,
                        extensions: extensionBody, isContiguous: isContiguous
                    ))
                }

                // **Arrival is reported before a sink is required, and that
                // ordering is load-bearing.** A tile only builds its display
                // layer — and therefore only registers a sink — once the app
                // believes there is a picture, and the app believes that when
                // this fires. Requiring the sink first is a cycle with no
                // entry: no sink, no decode, no first frame, no sink.
                //
                // Measured on a watched share: 1,511 of 1,557 packets opened
                // past the transport cipher, the MLS group reached epoch 1 with
                // both members, and the tile sat on "Opening share…" for ever
                // because nothing downstream of this line ever ran.
                if state.deliveringVideo.insert(userID).inserted { arrived.append(userID) }

                // Nothing to draw into yet. The frame is dropped rather than
                // decoded, because a decode nobody displays is a decode nobody
                // asked for — the tile attaches on the line above and the next
                // frame lands properly.
                guard let sink = state.sinks[userID] else {
                    state.video.sinkless += 1
                    return
                }

                guard let frame = stream.depacketizer.accept(
                    payload: payload,
                    sequence: header.sequence,
                    marker: header.marker,
                    isContiguous: isContiguous
                ) else { return }
                state.video.frames += 1
                if stream.frameProbesRemaining > 0 {
                    stream.frameProbesRemaining -= 1
                    VoiceTrace.write(Self.describe(frame: frame))
                }

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
                ) else {
                    state.video.undrawable += 1
                    return
                }
                state.video.drawn += 1
                // Delivered outside the lock. A display layer's enqueue reaches
                // into the window server, and holding the stream lock across it
                // would stall every arriving packet behind a compositor.
                deliveries.append(VideoDelivery(sink: sink, sample: sample))

            default:
                break
            }
        }

        for delivery in deliveries { delivery.sink(delivery.sample) }
        if !arrived.isEmpty, let announce = onFirstVideoFrame.withLock({ $0 }) {
            for userID in arrived { announce(userID) }
        }
    }

    // MARK: What the wire actually carried
    //
    // **Printed, not inferred.** Every earlier theory about a black video tile
    // was built from counters either side of the reassembler; these two lines
    // are the packets and the frames themselves, twenty and four of them per
    // stream, and they cost a build nobody is tracing nothing at all.

    private static func naming(_ units: [[UInt8]]) -> String {
        units.map { "\($0.first.map { $0 & 0x1F } ?? 0):\($0.count)" }.joined(separator: " ")
    }

    /// One arriving video packet: where it sat in the stream, what shape of NAL
    /// it carried, and every header extension element on it.
    private static func describe(
        packet: [UInt8], header: RTPHeader, extensions: ArraySlice<UInt8>, isContiguous: Bool
    ) -> String {
        let first = packet.first ?? 0
        var shape = "nal=\(first & 0x1F)"
        if first & 0x1F == H264.NALType.fuA.rawValue, packet.count > 1 {
            let fu = packet[1]
            shape += " fu=s\(fu >> 7 & 1)e\(fu >> 6 & 1)t\(fu & 0x1F)"
        }
        return "video ssrc=\(header.ssrc) seq=\(header.sequence) "
            + "ts=\(header.timestamp) m=\(header.marker ? 1 : 0) "
            + "len=\(packet.count) pad=\(header.hasPadding ? 1 : 0) "
            + "ct=\(isContiguous ? 1 : 0) " + shape
            + " ext=[" + RTPExtension.describe(extensions) + "]"
    }

    /// One reassembled access unit, before the end-to-end transform sees it.
    private static func describe(
        frame: (units: [[UInt8]], ordered: [[UInt8]], isKeyframe: Bool)
    ) -> String {
        "video frame ordered=[\(naming(frame.ordered))] "
            + "units=[\(naming(frame.units))] key=\(frame.isKeyframe ? 1 : 0)"
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

    /// What the video did since the last **drain**, ready to print.
    ///
    /// **Separate from `statistics`, and drained by the printer rather than by
    /// the reader.** §1.5's "large and still" trap in a second hat: the call
    /// reads its statistics four times for every line it writes, so a count
    /// that reset on every read would report the last five hundred milliseconds
    /// beside numbers covering two seconds, and three windows out of four would
    /// be thrown away. Draining where the line is written makes the interval
    /// the same for everything on it, whatever that interval is.
    func drainVideoReport() -> VideoReport {
        state.withLock { state in
            let report = VideoReport(
                census: state.video,
                arrivals: state.arrivals
                    .map { (ssrc: UInt32(truncatingIfNeeded: $0.key >> 8),
                            payloadType: UInt8(truncatingIfNeeded: $0.key),
                            packets: $0.value) }
                    .sorted { $0.packets > $1.packets }
            )
            state.video = VideoCensus()
            state.arrivals.removeAll(keepingCapacity: true)
            return report
        }
    }

    struct VideoReport: Sendable {
        var census = VideoCensus()
        /// Every SSRC that opened in the window, with its payload type and
        /// count, busiest first.
        var arrivals: [(ssrc: UInt32, payloadType: UInt8, packets: Int)] = []

        /// The video stages and the SSRCs behind them, or an empty string when
        /// there is nothing about the video worth a reader's attention.
        ///
        /// **Silent when no video arrived at all**, so the media line stays the
        /// length it was for everybody who is not receiving a picture.
        var description: String {
            guard !census.isEmpty else { return "" }
            var line = " in.video=[pkt=\(census.packets) frames=\(census.frames)"
            if census.unrouted > 0 { line += " unrouted=\(census.unrouted)" }
            if census.sinkless > 0 { line += " nosink=\(census.sinkless)" }
            if census.undrawable > 0 { line += " nopicture=\(census.undrawable)" }
            line += " drawn=\(census.drawn)]"
            guard !arrivals.isEmpty else { return line }
            return line + " ssrc=[" + arrivals
                .map { "\($0.ssrc)/\($0.payloadType):\($0.packets)" }
                .joined(separator: " ") + "]"
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
