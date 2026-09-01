import Foundation

// MARK: - The voice gateway
//
// A second websocket, entirely separate from the main one, opened per voice
// connection. The main gateway only ever tells you *where* it is and hands you
// a token; everything about the media session is negotiated here.
//
// **Version 8, and the version matters.** v8 moved the heartbeat to a keyed
// object carrying the last sequence the client saw, and made the server resend
// anything unacknowledged after a resume. A client that heartbeats with v4's
// bare nonce on a v8 socket is disconnected at the first interval with no error
// text at all.
//
// The handshake, in order, and every step is blocking on the one before it:
//
//   → 0  Identify        server_id, user_id, session_id, token
//   ← 8  Hello           heartbeat_interval
//   ← 2  Ready           our ssrc, the media server's ip and port, the modes
//                        it will accept, and the codecs it offers
//   ⇄     IP discovery   over UDP, to learn our own public address
//   → 1  Select Protocol our address, and the mode we picked from its list
//   ← 4  Session Desc.   the secret key, and the codec it settled on
//   → 5  Speaking        once, before the first packet, or the server drops
//                        everything we send
//
// Miss the last one and the connection is perfect and silent, which is the
// hardest failure in this protocol to see.

public actor VoiceGateway {
    enum Event: Sendable {
        /// The media server's address, our SSRC, and what it will accept.
        case ready(VoiceReady)
        /// The key. Media may start after this and not before.
        ///
        /// `daveProtocolVersion` is the server's choice for this session: zero
        /// means transport encryption only, and anything else means no media
        /// may be sent until the MLS group exists.
        case sessionDescription(
            cipher: VoiceCipher,
            secretKey: [UInt8],
            videoCodec: String?,
            daveProtocolVersion: UInt16
        )
        /// A DAVE message that arrived as a binary frame — the external sender
        /// package, proposals, a commit, or a welcome.
        case dave(DAVEInbound)
        /// Opcode 21: a transition away from the current protocol version.
        case davePrepareTransition(transitionID: UInt16, protocolVersion: UInt16)
        /// Opcode 22: perform a transition everybody is ready for.
        case daveExecuteTransition(transitionID: UInt16)
        /// Opcode 24: a protocol version or MLS epoch change is coming.
        case davePrepareEpoch(epoch: UInt64, protocolVersion: UInt16)
        /// Somebody's SSRC now belongs to somebody. The only way to know whose
        /// voice a packet is.
        case speaking(userID: UInt64, ssrc: UInt32, flags: Int)
        /// Their video and screen-share SSRCs, from the server's own op 12.
        case videoStreams(userID: UInt64, audioSSRC: UInt32, videoSSRC: UInt32)
        case clientsConnected([UInt64])
        case clientDisconnected(userID: UInt64)
        case resumed
        case closed(reason: String, canResume: Bool)
    }

    struct VoiceReady: Sendable {
        var ssrc: UInt32
        var ip: String
        var port: UInt16
        var modes: [String]
        /// Extension ids the server negotiated, by URI. The audio level and the
        /// absolute send time are read out of this rather than assumed — see
        /// `RTPExtension` for why sending them wrong is worse than not sending
        /// them.
        var headerExtensions: [String: UInt8]
    }

    // MARK: Connection state

    private let endpoint: String
    private let serverID: String
    private let userID: String
    private let sessionID: String
    private let token: String

    private var socket: URLSessionWebSocketTask?
    private let session: URLSession
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    /// v8's acknowledgement. Every server payload that carries `seq` moves it,
    /// and every heartbeat sends it back.
    private var lastSequence: Int?
    private var isStopped = false
    private var hasIdentified = false
    private var canResume = false
    /// Whether the socket that is coming up is a resume or a fresh identify.
    /// Read when HELLO arrives — see `openSocket`.
    private var wantsResume = false

    private var continuation: AsyncStream<Event>.Continuation?
    private(set) var events: AsyncStream<Event>!

    init(
        endpoint: String,
        serverID: String,
        userID: String,
        sessionID: String,
        token: String
    ) {
        self.endpoint = Self.authority(from: endpoint)
        self.serverID = serverID
        self.userID = userID
        self.sessionID = sessionID
        self.token = token

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)

        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        self.continuation = continuation
    }

    /// The host and port to open the websocket on.
    ///
    /// **The published port is the port, and only the legacy `:80` is
    /// stripped.** An earlier version threw the port away on the belief that it
    /// was always 443 and therefore redundant. It is not: one account's servers
    /// published `:2083` and `:8443` on two consecutive joins — both ordinary
    /// HTTPS-alternate ports — and the socket opened on 443 regardless,
    /// answered HELLO, and then ignored the IDENTIFY for ever. **A connection
    /// that comes up on the wrong port and says nothing** is the worst shape
    /// this failure has, and it cost a session to find.
    ///
    /// `:80` is the one that must go: Discord published it for years on
    /// endpoints that only ever spoke TLS, so pasting it into a `wss://` URL is
    /// a connection to a port nothing is listening on.
    static func authority(from endpoint: String) -> String {
        endpoint.hasSuffix(":80") ? String(endpoint.dropLast(3)) : endpoint
    }

    // MARK: Lifecycle

    func connect() {
        guard !isStopped else { return }
        openSocket(resuming: false)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        continuation?.finish()
        continuation = nil
    }

    private func openSocket(resuming: Bool) {
        guard !isStopped else { return }
        heartbeatTask?.cancel()
        receiveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        hasIdentified = false

        guard var components = URLComponents(string: "wss://\(endpoint)") else { return }
        components.queryItems = [URLQueryItem(name: "v", value: "8")]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.setValue("https://discord.com", forHTTPHeaderField: "Origin")
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        VoiceTrace.write("socket open \(url.absoluteString) resuming=\(resuming)")
        startReceiving()
        // **Nothing is sent until HELLO arrives.** An earlier version sent the
        // IDENTIFY at socket-open time on the belief that the gateway accepts
        // it at any point and that waiting costs a round trip. Measured: the
        // frame went out before the websocket handshake had even completed, the
        // server answered HELLO, and then closed with 4017 — so the belief was
        // wrong and the round trip it was avoiding was the protocol.
        //
        // `wantsResume` is remembered instead, because by the time HELLO
        // arrives the reason for opening has to still be known.
        wantsResume = resuming
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            while let self, await !self.isStopped {
                do {
                    guard let message = try await self.receiveNext() else { break }
                    await self.handle(message)
                } catch {
                    await self.socketFailed(error)
                    return
                }
            }
        }
    }

    private func receiveNext() async throws -> URLSessionWebSocketTask.Message? {
        guard let socket else { return nil }
        return try await socket.receive()
    }

    // MARK: Inbound

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let value):
            // **A binary frame on this socket is DAVE and nothing else.** The
            // voice gateway negotiates no compression, so everything else it
            // sends is text; six of DAVE's opcodes are binary to save the
            // base64 a JSON encoding of an MLS message would cost.
            handleBinary([UInt8](value))
            return
        @unknown default: return
        }
        guard let frame = try? JSONDecoder().decode(Frame.self, from: data) else {
            VoiceTrace.write("frame not decodable: \(String(data: data, encoding: .utf8) ?? "-")")
            return
        }
        if let sequence = frame.seq { lastSequence = sequence }
        VoiceTrace.write("op=\(frame.op) seq=\(frame.seq.map(String.init) ?? "-")")

        switch frame.op {
        case 2:
            guard let payload = decode(ReadyPayload.self, from: data) else { return }
            VoiceTrace.write("ready: ssrc=\(payload.d.ssrc) \(payload.d.ip):\(payload.d.port)")
            canResume = true
            var extensions: [String: UInt8] = [:]
            for entry in payload.d.header_extensions ?? [] {
                extensions[entry.uri] = entry.id
            }
            continuation?.yield(.ready(VoiceReady(
                ssrc: payload.d.ssrc,
                ip: payload.d.ip,
                port: payload.d.port,
                modes: payload.d.modes ?? [],
                headerExtensions: extensions
            )))

        case 4:
            guard let payload = decode(SessionDescriptionPayload.self, from: data) else { return }
            let dave = payload.d.dave_protocol_version ?? 0
            VoiceTrace.write("keyed with \(payload.d.mode) dave=\(dave)")
            guard let cipher = VoiceCipher(rawValue: payload.d.mode) else {
                VoiceTrace.fault("server chose an unknown mode: \(payload.d.mode)")
                continuation?.yield(.closed(reason: "unsupported encryption mode", canResume: false))
                return
            }
            continuation?.yield(.sessionDescription(
                cipher: cipher,
                secretKey: payload.d.secret_key,
                videoCodec: payload.d.video_codec,
                daveProtocolVersion: dave
            ))

        case 5:
            guard let payload = decode(SpeakingPayload.self, from: data),
                  let userID = UInt64(payload.d.user_id ?? "") else { return }
            continuation?.yield(.speaking(
                userID: userID,
                ssrc: payload.d.ssrc,
                flags: payload.d.speaking ?? 0
            ))

        case 6:
            break   // heartbeat ack

        case 8:
            guard let payload = decode(HelloPayload.self, from: data) else {
                VoiceTrace.write("HELLO would not decode")
                return
            }
            // **v8 removed the 0.75 multiplier.** Earlier versions published an
            // interval the client was expected to scale; beating at the raw
            // interval there was a disconnect every forty seconds. Here the
            // number is the number.
            startHeartbeat(milliseconds: payload.d.heartbeat_interval)
            if wantsResume { sendResume() } else { sendIdentify() }

        case 9:
            continuation?.yield(.resumed)

        case 11:
            guard let payload = decode(ClientsConnectPayload.self, from: data) else { return }
            continuation?.yield(.clientsConnected(payload.d.user_ids.compactMap(UInt64.init)))

        case 12:
            guard let payload = decode(VideoPayload.self, from: data),
                  let userID = UInt64(payload.d.user_id ?? "") else { return }
            continuation?.yield(.videoStreams(
                userID: userID,
                audioSSRC: payload.d.audio_ssrc ?? 0,
                videoSSRC: payload.d.video_ssrc ?? 0
            ))

        case 13:
            guard let payload = decode(ClientDisconnectPayload.self, from: data),
                  let userID = UInt64(payload.d.user_id) else { return }
            continuation?.yield(.clientDisconnected(userID: userID))

        case 21:
            guard let payload = decode(TransitionPayload.self, from: data) else { return }
            continuation?.yield(.davePrepareTransition(
                transitionID: payload.d.transition_id,
                protocolVersion: payload.d.protocol_version ?? 0
            ))

        case 22:
            guard let payload = decode(TransitionPayload.self, from: data) else { return }
            continuation?.yield(.daveExecuteTransition(transitionID: payload.d.transition_id))

        case 24:
            guard let payload = decode(EpochPayload.self, from: data) else { return }
            continuation?.yield(.davePrepareEpoch(
                epoch: payload.d.epoch,
                protocolVersion: payload.d.protocol_version ?? 0
            ))

        default:
            break
        }
    }

    /// A binary DAVE frame.
    ///
    /// **The sequence number is in the frame, ahead of the opcode.** v8
    /// acknowledges binary frames through the same `seq_ack` as text ones, so a
    /// gateway that only advanced the sequence on JSON would resume by asking
    /// for everything since the last text message.
    private func handleBinary(_ frame: [UInt8]) {
        guard let header = try? DAVEInbound.header(of: frame) else {
            VoiceTrace.fault("a binary frame too short to hold an opcode (\(frame.count) bytes)")
            return
        }
        // **Acknowledged on arrival, ahead of the payload.** The frame was
        // received whether or not its payload parses, and a client that only
        // advances `seq_ack` on messages it understood resumes by asking for
        // everything since the last one it did.
        lastSequence = Int(header.sequence)
        VoiceTrace.write(
            "dave in \(DAVEOpcode.name(header.opcode))(\(header.opcode)) "
            + "seq=\(header.sequence) \(frame.count) bytes"
        )
        do {
            // An opcode with no inbound meaning is already named by the line
            // above, which is the whole of what there is to say about it.
            guard let message = try DAVEInbound.parse(frame, header: header) else { return }
            continuation?.yield(.dave(message))
        } catch {
            // A DAVE message this client cannot parse is not something to
            // struggle on with: the group would silently diverge from
            // everybody else's. `VoiceEngine` reports it and asks to be re-added.
            VoiceTrace.fault(
                "dave \(DAVEOpcode.name(header.opcode))(\(header.opcode)) would not parse: \(error)"
            )
            continuation?.yield(.dave(.malformed))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            VoiceTrace.fault("payload decode failed: \(error)")
            return nil
        }
    }

    // MARK: Outbound

    private func sendIdentify() {
        guard !hasIdentified else { return }
        hasIdentified = true
        struct Identify: Encodable {
            var op = 0
            var d: Body
            struct Body: Encodable {
                var server_id: String
                var user_id: String
                var session_id: String
                var token: String
                /// Asked for at identify, not later. A session that identifies
                /// without it is an audio-only session as far as the server is
                /// concerned, and turning a camera on afterwards is refused —
                /// which presents as a camera button that works locally and
                /// shows nobody anything.
                var video = true
                /// The highest DAVE protocol version this client implements.
                ///
                /// **One, and it has to be true.** Discord refuses every voice
                /// session — server channel, direct message, group call — with
                /// `4017 E2EE/DAVE protocol required` unless this is non-zero;
                /// only stage channels are exempt. Declaring a version the
                /// client cannot actually speak would get past IDENTIFY and
                /// then fail later, less clearly, while claiming an end-to-end
                /// guarantee it does not deliver. See `DAVESession`.
                var max_dave_protocol_version = 1
            }
        }
        send(Identify(d: .init(
            server_id: serverID,
            user_id: userID,
            session_id: sessionID,
            token: token
        )))
    }

    private func sendResume() {
        struct Resume: Encodable {
            var op = 7
            var d: Body
            struct Body: Encodable {
                var server_id: String
                var session_id: String
                var token: String
                /// v8 resumes from a sequence, and the server replays what the
                /// client never acknowledged.
                var seq_ack: Int
            }
        }
        send(Resume(d: .init(
            server_id: serverID,
            session_id: sessionID,
            token: token,
            seq_ack: lastSequence ?? -1
        )))
    }

    /// Announces our public address and picks the cipher.
    func selectProtocol(address: String, port: UInt16, cipher: VoiceCipher) {
        struct SelectProtocol: Encodable {
            var op = 1
            var d: Body
            struct Body: Encodable {
                var `protocol` = "udp"
                var data: Data
                var codecs: [Codec]
                struct Data: Encodable {
                    var address: String
                    var port: UInt16
                    var mode: String
                }
                struct Codec: Encodable {
                    var name: String
                    var type: String
                    var priority: Int
                    var payload_type: Int
                    var rtx_payload_type: Int?
                }
            }
        }
        send(SelectProtocol(d: .init(
            data: .init(address: address, port: port, mode: cipher.rawValue),
            // **The codec list is an offer and its order is the preference.**
            // H.264 first because VideoToolbox encodes it in hardware on every
            // Mac this app runs on, and because it is the one video codec the
            // reference client decodes on every platform it ships. Offering VP8
            // ahead of it would land a software encoder on the CPU for no gain.
            codecs: [
                .init(name: "opus", type: "audio", priority: 1_000,
                      payload_type: Int(RTP.PayloadType.opus), rtx_payload_type: nil),
                .init(name: "H264", type: "video", priority: 1_000,
                      payload_type: Int(RTP.PayloadType.h264),
                      rtx_payload_type: Int(RTP.PayloadType.h264RTX)),
            ]
        )))
    }

    /// Declares which SSRCs carry what, and at what quality.
    ///
    /// **This is the op the reference client will not render a camera without.**
    /// Video packets on an SSRC the server was never told about are forwarded to
    /// nobody: the far end has no stream to attach them to, so a client that
    /// sends H.264 without this looks exactly like a client whose camera is off.
    func announceStreams(
        audioSSRC: UInt32,
        videoSSRC: UInt32,
        rtxSSRC: UInt32,
        isActive: Bool,
        width: Int,
        height: Int,
        framerate: Int,
        bitrate: Int
    ) {
        struct Video: Encodable {
            var op = 12
            var d: Body
            struct Body: Encodable {
                var audio_ssrc: UInt32
                var video_ssrc: UInt32
                var rtx_ssrc: UInt32
                var streams: [Stream]
                struct Stream: Encodable {
                    var type = "video"
                    /// The simulcast layer's id. One layer, so it is always the
                    /// base — a client that offers three and encodes one has
                    /// told the server about two streams that never arrive, and
                    /// the estimator then reads permanent loss on both.
                    var rid = "100"
                    var ssrc: UInt32
                    var active: Bool
                    var quality: Int
                    var rtx_ssrc: UInt32
                    var max_bitrate: Int
                    var max_framerate: Int
                    var max_resolution: Resolution
                }
                struct Resolution: Encodable {
                    var type = "fixed"
                    var width: Int
                    var height: Int
                }
            }
        }
        send(Video(d: .init(
            audio_ssrc: audioSSRC,
            video_ssrc: isActive ? videoSSRC : 0,
            rtx_ssrc: isActive ? rtxSSRC : 0,
            streams: [.init(
                ssrc: isActive ? videoSSRC : 0,
                active: isActive,
                quality: isActive ? 100 : 0,
                rtx_ssrc: isActive ? rtxSSRC : 0,
                max_bitrate: bitrate,
                max_framerate: framerate,
                max_resolution: .init(width: width, height: height)
            )]
        )))
    }

    /// Announces that we are — or have stopped — talking.
    ///
    /// **Sent once before the first packet, and it is the step that is silently
    /// fatal to miss.** The server routes by SSRC and learns ours from this; a
    /// connection that never sends it is fully established, encrypted, and
    /// discarded packet by packet.
    func setSpeaking(_ flags: SpeakingFlags, ssrc: UInt32) {
        struct Speaking: Encodable {
            var op = 5
            var d: Body
            struct Body: Encodable {
                var speaking: Int
                var delay = 0
                var ssrc: UInt32
            }
        }
        send(Speaking(d: .init(speaking: flags.rawValue, ssrc: ssrc)))
    }

    // MARK: DAVE

    /// Opcode 26. Sent as soon as the session description names a non-zero
    /// protocol version, and again whenever the group is re-created.
    func sendKeyPackage(_ keyPackage: KeyPackage) {
        sendBinary(.keyPackage(keyPackage))
    }

    /// Opcode 28. The commit this client produced for the gateway's proposals,
    /// with a welcome when it adds anybody.
    func sendCommitWelcome(commit: MLSMessage, welcome: Welcome?) {
        sendBinary(.commitWelcome(commit: commit, welcome: welcome))
    }

    /// Opcode 23. Everybody has to say this before anybody changes keys.
    func sendTransitionReady(_ transitionID: UInt16) {
        struct Ready: Encodable {
            var op = 23
            var d: Body
            struct Body: Encodable { var transition_id: UInt16 }
        }
        send(Ready(d: .init(transition_id: transitionID)))
    }

    /// Opcode 31. Asks the gateway to remove and re-add this client, which is
    /// the protocol's own recovery from a commit or welcome it cannot process.
    func sendInvalidCommitWelcome(_ transitionID: UInt16) {
        struct Invalid: Encodable {
            var op = 31
            var d: Body
            struct Body: Encodable { var transition_id: UInt16 }
        }
        send(Invalid(d: .init(transition_id: transitionID)))
    }

    /// A binary frame — the opcode and its payload, with no sequence number.
    private func sendBinary(_ message: DAVEOutbound) {
        guard let socket, !isStopped else { return }
        let opcode = message.opcode
        guard let bytes = try? message.encoded() else {
            VoiceTrace.fault("could not encode a DAVE \(opcode)")
            return
        }
        VoiceTrace.write("dave out \(opcode)(\(opcode.rawValue)) \(bytes.count) bytes")
        socket.send(.data(Data(bytes))) { error in
            guard let error else { return }
            VoiceTrace.fault("dave binary send failed: \(error.localizedDescription)")
        }
    }

    /// Sends one frame.
    ///
    /// **A TEXT frame, and the main gateway's binary one would be wrong here.**
    /// That socket negotiates `compress=zlib-stream`, so it is a binary
    /// protocol in both directions and `.data` is correct. This one negotiates
    /// nothing: it is JSON over a plain websocket, and a binary frame carrying
    /// JSON is accepted by the TCP layer, acknowledged by nothing, and answered
    /// by nothing. The socket stays open and perfectly healthy with the
    /// handshake never advancing past HELLO, which is exactly what it looked
    /// like.
    private func send(_ value: some Encodable) {
        guard let socket, !isStopped else { return }
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return }
        // The opcode, never the payload: an IDENTIFY carries the voice token,
        // and a log line is a file, a screen share and a sysdiagnose.
        VoiceTrace.write("send op=\(Self.opcode(of: data)) \(data.count) bytes")
        socket.send(.string(text)) { error in
            guard let error else { return }
            VoiceTrace.write("send failed: \(error.localizedDescription)")
        }
    }

    /// The `op` of a frame we just built, for the trace. Reading it back out of
    /// the encoded bytes is cheaper than threading it through every caller, and
    /// it is only done when a sink is installed.
    private nonisolated static func opcode(of data: Data) -> String {
        guard VoiceTrace.isOn else { return "?" }
        struct Envelope: Decodable { var op: Int }
        return (try? JSONDecoder().decode(Envelope.self, from: data)).map { String($0.op) } ?? "?"
    }

    // MARK: Heartbeat

    private func startHeartbeat(milliseconds: Double) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            let interval = milliseconds / 1_000
            try? await Task.sleep(for: .seconds(interval * Double.random(in: 0...1)))
            while !Task.isCancelled, await self?.isStopped == false {
                await self?.beat()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func beat() {
        struct Heartbeat: Encodable {
            var op = 3
            var d: Body
            struct Body: Encodable {
                /// A nonce the server echoes. v8 made this an object; v4 sent a
                /// bare integer, and the server closes on the wrong shape.
                var t: Int
                var seq_ack: Int
            }
        }
        send(Heartbeat(d: .init(
            t: Int(Date().timeIntervalSince1970 * 1_000),
            seq_ack: lastSequence ?? -1
        )))
    }

    // MARK: Failure

    private func socketFailed(_ error: any Error) {
        guard !isStopped else { return }
        let code = socket?.closeCode.rawValue ?? 0
        // **The reason text is the whole diagnostic.** The close code alone is a
        // number outside the documented range as often as inside it; Discord
        // sends a sentence with the frame, and reading it is the difference
        // between knowing which field is wrong and guessing at the payload.
        let reason = socket?.closeReason
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        VoiceTrace.write(
            "socket failed close=\(code) reason=\(reason.isEmpty ? "-" : reason) "
            + "error=\(error.localizedDescription)"
        )

        // 4014 is "disconnected" — moved, kicked, or the channel deleted. 4006
        // is a session that is no longer valid. Neither is resumable and both
        // mean the main gateway is about to say so.
        let fatal: Set<Int> = [4004, 4006, 4009, 4011, 4012, 4014, 4016]
        if fatal.contains(code) {
            continuation?.yield(.closed(
                reason: Self.describe(code: code, reason: reason), canResume: false
            ))
            stop()
            return
        }
        guard canResume else {
            continuation?.yield(.closed(
                reason: Self.describe(code: code, reason: reason), canResume: false
            ))
            stop()
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            await self?.openSocket(resuming: true)
        }
    }
    /// What to put in front of somebody when a call will not connect.
    ///
    /// **The server's own sentence wins** — Discord sends one with the close
    /// frame and it names the actual problem — with one exception, which is the
    /// refusal that is not a fault at all.
    private static func describe(code: Int, reason: String) -> String {
        // **"E2EE/DAVE protocol required" used to mean "not built"; it no
        // longer does.** DAVE is implemented, and the identify declares version
        // 1 — so this close code now means the server rejected *this client's*
        // declaration rather than the absence of one. Saying so is the whole
        // value of the sentence: it points at a handshake defect instead of at
        // a missing feature, which is the difference between a bug report worth
        // acting on and one that reads as "voice does not work".
        if reason.localizedCaseInsensitiveContains("dave")
            || reason.localizedCaseInsensitiveContains("e2ee") {
            return "Discord refused this call's end-to-end encryption. "
                + "That is a fault in Wingcord's DAVE handshake, not a missing feature — "
                + "the session log has the frames."
        }
        if !reason.isEmpty { return reason }
        return switch code {
        case 4004: "Voice refused this session."
        case 4006, 4009: "The voice session expired."
        case 4011: "That voice server could not be found."
        case 4014: "Disconnected from voice."
        case 4015: "The voice server restarted."
        case 4016: "Voice asked for an encryption mode this client does not have."
        default: "Voice would not connect (\(code))."
        }
    }
}

// MARK: - Speaking flags

struct SpeakingFlags: OptionSet, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let microphone = SpeakingFlags(rawValue: 1 << 0)
    static let priority = SpeakingFlags(rawValue: 1 << 2)
    static let none = SpeakingFlags([])
}

// MARK: - Wire shapes

private struct Frame: Decodable {
    var op: Int
    var seq: Int?
}

private struct HelloPayload: Decodable {
    var d: Body
    struct Body: Decodable { var heartbeat_interval: Double }
}

private struct ReadyPayload: Decodable {
    var d: Body
    struct Body: Decodable {
        var ssrc: UInt32
        var ip: String
        var port: UInt16
        var modes: [String]?
        var header_extensions: [Extension]?
        struct Extension: Decodable {
            var uri: String
            var id: UInt8
        }
    }
}

private struct SessionDescriptionPayload: Decodable {
    var d: Body
    struct Body: Decodable {
        var mode: String
        var secret_key: [UInt8]
        var video_codec: String?
        /// Absent on a session with no end-to-end encryption at all, which
        /// today means a stage channel.
        var dave_protocol_version: UInt16?
    }
}

private struct TransitionPayload: Decodable {
    var d: Body
    struct Body: Decodable {
        var transition_id: UInt16
        var protocol_version: UInt16?
    }
}

private struct EpochPayload: Decodable {
    var d: Body
    struct Body: Decodable {
        var epoch: UInt64
        var protocol_version: UInt16?
    }
}

private struct SpeakingPayload: Decodable {
    var d: Body
    struct Body: Decodable {
        var user_id: String?
        var ssrc: UInt32
        var speaking: Int?
    }
}

private struct ClientsConnectPayload: Decodable {
    var d: Body
    struct Body: Decodable { var user_ids: [String] }
}

private struct ClientDisconnectPayload: Decodable {
    var d: Body
    struct Body: Decodable { var user_id: String }
}

private struct VideoPayload: Decodable {
    var d: Body
    struct Body: Decodable {
        var user_id: String?
        var audio_ssrc: UInt32?
        var video_ssrc: UInt32?
    }
}
