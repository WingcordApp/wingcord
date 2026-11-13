import AVFoundation
import CoreMedia
import Foundation
import QuartzCore
import Synchronization
import WingcordCore

// MARK: - One media session
//
// A voice gateway, a UDP socket, a key, an MLS group, and the media that
// crosses them. **A call, a Go Live stream this client publishes and a stream
// it watches are all one of these.** Each is a separate session on the wire —
// its own gateway, socket, SSRCs and group — and they differ in what they send
// and what they receive and in nothing else. The handshake, the transport, the
// end-to-end encryption, the roster and the reports are one machine, and this
// file is the only copy of it.
//
// There used to be three: one type for the call, one for a share and one for
// watching a share, each with its own handshake and its own DAVE state machine.
// Every fault found in one had to be found again in the others, and was — the
// roster seeded before opcode 4, opcode 5 before the first packet, a recovery
// that defers rather than drops.
//
// **The actor is the control plane only.** The send paths and the inbound
// streams are `Sendable` classes with their own locks, called synchronously
// from whichever real-time thread produced the media: the capture tap, the
// render callback, VideoToolbox's encoder queue and Network.framework's receive
// queue are four threads with deadlines, and none of them may wait on a fifth.
// The app never touches a codec, a packet or a key. It sets the switches, reads
// the events, and hands over a display layer per person.

public actor MediaSession {

    // MARK: What a session is for

    /// What this session carries, and what its MLS group is keyed on.
    ///
    /// **The group key is part of the kind, never a parameter beside it.** A
    /// call keys its group on the voice channel and a Go Live stream on its
    /// media session id. A share that rode the call's group encrypted a second
    /// session's media under the first one's keys, which every other member
    /// rejects as belonging to another group — so a stream cannot be built
    /// without naming its media session, nor a call without naming its channel.
    public enum Kind: Sendable {
        /// A voice channel or a private call: the microphone and the camera
        /// out, everybody else in.
        ///
        /// - Parameters:
        ///   - channelID: the channel joined, which in a guild is not the
        ///     `serverID` the session identifies with.
        ///   - audioBitrate: the channel's own ceiling. A packet over it is
        ///     dropped by the server rather than transcoded.
        case call(channelID: UInt64, audioBitrate: Int, preferences: AudioPreferences)
        /// Our own Go Live stream: the screen and its sound out, and nothing
        /// in but the far end's reports.
        ///
        /// - Parameters:
        ///   - capture: **already running** — started when the reader picked
        ///     what to share, so the Go Live sheet could show it. The session
        ///     routes it to the encoder once it is keyed, and stops it when
        ///     the share ends.
        ///   - quality: what the capture was started at.
        ///   - audioBitrate: the call channel's own; the sound is sent at no
        ///     less than 128 kbit/s whatever it is, as Discord's
        ///     `setVoiceBitRate` does while a stream's sound is shared.
        case stream(
            mediaSessionID: UInt64,
            capture: ScreenShareCapture,
            quality: ScreenShareCapture.Quality,
            audioBitrate: Int
        )
        /// Somebody else's Go Live stream: their picture in, and nothing out
        /// but our requests for a keyframe. **This end joins the group the
        /// owner made**, so the media session id has to be theirs exactly.
        case watch(mediaSessionID: UInt64, owner: UInt64)
    }

    /// The credential, as the main gateway delivered it. Every kind of session
    /// identifies with the same five fields.
    public struct Connection: Sendable {
        public var endpoint: String
        /// The session's own token. **A stream's is not the call's**, and a
        /// stream that identifies with the call's is refused.
        public var token: String
        /// IDENTIFY's `server_id`: the guild, or the DM channel, for a call;
        /// the stream's **`rtc_server_id`** for Go Live.
        ///
        /// Measured for a stream, after two wrong answers: the DM channel and
        /// `rtc_channel_id` are each refused `4006 Session is no longer valid.`
        /// twenty milliseconds after the frame leaves, and `STREAM_SERVER_UPDATE`
        /// names neither — it sends `guild_id: null`. The pair is the call's
        /// shape again: a session identifies with its *server* and keys its
        /// group on its *channel*.
        public var serverID: String
        public var userID: UInt64
        /// The **main** gateway's session id. Discord mints no second one for a
        /// stream.
        public var sessionID: String

        public init(
            endpoint: String,
            token: String,
            serverID: String,
            userID: UInt64,
            sessionID: String
        ) {
            self.endpoint = endpoint
            self.token = token
            self.serverID = serverID
            self.userID = userID
            self.sessionID = sessionID
        }
    }

    // MARK: What the app sees

    public enum State: Sendable, Equatable {
        case idle
        case connecting
        /// Negotiated, keyed, and passing media: a call with its audio up, a
        /// share with its capture running, a watch ready for the picture.
        case connected
        case failed(String)
    }

    public enum Event: Sendable {
        case state(State)
        /// How well protected the session is. **Each session has its own
        /// group, so its own code**: a stream's epoch authenticator is not the
        /// call's, and showing one beside the other would be a claim about the
        /// wrong session.
        case encryption(EncryptionState)
        /// Everybody the gateway has announced on a call.
        case participantsChanged([UInt64])
        case speaking(userID: UInt64, isSpeaking: Bool)
        /// Our own gate opened or closed.
        case selfSpeaking(Bool)
        /// Somebody's picture started arriving, or went away — on a watch, the
        /// stream's owner. **Arriving, never announced**: see
        /// `InboundStreams.onFirstVideoFrame`.
        case videoAvailability(userID: UInt64, hasVideo: Bool)
        /// Our own microphone level, 0…1, once a frame's worth of meter.
        case inputLevel(Float)
        case statistics(Statistics)
        /// The voice processor heard speech while the input was muted.
        case speechWhileMuted
        /// A share's capture stopped for a reason that is not us: the window
        /// closed, the display went away, the permission was revoked.
        case captureEnded(reason: String)
        /// Somebody began speaking with priority. Whether they may is a fact
        /// about the channel's permissions, which this package does not hold:
        /// the app answers with `setMayHavePriority`, as Discord checks
        /// `PRIORITY_SPEAKER` on every such frame.
        case priorityRequested(userID: UInt64)
        /// Discord's "isn't detecting any input from your mic": nothing but
        /// digital silence, unmuted, for five seconds — and its end.
        case inputSilent(Bool)
        /// Which kind of client somebody in the call is on — opcode 20.
        case platform(userID: UInt64, platform: Int)
        /// What somebody's client says about clips — opcode 18's flags. See
        /// `VoiceGateway.Event.clientFlags`.
        case clientFlags(userID: UInt64, flags: Int)
    }

    /// What a session can promise about who else can see and hear it.
    ///
    /// **The distinction is not cosmetic.** Transport-only means Discord's
    /// servers can decode the media; end-to-end means they cannot. Showing the
    /// same thing for both would claim a guarantee this client is not making,
    /// which is the failure the whole protocol exists to prevent.
    public enum EncryptionState: Sendable, Equatable {
        /// Encrypted to the server and no further. Only a stage channel is
        /// meant to reach this today.
        case transportOnly
        /// End-to-end encryption is negotiated but the group is not built yet.
        /// Nothing is sent until it is.
        case establishing
        /// End-to-end encrypted. The code is the epoch authenticator, for
        /// comparing out of band with somebody on the other end.
        case endToEnd(verificationCode: String)

        /// The state in words, for a log line — **never the verification
        /// code**, which is for comparing with somebody, not for a report.
        public var logWord: String {
            switch self {
            case .transportOnly: "transport only"
            case .establishing: "establishing"
            case .endToEnd: "end-to-end"
            }
        }
    }

    public struct Statistics: Sendable, Equatable {
        public var packetsSent = 0
        public var packetsReceived = 0
        public var lossPercent = 0
        public var jitterMilliseconds: Double = 0
        public var outgoingBitrate = 0

        public init() {}
    }

    public enum InputMode: Sendable, Equatable {
        /// Open whenever there is a voice — see `TransmitGate`.
        case voiceActivity(VoiceActivity)
        /// Open only while the app says so.
        case pushToTalk
        /// Always open. For a mic test, and for nothing else.
        case open
    }

    /// Discord's Input Sensitivity.
    public struct VoiceActivity: Sendable, Equatable {
        /// "Automatically determine input sensitivity" — on by default, as
        /// Discord's desktop app has it.
        public var isAutomatic = true
        /// The line when it is off, in dBFS: Discord's slider runs −100…0 and
        /// starts at −60.
        public var threshold: Float = -60

        public init(isAutomatic: Bool = true, threshold: Float = -60) {
            self.isAutomatic = isAutomatic
            self.threshold = threshold
        }
    }

    public struct AudioPreferences: Sendable, Equatable {
        public var inputDeviceUniqueID: String?
        public var outputDeviceUniqueID: String?
        public var inputVolume: Float = 1
        public var outputVolume: Float = 1
        public var inputMode: InputMode = .voiceActivity(VoiceActivity())
        /// Discord's Echo Cancellation and Automatic Gain Control, as the input
        /// profile resolves them. See `VoiceAudioEngine.Processing`.
        public var processing = VoiceAudioEngine.Processing()
        /// Discord's Stream Attenuation: how far a watched stream's sound is
        /// lowered while somebody in the call speaks, 0…1, or `nil` when it is
        /// off. On at a half by default, as Discord's `sidechainCompression`
        /// and its strength of 50 are.
        public var streamAttenuation: Float? = 0.5

        public init() {}
    }

    public struct VideoPreferences: Sendable, Equatable {
        public var cameraDeviceID: String?
        /// The channel's video quality is "720p" rather than "Auto": the camera
        /// is encoded at 1280×720 whatever the viewers want. See
        /// `VideoQualityPolicy.camera`.
        public var isFullQuality = false

        public init() {}
    }

    // MARK: Owned state

    private let connection: Connection
    private let kind: Kind
    /// The call's audio preferences; a share and a watch have no microphone
    /// and keep the defaults.
    private var preferences: AudioPreferences

    private var gateway: VoiceGateway?
    private var transport: VoiceTransport?
    private var gatewayTask: Task<Void, Never>?
    private var mixPump: MixPump?
    private var statisticsTask: Task<Void, Never>?

    /// The session's end-to-end encryption, or `nil` on one the server said
    /// needs none. Held on the actor: every MLS transition is control-plane
    /// work, and only the `Sendable` transforms it produces reach the media
    /// threads.
    private var dave: DAVESession?
    private var lastEncryptionState: EncryptionState = .transportOnly
    /// When a DAVE recovery may run. See `RecoveryPacer` for what both ways of
    /// getting this wrong looked like.
    private var pacer = RecoveryPacer()
    /// Everybody the gateway has announced, whether or not there was a group
    /// to tell at the time.
    ///
    /// **A fact the server states before its consumer exists must be
    /// remembered.** The roster arrives on opcodes 11 and 18, and both land
    /// *before* opcode 4 — which is what creates the DAVE session. A call where
    /// the far end was announced once, by opcode 18 alone, refused every
    /// welcome with "user … is not in this call" and transmitted nothing in
    /// either direction for its whole life.
    private var announcedUsers: Set<UInt64> = []

    /// Our SSRC from READY. Audio goes on it, video on the next, retransmission
    /// on the one after: Discord's convention, which the server assumes.
    private var ourSSRC: UInt32 = 0
    /// The simulcast layer id READY allocated for our video, echoed back in
    /// opcode 12 rather than chosen — see `VoiceGateway.VoiceReady`.
    private var videoRID = ""
    /// The header extension ids a kind of packet carries.
    private struct ExtensionIDs {
        var audioLevel: UInt8?
        var sendTime: UInt8?
        var transportSequence: UInt8?
    }

    /// See `handle(.ready)` for why the two differ.
    private var audioExtensions = ExtensionIDs()
    private var videoExtensions = ExtensionIDs()
    /// The session's packet counter, **shared by every stream on its socket**.
    /// The number is transport-wide; one per stream would read to the far end
    /// as a path losing every other packet.
    private let transportSequence = TransportSequence()
    /// Whether opcode 4 has keyed the session. Once: see `handle`.
    private var isKeyed = false
    private var isConnected = false
    /// Set first thing in `stop`, and asked by everything that resumes after
    /// an `await`.
    ///
    /// **A suspended start can outlive the stop.** The actor is reentrant, so
    /// leaving the call while its audio engine, its camera or a share's capture
    /// is still coming up lets that start finish afterwards — on a session with
    /// no socket — and a capture that finishes then is somebody's screen or
    /// camera running with nothing on screen saying so.
    private var isStopped = false

    private let inbound: InboundStreams
    /// The microphone on a call, the shared sound on a stream.
    private let audioSend: AudioSendPath
    private let videoSend: VideoSendPath
    private let videoEncode = VideoEncodePath()
    /// Our own picture on the way to the self tile. See `setVideoSink`.
    private let preview = PreviewSink()

    /// The call's microphone and speakers, and `nil` on any other session: a
    /// share sends no voice and a watch plays nothing of its own — its sound
    /// is played by the call's, through `StreamAudio`.
    private let audio: VoiceAudioEngine?
    /// A voice message is listening, so the processor stays open whatever the mute.
    private var isRecordingVoiceNote = false
    private var camera: CameraCapture?
    /// A watched stream's sound, mixed into this call's output. See
    /// `setStreamAudio`.
    private let streamMix = Mutex(StreamMix())
    /// See `setClipTap`. Read from the mix thread, the microphone's and the
    /// actor.
    private let clipTap = Mutex<ClipAudioTap?>(nil)
    /// See `setStreamClipSink`. Read on VideoToolbox's callback thread.
    private let streamClip = Mutex<StreamClipSink?>(nil)
    /// A long sound looped under the call — a stage's waiting music. See
    /// `setLoopedTrack`.
    private let loopedTrack = Mutex<LoopedTrack?>(nil)
    /// Whether opcode 12 has declared our video active, so it is declared
    /// inactive again before the socket goes.
    private var isVideoAnnounced = false

    private var isMuted = false
    private var isDeafened = false
    /// Our gate, as last reported, and the priority key — together, the flags
    /// opcode 5 carries.
    private var isGateOpen = false
    private var isPriorityHeld = false
    /// Who has asked to speak with priority (opcode 5's flag), and who the app
    /// says may. The ones in both are ducked under.
    private var wantsPriority: Set<UInt64> = []
    private var mayHavePriority: Set<UInt64> = []
    /// Opcode 15 as last sent; nil until it first differed from `{any: 100}`.
    private var sentWants: MediaSinkWants?
    /// Reports in a row with the microphone delivering silence, and whether
    /// that has been said.
    private var silentReports = 0
    private var isReportedSilent = false
    /// The share of our audio the far end last reported losing, in per cent.
    private var audioLoss = 0

    // MARK: What our picture should be

    /// Opcode 15, as last read.
    private var sinkWants: MediaSinkWants?
    /// The channel's "720p": the camera's size fixed, its bitrate band still
    /// the want's.
    private var isFullQuality = false
    /// A camera whose owner is quiet drops its frame rate. See
    /// `FramerateReducer`.
    private var reducer = FramerateReducer(now: .now)
    /// A share's own picture — the quality's box, and the frame fitted inside
    /// it — for as long as it runs.
    private var shareShape: (box: ScreenShareCapture.Quality, width: Int, height: Int)?
    /// The pixels a share's viewers last asked for. Moves only on a change of
    /// more than five per cent, as Discord's does, so a viewer resizing a
    /// window by a few pixels is not a new bitrate band.
    private var viewerPixels = 0
    /// What the encoder runs at, and what moves its bitrate inside that.
    private var videoQuality: VideoQuality?
    private var bitrate: BitrateController?

    public nonisolated let events: AsyncStream<Event>
    private nonisolated let continuation: AsyncStream<Event>.Continuation

    public init(connection: Connection, kind: Kind) {
        self.connection = connection
        self.kind = kind
        if case .call(_, _, let preferences) = kind {
            self.preferences = preferences
            audio = VoiceAudioEngine()
            streamMix.withLock { $0.attenuation = preferences.streamAttenuation }
        } else {
            preferences = AudioPreferences()
            audio = nil
        }
        if case .stream = kind {
            audioSend = AudioSendPath(signal: .soundshare)
        } else {
            audioSend = AudioSendPath()
        }
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        self.continuation = continuation

        // **The far end's requests are answered where they are read.** A
        // retransmission is only worth sending while the frame it belongs to
        // can still be assembled, and a keyframe only while the viewer is
        // still waiting — so neither waits for the session's tick, or for this
        // actor.
        let videoSend = VideoSendPath()
        self.videoSend = videoSend
        inbound = InboundStreams { request in
            switch request {
            case .retransmit(let ssrc, let sequences):
                videoSend.retransmit(sequences, of: ssrc)
            case .keyframe:
                videoSend.requestKeyframe()
            }
        }
    }

    /// Which of the three this is, in the gateway's terms and the trace's.
    private var role: VoiceGateway.Role {
        switch kind {
        case .call: .call
        case .stream: .stream
        case .watch: .watch
        }
    }

    /// What the session's MLS group is keyed on. See `Kind`.
    var groupKey: DAVESession.GroupKey {
        switch kind {
        case .call(let channelID, _, _): .channel(channelID)
        case .stream(let id, _, _, _), .watch(let id, _): .mediaSession(id)
        }
    }

    private var isCall: Bool {
        if case .call = kind { true } else { false }
    }

    /// Whether anything but the far end's reports arrives on this socket. A
    /// share sends and does not receive.
    private var receivesMedia: Bool {
        if case .stream = kind { false } else { true }
    }

    /// Whether this session sends a picture. A watch never does.
    private var sendsVideo: Bool {
        if case .watch = kind { false } else { true }
    }

    // MARK: Lifecycle

    public func start() {
        Log.info(logArea, "\(role) session starting")
        emit(.state(.connecting))
        var line = "\(role) session server_id=\(connection.serverID) group=\(groupKey.snowflake)"
        if case .watch(_, let owner) = kind {
            line += " owner=\(owner)"
            // **One publisher, and this session exists to receive them.** See
            // `InboundStreams.State.soleVideoOwner`.
            inbound.setSoleVideoOwner(owner)
        }
        VoiceTrace.write(line)

        inbound.onFirstVideoFrame.withLock { slot in
            slot = { [weak self] userID in
                self?.emit(.videoAvailability(userID: userID, hasVideo: true))
            }
        }
        if isCall {
            audioSend.inputMode = preferences.inputMode
            audioSend.onGateChanged.withLock { slot in
                slot = { [weak self] isOpen in
                    Task { await self?.gateDidChange(isOpen) }
                }
            }
        }

        let gateway = VoiceGateway(
            role: role,
            endpoint: connection.endpoint,
            serverID: connection.serverID,
            userID: String(connection.userID),
            sessionID: connection.sessionID,
            token: connection.token
        )
        self.gateway = gateway
        gatewayTask = Task { [weak self] in
            await gateway.connect()
            guard let stream = await gateway.events else { return }
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    public func stop() async {
        isStopped = true
        gatewayTask?.cancel(); gatewayTask = nil
        mixPump?.cancel(); mixPump = nil
        statisticsTask?.cancel(); statisticsTask = nil

        // Declared inactive before the socket goes, so the server stops
        // forwarding rather than waiting out a timeout on a sender that
        // vanished.
        if isVideoAnnounced { await announceVideo(nil) }

        await audio?.stop()
        // **The session's to stop once it exists**, whether or not it got as
        // far as routing it: a capture handed over and then left running is
        // somebody's screen being read with nothing on screen saying so.
        await shareCapture?.stop()
        camera?.stop(); camera = nil
        videoEncode.end()
        audioSend.teardown()
        videoSend.teardown()
        preview.set(nil)

        transport?.stop(); transport = nil
        await gateway?.stop(); gateway = nil

        inbound.reset()
        emit(.state(.idle))
        continuation.finish()
    }

    // MARK: The handshake

    private func handle(_ event: VoiceGateway.Event) async {
        guard !isStopped else { return }
        switch event {
        case .ready(let ready):
            ourSSRC = ready.ssrc
            videoRID = ready.videoRID
            // **Audio sends what its server named, video what a working client
            // sends.** READY names no extension ids at all. Every video packet
            // Discord draws carries `abs-send-time` on id 3 and the
            // transport-wide sequence on id 5 — read off a Go Live stream, and
            // off a call's camera since (`RTPExtension.DefaultID`) — and both
            // are what the far end's estimator measures a publisher's path
            // with. Audio from Discord carries other ids again, which nothing
            // here has read well enough to copy.
            audioExtensions = ExtensionIDs(
                audioLevel: ready.audioLevelExtensionID,
                sendTime: ready.sendTimeExtensionID,
                transportSequence: ready.transportSequenceExtensionID
            )
            videoExtensions = ExtensionIDs(
                sendTime: ready.sendTimeExtensionID ?? RTPExtension.DefaultID.absoluteSendTime,
                transportSequence: ready.transportSequenceExtensionID
                    ?? RTPExtension.DefaultID.transportSequence
            )
            await openTransport(ready)

        case .sessionDescription(let cipher, let key, _, let daveVersion):
            // **Once.** A second session description would build a second
            // group, a second set of writers, a second mix pump and a second
            // statistics loop over the first. Discord has never been seen to
            // send one; if it ever does, the trace says so rather than the call
            // quietly doubling.
            guard !isKeyed else {
                VoiceTrace.fault("\(role) keyed a second time; the first key stands")
                return
            }
            guard let transport else { return }
            isKeyed = true
            let sealer = VoiceSealer(cipher: cipher, secretKey: key)
            inbound.setSealer(sealer)
            // **DAVE first, and the key package goes out immediately.** The
            // session description is the only place the server names the
            // protocol version, and the gateway will not start the group until
            // it has a key package from every pending member.
            await startDAVE(version: daveVersion)
            configureSendPaths(sealer: sealer, transport: transport)
            await startMedia()
            // Anything turned off before the session could say so.
            await sendSinkWants()

        case .speaking(let userID, let ssrc, let flags):
            guard receivesMedia else { return }
            inbound.bind(ssrc: ssrc, to: userID)
            guard isCall else { return }
            emit(.speaking(userID: userID, isSpeaking: flags != 0))
            notePriority(of: userID, wants: SpeakingFlags(rawValue: flags).contains(.priority))
            // A muted person's SSRC may only be learned now.
            await sendSinkWants()

        case .videoStreams(let userID, let audioSSRC, let videoSSRC, let retransmissionSSRC):
            // **This is how somebody's SSRCs arrive.** A watch announces nothing
            // of its own; everything it routes is described to it here.
            guard receivesMedia else { return }
            if audioSSRC != 0 { inbound.bind(ssrc: audioSSRC, to: userID) }
            if videoSSRC != 0 {
                // **Bound, not announced.** The SSRC has to be routed in case
                // packets do arrive; the tile is told only once one has. Telling
                // it here paints a black rectangle over the avatar of anybody
                // the gateway says has video — including a Go Live share on a
                // media session this one never joined.
                inbound.bindVideo(ssrc: videoSSRC, retransmission: retransmissionSSRC, to: userID)
            } else {
                inbound.unbindVideo(for: userID)
                if isCall { emit(.videoAvailability(userID: userID, hasVideo: false)) }
            }
            // A video turned off before its SSRC was known is unwanted now.
            if isCall { await sendSinkWants() }

        case .clientsConnected(let ids):
            // Also DAVE's admission list. A member the gateway never announced
            // here may not be added to the group, which is what stops the
            // delivery service seating a listener of its own.
            announcedUsers.formUnion(ids)
            dave?.recognise(users: Set(ids))
            if isCall { emit(.participantsChanged(Array(announcedUsers))) }

        case .clientPlatform(let userID, let platform):
            if isCall { emit(.platform(userID: userID, platform: platform)) }

        case .clientFlags(let userID, let flags):
            if isCall { emit(.clientFlags(userID: userID, flags: flags)) }

        case .clientDisconnected(let userID):
            announcedUsers.remove(userID)
            inbound.remove(userID: userID)
            dave?.forget(user: userID)
            if isCall {
                emit(.speaking(userID: userID, isSpeaking: false))
                emit(.videoAvailability(userID: userID, hasVideo: false))
            }

        case .dave(let message):
            await handleDAVE(message)

        case .davePrepareTransition(let transitionID, let version):
            if dave?.prepareTransition(id: transitionID, protocolVersion: version) == true {
                await gateway?.sendTransitionReady(transitionID)
            }
            daveDidChange()

        case .daveExecuteTransition(let transitionID):
            dave?.executeTransition(id: transitionID)
            daveDidChange()

        case .davePrepareEpoch(let epoch, let version):
            if dave?.prepareEpoch(epoch, protocolVersion: version) == true {
                await sendKeyPackage()
            }
            daveDidChange()

        case .mediaSinkWants(let wants):
            guard wants != sinkWants else { return }
            sinkWants = wants
            VoiceTrace.write("\(role) sink wants \(wants)")
            updateVideoQuality()

        case .resumed:
            if isConnected { emit(.state(.connected)) }

        case .closed(let code, let reason, _):
            // **4006 on a stream means the `server_id` is wrong**: the server
            // found the media server and no session on it under what was named.
            // It cost two wrong answers to learn which snowflake belongs there —
            // see `Connection.serverID` — and a guild stream is the one place
            // nothing has tested it.
            if code == 4006, !isCall {
                VoiceTrace.fault(
                    "\(role) identify refused with server_id=\(connection.serverID); "
                    + "that field is the suspect"
                )
            }
            emit(.state(.failed(reason)))
        }
    }

    private func openTransport(_ ready: VoiceGateway.VoiceReady) async {
        let transport = VoiceTransport(host: ready.ip, port: ready.port)
        self.transport = transport
        // **Routed on the socket's own queue, synchronously.** A hop here
        // re-orders bursts, which is the exact fault the jitter buffer
        // downstream exists to repair — and every session reads its socket,
        // because even a share is sent the far end's reports.
        transport.start { [inbound] bytes in
            inbound.accept(bytes, arrival: CACurrentMediaTime())
        }
        // This end's own requests — a NACK, a picture loss indication — go out
        // on the same socket, signed with our SSRC.
        inbound.attach(transport: transport, sender: ready.ssrc)

        guard await transport.waitUntilReady() else {
            emit(.state(.failed(
                isCall ? "Could not open the media socket." : "Could not open the stream's media socket."
            )))
            return
        }
        guard let cipher = VoiceCipher.best(from: ready.modes) else {
            emit(.state(.failed(
                (isCall ? "The voice server" : "The stream server")
                    + " offered no cipher this client supports."
            )))
            return
        }
        do {
            // **Our own address, even on a session that sends nothing.** The
            // server describes the session — and forwards anything at all —
            // only once the protocol is selected.
            let mapped = try await transport.discoverAddress(ssrc: ready.ssrc)
            await gateway?.selectProtocol(
                address: mapped.address, port: mapped.port, cipher: cipher
            )
        } catch {
            emit(.state(.failed("Could not discover this machine's address.")))
        }
    }

    /// Points the send paths at the socket, under the key opcode 4 just named.
    private func configureSendPaths(sealer: VoiceSealer, transport: VoiceTransport) {
        let audioBitrate: Int?
        switch kind {
        case .call(_, let bitrate, _):
            audioBitrate = bitrate
        case .stream(_, _, _, let bitrate):
            audioBitrate = max(Self.soundshareBitrate, bitrate)
            // A stream's sound has no gate: what the shared application
            // plays is sent, quiet passages included.
            audioSend.inputMode = .open
        case .watch:
            audioBitrate = nil
        }
        if let audioBitrate {
            audioSend.configure(
                sealer: sealer,
                transport: transport,
                ssrc: ourSSRC,
                bitrate: audioBitrate,
                audioLevelExtensionID: audioExtensions.audioLevel,
                sendTimeExtensionID: audioExtensions.sendTime,
                transportSequenceExtensionID: audioExtensions.transportSequence,
                transportSequence: transportSequence
            )
        }
        guard sendsVideo else { return }
        videoSend.configure(
            sealer: sealer,
            transport: transport,
            // Discord's convention, and the server assumes it: audio on the
            // SSRC it assigned, video on the next, retransmissions on the one
            // after. A client that picks its own numbers has its video
            // forwarded to nobody.
            ssrc: ourSSRC &+ 1,
            retransmissionSSRC: ourSSRC &+ 2,
            sendTimeExtensionID: videoExtensions.sendTime,
            transportSequenceExtensionID: videoExtensions.transportSequence,
            transportSequence: transportSequence
        )
    }

    /// Everything that may only start once there is a key, and then the
    /// session is connected.
    private func startMedia() async {
        switch kind {
        case .call:
            guard await startAudio() else { return }
        case .stream(_, let capture, let quality, _):
            guard await startShare(capture, quality: quality) else { return }
        case .watch:
            break
        }
        guard !isStopped else { return }
        isConnected = true
        startStatistics()
        emit(.state(.connected))
    }

    // MARK: End-to-end encryption
    //
    // The session owns the `DAVESession` and does every transition on the
    // actor; the transforms it hands to the media paths are `Sendable` and run
    // on the real-time threads that produce and receive frames.

    private func startDAVE(version: UInt16) async {
        guard version > 0 else {
            // Only a stage channel reaches here today. Nothing is protected
            // beyond the transport, and the app is told so rather than left to
            // imply it.
            VoiceTrace.write("\(role) dave off; transport encryption only")
            dave = nil
            audioSend.setDAVE(nil)
            videoSend.setDAVE(nil)
            daveDidChange()
            return
        }
        let session = DAVESession(
            protocolVersion: version,
            userID: connection.userID,
            groupKey: groupKey,
            label: role.rawValue
        )
        // **Everybody announced so far, not only ourselves** — the roster
        // arrives before this object exists. A watch adds the owner as well:
        // it joins their group, and they may not have been announced yet.
        var known = announcedUsers.union([connection.userID])
        if case .watch(_, let owner) = kind { known.insert(owner) }
        session.recognise(users: known)
        dave = session
        audioSend.setDAVE(session.encryptor)
        videoSend.setDAVE(session.encryptor)
        daveDidChange()
        await sendKeyPackage()
    }

    private func sendKeyPackage() async {
        guard let dave, let gateway else { return }
        do {
            await gateway.sendKeyPackage(try dave.makeKeyPackage())
        } catch {
            VoiceTrace.fault("\(role) dave key package would not build: \(error)")
        }
    }

    private func handleDAVE(_ message: DAVEInbound) async {
        guard let dave, let gateway else { return }
        switch message {
        case .externalSender(let sender):
            do {
                try dave.setExternalSender(sender)
            } catch {
                VoiceTrace.fault("\(role) dave external sender refused: \(error)")
            }

        case .proposals(let proposals):
            do {
                guard let outbound = try dave.processProposals(proposals),
                      case .commitWelcome(let commit, let welcome) = outbound
                else { return }
                await gateway.sendCommitWelcome(commit: commit, welcome: welcome)
            } catch {
                // A proposal this client will not accept is not a reason to
                // tear the session down: the gateway may still land a commit we
                // can follow, and if it does not, the transition times out.
                VoiceTrace.fault("\(role) dave proposals refused: \(error)")
            }

        case .announceCommit(let transitionID, let commit):
            guard let raw = try? commit.marshalled() else { return }
            await settle(
                dave.processCommit(commit, raw: raw, transitionID: transitionID),
                on: gateway
            )

        case .welcome(let transitionID, let welcome):
            await settle(dave.processWelcome(welcome, transitionID: transitionID), on: gateway)

        case .malformed:
            // Transition zero is the only id available when the frame itself
            // could not be read; the gateway's recovery is the same either way.
            await gateway.sendInvalidCommitWelcome(0)
            await rebuildDAVE()
        }
    }

    private func settle(_ outcome: DAVESession.Outcome, on gateway: VoiceGateway) async {
        switch outcome {
        case .ready(let transitionID):
            await gateway.sendTransitionReady(transitionID)
        case .executed, .ignored:
            break
        case .invalid(let transitionID):
            // §"Recovery from Invalid Commit or Welcome": tell the gateway,
            // reset the local state, and offer a fresh key package to be
            // re-added with.
            await gateway.sendInvalidCommitWelcome(transitionID)
            await rebuildDAVE()
        }
        daveDidChange()
    }

    /// The protocol's own recovery — opcode 31, reset, fresh key package —
    /// **paced, and the pacing defers rather than drops.**
    ///
    /// The gateway answers a key package with a welcome immediately, so while
    /// the media session holds somebody it has not announced, every welcome is
    /// refusable and an unbraked recovery spins: sixty-seven rebuilds in three
    /// seconds, measured. Dropping a request inside the window is the other way
    /// to break it — the refusal thrown away is the one whose key package
    /// would have been committed, and the session never recovers.
    private func rebuildDAVE() async {
        guard let dave else { return }
        switch pacer.request() {
        case .now:
            break
        case .alreadyWaiting:
            return
        case .after(let remaining):
            Task { [weak self] in
                try? await Task.sleep(for: remaining)
                await self?.rebuildAfterPacing()
            }
            return
        }
        dave.reset(protocolVersion: dave.protocolVersion)
        await sendKeyPackage()
        daveDidChange()
    }

    /// The rebuild the pacing window held back — **if it is still wanted.**
    ///
    /// Half a second is long enough for the group to establish, and a deferred
    /// rebuild acting on a decision taken before then tears a working group
    /// down and its send ratchet with it: measured as `dave sending under
    /// epoch 2` followed 185 ms later by `dave reset to v1`, and every frame
    /// after refused as `ours unkeyed`. So the precondition is asked again.
    private func rebuildAfterPacing() async {
        pacer.waitElapsed()
        guard let dave, dave.status == .establishing else { return }
        await rebuildDAVE()
    }

    /// Pushes the current per-sender transforms to the receive path, and the
    /// session's protection to the app.
    ///
    /// Called after every DAVE state change: a member added or removed changes
    /// who this client can decrypt, and a receive path holding a stale map
    /// either drops media it could play or plays media from an epoch the group
    /// has left.
    private func daveDidChange() {
        if let dave {
            inbound.setDAVE(decryptors: dave.receiveTransforms, active: dave.protocolVersion > 0)
        } else {
            inbound.setDAVE(decryptors: [:], active: false)
        }

        let state: EncryptionState = switch dave?.status {
        case .encrypted(let code): .endToEnd(verificationCode: code)
        case .establishing: .establishing
        case .transportOnly, nil: .transportOnly
        }
        guard state != lastEncryptionState else { return }
        lastEncryptionState = state
        stats.encryptionChanges += 1
        Log.info(logArea, "\(role) encryption \(public: state.logWord)")
        emit(.encryption(state))

        // **The first frame a receiver can open must be a keyframe, and the
        // group decides when that is.** The encoder's IDR is produced the
        // instant a capture starts, roughly half a second before the group
        // exists, so it is refused — correctly — and what follows is P-slices
        // nobody can start from. Asked for when the keys arrive, and on every
        // epoch after: a new key is a fresh start for everybody holding it.
        if case .endToEnd = state { videoSend.requestKeyframe() }
    }

    // MARK: Our picture

    /// Asks the encoder for a keyframe on its next frame.
    ///
    /// **Called when somebody starts watching.** A viewer who arrives halfway
    /// through has no parameter sets and no reference frame, and nothing sent
    /// until the next keyframe means anything to them.
    public func requestKeyframe() {
        videoSend.requestKeyframe()
    }

    /// A picture that would not decode, as somebody's display layer saw it.
    ///
    /// The decoder has lost its reference and every delta frame after this
    /// one fails the same way, so the sender is asked for a keyframe now
    /// rather than left to its own cadence. See
    /// `InboundStreams.requestKeyframe(from:)`.
    public nonisolated func requestKeyframe(from userID: UInt64) {
        inbound.requestKeyframe(from: userID)
    }

    /// Opens our video at a quality: opcode 12, then the encoder, then the
    /// send path.
    ///
    /// **The capture is the caller's, and it is switched on after this
    /// returns** wherever it can be: a capture that runs first spends its
    /// keyframe on a pipeline that is not there yet, and the first access unit
    /// that leaves is then a P-slice no decoder can start from — measured on a
    /// share as `video first frame in=[1:770]` against the camera's
    /// `in=[7:20 8:4 5:62643]`.
    ///
    /// - Parameter capture: what opcode 12 declares, which is Discord's — **the
    ///   capture's size, not the encoded frame's.** A client whose stream
    ///   renders announces 1280×720 while sending a scaled desktop, or a rung of
    ///   the ladder, of no such shape.
    private func beginVideo(
        quality: VideoQuality, capture: (width: Int, height: Int, framerate: Int)
    ) async {
        let controller = BitrateController(quality: quality)
        videoQuality = quality
        bitrate = controller
        // **Announced before a frame can leave, and awaited.** Video on an SSRC
        // the server has not been told about is forwarded to nobody, which
        // looks exactly like a camera that is off; announcing from a detached
        // task made that a race.
        await announceVideo(VideoAnnouncement(
            width: capture.width,
            height: capture.height,
            framerate: capture.framerate,
            bitrate: quality.bitrateMax
        ))
        // The rid printed is the one **announced**, not READY's: they differ
        // whenever READY names none, and printing the input to a decision
        // instead of its output is how a fix reads as a no-op.
        VoiceTrace.write(
            "\(role) video \(quality.width)x\(quality.height)@\(quality.framerate) "
            + "max=\(capture.width)x\(capture.height) "
            + "band=\(quality.bitrateMin / 1_000)-\(quality.bitrateMax / 1_000)kbit "
            + "ssrc=\(ourSSRC &+ 1) "
            + "rid=\(videoRID.isEmpty ? VoiceGateway.baseSimulcastLayer : videoRID) "
            + "ext=[\(videoExtensions.sendTime.map(String.init) ?? "-"):abs-send-time "
            + "\(videoExtensions.transportSequence.map(String.init) ?? "-"):transport-cc]"
        )
        let encoder = H264Encoder(configuration: .init(
            width: quality.width, height: quality.height,
            framerate: quality.framerate, bitrate: controller.bitrate
        ))
        if case .stream = kind {
            encoder.onSample = { [weak self] sample in self?.streamClip.withLock { $0 }?.video.append(sample) }
        }
        encoder.onEncodedFrame = { [videoSend] units, sets, isKeyframe, captured in
            videoSend.send(
                units: units,
                parameterSets: sets,
                isKeyframe: isKeyframe,
                captureTime: captured.seconds
            )
        }
        do {
            try encoder.start()
        } catch {
            VoiceTrace.fault("\(role) video encoder would not start: \(error)")
        }
        videoSend.setBitrate(controller.bitrate)
        videoEncode.begin(encoder, framerate: quality.framerate)
        videoSend.isActive = true
    }

    private func endVideo() async {
        videoSend.isActive = false
        videoEncode.end()
        videoQuality = nil
        bitrate = nil
        if isVideoAnnounced { await announceVideo(nil) }
    }

    /// What our picture should be now, from everything that decides it: the
    /// server's wants, the channel's quality and the reducer for a camera; the
    /// viewers for a share.
    private func wantedVideoQuality() -> VideoQuality? {
        if let shareShape {
            let band = VideoQualityPolicy.shareBand(
                boxHeight: shareShape.box.height, framerate: shareShape.box.framerate
            )
            let box = VideoQuality(
                width: shareShape.box.width,
                height: shareShape.box.height,
                framerate: shareShape.box.framerate,
                bitrateMin: band.min,
                bitrateMax: band.max
            )
            // The band is the box's; the frame is the source fitted inside it.
            var quality = VideoQualityPolicy.share(maximum: box, viewerPixels: viewerPixels)
            quality.width = shareShape.width
            quality.height = shareShape.height
            return quality
        }
        guard camera != nil else { return nil }
        return VideoQualityPolicy.camera(
            want: VideoQualityPolicy.want(for: ourSSRC &+ 1, in: sinkWants),
            isMuted: reducer.isMuted,
            isFull: isFullQuality
        )
    }

    /// Re-reads what the picture should be and moves the encoder to it.
    ///
    /// A new size is a new compression session, whose first frame is a
    /// keyframe; a new rate or band is a property write.
    private func updateVideoQuality() {
        if case .stream = kind, let pixels = sinkWants?.pixelCounts[ourSSRC &+ 1] {
            // Discord's smoothing: a viewer count that moved by less than five
            // per cent is the same viewers.
            let ratio = viewerPixels > 0 ? Double(pixels) / Double(viewerPixels) : 0
            if viewerPixels == 0 || ratio > 1.05 || ratio < 0.95 { viewerPixels = pixels }
        }
        guard let current = videoQuality, var controller = bitrate,
              let next = wantedVideoQuality(), next != current
        else { return }
        videoQuality = next
        if next.width != current.width || next.height != current.height
            || next.framerate != current.framerate {
            videoEncode.reconfigure(.init(
                width: next.width, height: next.height,
                framerate: next.framerate, bitrate: controller.bitrate
            ))
        }
        if let rate = controller.update(quality: next) { applyBitrate(rate) }
        bitrate = controller
        VoiceTrace.write(
            "\(role) video now \(next.width)x\(next.height)@\(next.framerate) "
            + "band=\(next.bitrateMin / 1_000)-\(next.bitrateMax / 1_000)kbit"
        )
    }

    private func applyBitrate(_ rate: Int) {
        videoEncode.setBitrate(rate)
        videoSend.setBitrate(rate)
    }

    private struct VideoAnnouncement {
        var width: Int
        var height: Int
        var framerate: Int
        var bitrate: Int
    }

    /// Opcode 12: our video active at this ceiling, or inactive.
    private func announceVideo(_ video: VideoAnnouncement?) async {
        isVideoAnnounced = video != nil
        await gateway?.announceStreams(
            audioSSRC: ourSSRC,
            videoSSRC: ourSSRC &+ 1,
            rtxSSRC: ourSSRC &+ 2,
            rid: videoRID,
            isActive: video != nil,
            width: video?.width ?? 0,
            height: video?.height ?? 0,
            framerate: video?.framerate ?? 0,
            bitrate: video?.bitrate ?? 0
        )
    }

    /// Where one person's picture goes.
    ///
    /// **Our own picture never comes from the network.** Everybody else's
    /// arrives over the socket and is keyed by user id in `InboundStreams`;
    /// ours never does, so a sink registered there for our own id waits for a
    /// frame that cannot exist — which is how a screen share's self tile drew
    /// black for a whole call while the share itself was healthy. Our own id
    /// takes a share's preview instead: ScreenCaptureKit's frames, from the
    /// capture, with no encode and no decode. A camera's self tile never comes
    /// here at all — it takes the capture session's preview layer.
    public nonisolated func setVideoSink(
        _ sink: (@Sendable (CMSampleBuffer) -> Void)?,
        for userID: UInt64
    ) {
        guard userID != connection.userID else {
            preview.set(sink)
            return
        }
        inbound.setVideoSink(sink, for: userID)
    }

    // MARK: The camera

    /// The camera's session, for the self-view.
    ///
    /// Handed out rather than drawn from the frames this session encodes:
    /// `AVCaptureVideoPreviewLayer` is a separate hardware path with no round
    /// trip through an encoder, which is why its self-view has no latency.
    public var cameraSession: CaptureSessionHandle? {
        camera.map { CaptureSessionHandle($0.session) }
    }

    /// Turns the call's camera on or off. Only a call has one.
    ///
    /// The camera is started **before** the encoder, unlike a share's capture:
    /// starting it is also the only way to learn whether there is a device and
    /// a permission, and a stream announced for a camera that then refuses is a
    /// spinner at every other end. What makes that safe is `VideoSendPath`:
    /// nothing leaves before a keyframe has, and turning the path on asks for
    /// one, so frames that reach the encoder first are simply not sent.
    public func setCameraOn(_ on: Bool, preferences video: VideoPreferences) async -> Bool {
        guard on else {
            camera?.stop()
            camera = nil
            await endVideo()
            return true
        }
        guard isCall else { return false }

        let capture = CameraCapture()
        capture.onFrame = { [videoEncode, videoSend] pixels, time in
            // **No actor hop.** Thirty frames a second, each queued behind
            // whatever the control plane is doing, is latency added where the
            // pipeline can least afford it.
            videoEncode.submit(
                VideoEncodePath.Frame(pixels: pixels, time: time),
                forceKeyframe: videoSend.takeKeyframeRequest()
            )
        }
        let size = VideoQualityPolicy.capture
        guard await capture.start(deviceID: video.cameraDeviceID, framerate: size.framerate)
        else { return false }
        guard !isStopped else {
            capture.stop()
            return false
        }
        camera = capture
        isFullQuality = video.isFullQuality
        guard let quality = wantedVideoQuality() else { return false }
        await beginVideo(quality: quality, capture: size)
        return true
    }

    // MARK: A share

    /// The least a stream's sound is sent at: Discord's `setVoiceBitRate`
    /// raises the connection to 128 kbit/s while a stream's sound is shared.
    static let soundshareBitrate = 128_000

    /// The capture a stream session carries.
    private var shareCapture: ScreenShareCapture? {
        if case .stream(_, let capture, _, _) = kind { capture } else { nil }
    }

    /// Routes the running capture to the encoder, last.
    private func startShare(_ capture: ScreenShareCapture, quality: ScreenShareCapture.Quality) async -> Bool {
        // **Opcode 5, once, before the first packet — a share needs it exactly
        // as much as a call does.** The server learns our SSRC from it and
        // discards everything sent by an SSRC it was never told about: 1,970
        // packets of correct video left the first share that connected, with a
        // viewer named the whole time, and not one was forwarded. Soundshare
        // when the sound is shared — Discord's flag for "context audio for
        // video, no speaking indicator" — and nothing when it is not; the
        // frame's existence is what registers the SSRC.
        await gateway?.setSpeaking(quality.capturesAudio ? .soundshare : .none, ssrc: ourSSRC)

        guard let source = capture.source else {
            emit(.state(.failed("The screen capture would not start.")))
            return false
        }
        let fitted = ScreenShareCapture.fit(
            width: source.width, height: source.height,
            into: quality.width, by: quality.height
        )
        shareShape = (quality, fitted.width, fitted.height)
        guard let wanted = wantedVideoQuality() else { return false }
        await beginVideo(
            quality: wanted, capture: (quality.width, quality.height, quality.framerate)
        )
        guard !isStopped else { return false }

        capture.route(ScreenShareCapture.Outputs(
            frame: { [videoEncode, videoSend] pixels, time in
                videoEncode.submit(
                    VideoEncodePath.Frame(pixels: pixels, time: time),
                    forceKeyframe: videoSend.takeKeyframeRequest()
                )
            },
            // **A screen at rest still owes a new viewer a keyframe.** Nothing
            // changes, so nothing is captured and nothing is encoded — and a
            // viewer who joined, or lost a packet, waits until something
            // moves. The held picture is encoded again only when somebody is
            // waiting for it.
            still: { [videoEncode, videoSend] pixels, time in
                guard videoSend.wantsKeyframe else { return }
                videoEncode.submit(
                    VideoEncodePath.Frame(pixels: pixels, time: time),
                    forceKeyframe: videoSend.takeKeyframeRequest()
                )
            },
            preview: { [preview] sample in preview.deliver(sample) },
            audio: { [audioSend] samples, level in audioSend.send(samples, level: level) },
            stopped: { [weak self] reason in
                Task { await self?.captureDidEnd(reason) }
            }
        ))
        return true
    }

    /// Moves a running share to another box, frame rate or sound setting —
    /// Discord's Stream Quality and Share Audio, while live.
    public func updateShare(quality: ScreenShareCapture.Quality) async {
        guard let capture = shareCapture, let previous = shareShape?.box else { return }
        do {
            let shape = try await capture.update(quality: quality)
            await reshape(box: quality, width: shape.width, height: shape.height)
            if quality.capturesAudio != previous.capturesAudio {
                await gateway?.setSpeaking(quality.capturesAudio ? .soundshare : .none, ssrc: ourSSRC)
            }
        } catch {
            VoiceTrace.fault("\(role) share quality refused: \(error)")
        }
    }

    /// Moves a running share to another source — Discord's Change Windows.
    public func changeShare(source: ShareSource) async {
        guard let capture = shareCapture, let box = shareShape?.box else { return }
        do {
            let shape = try await capture.update(source: source)
            await reshape(box: box, width: shape.width, height: shape.height)
        } catch {
            VoiceTrace.fault("\(role) share source refused: \(error)")
        }
    }

    /// The share's new picture: the encoder follows it, and the server is
    /// told the new ceiling as Discord's `setDesktopEncodingOptions` tells it.
    private func reshape(box: ScreenShareCapture.Quality, width: Int, height: Int) async {
        let previous = shareShape
        shareShape = (box, width, height)
        updateVideoQuality()
        guard previous?.box.width != box.width || previous?.box.height != box.height
            || previous?.box.framerate != box.framerate,
            let quality = videoQuality
        else { return }
        await announceVideo(VideoAnnouncement(
            width: box.width, height: box.height,
            framerate: box.framerate, bitrate: quality.bitrateMax
        ))
    }

    private func captureDidEnd(_ reason: String) async {
        await endVideo()
        emit(.captureEnded(reason: reason))
    }

    // MARK: The call's audio

    /// Brings the microphone and the speakers up, and opens the call.
    private func startAudio() async -> Bool {
        guard let audio else { return false }
        // **Asked here, and the answer is the difference between two failures
        // that look identical.** Without the grant the voice processing unit
        // will not initialise and `start()` throws an OSStatus that says
        // nothing about permission. Only the first call in the app's life
        // waits on a person; after that this is a property read.
        guard await VoiceAudioEngine.requestAccess() else {
            VoiceTrace.fault("microphone access refused; the call cannot capture")
            emit(.state(.failed("Wingcord needs microphone access in System Settings.")))
            return false
        }

        audio.inputVolume = preferences.inputVolume
        audio.outputVolume = isDeafened ? 0 : preferences.outputVolume
        // Set once, before the engine starts, and never cleared: the tap and
        // the processor read these from their own threads, and a closure
        // swapped under a running reader is a torn read. They hold nothing
        // that outlives this session.
        audio.onCaptureFrame = { [audioSend] samples, level in
            audioSend.send(samples, level: level)
        }
        audio.onSpeechWhileMuted = { [weak self] in
            self?.emit(.speechWhileMuted)
        }

        do {
            try await audio.start(
                inputUniqueID: preferences.inputDeviceUniqueID,
                outputUniqueID: preferences.outputDeviceUniqueID,
                processing: preferences.processing
            )
        } catch {
            // **The reason, not only the fact.** An OSStatus out of CoreAudio
            // is the same bargain a close code is.
            VoiceTrace.fault("audio engine would not start: \(error)")
            emit(.state(.failed("The audio engine would not start.")))
            return false
        }
        guard !isStopped else {
            await audio.stop()
            return false
        }
        audio.isInputMuted = isMuted && !isRecordingVoiceNote
        audioSend.isMuted = isMuted

        // **Announced before the first packet, and silently fatal to miss.**
        // The server learns our SSRC from this; without it every packet we send
        // is discarded and the connection looks perfect.
        await gateway?.setSpeaking(.microphone, ssrc: ourSSRC)
        startMixPump(audio)
        return true
    }

    // MARK: A voice message, during the call

    /// Lends the call's microphone to a voice message.
    ///
    /// **The same frames the call gets, the same way.** A second engine would fight this
    /// one for the input device and for the voice processor, and a Mac has one of those.
    /// Listening to the running one means the note hears what the call hears.
    ///
    /// **A muted call stays muted.** The processor is told to listen again, because
    /// muted it hands over silence and the note would be empty, but the call's own
    /// send path holds its own mute, and that's what decides what leaves the machine.
    ///
    /// - Returns: false when this session has no microphone to lend.
    public func beginVoiceNote(_ tap: @escaping @Sendable (UnsafePointer<Int16>, Float) -> Void) -> Bool {
        guard let audio else { return false }
        isRecordingVoiceNote = true
        audio.setCaptureTap(tap)
        audio.isInputMuted = false
        return true
    }

    /// Takes it back, and the processor goes back to what the call's mute says.
    public func endVoiceNote() {
        isRecordingVoiceNote = false
        audio?.setCaptureTap(nil)
        audio?.isInputMuted = isMuted
    }

    public func setMuted(_ muted: Bool) {
        isMuted = muted
        audio?.isInputMuted = muted && !isRecordingVoiceNote
        audioSend.isMuted = muted
        if reducer.selfMuted(muted) { updateVideoQuality() }
    }

    public func setDeafened(_ deafened: Bool) {
        isDeafened = deafened
        inbound.isDeafened = deafened
        audio?.outputVolume = deafened ? 0 : preferences.outputVolume
        if deafened { audio?.flushPlayback() }
    }

    // MARK: A watched stream's sound

    /// This session's sound, for a call to play — on a watch, the stream's.
    ///
    /// **A watch has no speakers of its own.** Its sound is mixed into the
    /// call's output, which puts it on the reader's chosen device, at their
    /// volume, and inside the echo canceller's reference — a second engine
    /// playing it would be heard back through everybody's microphone.
    public nonisolated var streamAudio: StreamAudio { StreamAudio(inbound: inbound) }

    /// Plays a watched stream's sound through this call, or stops.
    public nonisolated func setStreamAudio(_ source: StreamAudio?) {
        streamMix.withLock { mix in
            mix.source = source
            mix.duck = 1
        }
    }

    /// The watched stream's own volume, 0…2 — Discord's Stream Volume.
    public nonisolated func setStreamVolume(_ volume: Float) {
        streamMix.withLock { $0.volume = max(0, min(2, volume)) }
    }

    /// Loops a long sound into this call's output, or stops — a stage's
    /// waiting music, which the caller plays, pauses and stops through the
    /// track itself.
    public nonisolated func setLoopedTrack(_ track: LoopedTrack?) {
        loopedTrack.withLock { $0 = track }
    }

    // MARK: What this end asks to receive
    //
    // Each read on the next half-second tick — see `sendSinkWants`.

    /// The spotlighted person, whose picture is asked for whole.
    public nonisolated func setFocusedVideoUser(_ userID: UInt64?) {
        inbound.setFocusedVideoUser(userID)
    }

    /// A stage keeps an offscreen picture two minutes rather than thirty
    /// seconds, and is never sized as a one-to-one call.
    public nonisolated func setIsStage(_ isStage: Bool) {
        inbound.setIsStage(isStage)
    }

    /// The pixels a person's tile draws them at; zero when it goes.
    public nonisolated func setDrawnPixels(_ pixels: Int, for userID: UInt64) {
        inbound.setDrawnPixels(pixels, for: userID)
    }

    /// Off once every window has been hidden for thirty seconds — the app
    /// keeps the clock, as Discord's `WindowVisibilityVideoManager` does.
    public nonisolated func setIncomingVideoEnabled(_ enabled: Bool) {
        inbound.setIncomingVideoEnabled(enabled)
    }

    public func setPushToTalkHeld(_ held: Bool) {
        audioSend.isPushToTalkHeld = held
    }

    /// Discord's Push to Talk (Priority): the microphone open, and opcode 5
    /// saying so with the priority flag, for as long as the key is held.
    public func setPriorityHeld(_ held: Bool) async {
        isPriorityHeld = held
        audioSend.isPriorityHeld = held
        // An open gate changes only its flags; a shut one opens on the next
        // frame and says so itself.
        if isGateOpen { await gateway?.setSpeaking(speakingFlags, ssrc: ourSSRC) }
    }

    private var speakingFlags: SpeakingFlags {
        guard isGateOpen else { return .none }
        return isPriorityHeld ? [.microphone, .priority] : .microphone
    }

    // MARK: Somebody else's priority

    private func notePriority(of userID: UInt64, wants: Bool) {
        guard wants != wantsPriority.contains(userID) else { return }
        if wants {
            wantsPriority.insert(userID)
            emit(.priorityRequested(userID: userID))
        } else {
            wantsPriority.remove(userID)
        }
        inbound.setPrioritySpeakers(wantsPriority.intersection(mayHavePriority))
    }

    /// Whether somebody may speak with priority here — the channel's
    /// `PRIORITY_SPEAKER`, as the app reads it.
    public func setMayHavePriority(_ may: Bool, for userID: UInt64) {
        if may { mayHavePriority.insert(userID) } else { mayHavePriority.remove(userID) }
        inbound.setPrioritySpeakers(wantsPriority.intersection(mayHavePriority))
    }

    // MARK: What this end does not want

    /// Discord's Disable Video and Enable Video, for one person.
    public func setVideoDisabled(_ disabled: Bool, for userID: UInt64) async {
        inbound.setVideoDisabled(disabled, for: userID)
        if disabled { emit(.videoAvailability(userID: userID, hasVideo: false)) }
        await sendSinkWants()
    }

    /// Discord's Mute, for one person and for this reader alone — not
    /// played, and not sent.
    public func setLocallyMuted(_ muted: Bool, for userID: UInt64) async {
        inbound.setLocallyMuted(muted, for: userID)
        await sendSinkWants()
    }

    /// Opcode 15, when what this end wants has changed — on every event that
    /// can change it, and on the half-second tick, which is what pauses a
    /// picture once its thirty seconds offscreen are up.
    ///
    /// **Nothing is said until it differs from `{any: 100}`**, Discord's own
    /// starting point: a client that never sends it is sent everything, which
    /// is what this one wants until then.
    private func sendSinkWants() async {
        guard isCall, isKeyed else { return }
        let wants = inbound.sinkWants(now: .now, isOneToOne: announcedUsers.count == 1)
        guard wants != (sentWants ?? MediaSinkWants(any: VideoQualityPolicy.fullWant)) else { return }
        sentWants = wants
        await gateway?.sendMediaSinkWants(wants)
    }

    public func updatePreferences(_ next: AudioPreferences) {
        guard let audio else { return }
        let previous = preferences
        preferences = next
        audio.inputVolume = next.inputVolume
        audio.outputVolume = isDeafened ? 0 : next.outputVolume
        audioSend.inputMode = next.inputMode
        streamMix.withLock { $0.attenuation = next.streamAttenuation }
        // **A device swap or echo cancellation turned on or off is a new
        // engine** — an IO unit is bound to its device and the processor is
        // chosen when the graph is built. Gain control is a property of the
        // running processor. Both on the main actor, where the engine's
        // lifecycle lives — see `VoiceAudioEngine.start`.
        let rebuilds = next.inputDeviceUniqueID != previous.inputDeviceUniqueID
            || next.outputDeviceUniqueID != previous.outputDeviceUniqueID
            || next.processing.echoCancellation != previous.processing.echoCancellation
        if rebuilds {
            Task { @MainActor [audio] in
                audio.reconfigure(
                    inputUniqueID: next.inputDeviceUniqueID,
                    outputUniqueID: next.outputDeviceUniqueID,
                    processing: next.processing
                )
            }
        } else if next.processing.automaticGainControl != previous.processing.automaticGainControl {
            Task { @MainActor [audio] in
                audio.setAutomaticGainControl(next.processing.automaticGainControl)
            }
        }
    }

    public func setVolume(_ volume: Float, forUser userID: UInt64) {
        inbound.setVolume(volume, for: userID)
    }

    /// Mixes a decoded clip into the same output everybody's voice goes to.
    ///
    /// **A soundboard sound is played by every client for itself.** The server
    /// broadcasts that somebody pressed one, not the audio, so this is a local
    /// playback synchronised by an event — and routing it through the call's
    /// mixer is what puts it on the call's device, at the call's volume, inside
    /// the echo canceller's reference.
    ///
    /// - Parameter isSoundboard: a soundboard sound rather than one of the
    ///   app's own — only those go into a clip's soundboard track.
    public func playLocalClip(_ samples: [Float], volume: Float, isSoundboard: Bool = false) {
        inbound.playLocal(samples, volume: volume)
        if isSoundboard {
            // It starts with the next mixed frame, which is heard about three
            // frames from now.
            clipTap.withLock { $0 }?.noteSoundboard(samples, volume: volume, at: CACurrentMediaTime() + 0.06)
        }
    }

    // MARK: Clips

    /// Where this call's sound goes for clips — each kept speaker, the
    /// microphone, the soundboard, who spoke when — or nil to keep none.
    /// docs/CLIPS-PRESENCE.md, Phase 3.2.
    public nonisolated func setClipTap(_ tap: ClipAudioTap?) {
        clipTap.withLock { $0 = tap }
        inbound.setClipTap(tap)
        let sink: (@Sendable (TimedAudioFrame) -> Void)? = tap.map { tap in
            { @Sendable frame in tap.noteMicrophone(frame) }
        }
        audioSend.setClipSink(sink)
    }

    /// Where a Go Live stream's own picture and sound go for clips —
    /// Discord's `STREAMER` source: "clips are captured at the same quality
    /// as your stream when streaming", off the encoder that is already
    /// running. Only a stream session has one.
    public struct StreamClipSink: Sendable {
        public var video: ReplayVideoRing
        public var sound: TimedAudioBuffer

        public init(video: ReplayVideoRing, sound: TimedAudioBuffer) {
            self.video = video
            self.sound = sound
        }
    }

    public nonisolated func setStreamClipSink(_ sink: StreamClipSink?) {
        streamClip.withLock { $0 = sink }
        let sound: (@Sendable (TimedAudioFrame) -> Void)? = sink.map { sink in
            { @Sendable frame in sink.sound.append(frame) }
        }
        audioSend.setClipSink(sound)
    }

    private func gateDidChange(_ isOpen: Bool) async {
        isGateOpen = isOpen
        emit(.selfSpeaking(isOpen))
        clipTap.withLock { $0 }?.noteSpeaking(
            connection.userID, flags: isOpen ? ClipTimeline.voiceFlag : 0, at: CACurrentMediaTime()
        )
        if reducer.speaking(isOpen, at: .now) { updateVideoQuality() }
        await gateway?.setSpeaking(speakingFlags, ssrc: ourSSRC)
    }

    // MARK: The mix pump

    /// Produces mixed audio on the output device's own demand.
    ///
    /// **Clocked by the playback queue, not by a timer.** A 20 ms timer and a
    /// 48 kHz sound card drift by tens of milliseconds a minute, and the queue
    /// then either starves — clicks — or grows without bound. The pump wakes
    /// each time the device takes a buffer (`PlaybackClock`) and tops the queue
    /// up to its target, which makes the device the clock.
    ///
    /// Off the actor: a frame is a mix, a ring write and perhaps an event, and
    /// none of it is control-plane state.
    private func startMixPump(_ audio: VoiceAudioEngine) {
        let inbound = self.inbound
        mixPump = MixPump(clock: audio.playbackClock) { [weak self] in
            self?.pumpOnce(audio: audio, inbound: inbound) ?? true
        }
    }

    /// - Returns: true when there was nothing to do.
    private nonisolated func pumpOnce(audio: VoiceAudioEngine, inbound: InboundStreams) -> Bool {
        // Three frames — 60 ms — between the mixer and the device. Enough that
        // a scheduling hiccup cannot starve the render callback, little enough
        // that it is not audible as delay.
        guard audio.queuedFrames < Int(OpusFormat.frameSize) * 3 else { return true }
        let now = CACurrentMediaTime()
        // What is mixed now is heard once the frames already queued have
        // played — the stamp a clip keeps it under.
        let heardAt = now + Double(audio.queuedFrames) / Double(OpusFormat.sampleRate)
        // The music's frame is read from its file here, before the call's
        // lock, and only added under it.
        let track = loopedTrack.withLock { $0 }
        let hasMusic = track?.read() ?? false
        let mixed = inbound.mixNextFrame(at: now, heardAt: heardAt) { mix, isSpeech in
            var added = false
            // The stream's gain for this frame, then its sound — outside the
            // lock that decided the gain, inside the call's own.
            if let (source, from, to) = streamMix.withLock({ $0.step(isSpeech: isSpeech) }) {
                added = source.inbound.mixStream(into: &mix, at: now, gainFrom: from, to: to)
            }
            if hasMusic, let track {
                track.add(into: &mix)
                added = true
            }
            return added
        }
        let tap = clipTap.withLock { $0 }
        for change in mixed.speakingChanges {
            emit(.speaking(userID: change.userID, isSpeaking: change.isSpeaking))
            tap?.noteSpeaking(change.userID, flags: change.isSpeaking ? ClipTimeline.voiceFlag : 0, at: heardAt)
        }
        guard !mixed.isSilent else { return true }
        mixed.samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            audio.enqueue(base, frames: Int(OpusFormat.frameSize))
        }
        return false
    }

    // MARK: Watching the microphone

    /// What the two microphone watchdogs know between ticks.
    private struct CaptureWatch {
        var silentTicks = 0
        var lastCaptured = 0
        var hasRestartedThisStall = false
        var hasAbandonedVoiceProcessing = false
        var hasReportedSilence = false
        /// Ticks with the microphone feeding, nothing muted, and the gate still
        /// shut — and the loudest frame seen across them.
        var shutGateTicks = 0
        var shutGatePeak: Float = -100
        var hasReportedShutGate = false
    }

    private var captureWatch = CaptureWatch()

    /// Watches for a call that is connected and capturing silence.
    ///
    /// **The worst shape this stack fails in**: socket up, group established,
    /// every counter healthy, and the far end hears nothing because the tap
    /// stopped. **It watches for movement, not for zero** — a tap that dies
    /// during a call leaves a large count that stops moving, which is what
    /// actually happened: capture froze sixteen seconds into a real call and
    /// stayed frozen for two minutes. Four still ticks is two seconds, against
    /// a buffer due every twenty milliseconds.
    private func checkCaptureIsFeeding(_ audio: VoiceAudioEngine) {
        guard audio.isRunning else { return }
        let captured = audio.capturedFrames
        guard captured == captureWatch.lastCaptured else {
            captureWatch.lastCaptured = captured
            captureWatch.silentTicks = 0
            captureWatch.hasRestartedThisStall = false
            return
        }
        captureWatch.silentTicks += 1
        guard captureWatch.silentTicks >= 4 else { return }
        captureWatch.silentTicks = 0

        guard !captureWatch.hasRestartedThisStall else {
            // **The second recovery is to give up the canceller, not to give
            // up.** The voice processing unit hands over a bus far wider than
            // the device, and a machine where the capture is not where this
            // client reads it has a call nobody can hear. Tried once, and only
            // after a tap restart did not take.
            if !captureWatch.hasAbandonedVoiceProcessing {
                captureWatch.hasAbandonedVoiceProcessing = true
                captureWatch.lastCaptured = 0
                Task { @MainActor [audio] in _ = audio.abandonVoiceProcessing() }
                return
            }
            guard !captureWatch.hasReportedSilence else { return }
            captureWatch.hasReportedSilence = true
            VoiceTrace.fault("microphone still delivering nothing; this call is sending silence")
            return
        }
        captureWatch.hasRestartedThisStall = true
        VoiceTrace.fault(
            "microphone stopped delivering for two seconds; re-installing the capture tap"
        )
        // Re-installing zeroes the engine's count, so the baseline goes with it
        // or the next tick reads the drop as another stall.
        captureWatch.lastCaptured = 0
        Task { @MainActor [audio] in audio.restartCapture() }
    }

    /// Watches for a microphone feeding a gate that never opens.
    ///
    /// **The other way this stack is perfect and inert.** Voice activity
    /// compares an absolute level against the reader's threshold, and without
    /// the voice processor there is no automatic gain in front of it: the tap
    /// feeds, the meter moves, and not one packet is sent. Measured on two real
    /// calls. So the peak across the silent window is reported against the
    /// line it failed to reach — once, after six seconds, so that somebody who
    /// has not spoken yet is not told they are broken.
    private func checkTransmitIsOpening(_ report: AudioSendPath.Report, _ audio: VoiceAudioEngine) {
        guard !captureWatch.hasReportedShutGate,
              report.packets == 0,
              report.offered > 0,
              !report.isMuted,
              let threshold = report.threshold
        else {
            if report.packets > 0 {
                captureWatch.shutGateTicks = 0
                captureWatch.shutGatePeak = -100
            }
            return
        }
        captureWatch.shutGatePeak = max(captureWatch.shutGatePeak, report.peak)
        captureWatch.shutGateTicks += 1
        guard captureWatch.shutGateTicks >= 12 else { return }
        captureWatch.hasReportedShutGate = true
        VoiceTrace.fault(
            "microphone is feeding but voice activity has never opened: peak "
            + String(format: "%.1f", captureWatch.shutGatePeak)
            + " dB against a " + String(format: "%.1f", threshold)
            + " dB line over six seconds"
            + (audio.isVoiceProcessing ? "" : ", and the voice processor is off so there is no automatic gain")
        )
    }

    /// Discord's silent-mic warning: unmuted, and the microphone giving
    /// nothing but digital silence — or nothing at all — for ten reports, five
    /// seconds. **The span is this client's**; Discord decides in its native
    /// module.
    private func checkInputIsHeard(_ report: AudioSendPath.Report) {
        let isSilent = !report.isMuted && (report.offered == 0 || report.peak <= -90)
        silentReports = isSilent ? silentReports + 1 : 0
        let silent = silentReports >= 10
        guard silent != isReportedSilent else { return }
        isReportedSilent = silent
        emit(.inputSilent(silent))
    }

    // MARK: Reporting

    /// What one printed media line covers: four drains, two seconds.
    ///
    /// **Accumulated, because the counters drain every 500 ms and the line is
    /// written every two seconds.** A count read straight from the drain covers
    /// a quarter of the interval everything beside it does, and three windows
    /// out of four are thrown away — §1.5's "large and still" trap in a second
    /// hat.
    private struct Window {
        var ticks = 0
        /// The loudest frame the tap offered, in dBFS.
        var micPeak: Float = -100
        var framesSubmitted = 0
        var framesUnencodable = 0
        var framesRefused = 0
        var framesUnstartable = 0
        var retransmitted = 0
        var feedback = RTCP.Feedback()
        var unreadableFeedback = 0
    }

    private var window = Window()

    private func startStatistics() {
        statisticsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                await self.publish()
                await self.sendSinkWants()
            }
        }
    }

    private func publish() {
        // The far end's reports, for the bitrate and for the line. Its
        // requests of us — a resend, a keyframe — were answered as they
        // arrived; see `init`.
        let returned = inbound.drainFeedback()
        window.feedback.merge(returned.feedback)
        window.unreadableFeedback += returned.unreadable
        // Somebody's picture that arrived mid-stream has nothing to start from
        // until they are asked, and a stream that is still waiting is asked
        // again here.
        if receivesMedia { inbound.askForKeyframes() }

        // **The bitrate follows the far end's reports about our video.** Every
        // half second, inside the band the quality allows.
        if var controller = bitrate {
            if let rate = controller.update(
                fractionLost: returned.feedback.fractionLost[ourSSRC &+ 1],
                estimate: returned.feedback.bitrateEstimate,
                interval: .milliseconds(500)
            ) {
                applyBitrate(rate)
            }
            bitrate = controller
        }
        if camera != nil, reducer.tick(at: .now) { updateVideoQuality() }

        let summary = inbound.statistics()
        let sent = audioSend.drainCounters()
        let video = videoSend.drainCounters()
        let encode = videoEncode.drainCounters()
        window.micPeak = max(window.micPeak, sent.peak)
        window.framesSubmitted += encode.submitted
        window.framesUnencodable += encode.unencodable
        window.framesRefused += video.refused
        window.framesUnstartable += video.unstartable
        window.retransmitted += video.retransmitted

        // **The far end's loss of our audio is what the encoder spends
        // redundancy against** — a call's voice or a stream's sound — not the
        // loss this end sees of everybody else's, which is a different path.
        // With the flag on and the percentage at zero Opus allocates nothing
        // to the redundant copy; a window with no report about us keeps the
        // last answer, and a loss dies away over a few windows rather than at
        // once.
        if let lost = returned.feedback.fractionLost[ourSSRC] {
            audioLoss = max(Int(lost) * 100 / 256, audioLoss * 3 / 4)
            audioSend.updateExpectedLoss(percent: audioLoss)
        }

        if let audio {
            emit(.inputLevel(audio.currentInputLevel))
            checkCaptureIsFeeding(audio)
            checkTransmitIsOpening(sent, audio)
            checkInputIsHeard(sent)

            var statistics = Statistics()
            statistics.packetsSent = sent.packets + video.packets
            statistics.packetsReceived = summary.received
            statistics.lossPercent = summary.lossPercent
            statistics.jitterMilliseconds = summary.jitterMilliseconds
            statistics.outgoingBitrate = (sent.bytes + video.bytes) * 8 * 2
            emit(.statistics(statistics))
        }

        accumulateStats(summary: summary, sent: sent, video: video, framesSubmitted: encode.submitted)

        window.ticks += 1
        if window.ticks % 2 == 0 { sendReports() }
        guard window.ticks % 4 == 0 else { return }
        VoiceTrace.flushDrops()
        VoiceTrace.write(mediaLine(summary: summary, sent: sent, video: video))
        window = Window()
    }

    // MARK: The stats line (docs/BUG-REPORTING.md D20)

    /// What one stats line covers: twenty drains, ten seconds.
    ///
    /// **Its own window, beside the media line's**, because the two are
    /// written at different rates and for different readers: the media line
    /// every two seconds in detailed logging, for whoever is debugging the
    /// stack; this one every ten, always, for whoever reads a report.
    private struct StatsWindow {
        var ticks = 0
        var audioPackets = 0
        var audioBytes = 0
        var videoPackets = 0
        var videoBytes = 0
        var framesSubmitted = 0
        var micPeak: Float = -100
        var worstLoss = 0
        var worstJitter: Double = 0
        var encryptionChanges = 0
    }

    private var stats = StatsWindow()
    /// The inbound counters at the last stats line. They only ever grow.
    private var statsBaseline = (received: 0, datagrams: 0, drawn: 0)
    private static let statsTicks = 20

    /// A call writes to the voice area, a share and a watch to screen share's.
    private var logArea: Log.Area { isCall ? .voice : .share }

    private func accumulateStats(
        summary: InboundStreams.Summary,
        sent: AudioSendPath.Report,
        video: VideoSendPath.Report,
        framesSubmitted: Int
    ) {
        stats.ticks += 1
        stats.audioPackets += sent.packets
        stats.audioBytes += sent.bytes
        stats.videoPackets += video.packets
        stats.videoBytes += video.bytes
        stats.framesSubmitted += framesSubmitted
        stats.micPeak = max(stats.micPeak, sent.peak)
        stats.worstLoss = max(stats.worstLoss, summary.lossPercent)
        stats.worstJitter = max(stats.worstJitter, summary.jitterMilliseconds)
        guard stats.ticks >= Self.statsTicks else { return }
        Log.info(logArea, .raw(statsLine(summary: summary, gate: Self.gateDescription(sent))))
        statsBaseline = (summary.received, summary.datagrams, summary.framesDrawn)
        stats = StatsWindow()
    }

    /// `call 10s | opus out=33kbit/s mic=-21dB gate=open vp=on input=bluetooth
    /// output=bluetooth | in=1488/1490pkt loss=0% jitter=9ms | video out=…`
    ///
    /// Numbers, codecs, states and the KIND of device — no media, no address,
    /// no device name, no person.
    private func statsLine(summary: InboundStreams.Summary, gate: String) -> String {
        let seconds = Double(stats.ticks) / 2
        func kbit(_ bytes: Int) -> Int { Int((Double(bytes) * 8 / seconds / 1_000).rounded()) }
        func rate(_ count: Int) -> String { String(format: "%.1f", Double(count) / seconds) }
        // A counter that went backwards was reset with its session's inbound
        // half; what it holds now is the whole window.
        func delta(_ now: Int, _ then: Int) -> Int { now >= then ? now - then : now }

        var parts = ["\(role) \(Int(seconds))s"]
        if let audio {
            parts.append(
                "opus out=\(kbit(stats.audioBytes))kbit/s mic=\(Int(stats.micPeak.rounded()))dB gate=\(gate)"
                    + " vp=\(audio.isVoiceProcessing ? "on" : "off")"
                    + " input=\(AudioDeviceCatalog.kind(uniqueID: preferences.inputDeviceUniqueID, input: true))"
                    + " output=\(AudioDeviceCatalog.kind(uniqueID: preferences.outputDeviceUniqueID, input: false))"
            )
        }
        if receivesMedia {
            let received = delta(summary.received, statsBaseline.received)
            let datagrams = delta(summary.datagrams, statsBaseline.datagrams)
            var line = "in=\(received)/\(datagrams)pkt loss=\(stats.worstLoss)%"
                + " jitter=\(Int(stats.worstJitter.rounded()))ms"
            let drawn = delta(summary.framesDrawn, statsBaseline.drawn)
            if drawn > 0 { line += " video=\(rate(drawn))fps" }
            parts.append(line)
        }
        if sendsVideo, stats.videoPackets > 0 || stats.framesSubmitted > 0 {
            var line = "video out=\(kbit(stats.videoBytes))kbit/s \(rate(stats.framesSubmitted))fps"
            if let videoQuality {
                line += " q=\(videoQuality.width)x\(videoQuality.height)@\(videoQuality.framerate)"
            }
            if let bitrate { line += " target=\(bitrate.bitrate / 1_000)kbit" }
            parts.append(line)
        }
        var encryption = "encryption=" + lastEncryptionState.logWord
        if stats.encryptionChanges > 0 { encryption += " (changed \(stats.encryptionChanges)x)" }
        parts.append(encryption)
        return parts.joined(separator: " | ")
    }

    /// What our streams had sent at the last report, so a stream that has gone
    /// quiet reports as a receiver rather than as a sender with nothing new.
    private var reportedPackets = (audio: 0, video: 0)

    /// Once a second: a sender report for each of our streams that sent since
    /// the last one, and the receiver blocks for everything we receive. See
    /// `InboundStreams.sendReports`.
    private func sendReports() {
        let now = RTCP.ntpTime()
        var senders: [(ssrc: UInt32, info: RTCP.SenderInfo)] = []
        let audio = audioSend.senderCounts
        if audio.packets > reportedPackets.audio {
            senders.append((ourSSRC, RTCP.SenderInfo(
                ntpTime: now,
                // The clock moves with every captured frame, so where it
                // stands is where the microphone is now, to within a frame.
                rtpTimestamp: audio.clock,
                packets: UInt32(truncatingIfNeeded: audio.packets),
                octets: UInt32(truncatingIfNeeded: audio.octets)
            )))
        }
        let video = videoSend.senderCounts
        if video.packets > reportedPackets.video {
            senders.append((ourSSRC &+ 1, RTCP.SenderInfo(
                ntpTime: now,
                // Video is stamped from the capture's host clock, so this
                // instant on it is exact.
                rtpTimestamp: UInt32(truncatingIfNeeded: Int64((CACurrentMediaTime() * 90_000).rounded())),
                packets: UInt32(truncatingIfNeeded: video.packets),
                octets: UInt32(truncatingIfNeeded: video.octets)
            )))
        }
        reportedPackets = (audio.packets, video.packets)
        inbound.sendReports(senders: senders)
    }

    /// **The line that says whether media is moving at all**, once every two
    /// seconds, one per session.
    ///
    /// Every layer above it can report itself healthy — socket up, group
    /// established, shield filled — while nothing crosses the wire, and until
    /// it existed the two cases were indistinguishable. `in` is raw datagrams
    /// and `read` the ones past the transport cipher. **`out` carries the
    /// reason it is what it is**: on a call, `mic` is the loudest frame the tap
    /// offered against the threshold it had to clear and `gate` is what came of
    /// it, because a zero on its own once sent a whole session into the
    /// encryption underneath it when the gate above had simply never opened.
    private func mediaLine(
        summary: InboundStreams.Summary,
        sent: AudioSendPath.Report,
        video: VideoSendPath.Report
    ) -> String {
        var line = "\(role) media out=\(sent.packets + video.packets) "
            + "in=\(summary.datagrams) read=\(summary.received) loss=\(summary.lossPercent)%"
        if let audio {
            line += " capture=\(audio.capturedFrames) mic=" + String(format: "%.1f", window.micPeak)
                + (sent.threshold.map { "/" + String(format: "%.1f", $0) } ?? "")
                + "dB gate=" + Self.gateDescription(sent)
        }
        line += videoDescription(video)
        line += inbound.drainVideoReport().description
        if let refused = transport?.drainSendFailures(), refused.count > 0 {
            // **The one number that says the datagrams left.** `out` counts
            // calls into the socket; this counts the ones the stack refused.
            line += " UNSENT=\(refused.count)" + (refused.reason.map { " (\($0))" } ?? "")
        }
        line += window.feedback.description
        if window.unreadableFeedback > 0 { line += " rtcp?=\(window.unreadableFeedback)" }
        return line
    }

    /// The four reasons nothing is leaving, in one word each: the reader is
    /// muted, the tap has stopped, the level never cleared the line, or it did.
    private static func gateDescription(_ report: AudioSendPath.Report) -> String {
        if report.isMuted { return "muted" }
        if report.offered == 0 { return "no capture" }
        return report.isGateOpen ? "open" : "shut"
    }

    /// The video half of the line, and nothing at all when there is no video.
    ///
    /// **Four stages, named separately, because they fail separately**: no
    /// frame arriving from the capture, no encoder to take it, a transform
    /// refusing the access unit, or packets leaving perfectly well and the
    /// fault being elsewhere. Folded into one total, the first three are
    /// indistinguishable and the fourth is invisible.
    private func videoDescription(_ send: VideoSendPath.Report) -> String {
        guard send.isActive || window.framesSubmitted > 0 || send.packets > 0 else { return "" }
        var line = " video=\(send.packets) frames=\(window.framesSubmitted)"
        if window.framesUnencodable > 0 { line += " noencoder=\(window.framesUnencodable)" }
        if window.framesRefused > 0 { line += " refused=\(window.framesRefused)" }
        // Frames held back for want of a keyframe to open the stream with. A
        // handful at the start is the invariant working; a count that never
        // stops is an encoder ignoring the request.
        if window.framesUnstartable > 0 { line += " unstartable=\(window.framesUnstartable)" }
        // Packets sent again because a receiver said they never arrived.
        if window.retransmitted > 0 { line += " rtx=\(window.retransmitted)" }
        // What the encoder is running at, so a soft picture can be told apart
        // from a starved one.
        if let videoQuality, let bitrate {
            line += " q=\(videoQuality.width)x\(videoQuality.height)@\(videoQuality.framerate)"
                + " br=\(bitrate.bitrate / 1_000)kbit"
        }
        // The one state where every other number is legitimately zero, and
        // which otherwise reads exactly like a broken capture.
        if !send.isActive { line += " INACTIVE" }
        return line
    }

    private nonisolated func emit(_ event: Event) { continuation.yield(event) }
}

// MARK: - Our own picture, on the way to the self tile

/// A reference type holding the mutex: `Mutex` is non-copyable, so a
/// `@Sendable` closure cannot capture one out of an enclosing type without
/// consuming it.
/// A session's sound, handed to a call to play. Opaque: the call reads it and
/// nothing else can.
public final class StreamAudio: Sendable {
    let inbound: InboundStreams

    init(inbound: InboundStreams) {
        self.inbound = inbound
    }
}

/// A watched stream's sound on its way into the call's mix: its volume, and
/// Discord's Stream Attenuation — "Automatically reduce stream volume when
/// people are talking."
///
/// **The curve is this client's.** Discord's attenuation is a sidechain
/// compressor in its native voice module, which the web bundle only switches
/// and sets a strength on (0–100, 50 by default). Here the strength is how far
/// the stream drops — half, at 50 — and it drops within a few frames of
/// somebody speaking and comes back over half a second, so a stream does not
/// pump between words.
struct StreamMix {
    var source: StreamAudio?
    var volume: Float = 1
    var attenuation: Float?
    /// Where the attenuation has got to, 1 when there is none.
    var duck: Float = 1

    /// This frame's gain ramp, from where the last frame ended.
    mutating func step(isSpeech: Bool) -> (StreamAudio, Float, Float)? {
        guard let source else { return nil }
        let target: Float = isSpeech ? 1 - max(0, min(1, attenuation ?? 0)) : 1
        let start = duck
        duck += (target - duck) * (target < duck ? 0.5 : 0.08)
        return (source, start * volume, duck * volume)
    }
}

private final class PreviewSink: Sendable {
    private let sink = Mutex<(@Sendable (CMSampleBuffer) -> Void)?>(nil)

    func set(_ value: (@Sendable (CMSampleBuffer) -> Void)?) {
        sink.withLock { $0 = value }
    }

    /// Copied out from under the lock before it is called: a sink writes to a
    /// view's `AsyncStream` continuation, and holding a mutex across that puts
    /// ScreenCaptureKit's queue behind whatever the continuation does.
    func deliver(_ sample: CMSampleBuffer) {
        let sink = sink.withLock { $0 }
        sink?(sample)
    }
}

// MARK: - The thread that mixes

/// A thread of its own, woken by the output device, that keeps the playback
/// queue topped up.
///
/// **A thread, not a task**: it blocks on the device's clock, and a blocked
/// task would hold one of the cooperative pool's few threads for the whole of
/// a call.
private final class MixPump: Sendable {
    private let clock: PlaybackClock
    private let isCancelled = Atomic<Bool>(false)

    /// - Parameter produce: one frame's work; true when there was nothing to do.
    init(clock: PlaybackClock, produce: @escaping @Sendable () -> Bool) {
        self.clock = clock
        let thread = Thread { [self] in
            while !isCancelled.load(ordering: .relaxed) {
                // A device that stops asking — or a pump being stopped — still
                // lets the loop look up every 25 ms.
                clock.wait(milliseconds: 25)
                while !isCancelled.load(ordering: .relaxed), !produce() {}
            }
        }
        thread.name = "dev.wingcord.voice.mix"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func cancel() {
        isCancelled.store(true, ordering: .relaxed)
        clock.tick()
    }
}
