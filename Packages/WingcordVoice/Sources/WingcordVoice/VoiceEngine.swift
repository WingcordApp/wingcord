import AVFoundation
import CoreMedia
import Foundation

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
        case screenShareStopped(String)
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
        public var incomingVideoBitrate = 0

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
    private var screenShare: ScreenShareCapture?
    private let videoEncode = VideoEncodePath()

    private var ourSSRC: UInt32 = 0
    private var sendTimeExtensionID: UInt8?
    private var isMuted = false
    private var isDeafened = false
    public private(set) var isCameraOn = false
    public private(set) var isScreenSharing = false

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
            endpoint: connection.endpoint,
            serverID: connection.serverID,
            userID: String(connection.userID),
            sessionID: connection.sessionID,
            token: connection.token
        )
        self.gateway = gateway

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
        await screenShare?.stop(); screenShare = nil

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
            sendTimeExtensionID = ready.headerExtensions[
                "http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time"
            ]
            await openTransport(
                ready,
                audioLevelID: ready.headerExtensions[
                    "urn:ietf:params:rtp-hdrext:ssrc-audio-level"
                ]
            )

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
                sendTimeExtensionID: sendTimeExtensionID
            )
            videoSend.configure(
                sealer: sealer,
                transport: transport,
                // Discord's own convention, and the server assumes it: audio on
                // the SSRC it assigned, video on the next, retransmission on
                // the one after. A client that picks its own numbers has its
                // video forwarded to nobody.
                ssrc: ourSSRC &+ 1,
                sendTimeExtensionID: sendTimeExtensionID
            )
            await startMedia()

        case .speaking(let userID, let ssrc, let flags):
            inbound.bind(ssrc: ssrc, to: userID)
            emit(.speaking(userID: userID, isSpeaking: flags != 0))

        case .videoStreams(let userID, let audioSSRC, let videoSSRC):
            if audioSSRC != 0 { inbound.bind(ssrc: audioSSRC, to: userID) }
            if videoSSRC != 0 {
                inbound.bindVideo(ssrc: videoSSRC, to: userID)
                emit(.videoAvailability(userID: userID, hasVideo: true))
            } else {
                inbound.unbindVideo(for: userID)
                emit(.videoAvailability(userID: userID, hasVideo: false))
            }

        case .clientsConnected(let ids):
            // This is also DAVE's admission list. A member the gateway never
            // announced here may not be added to the MLS group, which is what
            // stops the delivery service seating a listener of its own.
            dave?.recognise(users: Set(ids))
            emit(.participantsChanged(ids))

        case .clientDisconnected(let userID):
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

        case .closed(let reason, _):
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
            // The MLS group is keyed by the **channel**, not the guild, and not
            // the identify payload's `server_id`.
            channelID: connection.channelID
        )
        session.recognise(users: [connection.userID])
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

    /// When the group was last torn down and rebuilt, for pacing.
    private var lastRebuild: ContinuousClock.Instant?

    private func rebuildDAVE() async {
        guard let dave else { return }

        // **Paced, because the gateway answers a key package with a welcome
        // immediately.** When the media session contains somebody it has not
        // announced yet, every welcome is refusable — and the protocol's own
        // recovery (opcode 31, reset, fresh key package) then spins against a
        // gateway that answers instantly. Measured against a peer that was
        // reconnecting: **sixty-seven rebuilds in three seconds**, each one a
        // fresh signature key, a fresh key package and a 400-byte frame, every
        // one of them thrown away by the next.
        //
        // Half a second between attempts costs nothing when recovery works the
        // first time, and turns the storm into a retry that still heals the
        // moment `clients_connect` names the missing member.
        let now = ContinuousClock.now
        if let last = lastRebuild, now - last < .milliseconds(500) { return }
        lastRebuild = now

        dave.reset(protocolVersion: dave.protocolVersion)
        await sendKeyPackage()
        syncTransforms()
        emitEncryptionState()
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
    /// nothing, and whether the tap has already been put back once.
    private var mediaTicks = 0
    private var silentCaptureTicks = 0
    private var hasRestartedCapture = false
    private var hasReportedSilentCapture = false

    /// Watches for a call that is connected and capturing silence.
    ///
    /// **This is the worst shape this stack fails in.** The socket is up, the
    /// group is established, the shield says end-to-end encrypted, every
    /// counter reads healthy — and the far end hears nothing, because the
    /// capture tap installed against a format the hardware then changed. It is
    /// the audio twin of the op 5 Speaking rule: a connection that is perfect
    /// and inert.
    ///
    /// Two seconds is not a slow start. At 48 kHz the first buffer is due in
    /// twenty milliseconds, so zero frames after four ticks means the tap is
    /// not delivering and never will be. It is put back once — that is the
    /// whole recovery — and if that does not take, the trace says so plainly
    /// rather than leaving the reader to work it out from the silence.
    private func checkCaptureIsFeeding() {
        guard audio.isRunning else { return }
        guard audio.capturedFrames == 0 else {
            silentCaptureTicks = 0
            return
        }
        silentCaptureTicks += 1
        guard silentCaptureTicks >= 4 else { return }
        // Reset the count either way: re-installing the tap zeroes the frame
        // counter, so without this the follow-up check below could never come
        // round again and a failed recovery would go unsaid.
        silentCaptureTicks = 0

        if !hasRestartedCapture {
            hasRestartedCapture = true
            VoiceTrace.fault(
                "microphone delivered nothing for two seconds; re-installing the capture tap"
            )
            Task { @MainActor [audio] in audio.restartCapture() }
        } else if !hasReportedSilentCapture {
            hasReportedSilentCapture = true
            VoiceTrace.fault("microphone still delivering nothing; this call is sending silence")
        }
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

    public nonisolated func setVideoSink(
        _ sink: (@Sendable (CMSampleBuffer) -> Void)?,
        for userID: UInt64
    ) {
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
        guard !isScreenSharing else { return false }

        let capture = CameraCapture()
        capture.onFrame = { [weak self] pixels, _ in
            self?.encodeVideoFrame(pixels)
        }
        guard await capture.start(deviceID: video.cameraDeviceID, framerate: video.framerate)
        else { return false }
        camera = capture
        isCameraOn = true
        beginVideo(width: video.width, height: video.height, framerate: video.framerate,
                   bitrate: video.bitrate)
        return true
    }

    public func startScreenShare(
        target: ShareableTarget,
        quality: ScreenShareCapture.Quality
    ) async -> Bool {
        guard !isCameraOn else { return false }
        let capture = ScreenShareCapture()
        capture.onFrame = { [weak self] pixels, _ in
            self?.encodeVideoFrame(pixels)
        }
        capture.onStopped = { [weak self] reason in
            Task { await self?.screenShareEnded(reason) }
        }
        do {
            try await capture.start(target: target, quality: quality)
        } catch {
            return false
        }
        screenShare = capture
        isScreenSharing = true
        let fitted = ScreenShareCapture.fit(
            width: target.width, height: target.height,
            into: quality.width, by: quality.height
        )
        // A screen is text at rest and motion in bursts, so it earns a higher
        // ceiling than a face does — a shared editor at a camera's bitrate is
        // unreadable, which is the only thing anybody shares a screen for.
        beginVideo(
            width: fitted.width, height: fitted.height,
            framerate: quality.framerate, bitrate: 3_500_000
        )
        return true
    }

    public func stopScreenShare() async {
        await screenShare?.stop()
        screenShare = nil
        isScreenSharing = false
        await endVideo()
    }

    private func screenShareEnded(_ reason: String) async {
        screenShare = nil
        isScreenSharing = false
        await endVideo()
        emit(.screenShareStopped(reason))
    }

    private func beginVideo(width: Int, height: Int, framerate: Int, bitrate: Int) {
        let encoder = H264Encoder(configuration: .init(
            width: width, height: height, framerate: framerate, bitrate: bitrate
        ))
        encoder.onEncodedFrame = { [videoSend] units, sets, _ in
            videoSend.send(
                units: units,
                parameterSets: sets,
                presentationTime: CACurrentMediaTime()
            )
        }
        try? encoder.start()
        videoEncode.begin(encoder)
        videoSend.isActive = true

        Task { [gateway, ourSSRC] in
            await gateway?.announceStreams(
                audioSSRC: ourSSRC,
                videoSSRC: ourSSRC &+ 1,
                rtxSSRC: ourSSRC &+ 2,
                isActive: true,
                width: width,
                height: height,
                framerate: framerate,
                bitrate: bitrate
            )
        }
    }

    private func endVideo() async {
        isCameraOn = false
        videoSend.isActive = false
        videoEncode.end()
        await gateway?.announceStreams(
            audioSSRC: ourSSRC,
            videoSSRC: ourSSRC &+ 1,
            rtxSSRC: ourSSRC &+ 2,
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

    private func publish() {
        emit(.inputLevel(audio.currentInputLevel))
        VoiceTrace.flushDrops()
        checkCaptureIsFeeding()

        let summary = inbound.statistics()
        let audioCounters = audioSend.drainCounters()
        let videoCounters = videoSend.drainCounters()
        // The far end's loss is what our encoder spends redundancy against.
        // Feeding it back is what makes in-band FEC do anything at all — with
        // the flag on and the percentage at zero, Opus allocates nothing to the
        // redundant copy and the feature is inert.
        audioSend.updateExpectedLoss(percent: summary.lossPercent)

        var statistics = Statistics()
        statistics.packetsSent = audioCounters.packets + videoCounters.packets
        statistics.packetsReceived = summary.received

        // **The line that says whether media is moving at all.** Every layer
        // above this can report itself healthy — socket up, group established,
        // shield filled — while nothing crosses the wire in either direction,
        // and until this existed the two cases were indistinguishable from the
        // outside. `in` is raw datagrams; `read` is the ones that got past the
        // transport cipher. Once every two seconds, and only in a call.
        mediaTicks += 1
        if mediaTicks % 4 == 0 {
            VoiceTrace.write(
                "media out=\(statistics.packetsSent) in=\(summary.datagrams) "
                + "read=\(summary.received) loss=\(summary.lossPercent)% "
                + "capture=\(audio.capturedFrames)"
            )
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
