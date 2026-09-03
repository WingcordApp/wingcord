import CoreMedia
import Foundation
import QuartzCore

// MARK: - Watching somebody else's Go Live stream
//
// **The mirror of `StreamSession`, and a separate media session for the same
// reason.** Somebody else's share is not their camera: it is not on the call's
// socket, not on the call's SSRCs, and not under the call's MLS group. Knowing
// that they are live carries no address — `self_stream` on a voice state is a
// boolean — so watching means asking for a session of our own with opcode 20
// and connecting to whatever it answers with.
//
// What this does NOT do is send. There is no capture, no encoder and no send
// path in this file; `VideoSendPath` is never built. The one thing it produces
// is decoded frames for a display layer, which is the same hand-off the call
// makes for everybody else's camera.
public actor StreamViewSession {

    public enum State: Sendable, Equatable {
        case connecting
        /// Negotiated and keyed. A picture may still be a keyframe away.
        case watching
        case failed(String)
    }

    public enum Event: Sendable {
        case state(State)
        /// A frame has actually arrived and been decoded. **Announced is not
        /// arriving** — §1.5 — so this, never the connection, is what a tile
        /// may switch to video on.
        case pictureArrived
    }

    public struct Connection: Sendable {
        public var endpoint: String
        public var token: String
        /// The stream's `rtc_server_id`, which is what IDENTIFY names — the
        /// same field, found the same way, as a stream we publish ourselves.
        public var serverID: String
        /// The stream's `rtc_channel_id`: the media session, and the id its MLS
        /// group is keyed on. **We join that group rather than create it**, so
        /// this has to match what the owner used exactly.
        public var mediaSessionID: UInt64
        public var userID: UInt64
        public var sessionID: String
        /// Whose stream this is. Frames are delivered under this id, so the
        /// tile already drawing them needs no second identity.
        public var ownerID: UInt64

        public init(
            endpoint: String,
            token: String,
            serverID: String,
            mediaSessionID: UInt64,
            userID: UInt64,
            sessionID: String,
            ownerID: UInt64
        ) {
            self.endpoint = endpoint
            self.token = token
            self.serverID = serverID
            self.mediaSessionID = mediaSessionID
            self.userID = userID
            self.sessionID = sessionID
            self.ownerID = ownerID
        }
    }

    // MARK: Owned state

    private let connection: Connection
    private var gateway: VoiceGateway?
    private var transport: VoiceTransport?
    private var sealer: VoiceSealer?
    private var dave: DAVESession?
    private var gatewayTask: Task<Void, Never>?
    private var statisticsTask: Task<Void, Never>?

    private let inbound = InboundStreams()
    /// Everybody the gateway has announced, whether or not there was a DAVE
    /// session to tell at the time. See `VoiceEngine.announcedUsers`.
    private var announcedUsers: Set<UInt64> = []
    /// Our own SSRC from READY. Nothing is sent from it, but a picture loss
    /// indication has to name its sender.
    private var ourSSRC: UInt32 = 0

    private var continuation: AsyncStream<Event>.Continuation?
    public private(set) var events: AsyncStream<Event>!

    public init(connection: Connection) {
        self.connection = connection
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        self.continuation = continuation
    }

    // MARK: Lifecycle

    public func start() {
        emit(.state(.connecting))
        VoiceTrace.write(
            "stream watch session server_id=\(connection.serverID) "
            + "media=\(connection.mediaSessionID) owner=\(connection.ownerID)"
        )
        // **One publisher, and this session exists to receive them.** See
        // `InboundStreams.State.soleVideoOwner`: it makes the picture arrive
        // whether or not the gateway describes the SSRC in a shape this client
        // reads, which is the one gate in the receive path that nothing on this
        // end could observe.
        inbound.setSoleVideoOwner(connection.ownerID)
        inbound.onFirstVideoFrame.withLock { slot in
            slot = { [weak self] _ in
                Task { await self?.emit(.pictureArrived) }
            }
        }

        let gateway = VoiceGateway(
            role: .watch,
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
        transport?.stop(); transport = nil
        await gateway?.stop(); gateway = nil
        inbound.reset()
        continuation?.finish()
        continuation = nil
    }

    /// Where the watched picture goes.
    public nonisolated func setVideoSink(_ sink: (@Sendable (CMSampleBuffer) -> Void)?) {
        inbound.setVideoSink(sink, for: connection.ownerID)
    }

    // MARK: The handshake

    private func handle(_ event: VoiceGateway.Event) async {
        switch event {
        case .ready(let ready):
            await openTransport(ready)

        case .sessionDescription(let cipher, let key, _, let daveVersion):
            sealer = VoiceSealer(cipher: cipher, secretKey: key)
            inbound.setSealer(sealer)
            await startDAVE(version: daveVersion)
            startStatistics()
            emit(.state(.watching))

        case .speaking(let userID, let ssrc, _):
            inbound.bind(ssrc: ssrc, to: userID)

        case .videoStreams(let userID, let audioSSRC, let videoSSRC):
            // **This is how the owner's SSRCs arrive.** A viewer announces
            // nothing of its own; everything it needs to route is described to
            // it here, and a client that guessed instead would be decoding a
            // stream the server never sent.
            if audioSSRC != 0 { inbound.bind(ssrc: audioSSRC, to: userID) }
            if videoSSRC != 0 {
                inbound.bindVideo(ssrc: videoSSRC, to: userID)
            } else {
                inbound.unbindVideo(for: userID)
            }

        case .clientsConnected(let ids):
            announcedUsers.formUnion(ids)
            dave?.recognise(users: Set(ids))

        case .clientDisconnected(let userID):
            announcedUsers.remove(userID)
            inbound.remove(userID: userID)
            dave?.forget(user: userID)

        case .dave(let message):
            await handleDAVE(message)

        case .davePrepareTransition(let transitionID, let version):
            if dave?.prepareTransition(id: transitionID, protocolVersion: version) == true {
                await gateway?.sendTransitionReady(transitionID)
            }
            syncTransforms()

        case .daveExecuteTransition(let transitionID):
            dave?.executeTransition(id: transitionID)
            syncTransforms()

        case .davePrepareEpoch(let epoch, let version):
            if dave?.prepareEpoch(epoch, protocolVersion: version) == true {
                await sendKeyPackage()
            }
            syncTransforms()

        case .closed(_, let reason, _):
            emit(.state(.failed(reason)))

        case .resumed:
            break
        }
    }

    private func openTransport(_ ready: VoiceGateway.VoiceReady) async {
        let transport = VoiceTransport(host: ready.ip, port: ready.port)
        self.transport = transport
        ourSSRC = ready.ssrc
        // **Routed on the socket's own queue, synchronously** — §1.5's second
        // rule. A hop here re-orders bursts, which is the exact fault the
        // jitter buffer downstream exists to repair.
        transport.onDatagram = { [inbound] bytes in
            inbound.accept(bytes, arrival: CACurrentMediaTime())
        }
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
            // **Our own address, even though nothing is sent from it.** The
            // server will not describe the session — and therefore will not
            // forward anything to us — until the protocol is selected, and the
            // discovery packet is the only thing this session ever transmits.
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
    // **This end joins; it does not create.** The owner built the group and
    // committed us into it, so the whole of our part is a key package out and a
    // welcome in. Everything else here exists because a group that re-keys
    // while we are watching must not leave us decoding under a dead epoch.

    private func startDAVE(version: UInt16) async {
        guard version > 0 else {
            VoiceTrace.write("stream watch dave off; transport encryption only")
            dave = nil
            inbound.setDAVE(decryptors: [:], active: false)
            return
        }
        let session = DAVESession(
            protocolVersion: version,
            userID: connection.userID,
            groupKey: .mediaSession(connection.mediaSessionID),
            label: "watch"
        )
        session.recognise(
            users: announcedUsers.union([connection.userID, connection.ownerID])
        )
        dave = session
        syncTransforms()
        await sendKeyPackage()
    }

    private func sendKeyPackage() async {
        guard let dave, let gateway else { return }
        do {
            await gateway.sendKeyPackage(try dave.makeKeyPackage())
        } catch {
            VoiceTrace.fault("stream watch key package would not build: \(error)")
        }
    }

    private func handleDAVE(_ message: DAVEInbound) async {
        guard let dave, let gateway else { return }
        switch message {
        case .externalSender(let sender):
            do {
                try dave.setExternalSender(sender)
            } catch {
                VoiceTrace.fault("stream watch external sender refused: \(error)")
            }

        case .proposals(let proposals):
            do {
                guard let outbound = try dave.processProposals(proposals),
                      case .commitWelcome(let commit, let welcome) = outbound
                else { return }
                await gateway.sendCommitWelcome(commit: commit, welcome: welcome)
            } catch {
                VoiceTrace.fault("stream watch proposals refused: \(error)")
            }

        case .announceCommit(let transitionID, let commit):
            guard let raw = try? commit.marshalled() else { return }
            await settle(
                dave.processCommit(commit, raw: raw, transitionID: transitionID), on: gateway
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
        syncTransforms()
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

    private func syncTransforms() {
        guard let dave else {
            inbound.setDAVE(decryptors: [:], active: false)
            return
        }
        inbound.setDAVE(decryptors: dave.receiveTransforms, active: dave.protocolVersion > 0)
    }

    // MARK: Whether a picture is arriving

    private var ticks = 0
    /// The server's reports, gathered across the four drains that make one
    /// printed line.
    private var feedback = RTCP.Feedback()
    private var unreadable = 0

    /// **The receive half of `stream out=`.** A watched stream that shows
    /// nothing has the same four candidate causes a sent one does — nothing
    /// arriving, arriving and refused by the transport cipher, opened and
    /// refused by the end-to-end transform, or decoded and drawn nowhere — and
    /// they are four different things to fix.
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
        // **The one thing a viewer sends.** Media is arriving and every frame
        // of it is refused for want of a reference; the owner has no way to
        // know that unless it is told. See `InboundStreams.askForKeyframes`.
        if let transport { inbound.askForKeyframes(on: transport, from: ourSSRC) }
        let report = inbound.drainFeedback()
        feedback.merge(report.feedback)
        unreadable += report.unreadable

        ticks += 1
        guard ticks % 4 == 0 else { return }
        VoiceTrace.flushDrops()
        let summary = inbound.statistics()
        var line = "stream watch in=\(summary.datagrams) read=\(summary.received) "
        line += "loss=\(summary.lossPercent)%" + inbound.drainVideoReport().description
        line += feedback.description
        if unreadable > 0 { line += " rtcp?=\(unreadable)" }
        VoiceTrace.write(line)
        feedback = RTCP.Feedback()
        unreadable = 0
    }


    private func emit(_ event: Event) { continuation?.yield(event) }
}
