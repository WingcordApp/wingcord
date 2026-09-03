import AVFoundation
import CoreMedia
import Foundation
import QuartzCore
import Synchronization

// MARK: - One Go Live stream
//
// **A screen share is not the camera, and this is why it needs its own type.**
// Turning a camera on is a switch on the call's existing media session:
// `self_video` at op 4, the same SSRC, the same socket, the same MLS group. A
// Go Live stream is a *second media session* — its own `STREAM_CREATE` on the
// main gateway, its own RTC server, its own endpoint and token, its own voice
// websocket, its own SSRCs, and its own MLS group keyed on the media session id
// rather than on the channel.
//
// Wingcord pushed the screen down the call's video track for its whole life, so
// Discord never created a stream and the far end was never told there was
// anything to watch. Every byte was correct and addressed to a session that did
// not exist — the same shape as the rid fault, one layer up.
//
// **Everything below the gateway is reused, deliberately.** The handshake, the
// cipher, the RTP writer, the packetiser, the DAVE transform and the H.264
// encoder are the ones the call proved against production Discord; a parallel
// copy of them would be a second thing to keep right. What is not reused is the
// audio engine, the mixer and the jitter buffers: a stream sends and does not
// receive, and there is no microphone anywhere in this file.
//
// The actor is the control plane only, exactly as `VoiceEngine`'s is. The send
// path and the encoder are `Sendable` classes called synchronously from
// ScreenCaptureKit's queue and VideoToolbox's callback thread, neither of which
// may wait on an actor.
public actor StreamSession {

    // MARK: What the app sees

    public enum State: Sendable, Equatable {
        case connecting
        /// Negotiated, keyed, and passing media.
        case live
        case failed(String)
    }

    public enum Event: Sendable {
        case state(State)
        /// How well protected the stream is. **Its own group, so its own
        /// code** — a stream's epoch authenticator is not the call's, and
        /// showing the call's beside a stream would be claiming a guarantee
        /// about the wrong session.
        case encryption(VoiceEngine.EncryptionState)
        /// The capture stopped for a reason that is not us: the window closed,
        /// the display went away, the permission was revoked.
        case ended(reason: String)
    }

    /// Everything the two halves of a Go Live credential add up to.
    public struct Connection: Sendable {
        /// The stream's own voice endpoint, from `STREAM_SERVER_UPDATE`.
        public var endpoint: String
        /// The stream's own token. **Not the call's** — a session that
        /// identifies with the call's token is refused.
        public var token: String
        /// IDENTIFY's `server_id`: the stream's **`rtc_server_id`**.
        ///
        /// **Measured, after two wrong answers.** The DM channel and the
        /// `rtc_channel_id` are each refused `4006 Session is no longer valid.`
        /// about twenty milliseconds after the frame leaves; `rtc_server_id`
        /// gets past IDENTIFY. `STREAM_SERVER_UPDATE` names none of the three —
        /// it sends `guild_id: null` and no channel at all — so nothing on the
        /// wire says this and it had to be found by trying.
        ///
        /// The pair is the same shape the call's is, which is what makes it
        /// memorable: a call identifies with its **server** — the guild — and
        /// keys its group on its **channel**. A stream identifies with
        /// `rtc_server_id` and keys its group on `rtc_channel_id`. The two
        /// fields are named for exactly what they are.
        public var serverID: String
        /// The stream's media session — `rtc_channel_id`, **read rather than
        /// derived**. Its MLS group is keyed on this.
        public var mediaSessionID: UInt64
        public var userID: UInt64
        /// The **main** gateway's session id, shared with the call. Discord
        /// mints no second one for a stream.
        public var sessionID: String

        public init(
            endpoint: String,
            token: String,
            serverID: String,
            mediaSessionID: UInt64,
            userID: UInt64,
            sessionID: String
        ) {
            self.endpoint = endpoint
            self.token = token
            self.serverID = serverID
            self.mediaSessionID = mediaSessionID
            self.userID = userID
            self.sessionID = sessionID
        }
    }

    // MARK: Owned state

    private let connection: Connection
    private let target: ShareableTarget
    private let quality: ScreenShareCapture.Quality

    private var gateway: VoiceGateway?
    private var transport: VoiceTransport?
    private var dave: DAVESession?
    private var lastEncryptionState: VoiceEngine.EncryptionState = .transportOnly
    private var gatewayTask: Task<Void, Never>?
    private var statisticsTask: Task<Void, Never>?

    private let videoSend = VideoSendPath()
    private let videoEncode = VideoEncodePath()
    private var capture: ScreenShareCapture?

    private var ourSSRC: UInt32 = 0
    /// The layer id READY allocated. **Echoed back, never chosen** — see
    /// `VoiceGateway.VoiceReady`. This session's READY is its own; the call's
    /// answer says nothing about it.
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
    /// This session's packet counter. One socket, one sequence — and a stream
    /// sends only video, so the video path owns all of it.
    private let transportSequence = TransportSequence()
    private var isAnnounced = false

    /// The self-view's sink, fed from the capture's own frames.
    private let preview = StreamPreview()

    /// Datagrams the SFU has sent back on this session's socket. See
    /// `openTransport`.
    private let inbound = RTCPListener()

    private var continuation: AsyncStream<Event>.Continuation?
    public private(set) var events: AsyncStream<Event>!

    public init(
        connection: Connection,
        target: ShareableTarget,
        quality: ScreenShareCapture.Quality
    ) {
        self.connection = connection
        self.target = target
        self.quality = quality
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        self.continuation = continuation
    }

    // MARK: Lifecycle

    public func start() {
        emit(.state(.connecting))
        VoiceTrace.write(
            "stream session server_id=\(connection.serverID) "
            + "media=\(connection.mediaSessionID)"
        )
        let gateway = VoiceGateway(
            role: .stream,
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
        gatewayTask?.cancel(); gatewayTask = nil
        statisticsTask?.cancel(); statisticsTask = nil

        // The stream is announced inactive before the socket goes, so the
        // server stops forwarding rather than waiting out a timeout on a
        // sender that vanished.
        if isAnnounced { await announce(isActive: false, width: 0, height: 0) }

        await capture?.stop(); capture = nil
        videoEncode.end()
        videoSend.teardown()
        preview.set(nil)

        transport?.stop(); transport = nil
        await gateway?.stop(); gateway = nil

        continuation?.finish()
        continuation = nil
    }

    /// Asks the encoder for a keyframe.
    ///
    /// **Called when somebody starts watching.** A viewer who presses watch
    /// halfway through a share arrives with no parameter sets and no reference
    /// frame; everything sent until the next keyframe is undecodable to them.
    /// The encoder's own cadence is two seconds, so without this a new viewer
    /// stares at black for up to that long — and this client answers no
    /// retransmission requests, so a keyframe they miss is a keyframe they
    /// never get.
    public func requestKeyframe() {
        videoSend.requestKeyframe()
    }

    /// Where our own share's picture goes.
    ///
    /// **Not an inbound stream, and never one.** §1.5: our own id can never
    /// appear in `InboundStreams`, and a self-view sourced from the wire is a
    /// tile that stays black for the whole call.
    public nonisolated func setPreviewSink(_ sink: (@Sendable (CMSampleBuffer) -> Void)?) {
        preview.set(sink)
    }

    // MARK: The handshake
    //
    // The same four steps the call takes, in the same order, against the same
    // gateway implementation — this session simply has its own of everything.

    private func handle(_ event: VoiceGateway.Event) async {
        switch event {
        case .ready(let ready):
            ourSSRC = ready.ssrc
            videoRID = ready.videoRID
            // **The captured defaults apply here and nowhere else.** Every
            // video packet of a Go Live stream that Discord renders carries
            // `abs-send-time` on id 3 and the transport-wide sequence on id 5 —
            // read off one, twenty packets of it, in `RTPExtension.DefaultID`.
            // That capture is of a *stream* session and says nothing about a
            // call, so a call sends what its own server named and nothing else
            // until somebody reads a working call's packets the same way.
            sendTimeExtensionID = ready.sendTimeExtensionID
                ?? RTPExtension.DefaultID.absoluteSendTime
            transportSequenceExtensionID = ready.transportSequenceExtensionID
                ?? RTPExtension.DefaultID.transportSequence
            await openTransport(ready)

        case .sessionDescription(let cipher, let key, _, let daveVersion):
            let sealer = VoiceSealer(cipher: cipher, secretKey: key)
            guard let transport else { return }
            // The SFU's reports are sealed under the same key its media is.
            inbound.setSealer(sealer)
            await startDAVE(version: daveVersion)
            videoSend.configure(
                sealer: sealer,
                transport: transport,
                // The same triple the call uses and the server assumes: audio
                // on the SSRC it assigned, video on the next, retransmission on
                // the one after.
                ssrc: ourSSRC &+ 1,
                sendTimeExtensionID: sendTimeExtensionID,
                transportSequenceExtensionID: transportSequenceExtensionID,
                transportSequence: transportSequence,
                label: "stream"
            )
            await beginCapture()

        case .clientsConnected(let ids):
            // A stream's group admits whoever the gateway names here, exactly
            // as the call's does — a member it never announced may not be added.
            announcedUsers.formUnion(ids)
            dave?.recognise(users: Set(ids))

        case .clientDisconnected(let userID):
            announcedUsers.remove(userID)
            dave?.forget(user: userID)

        case .dave(let message):
            await handleDAVE(message)

        case .davePrepareTransition(let transitionID, let version):
            if dave?.prepareTransition(id: transitionID, protocolVersion: version) == true {
                await gateway?.sendTransitionReady(transitionID)
            }
            emitEncryptionState()

        case .daveExecuteTransition(let transitionID):
            dave?.executeTransition(id: transitionID)
            emitEncryptionState()

        case .davePrepareEpoch(let epoch, let version):
            if dave?.prepareEpoch(epoch, protocolVersion: version) == true {
                await sendKeyPackage()
            }
            emitEncryptionState()

        case .closed(let code, let reason, _):
            // **4006 here means the `server_id` is wrong**, and it is worth
            // saying so in those words: it is the server finding this media
            // server and no session on it under what we named. It cost two
            // wrong answers to learn which snowflake belongs here — see
            // `Connection.serverID` — and a guild stream, which nothing has
            // tested, is the one place it could still bite.
            if code == 4006 {
                VoiceTrace.fault(
                    "stream identify refused with server_id=\(connection.serverID); "
                    + "that field is the suspect"
                )
            }
            emit(.state(.failed(reason)))

        case .speaking, .videoStreams, .resumed:
            // A stream sends and does not receive. Nothing is bound, nothing is
            // decoded, and there is no mixer for anything to arrive at.
            break
        }
    }

    private func openTransport(_ ready: VoiceGateway.VoiceReady) async {
        let transport = VoiceTransport(host: ready.ip, port: ready.port)
        self.transport = transport
        // **Read, not merely counted.** There is no inbound media here — a
        // stream sends and does not receive — but everything coming back is
        // the far end's own account of what it got, and it is the one fact
        // about this session that cannot be read from our own counters.
        //
        // It separates three failures that are identical from this end: media
        // the server never forwarded, which is silence; media it forwarded and
        // lost, which is a receiver report with a loss fraction; and media that
        // arrived whole and would not decode, which is a picture loss
        // indication asking for a keyframe. See `RTCP`.
        transport.onDatagram = { [inbound] bytes in inbound.accept(bytes) }
        transport.start()

        guard await transport.waitUntilReady() else {
            emit(.state(.failed("Could not open the stream's media socket.")))
            return
        }
        guard let cipher = VoiceCipher.best(from: ready.modes) else {
            emit(.state(.failed("The stream server offered no cipher this client supports.")))
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

    // MARK: End-to-end encryption
    //
    // The same state machine the call runs, over this session's own group.

    private func startDAVE(version: UInt16) async {
        guard version > 0 else {
            VoiceTrace.write("stream dave off; transport encryption only")
            dave = nil
            videoSend.setDAVE(nil)
            emitEncryptionState()
            return
        }
        let session = DAVESession(
            protocolVersion: version,
            userID: connection.userID,
            // **The media session id, not the channel.** This is the whole
            // defect this type exists to fix: a stream that keys on the channel
            // encrypts a second session's media under the first session's group,
            // which every other member rejects as belonging to another group.
            groupKey: .mediaSession(connection.mediaSessionID),
            label: "stream"
        )
        // **Everybody announced so far, not only ourselves.** The roster
        // arrives before this object exists — see `announcedUsers`.
        session.recognise(users: announcedUsers.union([connection.userID]))
        dave = session
        videoSend.setDAVE(session.encryptor)
        emitEncryptionState()
        await sendKeyPackage()
    }

    private func sendKeyPackage() async {
        guard let dave, let gateway else { return }
        do {
            await gateway.sendKeyPackage(try dave.makeKeyPackage())
        } catch {
            VoiceTrace.fault("stream dave key package would not build: \(error)")
        }
    }

    private func handleDAVE(_ message: DAVEInbound) async {
        guard let dave, let gateway else { return }
        switch message {
        case .externalSender(let sender):
            do {
                try dave.setExternalSender(sender)
            } catch {
                VoiceTrace.fault("stream dave external sender refused: \(error)")
            }

        case .proposals(let proposals):
            do {
                guard let outbound = try dave.processProposals(proposals),
                      case .commitWelcome(let commit, let welcome) = outbound
                else { return }
                await gateway.sendCommitWelcome(commit: commit, welcome: welcome)
            } catch {
                VoiceTrace.fault("stream dave proposals refused: \(error)")
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
            await gateway.sendInvalidCommitWelcome(transitionID)
            await rebuildDAVE()
        }
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

    private func emitEncryptionState() {
        let state: VoiceEngine.EncryptionState = switch dave?.status {
        case .encrypted(let code): .endToEnd(verificationCode: code)
        case .establishing: .establishing
        case .transportOnly, nil: .transportOnly
        }
        guard state != lastEncryptionState else { return }
        lastEncryptionState = state
        emit(.encryption(state))

        // **The first frame a receiver can open must be a keyframe, and the
        // group decides when that is.** The encoder's IDR is produced the
        // instant the capture starts, roughly half a second before the MLS
        // group exists — so it is refused, correctly, and dropped. What
        // followed was a run of P-slices under a working key that no decoder
        // could start from, and the next keyframe was the encoder's own
        // two-second cadence away.
        //
        // Measured as `video first frame in=[1:4706]` — one P-slice — against
        // the `in=[7:20 8:4 5:51462]` the same code path produced on a run
        // where the group happened to win the race. A fault that depends on
        // which of two things finishes first is one that will come back, so the
        // keyframe is asked for *when the keys arrive* rather than hoped for.
        //
        // This fires on every epoch too, which is right for the same reason: a
        // new epoch is a new key, and the far end needs a fresh start under it.
        if case .endToEnd = state { videoSend.requestKeyframe() }
    }

    // MARK: The picture

    private func beginCapture() async {
        let capture = ScreenShareCapture()
        capture.onFrame = { [videoEncode, videoSend] pixels, _ in
            videoEncode.submit(
                VideoEncodePath.Frame(pixels: pixels),
                forceKeyframe: videoSend.takeKeyframeRequest()
            )
        }
        capture.onPreviewSample = { [preview] sample in preview.deliver(sample) }
        capture.onStopped = { [weak self] reason in
            Task { await self?.captureEnded(reason) }
        }
        self.capture = capture

        // **Opcode 5, once, before the first packet — and this session needs it
        // exactly as much as the call does.** §1.5 lists it among the three
        // steps that are silently fatal to skip: the server learns our SSRC
        // from it and *discards everything sent by an SSRC it was never told
        // about*.
        //
        // Measured, and it is why the first stream that connected was still
        // black: 1,970 packets of correctly encoded, correctly encrypted,
        // correctly packetised video left this session over thirteen seconds
        // with somebody's id in `viewer_ids` the whole time, and not one of
        // them was forwarded. The call sends this in `startMedia`; a second
        // media session that skipped it looked healthy from every counter at
        // both ends.
        //
        // **`.none`, because this session transmits no audio.** The flag says
        // what is being transmitted; it is the frame's *existence* that
        // registers the SSRC, and claiming a microphone here would be claiming
        // one that does not exist. Video is announced separately, by opcode 12
        // below.
        await gateway?.setSpeaking(.none, ssrc: ourSSRC)

        let fitted = ScreenShareCapture.fit(
            width: target.width, height: target.height,
            into: quality.width, by: quality.height
        )
        // A screen is text at rest and motion in bursts, so it earns a higher
        // ceiling than a face does — a shared editor at a camera's bitrate is
        // unreadable, which is the only thing anybody shares a screen for.
        // **The quality's ceiling, not the frame's size.** `max_resolution` is
        // what this stream will not exceed, and a client whose stream renders
        // announces its preset: `{"width":1280,"type":"fixed","height":720}`
        // while sending a scaled desktop that is no such shape. Announcing the
        // fitted size instead describes a stream at 1104×720 — a number no
        // Discord preset contains — and the encoder's own SPS carries the real
        // dimensions regardless.
        await announce(isActive: true, width: quality.width, height: quality.height)

        // The rid printed is the one **announced**, not the one READY gave —
        // they differ whenever READY names none, and printing the input to a
        // decision instead of its output is how a fix reads as a no-op.
        VoiceTrace.write(
            "stream video \(fitted.width)x\(fitted.height)@\(quality.framerate) "
            + "max=\(quality.width)x\(quality.height) \(Self.bitrate / 1_000)kbit "
            + "ssrc=\(ourSSRC &+ 1) rid=\(videoRID.isEmpty ? VoiceGateway.baseSimulcastLayer : videoRID) "
            + "ext=[\(sendTimeExtensionID.map(String.init) ?? "-"):abs-send-time "
            + "\(transportSequenceExtensionID.map(String.init) ?? "-"):transport-cc]"
        )
        let encoder = H264Encoder(configuration: .init(
            width: fitted.width,
            height: fitted.height,
            framerate: quality.framerate,
            bitrate: Self.bitrate
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

        // **The capture starts LAST, and that ordering is the whole of a fault
        // that presented as a working stream nobody could see.**
        //
        // Started before the encoder and the send path, ScreenCaptureKit
        // delivers immediately: the first frame is submitted while there is
        // still no encoder, the keyframe request that came with it is spent,
        // and the keyframe the encoder does eventually produce arrives at a
        // send path whose `isActive` is still false — so it is dropped. The
        // first access unit that actually leaves is then a **P-slice with no
        // parameter sets**, which no decoder on earth can start from.
        //
        // Measured, as the one line that separates this from every other
        // theory: `video first frame in=[1:770]` for the share against
        // `in=[7:20 8:4 5:62643]` for the camera — one P-slice where there
        // should be an SPS, a PPS and an IDR. Every counter above it read
        // healthy and 3,961 packets went out to somebody watching a black
        // rectangle.
        //
        // Nothing downstream can race the capture if the capture is the last
        // thing switched on.
        do {
            try await capture.start(target: target, quality: quality)
        } catch {
            videoSend.isActive = false
            videoEncode.end()
            self.capture = nil
            emit(.state(.failed("The screen capture would not start.")))
            return
        }

        startStatistics()
        emit(.state(.live))
    }

    static let bitrate = 3_500_000

    /// Opcode 12, and **silently fatal to skip** — video on an SSRC the server
    /// has not been told about is forwarded to nobody, which looks exactly like
    /// a share that is not running. Awaited before a frame can leave, because
    /// announcing from a detached task makes that a race.
    private func announce(isActive: Bool, width: Int, height: Int) async {
        isAnnounced = isActive
        await gateway?.announceStreams(
            audioSSRC: ourSSRC,
            videoSSRC: ourSSRC &+ 1,
            rtxSSRC: ourSSRC &+ 2,
            rid: videoRID,
            isActive: isActive,
            width: width,
            height: height,
            framerate: isActive ? quality.framerate : 0,
            bitrate: isActive ? Self.bitrate : 0
        )
    }

    private func captureEnded(_ reason: String) async {
        capture = nil
        videoSend.isActive = false
        videoEncode.end()
        emit(.ended(reason: reason))
    }

    // MARK: Whether anything is actually leaving

    private var ticks = 0
    private var framesSubmitted = 0
    private var framesRefused = 0
    private var framesUnstartable = 0
    /// The far end's reports, gathered across the four drains that go into one
    /// printed line — §"large and still": a counter read straight from the
    /// drain covers a quarter of the interval every other number on the line
    /// does, and three windows out of four are thrown away.
    private var feedback = RTCP.Feedback()
    private var unreadable = 0

    /// The stream's own media line.
    ///
    /// **A separate session needs a separate line.** The call's says nothing
    /// about this one: they have different sockets, different SSRCs and
    /// different keys, and a share that sends nothing while the call is healthy
    /// is exactly the case that has to be legible.
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
        let send = videoSend.drainCounters()
        let encode = videoEncode.drainCounters()
        framesSubmitted += encode.submitted
        framesRefused += send.refused
        framesUnstartable += send.unstartable

        // **Answered on every drain, not on every printed line.** A viewer that
        // cannot decode is asking for one keyframe, and half a second is the
        // longest this may take; the accumulation below is for the trace, which
        // is a slower instrument on purpose.
        let report = inbound.drain()
        feedback.merge(report.feedback)
        unreadable += report.unreadable
        if report.feedback.wantsKeyframe { videoSend.requestKeyframe() }

        ticks += 1
        guard ticks % 4 == 0 else { return }
        var line = "stream out=\(send.packets) frames=\(framesSubmitted)"
        line += " in=\(inbound.datagrams)"
        if framesRefused > 0 { line += " refused=\(framesRefused)" }
        if framesUnstartable > 0 { line += " unstartable=\(framesUnstartable)" }
        if !send.isActive { line += " INACTIVE" }
        // **The one number that says the datagrams left.** `out=` counts calls
        // into the socket; this counts the ones the stack refused.
        let refusedDatagrams = transport?.drainSendFailures()
        if let refusedDatagrams, refusedDatagrams.count > 0 {
            line += " UNSENT=\(refusedDatagrams.count)"
            if let reason = refusedDatagrams.reason { line += " (\(reason))" }
        }
        line += feedback.description
        if unreadable > 0 { line += " rtcp?=\(unreadable)" }
        VoiceTrace.write(line)
        framesSubmitted = 0
        framesRefused = 0
        framesUnstartable = 0
        feedback = RTCP.Feedback()
        unreadable = 0
    }

    private func emit(_ event: Event) { continuation?.yield(event) }
}

// MARK: - The share's own picture, on the way to the self tile

/// A reference type holding the mutex, for the reason `SelfPreview` is one:
/// `Mutex` is non-copyable, so a `@Sendable` closure cannot capture one out of
/// an enclosing type without consuming it.
private final class StreamPreview: Sendable {
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
