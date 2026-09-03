import AVFoundation
import CoreMedia
import Foundation
import Synchronization

// MARK: - The voice session
//
// One object per connected channel. It owns the gateway, the socket, the key,
// the codecs and both media engines, and it is the only thing in the app that
// knows any of them exist.
//
// **The app never touches a codec, a packet or a key.** It sets five switches —
// muted, deafened, camera, screen, push-to-talk — reads who is talking, and
// hands over a display layer per person. Everything else is here and off the
// main actor, because every piece of it runs on a thread with a deadline: the
// capture tap, the render callback, VideoToolbox's encoder queue and
// Network.framework's receive queue are four different threads and none of them
// may wait on a fifth.
//
// The actor is the **control plane only**. The two send paths and the inbound
// streams are `Sendable` classes with their own locks, called synchronously from
// whichever real-time thread produced the media — an `await` between a
// microphone and a socket is jitter this client would be adding to a path that
// already has some.

public actor VoiceEngine {

    // MARK: What the app sees

    public enum State: Sendable, Equatable {
        case idle
        case connecting
        /// Negotiated, keyed, and passing media.
        case connected
        case failed(String)
    }

    public enum Event: Sendable {
        case state(State)
        case speaking(userID: UInt64, isSpeaking: Bool)
        /// Our own gate opened or closed.
        case selfSpeaking(Bool)
        case videoAvailability(userID: UInt64, hasVideo: Bool)
        case participantsChanged([UInt64])
        /// Our own microphone level, 0…1, once a frame's worth of meter.
        case inputLevel(Float)
        case statistics(Statistics)
        /// The voice processor heard speech while the input was muted.
        case speechWhileMuted
        /// How well protected the call is, and the code to read out to check it.
        case encryption(EncryptionState)
    }

    /// What a call can promise about who else can hear it.
    ///
    /// **The distinction is not cosmetic.** Transport-only means Discord's
    /// servers can decode the media; end-to-end means they cannot. A client that
    /// showed the same thing for both would be claiming a guarantee it is not
    /// making, which is the failure mode the whole protocol exists to avoid.
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
        /// Open whenever the level clears the threshold, with a hangover so a
        /// pause between words does not clip the tail off every sentence.
        case voiceActivity(threshold: Float)
        /// Open only while the app says so.
        case pushToTalk
        /// Always open. For a mic test, and for nothing else.
        case open
    }

    // MARK: Configuration

    public struct Connection: Sendable {
        public var endpoint: String
        public var token: String
        /// The guild id, or the DM channel id for a private call.
        public var serverID: String
        /// The channel being joined.
        ///
        /// **This, not `serverID`, is the MLS group id.** In a guild the two
        /// differ, and a client that keyed its group on the guild would produce
        /// commits every other member rejects as belonging to another group.
        public var channelID: UInt64
        public var userID: UInt64
        public var sessionID: String
        /// The channel's own ceiling. A packet over it is dropped by the server
        /// rather than transcoded.
        public var audioBitrate: Int

        public init(
            endpoint: String,
            token: String,
            serverID: String,
            channelID: UInt64,
            userID: UInt64,
            sessionID: String,
            audioBitrate: Int = 64_000
        ) {
            self.endpoint = endpoint
            self.token = token
            self.serverID = serverID
            self.channelID = channelID
            self.userID = userID
            self.sessionID = sessionID
            self.audioBitrate = audioBitrate
        }
    }

    public struct AudioPreferences: Sendable, Equatable {
        public var inputDeviceUniqueID: String?
        public var outputDeviceUniqueID: String?
        public var inputVolume: Float = 1
        public var outputVolume: Float = 1
        public var inputMode: InputMode = .voiceActivity(threshold: 0.03)

        public init() {}
    }

    public struct VideoPreferences: Sendable, Equatable {
        public var cameraDeviceID: String?
        public var width = 1_280
        public var height = 720
        public var framerate = 30
        public var bitrate = 2_000_000

        public init() {}
    }

    // MARK: Owned state

    private let connection: Connection
    private var preferences: AudioPreferences
    private var videoPreferences = VideoPreferences()

    private var gateway: VoiceGateway?
    private var transport: VoiceTransport?
    /// The call's end-to-end encryption, or `nil` on a session the server said
    /// needs none. Held on the actor: every MLS transition is control-plane
    /// work, and only the `Sendable` transforms it produces reach the media
    /// threads.
    private var dave: DAVESession?
    private var lastEncryptionState: EncryptionState = .transportOnly
    private var gatewayTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var statisticsTask: Task<Void, Never>?

    private let audio = VoiceAudioEngine()
    private let audioSend = AudioSendPath()
    private let videoSend = VideoSendPath()
    private let inbound = InboundStreams()

    private var camera: CameraCapture?
    private let videoEncode = VideoEncodePath()


    private var ourSSRC: UInt32 = 0
    /// The simulcast layer id READY allocated for our video. Echoed back in
    /// opcode 12 rather than chosen — see `VoiceGateway.VoiceReady`.
    private var videoRID = ""
    /// Everybody the gateway has announced on this session, whether or not
    /// there was a DAVE session to tell at the time.
    ///
    /// **A fact the server states before its consumer exists must be
    /// remembered, not dropped.** The roster arrives on opcodes 11 and 18, and
    /// both land *before* opcode 4 — which is what creates the DAVE session, so
    /// `dave?.recognise` was a call on `nil` every time. What saved it was a
    /// second announcement arriving later by luck; a call where the far end was
    /// announced once, by opcode 18 alone, refused every welcome the gateway
    /// sent with "user … is not in this call", never established a group, and
    /// transmitted nothing in either direction for its whole life.
    ///
    /// `StreamViewSession` never had the fault because it seeds its group from
    /// the two people it knows are on it, which is why watching a share worked
    /// while nothing this client sent ever left.
    private var announcedUsers: Set<UInt64> = []
    private var sendTimeExtensionID: UInt8?
    private var transportSequenceExtensionID: UInt8?
    /// The call's packet counter, **shared by the microphone and the camera**.
    /// The number is transport-wide; one per stream would read to the far end
    /// as a path losing every other packet.
    private let transportSequence = TransportSequence()
    private var isMuted = false
    private var isDeafened = false
    public private(set) var isCameraOn = false

    private var continuation: AsyncStream<Event>.Continuation?
    public private(set) var events: AsyncStream<Event>!

    public init(connection: Connection, preferences: AudioPreferences) {
        self.connection = connection
        self.preferences = preferences
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        self.continuation = continuation
    }

    /// The camera's session, for the self-view.
    ///
    /// Handed out rather than drawn from the frames this engine encodes:
    /// `AVCaptureVideoPreviewLayer` is a separate hardware path with no round
    /// trip through an encoder, which is why every reference client's self-view
    /// has no latency and a hand-rolled one always does.
    public var cameraSession: CaptureSessionHandle? {
        camera.map { CaptureSessionHandle($0.session) }
    }

    // MARK: Lifecycle

    public func connect() {
        emit(.state(.connecting))
        let gateway = VoiceGateway(
            role: .call,
            endpoint: connection.endpoint,
            serverID: connection.serverID,
            userID: String(connection.userID),
            sessionID: connection.sessionID,
            token: connection.token
        )
        self.gateway = gateway

        inbound.onFirstVideoFrame.withLock { slot in
            slot = { [weak self] userID in
                Task { await self?.emit(.videoAvailability(userID: userID, hasVideo: true)) }
            }
        }

        audioSend.inputMode = preferences.inputMode
        audioSend.onGateChanged.withLock { slot in
            slot = { [weak self] isOpen in
                Task { await self?.gateDidChange(isOpen) }
            }
        }

        gatewayTask = Task { [weak self] in
            await gateway.connect()
            guard let stream = await gateway.events else { return }
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    public func disconnect() async {
        gatewayTask?.cancel(); gatewayTask = nil
        pumpTask?.cancel(); pumpTask = nil
        statisticsTask?.cancel(); statisticsTask = nil

        audio.onCaptureFrame = nil
        audio.onSpeechWhileMuted = nil
        await audio.stop()
        audioSend.teardown()
        videoSend.teardown()

        videoEncode.end()
        camera?.stop(); camera = nil

        transport?.stop(); transport = nil
        await gateway?.stop(); gateway = nil

        inbound.reset()
        emit(.state(.idle))
        continuation?.finish()
        continuation = nil
    }

    // MARK: The handshake

    private func handle(_ event: VoiceGateway.Event) async {
        switch event {
        case .ready(let ready):
            ourSSRC = ready.ssrc
            videoRID = ready.videoRID
            sendTimeExtensionID = ready.sendTimeExtensionID
            transportSequenceExtensionID = ready.transportSequenceExtensionID
            await openTransport(ready, audioLevelID: ready.audioLevelExtensionID)

        case .sessionDescription(let cipher, let key, _, let daveVersion):
            let sealer = VoiceSealer(cipher: cipher, secretKey: key)
            guard let transport else { return }
            // **DAVE first, and the key package goes out immediately.** The
            // session description is the only place the server names the
            // protocol version, and the gateway will not start the group until
            // it has a key package from every pending member.
            await startDAVE(version: daveVersion)
            inbound.setSealer(sealer)
            audioSend.configure(
                sealer: sealer,
                transport: transport,
                ssrc: ourSSRC,
                bitrate: connection.audioBitrate,
                audioLevelExtensionID: pendingAudioLevelID,
                sendTimeExtensionID: sendTimeExtensionID,
                transportSequenceExtensionID: transportSequenceExtensionID,
                transportSequence: transportSequence
            )
            videoSend.configure(
                sealer: sealer,
                transport: transport,
                // Discord's own convention, and the server assumes it: audio on
                // the SSRC it assigned, video on the next, retransmission on
                // the one after. A client that picks its own numbers has its
                // video forwarded to nobody.
                ssrc: ourSSRC &+ 1,
                sendTimeExtensionID: sendTimeExtensionID,
                transportSequenceExtensionID: transportSequenceExtensionID,
                transportSequence: transportSequence,
                label: "call"
            )
            await startMedia()

        case .speaking(let userID, let ssrc, let flags):
            inbound.bind(ssrc: ssrc, to: userID)
            emit(.speaking(userID: userID, isSpeaking: flags != 0))

        case .videoStreams(let userID, let audioSSRC, let videoSSRC):
            if audioSSRC != 0 { inbound.bind(ssrc: audioSSRC, to: userID) }
            if videoSSRC != 0 {
                // **Bound, not announced.** The SSRC has to be routed in case
                // packets do arrive; the tile is told only once one has — see
                // `InboundStreams.onFirstVideoFrame`. Announcing here paints a
                // black rectangle over the avatar of anybody the gateway says
                // has video, including a Go Live share on a media session this
                // client never joined.
                inbound.bindVideo(ssrc: videoSSRC, to: userID)
            } else {
                inbound.unbindVideo(for: userID)
                emit(.videoAvailability(userID: userID, hasVideo: false))
            }

        case .clientsConnected(let ids):
            // This is also DAVE's admission list. A member the gateway never
            // announced here may not be added to the MLS group, which is what
            // stops the delivery service seating a listener of its own.
            announcedUsers.formUnion(ids)
            dave?.recognise(users: Set(ids))
            emit(.participantsChanged(Array(announcedUsers)))

        case .clientDisconnected(let userID):
            announcedUsers.remove(userID)
            inbound.remove(userID: userID)
            dave?.forget(user: userID)
            emit(.speaking(userID: userID, isSpeaking: false))
            emit(.videoAvailability(userID: userID, hasVideo: false))

        case .dave(let message):
            await handleDAVE(message)

        case .davePrepareTransition(let transitionID, let version):
            if dave?.prepareTransition(id: transitionID, protocolVersion: version) == true {
                await gateway?.sendTransitionReady(transitionID)
            }
            emitEncryptionState()

        case .daveExecuteTransition(let transitionID):
            dave?.executeTransition(id: transitionID)
            syncTransforms()
            emitEncryptionState()

        case .davePrepareEpoch(let epoch, let version):
            if dave?.prepareEpoch(epoch, protocolVersion: version) == true {
                await sendKeyPackage()
            }
            syncTransforms()
            emitEncryptionState()

        case .resumed:
            emit(.state(.connected))

        case .closed(_, let reason, _):
            emit(.state(.failed(reason)))
        }
    }

    // MARK: End-to-end encryption
    //
    // The engine owns the `DAVESession` and does every transition on the actor;
    // the transforms it hands to the media paths are `Sendable` and run on the
    // real-time threads that produce and receive frames.

    private func startDAVE(version: UInt16) async {
        guard version > 0 else {
            VoiceTrace.write("dave off for this session; transport encryption only")
            // Only a stage channel reaches here today. Nothing is protected
            // beyond the transport, and the app is told so rather than left to
            // imply it.
            dave = nil
            inbound.setDAVE(decryptors: [:], active: false)
            audioSend.setDAVE(nil)
            videoSend.setDAVE(nil)
            emitEncryptionState()
            return
        }
        let session = DAVESession(
            protocolVersion: version,
            userID: connection.userID,
            // A call's group is keyed by the **channel**, not the guild, and
            // not the identify payload's `server_id`. A Go Live stream is a
            // separate media session and keys on its own — see `StreamSession`.
            groupKey: .channel(connection.channelID),
            label: "call"
        )
        // **Everybody announced so far, not only ourselves.** The roster
        // arrives before this object exists — see `announcedUsers`.
        session.recognise(users: announcedUsers.union([connection.userID]))
        dave = session
        audioSend.setDAVE(session.encryptor)
        videoSend.setDAVE(session.encryptor)
        syncTransforms()
        emitEncryptionState()
        await sendKeyPackage()
    }

    private func sendKeyPackage() async {
        guard let dave, let gateway else { return }
        do {
            await gateway.sendKeyPackage(try dave.makeKeyPackage())
        } catch {
            VoiceTrace.fault("dave key package would not build: \(error)")
        }
    }

    private func handleDAVE(_ message: DAVEInbound) async {
        guard let dave, let gateway else { return }
        switch message {
        case .externalSender(let sender):
            do {
                try dave.setExternalSender(sender)
            } catch {
                VoiceTrace.fault("dave external sender refused: \(error)")
            }

        case .proposals(let proposals):
            do {
                guard let outbound = try dave.processProposals(proposals),
                      case .commitWelcome(let commit, let welcome) = outbound
                else { return }
                await gateway.sendCommitWelcome(commit: commit, welcome: welcome)
            } catch {
                // A proposal this client will not accept is not a reason to
                // tear the call down: the gateway may still land a commit we
                // can follow, and if it does not, the transition times out.
                VoiceTrace.fault("dave proposals refused: \(error)")
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
            // §"Recovery from Invalid Commit or Welcome": tell the gateway, reset
            // the local state, and offer a fresh key package to be re-added with.
            await gateway.sendInvalidCommitWelcome(transitionID)
            await rebuildDAVE()
        }
        syncTransforms()
        emitEncryptionState()
    }

    /// When a recovery may run. See `RecoveryPacer` for what both ways of
    /// getting this wrong looked like.
    private var pacer = RecoveryPacer()

    private func rebuildDAVE() async {
        guard let dave else { return }
        // **Paced, and the pacing DEFERS rather than drops.** The gateway
        // answers a key package with a welcome immediately, so when the media
        // session contains somebody it has not announced yet, every welcome is
        // refusable and the protocol's own recovery — opcode 31, reset, fresh
        // key package — spins against a server that answers instantly. Measured
        // against a reconnecting peer: sixty-seven rebuilds in three seconds.
        //
        // **Dropping the request inside the window is what made that unsafe.**
        // Two refusals a hundred and fifty milliseconds apart, and the second
        // one is discarded: no key package leaves, the gateway has nothing to
        // commit us with, and the session never recovers for the rest of the
        // call — measured as a call that transmitted nothing in either
        // direction, for its whole life, with `out=0` and a healthy socket. A
        // rate limiter in front of a recovery path must delay the last attempt,
        // never throw it away.
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
        syncTransforms()
        emitEncryptionState()
    }


    /// The rebuild the pacing window held back — **if it is still wanted.**
    ///
    /// **A deferred rebuild is a decision taken half a second ago, and half a
    /// second is long enough for the group to establish.** Acting on it then
    /// tears down a working group and throws away the send ratchet with it:
    /// measured as `dave sending under epoch 2` followed a hundred and
    /// eighty-five milliseconds later by `dave reset to v1`, and every frame
    /// after that refused as `ours unkeyed` for the rest of the call.
    ///
    /// So the precondition is checked again here, not only where the delay
    /// began. A brake that holds a request back has to ask whether the request
    /// still makes sense when it lets go.
    private func rebuildAfterPacing() async {
        pacer.waitElapsed()
        guard let dave, dave.status == .establishing else { return }
        await rebuildDAVE()
    }

    /// Pushes the current per-sender transforms to the receive path.
    ///
    /// Called after every DAVE state change, because a member added or removed
    /// changes who this client can decrypt — and a receive path holding a stale
    /// map either drops media it could play or plays media from an epoch the
    /// group has left.
    private func syncTransforms() {
        guard let dave else {
            inbound.setDAVE(decryptors: [:], active: false)
            return
        }
        inbound.setDAVE(
            decryptors: dave.receiveTransforms, active: dave.protocolVersion > 0
        )
    }

    private func emitEncryptionState() {
        let state: EncryptionState = switch dave?.status {
        case .encrypted(let code): .endToEnd(verificationCode: code)
        case .establishing: .establishing
        case .transportOnly, nil: .transportOnly
        }
        guard state != lastEncryptionState else { return }
        lastEncryptionState = state
        emit(.encryption(state))

        // A camera turned on before the group exists has the identical fault
        // `StreamSession` was found with: its keyframe is refused while there
        // is no ratchet, and the P-slices after it are undecodable to everybody
        // until the encoder's own cadence comes round. It is only rarer here,
        // because a camera is usually switched on well after the call is keyed.
        if case .endToEnd = state { videoSend.requestKeyframe() }
    }

    private var pendingAudioLevelID: UInt8?

    private func openTransport(_ ready: VoiceGateway.VoiceReady, audioLevelID: UInt8?) async {
        pendingAudioLevelID = audioLevelID
        let transport = VoiceTransport(host: ready.ip, port: ready.port)
        self.transport = transport
        transport.onDatagram = { [inbound] bytes in
            inbound.accept(bytes, arrival: CACurrentMediaTime())
        }
        transport.start()

        guard await transport.waitUntilReady() else {
            emit(.state(.failed("Could not open the media socket.")))
            return
        }
        guard let cipher = VoiceCipher.best(from: ready.modes) else {
            emit(.state(.failed("The voice server offered no cipher this client supports.")))
            return
        }
        do {
            let mapped = try await transport.discoverAddress(ssrc: ready.ssrc)
            await gateway?.selectProtocol(
                address: mapped.address, port: mapped.port, cipher: cipher
            )
        } catch {
            emit(.state(.failed("Could not discover this machine's address.")))
        }
    }

    /// Everything that may only start once there is a key.
    private func startMedia() async {
        // **Asked here, and the answer is the difference between two failures
        // that look identical.** Without the grant the voice processing unit
        // will not initialise and `start()` throws an OSStatus that says
        // nothing about permission — so a reader is told the audio engine
        // broke when what actually happened is that nobody ever asked them.
        //
        // Only the first call in the app's life waits on a person; after that
        // this is a property read.
        guard await VoiceAudioEngine.requestAccess() else {
            VoiceTrace.fault("microphone access refused; the call cannot capture")
            emit(.state(.failed("Wingcord needs microphone access in System Settings.")))
            return
        }

        audio.inputVolume = preferences.inputVolume
        audio.outputVolume = preferences.outputVolume
        audio.onCaptureFrame = { [audioSend] samples, level in
            audioSend.send(samples, level: level)
        }
        audio.onSpeechWhileMuted = { [weak self] in
            Task { await self?.emit(.speechWhileMuted) }
        }

        do {
            try await audio.start(
                inputUniqueID: preferences.inputDeviceUniqueID,
                outputUniqueID: preferences.outputDeviceUniqueID
            )
        } catch {
            // **The reason, not only the fact.** `INVARIANTS.md` §1.5 says a
            // close code is never logged without its sentence; an OSStatus out
            // of CoreAudio is the same bargain, and without it this is one
            // sentence that fits every audio fault there is.
            VoiceTrace.fault("audio engine would not start: \(error)")
            emit(.state(.failed("The audio engine would not start.")))
            return
        }
        audio.isInputMuted = isMuted
        audioSend.isMuted = isMuted

        // **Announced before the first packet, and silently fatal to miss.**
        // The server learns our SSRC from this; without it every packet we send
        // is discarded and the connection looks perfect.
        Task { [gateway, ourSSRC] in
            await gateway?.setSpeaking(.microphone, ssrc: ourSSRC)
        }

        startMixPump()
        startStatistics()
        emit(.state(.connected))
    }

    /// How many 500 ms ticks have passed with the microphone delivering
    /// nothing, and what it had delivered when we last looked.
    private var mediaTicks = 0
    /// Video counters gathered across the four drains that make up one printed
    /// media line. See `publish`.
    private var videoFramesSubmitted = 0
    private var videoFramesUnencodable = 0
    private var videoFramesRefused = 0
    /// The far end's reports, gathered over the same four drains. See `RTCP`.
    private var feedback = RTCP.Feedback()
    private var unreadableFeedback = 0
    private var silentCaptureTicks = 0
    private var lastCapturedFrames = 0
    private var hasRestartedThisStall = false
    private var hasAbandonedVoiceProcessing = false
    private var hasReportedSilentCapture = false
    /// Ticks with the microphone feeding, nothing muted, and the gate still
    /// shut — and the loudest frame seen across them.
    private var shutGateTicks = 0
    private var shutGatePeak: Float = 0
    private var hasReportedShutGate = false

    /// Watches for a call that is connected and capturing silence.
    ///
    /// **This is the worst shape this stack fails in.** The socket is up, the
    /// group is established, the shield says end-to-end encrypted, every
    /// counter reads healthy — and the far end hears nothing, because the
    /// capture tap installed against a format the hardware then changed. It is
    /// the audio twin of the op 5 Speaking rule: a connection that is perfect
    /// and inert.
    ///
    /// **It watches for movement, not for zero.** The first version asked
    /// whether the count was zero, which only ever caught a tap that never
    /// started. A tap that dies *during* a call leaves a large count that stops
    /// moving, and that is the case this actually has: measured on a real call,
    /// capture froze sixteen seconds in and stayed frozen for the remaining two
    /// minutes with nothing said.
    ///
    /// Two seconds is not a slow start. At 48 kHz the next buffer is due in
    /// twenty milliseconds, so four still ticks means the tap has stopped. The
    /// tap is put back once per stall — repeatedly is a storm — and if that
    /// does not take, the trace says so plainly rather than leaving the reader
    /// to work it out from the silence.
    private func checkCaptureIsFeeding() {
        guard audio.isRunning else { return }
        let captured = audio.capturedFrames
        guard captured == lastCapturedFrames else {
            lastCapturedFrames = captured
            silentCaptureTicks = 0
            hasRestartedThisStall = false
            return
        }
        silentCaptureTicks += 1
        guard silentCaptureTicks >= 4 else { return }
        silentCaptureTicks = 0

        guard !hasRestartedThisStall else {
            // **The second recovery is to give up the canceller, not to give
            // up.** The voice processing unit hands over a bus far wider than
            // the device and there is no guarantee the capture is where this
            // client reads it; a machine where that is true has a call nobody
            // can hear, and a call without echo cancellation beats one nobody
            // can hear. Tried once, and only after a tap restart did not take.
            if !hasAbandonedVoiceProcessing {
                hasAbandonedVoiceProcessing = true
                Task { @MainActor [audio] in _ = audio.abandonVoiceProcessing() }
                lastCapturedFrames = 0
                return
            }
            guard !hasReportedSilentCapture else { return }
            hasReportedSilentCapture = true
            VoiceTrace.fault("microphone still delivering nothing; this call is sending silence")
            return
        }
        hasRestartedThisStall = true
        VoiceTrace.fault(
            "microphone stopped delivering for two seconds; re-installing the capture tap"
        )
        // Re-installing zeroes the engine's frame count, so the baseline goes
        // with it or the next tick reads the drop as another stall.
        lastCapturedFrames = 0
        Task { @MainActor [audio] in audio.restartCapture() }
    }

    /// Watches for a microphone that is feeding a gate which never opens.
    ///
    /// **The other way this stack is perfect and inert, and the one that
    /// actually happened.** Voice activity compares an absolute level against a
    /// threshold the reader set. When the system voice processor is refused
    /// there is no automatic gain in front of it, the same threshold now means
    /// something else, and the gate simply never opens: the tap feeds, the
    /// meter moves, every counter is healthy, and not one packet is ever sent.
    /// Measured on two real calls — `out=0` for their whole length, with no
    /// drop counted anywhere, because the frame was refused before anything
    /// downstream ever saw it.
    ///
    /// So the peak is carried across the whole silent window and reported
    /// against the threshold it failed to reach. One line, once, naming both
    /// numbers — which is the difference between "nothing is being sent" and
    /// "you are two thirds of the way to the line you drew".
    private func checkTransmitIsOpening(_ report: AudioSendPath.Report) {
        guard !hasReportedShutGate,
              report.packets == 0,
              report.offered > 0,
              !report.isMuted,
              let threshold = report.threshold
        else {
            if report.packets > 0 { shutGateTicks = 0; shutGatePeak = 0 }
            return
        }
        shutGatePeak = max(shutGatePeak, report.peak)
        shutGateTicks += 1
        // Twelve ticks is six seconds. Long enough that somebody who joined and
        // has not spoken yet is not told they are broken.
        guard shutGateTicks >= 12 else { return }
        hasReportedShutGate = true
        VoiceTrace.fault(
            "microphone is feeding but voice activity has never opened: peak "
            + String(format: "%.3f", shutGatePeak)
            + " against a " + String(format: "%.3f", threshold)
            + " threshold over six seconds"
            + (audio.isVoiceProcessing ? "" : ", and the voice processor is off so there is no automatic gain")
        )
    }

    // MARK: Switches

    public func setMuted(_ muted: Bool) {
        isMuted = muted
        audio.isInputMuted = muted
        audioSend.isMuted = muted
    }

    public func setDeafened(_ deafened: Bool) {
        isDeafened = deafened
        inbound.isDeafened = deafened
        audio.outputVolume = deafened ? 0 : preferences.outputVolume
        if deafened { audio.flushPlayback() }
    }

    public func setPushToTalkHeld(_ held: Bool) {
        audioSend.isPushToTalkHeld = held
    }

    public func updatePreferences(_ next: AudioPreferences) {
        let devicesMoved = next.inputDeviceUniqueID != preferences.inputDeviceUniqueID
            || next.outputDeviceUniqueID != preferences.outputDeviceUniqueID
        preferences = next
        audio.inputVolume = next.inputVolume
        audio.outputVolume = isDeafened ? 0 : next.outputVolume
        audioSend.inputMode = next.inputMode
        if devicesMoved {
            // The engine's lifecycle belongs to the main actor — see
            // `VoiceAudioEngine.start`. A device swap is a restart, so it goes
            // the same way.
            let input = next.inputDeviceUniqueID
            let output = next.outputDeviceUniqueID
            Task { @MainActor [audio] in
                audio.reconfigure(inputUniqueID: input, outputUniqueID: output)
            }
        }
    }

    public func setVolume(_ volume: Float, forUser userID: UInt64) {
        inbound.setVolume(volume, for: userID)
    }

    /// Where one person's picture goes.
    ///
    /// **Our own id is not an inbound stream, and asking for one is how the
    /// share went black.** Every other participant's video arrives over the
    /// socket and is keyed by user id in `InboundStreams`; ours never does, so
    /// a sink registered for our own id there waits for a frame that cannot
    /// exist. The camera hides this because its tile takes the capture
    /// session's preview layer and never reaches here at all — a screen share
    /// has no such layer, falls through to the same view every remote tile
    /// uses, and draws black for the whole call while the send path is
    /// perfectly healthy.
    ///
    /// So our own id is **refused here** rather than registered: the camera's
    /// tile takes the capture session's preview layer, and a screen share's
    /// comes from `StreamSession.setPreviewSink` — a different media session
    /// entirely. Neither is ever a stream on this socket.
    public nonisolated func setVideoSink(
        _ sink: (@Sendable (CMSampleBuffer) -> Void)?,
        for userID: UInt64
    ) {
        guard userID != connection.userID else { return }
        inbound.setVideoSink(sink, for: userID)
    }

    private func gateDidChange(_ isOpen: Bool) {
        emit(.selfSpeaking(isOpen))
        Task { [gateway, ourSSRC] in
            await gateway?.setSpeaking(isOpen ? .microphone : .none, ssrc: ourSSRC)
        }
    }

    // MARK: Video

    public func setCameraOn(_ on: Bool, preferences video: VideoPreferences) async -> Bool {
        videoPreferences = video
        guard on else {
            camera?.stop()
            camera = nil
            await endVideo()
            return true
        }

        let capture = CameraCapture()
        capture.onFrame = { [weak self] pixels, _ in
            self?.encodeVideoFrame(pixels)
        }
        guard await capture.start(deviceID: video.cameraDeviceID, framerate: video.framerate)
        else { return false }
        camera = capture
        isCameraOn = true
        await beginVideo(width: video.width, height: video.height, framerate: video.framerate,
                         bitrate: video.bitrate)
        return true
    }

    private func beginVideo(
        width: Int, height: Int, framerate: Int, bitrate: Int
    ) async {
        // **Announced before a single frame can leave, and awaited.** §1.5: op
        // 12 is silently fatal to skip, and sending before it is the same fault
        // with a stopwatch on it — video on an SSRC the server has not been
        // told about is forwarded to nobody, which looks exactly like a camera
        // that is off. Turning the send path on first and announcing from a
        // detached task left that a race, won by whichever the scheduler
        // preferred.
        await gateway?.announceStreams(
            audioSSRC: ourSSRC,
            videoSSRC: ourSSRC &+ 1,
            rtxSSRC: ourSSRC &+ 2,
            rid: videoRID,
            isActive: true,
            width: width,
            height: height,
            framerate: framerate,
            bitrate: bitrate
        )

        // **What the far end has to be able to decode**, said out loud. The
        // profile is constrained baseline and its level is chosen from the
        // frame size: a receiver that negotiated a lower level than the one in
        // our SPS refuses to build a decoder at all, which it reports as a
        // camera that would not start rather than as a resolution it cannot
        // take.
        VoiceTrace.write(
            "video \(width)x\(height)@\(framerate) \(bitrate / 1_000)kbit "
            + "ssrc=\(ourSSRC &+ 1)"
        )
        let encoder = H264Encoder(configuration: .init(
            width: width, height: height, framerate: framerate, bitrate: bitrate
        ))
        encoder.onEncodedFrame = { [videoSend] units, sets, isKeyframe in
            videoSend.send(
                units: units,
                parameterSets: sets,
                isKeyframe: isKeyframe,
                presentationTime: CACurrentMediaTime()
            )
        }
        try? encoder.start()
        videoEncode.begin(encoder)
        videoSend.isActive = true
    }

    private func endVideo() async {
        isCameraOn = false
        videoSend.isActive = false
        videoEncode.end()
        await gateway?.announceStreams(
            audioSSRC: ourSSRC,
            videoSSRC: ourSSRC &+ 1,
            rtxSSRC: ourSSRC &+ 2,
            rid: videoRID,
            isActive: false,
            width: 0, height: 0, framerate: 0, bitrate: 0
        )
    }

    /// Runs on the capture's own queue, synchronously.
    ///
    /// **No actor hop.** Thirty frames a second, each one queued behind
    /// whatever the control plane happens to be doing, is latency added at the
    /// one place in the pipeline that can least afford it — and a frame that
    /// arrives at the encoder late is a frame the whole path is late by.
    private nonisolated func encodeVideoFrame(_ pixels: CVPixelBuffer) {
        // A keyframe on demand, and the first frame of every stream is one:
        // anybody already in the channel has no parameter sets until they see
        // one, and waiting for the encoder's own two-second cadence is two
        // seconds of black rectangle.
        videoEncode.submit(
            VideoEncodePath.Frame(pixels: pixels),
            forceKeyframe: videoSend.takeKeyframeRequest()
        )
    }

    // MARK: The mix pump

    /// Produces mixed audio on the output device's own demand.
    ///
    /// **Clocked by the playback queue, not by a timer.** A 20 ms timer and a
    /// 48 kHz sound card do not agree for long: they drift by tens of
    /// milliseconds a minute, and the queue then either starves — clicks — or
    /// grows without bound — latency. Producing whenever the queue falls below
    /// its target makes the device the clock, which is the only clock that
    /// matters.
    private func startMixPump() {
        pumpTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let idle = await self.pumpOnce()
                // Four milliseconds is well under one frame and well over a
                // scheduling quantum, so the queue is topped up long before the
                // render callback can reach the end of it.
                if idle { try? await Task.sleep(for: .milliseconds(4)) }
            }
        }
    }

    /// - Returns: true when there was nothing to do.
    private func pumpOnce() -> Bool {
        // Three frames — 60 ms — between the mixer and the device. Enough that
        // a scheduling hiccup cannot starve the render callback, little enough
        // that it is not audible as delay.
        guard audio.queuedFrames < Int(OpusFormat.frameSize) * 3 else { return true }
        let mixed = inbound.mixNextFrame()
        for change in mixed.speakingChanges {
            emit(.speaking(userID: change.userID, isSpeaking: change.isSpeaking))
        }
        guard !mixed.isSilent else { return true }
        mixed.samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            audio.enqueue(base, frames: Int(OpusFormat.frameSize))
        }
        return false
    }

    // MARK: Reporting

    private func startStatistics() {
        statisticsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                await self.publish()
            }
        }
    }

    /// The four reasons nothing is leaving, in one word each: the reader is
    /// muted, the tap has stopped, the level never cleared the line, or it did.
    private static func gateDescription(_ report: AudioSendPath.Report) -> String {
        if report.isMuted { return "muted" }
        if report.offered == 0 { return "no capture" }
        return report.isGateOpen ? "open" : "shut"
    }

    /// The video half of the media line, and nothing at all when there is no
    /// video.
    ///
    /// **Four stages, named separately, because they fail separately.** A share
    /// or a camera that shows the far end black is one of: no frame arriving
    /// from the capture, no encoder to take it, a transform refusing the access
    /// unit, or packets leaving perfectly well and the fault being elsewhere.
    /// Folding them into the one `out=` total — which is what this line did —
    /// means the first three are indistinguishable and the fourth is invisible.
    ///
    /// Silent when nothing is sending video, so an audio-only call's line stays
    /// the length it has always been.
    private static func videoDescription(
        submitted: Int,
        unencodable: Int,
        refused: Int,
        send: VideoSendPath.Report
    ) -> String {
        guard send.isActive || submitted > 0 || send.packets > 0 else { return "" }
        var line = " video=\(send.packets)"
        line += " frames=\(submitted)"
        if unencodable > 0 { line += " noencoder=\(unencodable)" }
        if refused > 0 { line += " refused=\(refused)" }
        // Frames held back for want of a keyframe to open the stream with. A
        // handful at the start is the invariant working; a count that never
        // stops is an encoder ignoring the request.
        if send.unstartable > 0 { line += " unstartable=\(send.unstartable)" }
        // The one state where every other number is legitimately zero, and
        // which otherwise reads exactly like a broken capture.
        if !send.isActive { line += " INACTIVE" }
        return line
    }

    /// Datagrams the stack would not take, when there were any. See
    /// `VoiceTransport.drainSendFailures`.
    private static func unsentDescription(_ refused: (count: Int, reason: String?)?) -> String {
        guard let refused, refused.count > 0 else { return "" }
        return " UNSENT=\(refused.count)" + (refused.reason.map { " (\($0))" } ?? "")
    }

    private func publish() {
        emit(.inputLevel(audio.currentInputLevel))
        VoiceTrace.flushDrops()
        checkCaptureIsFeeding()

        let summary = inbound.statistics()
        let audioCounters = audioSend.drainCounters()
        let videoCounters = videoSend.drainCounters()
        checkTransmitIsOpening(audioCounters)
        // The far end's loss is what our encoder spends redundancy against.
        // Feeding it back is what makes in-band FEC do anything at all — with
        // the flag on and the percentage at zero, Opus allocates nothing to the
        // redundant copy and the feature is inert.
        audioSend.updateExpectedLoss(percent: summary.lossPercent)

        // **Accumulated, because this drains four times per printed line.**
        // `publish` runs every 500 ms and the media line is written every
        // fourth call, so a counter read straight from the drain reports the
        // last 500 ms while every other number on the line covers two seconds.
        // That is the same "large and still" trap §1.5 warns about wearing a
        // different hat: three windows out of four are thrown away, and a
        // capture that delivered frames in one of them still prints zero.
        let encodeCounters = videoEncode.drainCounters()
        videoFramesSubmitted += encodeCounters.submitted
        videoFramesUnencodable += encodeCounters.unencodable
        videoFramesRefused += videoCounters.refused

        // **Answered on every drain, not on every printed line.** A viewer who
        // cannot decode our camera is asking for one keyframe, and this is the
        // whole of the answer: half a second at worst, against the encoder's
        // own two-second cadence.
        let report = inbound.drainFeedback()
        feedback.merge(report.feedback)
        unreadableFeedback += report.unreadable
        if report.feedback.wantsKeyframe { videoSend.requestKeyframe() }
        // And the other direction: somebody else's camera that arrived
        // mid-picture has nothing to start from until they are asked.
        if let transport { inbound.askForKeyframes(on: transport, from: ourSSRC) }

        var statistics = Statistics()
        statistics.packetsSent = audioCounters.packets + videoCounters.packets
        statistics.packetsReceived = summary.received

        // **The line that says whether media is moving at all.** Every layer
        // above this can report itself healthy — socket up, group established,
        // shield filled — while nothing crosses the wire in either direction,
        // and until this existed the two cases were indistinguishable from the
        // outside. `in` is raw datagrams; `read` is the ones that got past the
        // transport cipher. Once every two seconds, and only in a call.
        //
        // **`out` carries the reason it is what it is.** A zero on its own sent
        // one whole session looking at the encryption underneath it, when the
        // gate above had simply never opened. `mic` is the loudest frame the
        // tap offered against the threshold it had to clear, and `gate` is what
        // came of it.
        mediaTicks += 1
        if mediaTicks % 4 == 0 {
            VoiceTrace.write(
                "media out=\(statistics.packetsSent) in=\(summary.datagrams) "
                + "read=\(summary.received) loss=\(summary.lossPercent)% "
                + "capture=\(audio.capturedFrames) "
                + "mic=" + String(format: "%.3f", audioCounters.peak)
                + (audioCounters.threshold.map { "/" + String(format: "%.3f", $0) } ?? "")
                + " gate=" + Self.gateDescription(audioCounters)
                + Self.videoDescription(
                    submitted: videoFramesSubmitted,
                    unencodable: videoFramesUnencodable,
                    refused: videoFramesRefused,
                    send: videoCounters
                )
                + inbound.drainVideoReport().description
                + Self.unsentDescription(transport?.drainSendFailures())
                + feedback.description
                + (unreadableFeedback > 0 ? " rtcp?=\(unreadableFeedback)" : "")
            )
            feedback = RTCP.Feedback()
            unreadableFeedback = 0
            videoFramesSubmitted = 0
            videoFramesUnencodable = 0
            videoFramesRefused = 0
        }
        statistics.lossPercent = summary.lossPercent
        statistics.jitterMilliseconds = summary.jitterMilliseconds
        statistics.outgoingBitrate = (audioCounters.bytes + videoCounters.bytes) * 8 * 2
        emit(.statistics(statistics))
    }

    // MARK: Playing a sound locally

    /// Mixes a decoded clip into the same output everybody's voice goes to.
    ///
    /// **A soundboard sound is played by every client for itself.** The server
    /// broadcasts the fact that somebody pressed one; it does not carry the
    /// audio. So this is a local playback that happens to be synchronised by an
    /// event, and routing it through the call's own mixer is what makes it come
    /// out of the call's output device at the call's volume.
    public func playLocalClip(_ samples: [Float], volume: Float) {
        inbound.playLocal(samples, volume: volume)
    }

    private func emit(_ event: Event) { continuation?.yield(event) }
}
