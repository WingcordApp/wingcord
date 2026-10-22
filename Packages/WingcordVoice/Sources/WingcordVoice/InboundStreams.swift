import CoreMedia
import Foundation
import QuartzCore
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
        var reception = ReceptionStatistics(clockRate: Double(OpusFormat.sampleRate))
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
        /// The packets back in order, with the holes asked for. See
        /// `VideoReorderBuffer`.
        var reorder = VideoReorderBuffer()
        var reception = ReceptionStatistics(clockRate: 90_000)
        let depacketizer = H264Depacketizer()
        let builder = H264SampleBuilder()
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

    /// The far end's own account of what it received, and its requests about
    /// what we send. Shares this socket, and is read here because this is the
    /// object every datagram passes through.
    private let rtcp: RTCPListener

    /// Where this end's own requests go — a NACK for a hole, a picture loss
    /// indication for a stream that cannot start — and whose they are.
    private struct FeedbackRoute {
        var transport: VoiceTransport
        var sender: UInt32
    }

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
        /// Each retransmission SSRC's media SSRC, from opcode 12's `rtx_ssrc`.
        var mediaByRetransmission: [UInt32: UInt32] = [:]
        var sinks: [UInt64: @Sendable (CMSampleBuffer) -> Void] = [:]
        var feedbackRoute: FeedbackRoute?
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
        /// Where each kept speaker's frames go for clips, when clips are on
        /// (docs/CLIPS-PRESENCE.md, Phase 3.2).
        var clipTap: ClipAudioTap?
        var packetsReceived = 0
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
        /// People whose video the reader turned off — Discord's Disable Video.
        /// Their packets stop here as well as at the server, so the few already
        /// in flight when it was asked do not light the tile again.
        var videoDisabled: Set<UInt64> = []
        /// People the reader muted for themselves, whatever their volume.
        var locallyMuted: Set<UInt64> = []
        /// The person spotlighted, whose picture is asked for whole while
        /// everybody else's shares the budget — Discord's selected participant.
        var focusedVideoUser: UInt64?
        /// A stage keeps an offscreen picture two minutes, a call thirty
        /// seconds.
        var isStage = false
        /// How many pixels each person's tile draws them at — Discord's
        /// `streamPixelCounts`, which sizes a one-to-one call's want.
        var drawnPixels: [UInt64: Int] = [:]
        /// False once every window has been hidden for thirty seconds —
        /// Discord's `WindowVisibilityVideoManager`. The app keeps the clock.
        var incomingVideoEnabled = true
        /// Whether any tile has drawn anybody yet. Until one has, nobody is
        /// offscreen — Discord's `getActiveOutputSinkTrackingEnabled`.
        var tracksSinks = false
        /// When each person's picture lost the last tile drawing it.
        var offscreenSince: [UInt64: ContinuousClock.Instant] = [:]
        /// Offscreen long enough, or beyond the three kept: asked for nothing
        /// until a tile draws them again.
        var offscreenPaused: Set<UInt64> = []
        /// Each person's volume, by person rather than by stream: it is set
        /// from the account's settings before anybody's SSRC is known, and
        /// outlives a reconnect that gives them a new one.
        var volumes: [UInt64: Float] = [:]
        /// Who is speaking with priority and may: everybody else plays at a
        /// tenth while any of them is — Discord's `prioritySpeakerDucking`.
        var prioritySpeakers: Set<UInt64> = []
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

    /// - Parameter requests: where the far end's requests about our own
    ///   streams go, on the socket's queue, the moment they are read.
    init(requests: @escaping @Sendable (RTCP.Request) -> Void = { _ in }) {
        rtcp = RTCPListener(requests: requests)
    }

    // MARK: Wiring

    func setSealer(_ sealer: VoiceSealer?) {
        state.withLock { $0.sealer = sealer }
        rtcp.setSealer(sealer)
    }

    /// The socket this end's own requests go out on, and our SSRC to sign them
    /// with — nothing is sent from it, but a request has to name its sender.
    func attach(transport: VoiceTransport, sender: UInt32) {
        state.withLock { $0.feedbackRoute = FeedbackRoute(transport: transport, sender: sender) }
    }

    /// What the far end said since the last call. See `RTCP`.
    func drainFeedback() -> (feedback: RTCP.Feedback, unreadable: Int) {
        rtcp.drain()
    }

    /// Asks every sender whose picture cannot start for a keyframe.
    ///
    /// **A receiver that only waits waits for ever.** A stream joined
    /// mid-picture has no parameter sets and no reference frame, so every frame
    /// until the sender's next keyframe is refused — correctly, because a delta
    /// frame with no reference decodes to rubbish. The sender has no way to
    /// know that unless it is told, and on an encoder that produces keyframes
    /// only on request there is no next one to wait for. Rate limited by the
    /// listener, so asking on every reason there is costs nothing.
    func askForKeyframes() {
        let (wanted, route) = state.withLock { state in
            // **Only where media is actually arriving.** An announced stream on
            // a media session this client never joined delivers nothing and
            // wants a keyframe for ever; asking for one is a packet a second,
            // to a server that has nothing to forward it to.
            (state.videoBySSRC.compactMap { ssrc, stream in
                stream.hasSeenPacket && stream.depacketizer.needsKeyframe ? ssrc : nil
            }, state.feedbackRoute)
        }
        guard let route else { return }
        rtcp.askForKeyframes(on: route.transport, from: route.sender, about: wanted)
    }

    /// Reports what this end received, and what it sent, to the far end.
    ///
    /// **Every second, whether or not anything else is moving.** A report block
    /// per stream received is how the server learns the path it sends us down;
    /// a sender report per stream sent is what lets a receiver time the round
    /// trip and line our audio up with our video; and the packet itself is the
    /// traffic that keeps a NAT mapping open on a call where nobody is talking.
    ///
    /// - Parameter senders: our own streams that sent since the last report,
    ///   with what they would say about themselves. With none, one receiver
    ///   report goes out from our SSRC.
    func sendReports(senders: [(ssrc: UInt32, info: RTCP.SenderInfo)]) {
        let now = CACurrentMediaTime()
        guard let route = state.withLock({ $0.feedbackRoute }) else { return }
        let received = state.withLock { state -> [(UInt32, StatisticsSource)] in
            state.audioBySSRC.map { ($0.key, .audio($0.value)) }
                + state.videoBySSRC.map { ($0.key, .video($0.value)) }
        }
        let timing = received.map { ssrc, _ in rtcp.lastSenderReport(about: ssrc, at: now) }
        let blocks = state.withLock { _ in
            zip(received, timing).compactMap { entry, timing -> RTCP.ReportBlock? in
                switch entry.1 {
                case .audio(let stream):
                    stream.reception.block(
                        for: entry.0, lastSenderReport: timing.lastSenderReport,
                        delaySinceLastSenderReport: timing.delay
                    )
                case .video(let stream):
                    stream.reception.block(
                        for: entry.0, lastSenderReport: timing.lastSenderReport,
                        delaySinceLastSenderReport: timing.delay
                    )
                }
            }
        }
        // The blocks ride on the first report; each stream we send has its own.
        if senders.isEmpty {
            rtcp.sendReport(RTCP.report(from: route.sender, sender: nil, blocks: blocks), on: route.transport)
        }
        for (index, sender) in senders.enumerated() {
            rtcp.sendReport(
                RTCP.report(from: sender.ssrc, sender: sender.info, blocks: index == 0 ? blocks : []),
                on: route.transport
            )
        }
    }

    /// A received stream whose statistics a report reads, under the lock.
    private enum StatisticsSource {
        case audio(AudioStream)
        case video(VideoStream)
    }

    /// One person's picture would not decode, as the display layer saw it.
    ///
    /// **A decoder that failed is a decoder with no reference**, and every
    /// delta frame after it fails the same way: the tile freezes until the
    /// sender's own next keyframe. So the stream drops what it cannot use and
    /// asks for a keyframe now.
    func requestKeyframe(from userID: UInt64) {
        state.withLock { state in
            guard let ssrc = state.videoSSRCByUser[userID] else { return }
            state.videoBySSRC[ssrc]?.depacketizer.requireKeyframe()
        }
        askForKeyframes()
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
            if state.audioBySSRC[ssrc] == nil {
                let stream = AudioStream()
                stream.volume = state.volumes[userID] ?? 1
                state.audioBySSRC[ssrc] = stream
            }
        }
    }

    /// - Parameter retransmission: the SSRC its retransmissions arrive on,
    ///   when the gateway named one.
    func bindVideo(ssrc: UInt32, retransmission: UInt32? = nil, to userID: UInt64) {
        guard ssrc != 0 else { return }
        state.withLock { state in
            Self.bindVideo(ssrc: ssrc, to: userID, in: &state)
            if let retransmission, retransmission != 0 {
                state.mediaByRetransmission[retransmission] = ssrc
            }
        }
    }

    /// The same binding, for a caller that already holds the lock.
    private static func bindVideo(ssrc: UInt32, to userID: UInt64, in state: inout State) {
        // A person's SSRC changes when they reconnect, and the stream that was
        // reassembling the old one has to go with it.
        if let previous = state.videoSSRCByUser[userID], previous != ssrc {
            dropVideo(ssrc: previous, in: &state)
        }
        state.videoSSRCByUser[userID] = ssrc
        state.videoUserBySSRC[ssrc] = userID
        if state.videoBySSRC[ssrc] == nil { state.videoBySSRC[ssrc] = VideoStream() }
    }

    private static func dropVideo(ssrc: UInt32, in state: inout State) {
        state.videoBySSRC[ssrc] = nil
        state.videoUserBySSRC[ssrc] = nil
        state.mediaByRetransmission = state.mediaByRetransmission.filter { $0.value != ssrc }
    }

    func unbindVideo(for userID: UInt64) {
        state.withLock { state in
            guard let ssrc = state.videoSSRCByUser.removeValue(forKey: userID) else { return }
            Self.dropVideo(ssrc: ssrc, in: &state)
            state.deliveringVideo.remove(userID)
            // A camera turned back on starts with no offscreen history.
            state.offscreenSince[userID] = nil
            state.offscreenPaused.remove(userID)
        }
    }

    func remove(userID: UInt64) {
        state.withLock { state in
            if let ssrc = state.ssrcByUser.removeValue(forKey: userID) {
                state.audioBySSRC[ssrc] = nil
                state.userBySSRC[ssrc] = nil
            }
            if let ssrc = state.videoSSRCByUser.removeValue(forKey: userID) {
                Self.dropVideo(ssrc: ssrc, in: &state)
            }
            state.sinks[userID] = nil
            state.deliveringVideo.remove(userID)
            state.offscreenSince[userID] = nil
            state.offscreenPaused.remove(userID)
            state.drawnPixels[userID] = nil
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
    ///
    /// **Attaching is starting over.** A tile that has just appeared has no
    /// parameter sets and no keyframe, and a display layer that failed to
    /// decode has lost its reference — both re-attach, and both are owed the
    /// same thing: the reassembler emptied and a keyframe asked for now rather
    /// than on the session's next tick.
    func setVideoSink(_ sink: (@Sendable (CMSampleBuffer) -> Void)?, for userID: UInt64) {
        state.withLock { state in
            state.sinks[userID] = sink
            if sink != nil { state.tracksSinks = true }
            if let ssrc = state.videoSSRCByUser[userID] {
                state.videoBySSRC[ssrc]?.reorder.reset()
                state.videoBySSRC[ssrc]?.depacketizer.reset()
                state.videoBySSRC[ssrc]?.builder.reset()
            }
        }
        if sink != nil { askForKeyframes() }
    }

    /// One person's volume, as a gain: 1 is as sent, and Discord's slider
    /// reaches about 2 at its 200%.
    func setVolume(_ volume: Float, for userID: UInt64) {
        state.withLock { state in
            let clamped = max(0, min(2, volume))
            state.volumes[userID] = clamped
            guard let ssrc = state.ssrcByUser[userID] else { return }
            state.audioBySSRC[ssrc]?.volume = clamped
        }
    }

    /// Discord's Disable Video and Enable Video, for one person.
    ///
    /// Turning it back on starts their picture over: the reassembler holds
    /// nothing worth keeping from before, and they are asked for a keyframe at
    /// once rather than on their own cadence.
    func setVideoDisabled(_ disabled: Bool, for userID: UInt64) {
        let resumes = state.withLock { state -> Bool in
            guard disabled else { return state.videoDisabled.remove(userID) != nil }
            state.videoDisabled.insert(userID)
            state.deliveringVideo.remove(userID)
            if let ssrc = state.videoSSRCByUser[userID], let stream = state.videoBySSRC[ssrc] {
                stream.reorder.reset()
                stream.depacketizer.reset()
                stream.builder.reset()
            }
            return false
        }
        if resumes { requestKeyframe(from: userID) }
    }

    /// Discord's Mute, for one person and for this reader alone.
    func setLocallyMuted(_ muted: Bool, for userID: UInt64) {
        state.withLock { state in
            if muted { state.locallyMuted.insert(userID) } else { state.locallyMuted.remove(userID) }
        }
    }

    /// Who is speaking with priority, and may.
    func setPrioritySpeakers(_ userIDs: Set<UInt64>) {
        state.withLock { $0.prioritySpeakers = userIDs }
    }

    /// The spotlighted person — see `State.focusedVideoUser`.
    func setFocusedVideoUser(_ userID: UInt64?) {
        state.withLock { $0.focusedVideoUser = userID }
    }

    func setIsStage(_ isStage: Bool) {
        state.withLock { $0.isStage = isStage }
    }

    /// The pixels a person's tile draws them at; zero when it goes.
    func setDrawnPixels(_ pixels: Int, for userID: UInt64) {
        state.withLock { $0.drawnPixels[userID] = pixels > 0 ? pixels : nil }
    }

    func setIncomingVideoEnabled(_ enabled: Bool) {
        state.withLock { $0.incomingVideoEnabled = enabled }
    }

    /// What this end wants the server to send — Discord's desktop
    /// `LocalMediaSinkWantsManager.update`, with the ladder (module 4511):
    ///
    /// - `any` is the ladder's want for the number of pictures being received,
    ///   which falls from 100 as more people show video;
    /// - the spotlighted person's picture is asked for whole (when `any` is
    ///   not already);
    /// - in a one-to-one call, each picture as big as its tile draws it;
    /// - nothing of a video turned off, a picture no tile has drawn for thirty
    ///   seconds (two minutes on a stage, three kept at most), every picture
    ///   while the windows are hidden, or a person muted.
    func sinkWants(now: ContinuousClock.Instant = .now, isOneToOne: Bool = false) -> MediaSinkWants {
        state.withLock { state in
            Self.noteOffscreen(at: now, in: &state)
            let pictures = state.videoSSRCByUser.keys.count { !state.videoDisabled.contains($0) }
            let want = VideoLadder.maxSinkValue(streams: pictures)
            var wants = MediaSinkWants(any: want)
            let sized = isOneToOne && !state.isStage
            for (userID, ssrc) in state.videoSSRCByUser {
                let receives = !state.videoDisabled.contains(userID)
                    && !state.offscreenPaused.contains(userID)
                    && state.incomingVideoEnabled
                if !receives {
                    wants.bySSRC[ssrc] = 0
                } else if userID == state.focusedVideoUser, want != VideoQualityPolicy.fullWant {
                    wants.bySSRC[ssrc] = VideoQualityPolicy.fullWant
                } else if sized {
                    wants.bySSRC[ssrc] = VideoLadder.maxSinkValue(
                        streams: pictures, drawnPixels: state.drawnPixels[userID] ?? 0
                    )
                }
            }
            for userID in state.locallyMuted {
                if let ssrc = state.ssrcByUser[userID] { wants.bySSRC[ssrc] = 0 }
            }
            return wants
        }
    }

    /// Discord's `updateOffscreenUsers`: a picture with no tile is marked
    /// offscreen, paused once it has been for the timeout, and of the ones not
    /// yet paused at most three are kept — past three, the one offscreen
    /// longest goes at once.
    private static func noteOffscreen(at now: ContinuousClock.Instant, in state: inout State) {
        guard state.tracksSinks else { return }
        let timeout: Duration = state.isStage ? .seconds(120) : .seconds(30)
        var kept: [UInt64] = []
        func keep(_ userID: UInt64) {
            kept.append(userID)
            guard kept.count > 3 else { return }
            let longest = kept.indices.max { lhs, rhs in
                (state.offscreenSince[kept[lhs]] ?? now) > (state.offscreenSince[kept[rhs]] ?? now)
            } ?? 0
            state.offscreenPaused.insert(kept[longest])
            kept.remove(at: longest)
        }
        // In a fixed order, so that which three are kept does not depend on
        // a dictionary's. **Only pictures that have arrived**: a tile here
        // attaches once one has, so a picture paused before its first packet
        // would never be drawn, and never be asked for again.
        for userID in state.videoSSRCByUser.keys.sorted() where state.deliveringVideo.contains(userID) {
            if state.sinks[userID] != nil {
                state.offscreenSince[userID] = nil
                state.offscreenPaused.remove(userID)
            } else if let since = state.offscreenSince[userID] {
                guard !state.offscreenPaused.contains(userID) else { continue }
                if now - since >= timeout { state.offscreenPaused.insert(userID) } else { keep(userID) }
            } else {
                state.offscreenSince[userID] = now
                keep(userID)
            }
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
            state.mediaByRetransmission.removeAll()
            state.sinks.removeAll()
            state.deliveringVideo.removeAll()
            state.feedbackRoute = nil
            state.sealer = nil
            state.localClips.removeAll()
            state.arrivals.removeAll()
            state.video = VideoCensus()
            state.offscreenSince.removeAll()
            state.offscreenPaused.removeAll()
            state.drawnPixels.removeAll()
            state.tracksSinks = false
        }
    }

    // MARK: Arrival

    /// Called on the socket's queue, once per datagram.
    func accept(_ packet: [UInt8], arrival: TimeInterval) {
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

        // Everything a packet leads to that leaves this lock: the frames, the
        // first-arrival notices, and this end's own requests. A display
        // layer's enqueue reaches into the window server and a request is a
        // socket write, and holding the stream lock across either would stall
        // every arriving packet behind it.
        var outcome = Outcome()
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

            // **Padding first, from the back.** Its count is the final octet
            // and includes itself, so it has to come off before anything reads
            // the end of the frame — which is exactly where the DAVE footer
            // lives.
            if header.hasPadding {
                guard let count = payload.last.map(Int.init),
                      count > 0, count <= payload.count
                else { return }
                payload.removeLast(count)
            }
            // **Then the extension elements, from the front.** They were
            // encrypted, so they arrive at the head of the plaintext rather
            // than in the header, and the media starts after them. A receiver
            // that forgets this decrypts perfectly and hands the decoder four
            // bytes of RFC 8285 preamble.
            let head = header.extensionBodyLength
            if head > 0 {
                guard payload.count >= head else { return }
                payload.removeFirst(head)
            }

            switch header.payloadType {
            case RTP.PayloadType.opus:
                state.audioBySSRC[header.ssrc]?.reception.record(
                    sequence: header.sequence, timestamp: header.timestamp, arrival: arrival
                )
                // Deafened is enforced here rather than at the mixer: a client
                // that decodes everything and multiplies by zero has paid the
                // whole cost of listening.
                guard !payload.isEmpty, !state.isDeafened,
                      let sender = state.userBySSRC[header.ssrc],
                      let frame = Self.open(payload, from: sender, isAudio: true, state: state)
                else { return }
                state.audioBySSRC[header.ssrc]?.buffer.accept(
                    sequence: header.sequence,
                    timestamp: header.timestamp,
                    payload: frame,
                    arrival: arrival
                )

            case RTP.PayloadType.h264, RTP.PayloadType.h264RTX:
                Self.acceptVideo(
                    payload, header: header, arrival: arrival, state: &state, outcome: &outcome
                )

            default:
                break
            }
        }

        for delivery in outcome.frames { delivery.sink(delivery.sample) }
        if !outcome.arrived.isEmpty, let announce = onFirstVideoFrame.withLock({ $0 }) {
            for userID in outcome.arrived { announce(userID) }
        }
        if let route = outcome.route {
            for ask in outcome.retransmissions {
                rtcp.askForRetransmission(
                    on: route.transport, from: route.sender,
                    about: ask.ssrc, sequences: ask.sequences
                )
            }
        }
        if outcome.wantsKeyframe { askForKeyframes() }
    }

    /// What one datagram leads to once the lock is let go.
    private struct Outcome {
        var frames: [VideoDelivery] = []
        /// Senders whose picture this datagram was the first of.
        var arrived: [UInt64] = []
        var retransmissions: [(ssrc: UInt32, sequences: [UInt16])] = []
        var route: FeedbackRoute?
        /// Whether a stream just lost its reference and should ask now rather
        /// than on the session's next tick.
        var wantsKeyframe = false
    }

    /// One video packet — or a retransmission of one — on its way to a frame.
    private static func acceptVideo(
        _ received: [UInt8],
        header: RTPHeader,
        arrival: TimeInterval,
        state: inout State,
        outcome: inout Outcome
    ) {
        var payload = received
        var ssrc = header.ssrc
        var sequence = header.sequence
        if header.payloadType == RTP.PayloadType.h264RTX {
            // RFC 4588: the original sequence number ahead of the original
            // payload, on a stream of its own. Nothing past the number is the
            // server padding the path to measure it, and carries no packet.
            guard payload.count >= 2,
                  let media = state.mediaByRetransmission[header.ssrc]
                    ?? adoptRetransmission(header.ssrc, in: &state)
            else { return }
            ssrc = media
            sequence = UInt16(payload[0]) << 8 | UInt16(payload[1])
            payload.removeFirst(2)
        } else if state.videoBySSRC[ssrc] == nil, let owner = state.soleVideoOwner,
                  state.videoSSRCByUser[owner]
                      .flatMap({ state.videoBySSRC[$0]?.hasSeenPacket }) != true {
            // **A stream session's video binds itself.** See
            // `State.soleVideoOwner`: on a socket with one publisher, H.264 on
            // an unclaimed SSRC is that publisher's, and reading it off the
            // wire cannot disagree with the wire the way a gateway field can.
            //
            // **Only over a binding that has never carried anything.** A
            // publisher offering two simulcast layers would otherwise have each
            // arriving packet unbind the other one, and the reassembler would
            // be reset between every pair of fragments.
            bindVideo(ssrc: ssrc, to: owner, in: &state)
        }

        guard let stream = state.videoBySSRC[ssrc], let userID = state.videoUserBySSRC[ssrc]
        else {
            state.video.unrouted += 1
            return
        }
        // Turned off by the reader: the server was told, and what it had
        // already sent is not drawn either.
        guard !state.videoDisabled.contains(userID) else { return }
        state.video.packets += 1
        stream.hasSeenPacket = true
        if header.payloadType == RTP.PayloadType.h264 {
            stream.reception.record(sequence: sequence, timestamp: header.timestamp, arrival: arrival)
        }

        // **Arrival is reported before a sink is required, and that ordering
        // is load-bearing.** A tile only builds its display layer — and
        // therefore only registers a sink — once the app believes there is a
        // picture, and the app believes that when this fires. Requiring the
        // sink first is a cycle with no entry: no sink, no decode, no first
        // frame, no sink. Measured on a watched share: 1,511 of 1,557 packets
        // opened, the group established, and the tile sat on "Opening share…"
        // for ever because nothing downstream of this line ever ran.
        if state.deliveringVideo.insert(userID).inserted { outcome.arrived.append(userID) }

        // Nothing to draw into yet. The packet goes no further, because a
        // decode nobody displays is a decode nobody asked for — and the
        // reorder buffer starts again when a tile attaches.
        guard let sink = state.sinks[userID] else {
            state.video.sinkless += 1
            return
        }

        // **Every packet on the SSRC goes through the buffer, including the
        // ones carrying no media.** A padding-only probe packet — which an SFU
        // sends to measure the path, and which trims to nothing — still
        // consumes a sequence number, and a receiver that skipped it would see
        // a hole that never fills.
        let deliveries = stream.reorder.insert(
            VideoReorderBuffer.Packet(
                payload: payload, sequence: sequence, marker: header.marker,
                timestamp: header.timestamp
            ),
            at: arrival
        )
        var isContiguous = true
        for delivery in deliveries {
            isContiguous = isContiguous && delivery.isContiguous
            // An empty packet carries its place in the stream and nothing else;
            // a discontinuity it arrived with is carried to the packet after.
            guard !delivery.packet.payload.isEmpty else { continue }
            defer { isContiguous = true }
            let hadReference = !stream.depacketizer.needsKeyframe
            guard let frame = stream.depacketizer.accept(
                payload: delivery.packet.payload,
                sequence: delivery.packet.sequence,
                marker: delivery.packet.marker,
                isContiguous: isContiguous
            ) else {
                if hadReference, stream.depacketizer.needsKeyframe { outcome.wantsKeyframe = true }
                continue
            }
            state.video.frames += 1
            if let sample = picture(
                from: frame, of: userID, stream: stream,
                timestamp: delivery.packet.timestamp, state: &state
            ) {
                outcome.frames.append(VideoDelivery(sink: sink, sample: sample))
            } else {
                outcome.wantsKeyframe = true
            }
        }

        let missing = stream.reorder.asks(at: arrival)
        if !missing.isEmpty {
            outcome.retransmissions.append((ssrc, missing))
            outcome.route = state.feedbackRoute
        }
        if outcome.wantsKeyframe { outcome.route = state.feedbackRoute }
    }

    /// A retransmission on an SSRC nobody named, on a session with one
    /// publisher: it is theirs, for the reason their video is.
    private static func adoptRetransmission(_ ssrc: UInt32, in state: inout State) -> UInt32? {
        guard let owner = state.soleVideoOwner, let media = state.videoSSRCByUser[owner]
        else { return nil }
        state.mediaByRetransmission[ssrc] = media
        return media
    }

    /// One reassembled access unit, opened and made into something a display
    /// layer takes — or `nil`, with the stream told it has lost its reference.
    private static func picture(
        from frame: (units: [[UInt8]], ordered: [[UInt8]], isKeyframe: Bool),
        of userID: UInt64,
        stream: VideoStream,
        timestamp: UInt32,
        state: inout State
    ) -> CMSampleBuffer? {
        // DAVE covers the whole access unit, so it is rebuilt in the arrival
        // order the sender used — parameter sets and SEI included — opened,
        // and split again. `frame.units` is the classified list and is the
        // wrong input: it has already dropped bytes the sender authenticated.
        var units = frame.units
        if state.isDAVEActive || state.decryptors[userID] != nil {
            guard let opened = open(
                H264.annexB(units: frame.ordered), from: userID, isAudio: false, state: state
            ) else {
                // **A frame that will not open is a reference the next frame
                // needs.** Everything after it until a keyframe decodes to
                // rubbish, so the stream asks for one now rather than leaving
                // the tile to smear until the sender's own cadence.
                stream.depacketizer.requireKeyframe()
                return nil
            }
            units = H264.splitAnnexB(opened).filter {
                let type = ($0.first ?? 0) & 0x1F
                return type != H264.NALType.sps.rawValue
                    && type != H264.NALType.pps.rawValue
                    && type != H264.NALType.sei.rawValue
            }
            guard !units.isEmpty else {
                stream.depacketizer.requireKeyframe()
                return nil
            }
        }

        stream.builder.updateParameterSets(stream.depacketizer.parameterSets)
        if stream.baseTimestamp == nil { stream.baseTimestamp = timestamp }
        let elapsed = Double(timestamp &- (stream.baseTimestamp ?? 0)) / 90_000
        guard let sample = stream.builder.sampleBuffer(
            units: units,
            presentationTime: CMTime(seconds: elapsed, preferredTimescale: 90_000),
            isKeyframe: frame.isKeyframe
        ) else {
            state.video.undrawable += 1
            stream.depacketizer.requireKeyframe()
            return nil
        }
        state.video.drawn += 1
        return sample
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
    ///
    /// - Parameters:
    ///   - now: the local clock — the one arrivals were stamped with — which
    ///     each speaker's jitter buffer plays out against.
    ///   - companion: another session's sound to add before the limiter — a
    ///     watched stream's, which plays out of the call's device and inside
    ///     its echo canceller's reference. Told whether anybody in the call is
    ///     speaking on this frame, which is what Stream Attenuation listens
    ///     for; returns whether it added anything. Not asked while deafened.
    func mixNextFrame(
        at now: TimeInterval,
        heardAt: TimeInterval? = nil,
        adding companion: (_ mix: inout [Float], _ isSpeech: Bool) -> Bool = { _, _ in false }
    ) -> MixedFrame {
        state.withLock { state in
            var (contributors, changes) = Self.pullFrame(at: now, heardAt: heardAt, state: &state)

            if !state.isDeafened {
                let isSpeech = state.audioBySSRC.values.contains { $0.isSpeaking }
                if companion(&state.mixScratch, isSpeech) { contributors += 1 }
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

    /// Adds this session's sound to another session's mix, with a gain that
    /// moves from `start` to `end` across the frame.
    ///
    /// **A ramp, not a step.** Stream Attenuation moves the gain every frame,
    /// and a gain that jumps at a frame boundary is a click fifty times a
    /// second while it settles.
    ///
    /// - Returns: whether anything was audible to add.
    func mixStream(
        into mix: inout [Float], at now: TimeInterval, gainFrom start: Float, to end: Float
    ) -> Bool {
        state.withLock { state in
            let (contributors, _) = Self.pullFrame(at: now, state: &state)
            guard contributors > 0 else { return false }
            let count = min(mix.count, state.mixScratch.count)
            let step = (end - start) / Float(max(1, count - 1))
            for index in 0..<count {
                mix[index] += state.mixScratch[index] * (start + step * Float(index))
            }
            return true
        }
    }

    /// How loud everybody else is while a priority speaker talks: Discord's
    /// `prioritySpeakerDucking`, a tenth.
    static let priorityDucking: Float = 0.1

    /// One 20 ms frame from every stream, summed into `mixScratch` with each
    /// person's gain, and who started or stopped speaking on it.
    /// - Parameter heardAt: when this frame will come out of the speakers, on
    ///   the host clock — the stamp a clip keeps it under. Nil for a watched
    ///   stream's sound, which no clip keeps.
    private static func pullFrame(
        at now: TimeInterval, heardAt: TimeInterval? = nil, state: inout State
    ) -> (contributors: Int, changes: [(userID: UInt64, isSpeaking: Bool)]) {
        var changes: [(userID: UInt64, isSpeaking: Bool)] = []
        var contributors = 0

        for index in state.mixScratch.indices { state.mixScratch[index] = 0 }

        for (ssrc, stream) in state.audioBySSRC {
            let frame = stream.buffer.pull(at: now)
            let userID = state.userBySSRC[ssrc]
            // Muted by the reader: pulled, so the buffer keeps draining, and
            // never decoded — and not drawn as speaking either.
            if let userID, state.locallyMuted.contains(userID) {
                if stream.isSpeaking {
                    stream.isSpeaking = false
                    changes.append((userID, false))
                }
                continue
            }
            // **Kept as it arrived**, before the decode: a save decodes the
            // same packets again and hears what was heard here. Only for
            // somebody the tap's plan names — see `ClipAudioTap.Plan`.
            if let tap = state.clipTap, let userID, let heardAt {
                switch frame {
                case .packet(let payload):
                    tap.noteVoice(userID, TimedAudioFrame(time: heardAt, payload: .opus(payload)))
                case .forwardCorrection(let successor):
                    tap.noteVoice(userID, TimedAudioFrame(time: heardAt, payload: .recovered(successor: successor)))
                case .conceal:
                    tap.noteVoice(userID, TimedAudioFrame(time: heardAt, payload: .concealed))
                case .idle:
                    break
                }
            }
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
            let isDucked = !state.prioritySpeakers.isEmpty
                && !(userID.map(state.prioritySpeakers.contains) ?? false)
            let gain = stream.volume * (isDucked ? Self.priorityDucking : 1)
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
        return (contributors, changes)
    }

    /// Adds a locally-played clip to the mix, alongside anything already
    /// playing.
    ///
    /// Bounded: past a handful of overlapping clips the result is noise rather
    /// than sounds, and a channel where everybody presses at once must not be
    /// able to make the mixer do unbounded work per frame.
    /// Where kept voices go for clips, or nil to keep none.
    func setClipTap(_ tap: ClipAudioTap?) {
        state.withLock { $0.clipTap = tap }
    }

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
}
