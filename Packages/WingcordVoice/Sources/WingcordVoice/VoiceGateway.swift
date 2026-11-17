import Foundation
import WingcordCore

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
        /// Their video SSRCs, from the server's own op 12, and the one their
        /// retransmissions arrive on.
        case videoStreams(
            userID: UInt64, audioSSRC: UInt32, videoSSRC: UInt32, retransmissionSSRC: UInt32
        )
        /// Opcode 15: how much of our picture the server's subscribers want.
        case mediaSinkWants(MediaSinkWants)
        case clientsConnected([UInt64])
        case clientDisconnected(userID: UInt64)
        /// Opcode 20: which kind of client somebody is on — Discord's
        /// `RTC_CONNECTION_PLATFORM`, drawn as the mark beside their name.
        case clientPlatform(userID: UInt64, platform: Int)
        /// Opcode 18's `flags`: what somebody's client says about clips —
        /// Discord's `RTC_CONNECTION_FLAGS` (1 clips on, 2 allows their voice
        /// to be recorded, 4 allows any viewer to clip their stream).
        case clientFlags(userID: UInt64, flags: Int)
        case resumed
        /// A heartbeat came back: the round trip to the voice server, which is
        /// Discord's "ping" (decision 11's connection panel).
        case heartbeatAcknowledged(roundTripMilliseconds: Int)
        /// - Parameter code: the websocket close code. §"Never log a close code
        ///   without its reason" is about the reader; a caller that recovers
        ///   from one refusal and not another needs the number too.
        case closed(code: Int, reason: String, canResume: Bool)
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
        /// The simulcast layer id the server allocated for our video, echoed
        /// back verbatim in opcode 12.
        ///
        /// **Read from the server rather than chosen.** READY describes the
        /// stream it has already made — `{"type":"video","ssrc":…,"rid":"",…}` —
        /// and a value it *names* is the value to use. An **empty** one is the
        /// absence of a layer name rather than a name, and is supplied instead:
        /// see `VoiceGateway.baseSimulcastLayer`.
        var videoRID: String

        /// The ids the server named, and **only** the ones it named.
        ///
        /// **No fallback here, deliberately.** Discord names none of these, so
        /// a default belongs to whichever session has a capture of what a
        /// working client sends *on that kind of session* — and those are two
        /// different answers until both have been read off the wire. A default
        /// on this type is one applied to every session at once, which is how
        /// ids captured from a Go Live stream ended up on a call that had never
        /// been measured. See `RTPExtension.DefaultID`.
        var sendTimeExtensionID: UInt8? {
            headerExtensions[RTPExtension.URI.absoluteSendTime]
        }

        var transportSequenceExtensionID: UInt8? {
            headerExtensions[RTPExtension.URI.transportSequence]
        }

        var audioLevelExtensionID: UInt8? {
            headerExtensions[RTPExtension.URI.audioLevel]
        }
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

    /// Which of a call's sessions this gateway belongs to.
    ///
    /// **Three of these run at once and every line they wrote looked the
    /// same.** A call, a share it publishes and a share it watches each own a
    /// gateway, a socket, SSRCs and an MLS group, and the trace interleaved all
    /// three under one `voice:` prefix — so `op=12 seq=3` and `dave epoch=1`
    /// could belong to any of them, and reading which cost real time on every
    /// diagnosis. The statistics lines were already named apart; nothing else
    /// was.
    enum Role: String, Sendable {
        case call
        case stream
        case watch
    }

    private let role: Role

    init(
        role: Role,
        endpoint: String,
        serverID: String,
        userID: String,
        sessionID: String,
        token: String
    ) {
        self.role = role
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
        VoiceTrace.write("\(role) op=\(frame.op) seq=\(frame.seq.map(String.init) ?? "-")")

        switch frame.op {
        case 2:
            guard let payload = decode(ReadyPayload.self, from: data) else { return }
            VoiceTrace.write("ready: ssrc=\(payload.d.ssrc) \(payload.d.ip):\(payload.d.port)")
            // **The frame as it arrived, once.** This client reads five fields
            // out of READY and assumed the rest were not there; the RTP header
            // extension ids turned out to be among the ones it could not find,
            // and a video stream sent without them is one the far end's
            // estimator has nothing to measure. Carries no key material — the
            // secret arrives on opcode 4 — so it is safe to write down.
            VoiceTrace.write(
                "ready raw: " + (String(data: data, encoding: .utf8) ?? "<not text>")
            )
            canResume = true
            var extensions: [String: UInt8] = [:]
            for entry in payload.d.header_extensions ?? [] {
                extensions[entry.uri] = entry.id
            }
            // **Every extension the server negotiated, not only the two this
            // client writes.** An extension the server expects and nobody
            // sends is silently fatal in the way the whole voice stack fails:
            // an SFU that routes a simulcast layer by its RID cannot place
            // packets that carry no RID, and forwards them to nobody.
            if !extensions.isEmpty {
                VoiceTrace.write(
                    "ready: header extensions "
                    + extensions.sorted { $0.value < $1.value }
                        .map { "\($0.value)=\($0.key)" }
                        .joined(separator: " ")
                )
            }
            continuation?.yield(.ready(VoiceReady(
                ssrc: payload.d.ssrc,
                ip: payload.d.ip,
                port: payload.d.port,
                modes: payload.d.modes ?? [],
                headerExtensions: extensions,
                videoRID: payload.d.streams?
                    .first { $0.type == "video" }?.rid ?? ""
            )))

        case 4:
            guard let payload = decode(SessionDescriptionPayload.self, from: data) else { return }
            let dave = payload.d.dave_protocol_version ?? 0
            // **The video codec is named here and nowhere else.** This client
            // sends H.264 on payload type 101 because that is what it offered;
            // nothing has ever checked what the server picked, and a stream on
            // a payload type the server did not choose is forwarded to nobody —
            // which is indistinguishable from every other way video fails.
            VoiceTrace.write(
                "keyed with \(payload.d.mode) dave=\(dave) "
                + "video=\(payload.d.video_codec ?? "unnamed")"
            )
            guard let cipher = VoiceCipher(rawValue: payload.d.mode) else {
                VoiceTrace.fault("server chose an unknown mode: \(payload.d.mode)")
                continuation?.yield(.closed(
                    code: 4016, reason: "unsupported encryption mode", canResume: false
                ))
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
            // The nonce is the send time in milliseconds, echoed back.
            if let payload = decode(HeartbeatAckPayload.self, from: data), let sent = payload.d.t {
                let now = Int(Date().timeIntervalSince1970 * 1_000)
                let roundTrip = now - sent
                if roundTrip >= 0, roundTrip < 60_000 {
                    continuation?.yield(.heartbeatAcknowledged(roundTripMilliseconds: roundTrip))
                }
            }

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

        case 18:
            // **One client connecting, and the server sometimes sends only
            // this.** Opcode 11 is the bulk form and 18 is the per-client one;
            // a client that reads only the first is told about a participant it
            // then refuses to admit to the MLS group.
            //
            // Measured: a call where the other end was announced by 18 and 20
            // alone — no 11 at all — and every welcome the gateway sent was
            // refused with "user … is not in this call". No group, no key,
            // nothing transmitted in either direction for the whole call, with
            // a healthy socket and `out=0`.
            guard let payload = decode(ClientConnectPayload.self, from: data),
                  let userID = UInt64(payload.d.user_id)
            else { return }
            continuation?.yield(.clientsConnected([userID]))
            if let flags = payload.d.flags {
                continuation?.yield(.clientFlags(userID: userID, flags: flags))
            }

        case 20:
            guard let payload = decode(ClientPlatformPayload.self, from: data),
                  let userID = UInt64(payload.d.user_id), let platform = payload.d.platform
            else { return }
            continuation?.yield(.clientPlatform(userID: userID, platform: platform))

        case 12:
            // **The frame as it arrived, every time.** This is the only place
            // the server says which SSRC somebody's picture will be on, and a
            // client that reads two fields out of it has no way to notice that
            // the one it wanted was named somewhere else — the failure is a
            // routing table that disagrees with the wire, which drops every
            // packet at a `guard` and counts nothing. There are a handful of
            // these per call and they carry no key material.
            VoiceTrace.write(
                "video raw: " + (String(data: data, encoding: .utf8) ?? "<not text>")
            )
            guard let payload = decode(VideoPayload.self, from: data),
                  let userID = UInt64(payload.d.user_id ?? "") else { return }
            continuation?.yield(.videoStreams(
                userID: userID,
                audioSSRC: payload.d.audio_ssrc ?? 0,
                videoSSRC: payload.d.video_ssrc ?? 0,
                retransmissionSSRC: payload.d.rtx_ssrc ?? 0
            ))

        case 15:
            // **The server telling a publisher what its subscribers want.** A
            // want per SSRC, and the pixels its viewers draw it at — measured
            // as `{"pixelCounts":{"91568":0},"any":100}` on a share and
            // `{"any":0,"95747":100}` on a call. It changes over the life of a
            // session, and a client that never reads it encodes for nobody in
            // particular. See `VideoQualityPolicy`.
            guard let payload = decode(SinkWantsPayload.self, from: data) else { return }
            continuation?.yield(.mediaSinkWants(payload.d))

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

        // **An opcode nobody acts on is a fact nobody has read.** A few of
        // each, printed whole, once, because they repeat.
        noteUnhandled(frame.op, data)
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
            // everybody else's. `MediaSession` reports it and asks to be re-added.
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
                /// **The simulcast layer this session may publish, declared at
                /// IDENTIFY.**
                ///
                /// `video: true` above says the session is capable; this says
                /// what it will send, and the server registers the layer from
                /// it. Without it the SFU has a video-capable client with no
                /// video layer — and answers opcode 15 with
                /// `pixelCounts: {<our video ssrc>: 0}` on a stream and
                /// `{"any": 0}` on a call, which is the server saying it wants
                /// no pixels from us and never revising it however many people
                /// subscribe. Measured on both paths, for hours: keys up,
                /// twenty thousand packets out, `UNSENT=0`, a decodable
                /// bitstream, and a black tile at the far end.
                ///
                /// Opcode 12 later names the SSRCs for this layer; it does not
                /// create it. The `rid` matches the one announced there — see
                /// `VoiceGateway.baseSimulcastLayer`.
                var streams = [Stream(rid: VoiceGateway.baseSimulcastLayer)]

                struct Stream: Encodable {
                    var type = "video"
                    var rid: String
                    var quality = 100
                }

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
        // **The identify, field by field, less the token.** Two sessions of one
        // call send this payload and they must differ in three of its fields;
        // a byte count cannot show that, and the call's and the stream's came
        // out the same length. A 4006 twenty milliseconds later says the server
        // could not find the session this names — which is unreadable without
        // knowing what was named.
        //
        // The token is a media credential in the clear, so only its length goes
        // in: §"the payload is never logged", and a trace line is a file, a
        // screen share and a sysdiagnose.
        VoiceTrace.write(
            "identify server_id=\(serverID) user_id=\(userID) "
            + "session_id=\(sessionID) token=<\(token.count) chars>"
        )
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
        rid: String,
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
                    /// The simulcast layer's id — **`"100"`, which is what a
                    /// real Discord client announces**, captured from one.
                    ///
                    /// This has now been both. It was `"100"` on a guess, then
                    /// `""` on the reasoning that READY describes the stream
                    /// the server already made — `{"type":"video","ssrc":9240,
                    /// "rtx_ssrc":9241,"rid":"","quality":0,"active":false}` —
                    /// so echoing it back was the safe thing.
                    ///
                    /// The reasoning was wrong, and the wire says so. The
                    /// server relayed somebody else's Go Live stream to us as
                    /// `{"ssrc":15502,"rtx_ssrc":15503,"rid":"100",
                    /// "quality":100,"max_resolution":{"width":1280,
                    /// "type":"fixed","height":720},"max_framerate":30,
                    /// "active":true}` — from a Discord client whose READY
                    /// said `""` exactly as ours does. **A client names its
                    /// layer; READY's empty rid is the absence of one, not a
                    /// value to echo.** See §"Wire facts are captured, never
                    /// assumed": this one now is.
                    ///
                    /// READY's value still wins when it has one, because a
                    /// server that does name a layer is naming the layer.
                    var rid: String
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
                rid: rid.isEmpty ? Self.baseSimulcastLayer : rid,
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

    /// The layer id a client names when the server has not named one. See
    /// `announceStreams`.
    static let baseSimulcastLayer = "100"

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

    /// Opcode 15: what this end wants sent to it — a video turned off, a
    /// person muted. See `InboundStreams.sinkWants`.
    func sendMediaSinkWants(_ wants: MediaSinkWants) {
        struct Wants: Encodable {
            var op = 15
            var d: MediaSinkWants
        }
        send(Wants(d: wants))
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
        // The opcode, and for the two that describe what we transmit, the
        // payload with it.
        //
        // **Never for the rest**: an IDENTIFY carries the voice token, and a
        // log line is a file, a screen share and a sysdiagnose. Opcodes 5, 12
        // and 15 carry SSRCs, a resolution and wants and nothing else, and
        // they are the whole of what this client tells a server about the
        // media it sends and the media it wants — the difference between a
        // stream that is forwarded and one that is accepted and dropped is
        // somewhere in those payloads, and until now the trace said only how
        // many bytes long they were.
        let opcode = Self.opcode(of: data)
        if opcode == "5" || opcode == "12" || opcode == "15" {
            VoiceTrace.write("\(role) send op=\(opcode) \(text)")
        } else {
            VoiceTrace.write("\(role) send op=\(opcode) \(data.count) bytes")
        }
        socket.send(.string(text)) { error in
            guard let error else { return }
            VoiceTrace.write("send failed: \(error.localizedDescription)")
        }
    }

    /// Opcodes this client takes no action on, printed a few times each.
    ///
    /// Bounded per opcode rather than overall: one chatty opcode would
    /// otherwise use up the budget for the one that matters.
    private var unhandledSeen: [Int: Int] = [:]

    private func noteUnhandled(_ opcode: Int, _ data: Data) {
        guard VoiceTrace.isOn, Self.handledOpcodes.contains(opcode) == false else { return }
        let seen = unhandledSeen[opcode, default: 0]
        guard seen < 3 else { return }
        unhandledSeen[opcode] = seen + 1
        VoiceTrace.write(
            "\(role) op=\(opcode) unhandled: "
            + (String(data: data, encoding: .utf8) ?? "<not text>")
        )
    }

    /// Everything the switch above has a case for. Listed rather than derived,
    /// because a case that is added without adding it here starts printing
    /// itself, which is the harmless direction.
    private static let handledOpcodes: Set<Int> = [
        2, 4, 5, 6, 8, 9, 11, 12, 13, 15, 18, 20, 21, 22, 24,
        25, 26, 27, 28, 29, 30, 31,
    ]

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
        // Always, with its reason: INVARIANTS §1.5.
        Log.info(
            .voice,
            "\(role) voice socket closed: code=\(code) reason=\(public: reason.isEmpty ? "-" : reason)"
        )

        // 4014 is "disconnected" — moved, kicked, or the channel deleted. 4006
        // is a session that is no longer valid. Neither is resumable and both
        // mean the main gateway is about to say so.
        let fatal: Set<Int> = [4004, 4006, 4009, 4011, 4012, 4014, 4016]
        if fatal.contains(code) {
            continuation?.yield(.closed(
                code: code, reason: Self.describe(code: code, reason: reason), canResume: false
            ))
            stop()
            return
        }
        guard canResume else {
            continuation?.yield(.closed(
                code: code, reason: Self.describe(code: code, reason: reason), canResume: false
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
    /// "Transmission of context audio for video, no speaking indicator" —
    /// Discord's documented flag for a stream's own sound.
    static let soundshare = SpeakingFlags(rawValue: 1 << 1)
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
        var streams: [Stream]?
        struct Extension: Decodable {
            var uri: String
            var id: UInt8
        }
        /// The stream the server has already allocated for us. Its shape is
        /// what opcode 12 has to describe back.
        struct Stream: Decodable {
            var type: String?
            var rid: String?
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

private struct HeartbeatAckPayload: Decodable {
    var d: Body
    struct Body: Decodable { var t: Int? }
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

/// Opcode 18: one client connecting. The bulk form is `ClientsConnectPayload`.
/// Opcode 20: `{user_id, platform}` — DESKTOP 0, MOBILE 1, XBOX 2,
/// PLAYSTATION 3, QUEST 4 (Discord's module 806931).
private struct ClientPlatformPayload: Decodable {
    var d: Body
    struct Body: Decodable {
        var user_id: String
        var platform: Int?
    }
}

private struct ClientConnectPayload: Decodable {
    var d: Body
    struct Body: Decodable {
        var user_id: String
        /// What their client says about clips — **not** what it transmits,
        /// which opcodes 5 and 12 say. Discord's media engine reports it as
        /// `RTC_CONNECTION_FLAGS`, and its `ClipsManager` reads two bits:
        /// `CLIPS_ENABLED` (1) and `ALLOW_VOICE_RECORDING` (2), with
        /// `ALLOW_ANY_VIEWER_CLIPS` (4) beside them (web build 641803).
        var flags: Int?
    }
}

private struct VideoPayload: Decodable {
    var d: Body
    struct Body: Decodable {
        var user_id: String?
        var audio_ssrc: UInt32?
        var video_ssrc: UInt32?
        var rtx_ssrc: UInt32?
    }
}

private struct SinkWantsPayload: Decodable {
    var d: MediaSinkWants
}
