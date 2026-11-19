import Foundation
import OSLog
import WingcordCore

/// The gateway connection.
///
/// **The receive loop never awaits a handler**, and that is not a style
/// preference — it is the difference between a working socket and a deadlocked
/// one. If the loop awaited something that could itself wait on a future inbound
/// frame, the socket would stop reading while waiting for a frame it is the only
/// thing that can read. Frames are decoded and pushed into a stream; the
/// consumer is somebody else's problem.
///
/// `zlib-stream` compression is on. READY for a busy account is several
/// megabytes of JSON and roughly a tenth of that compressed, so this is the
/// single biggest lever on time-to-first-frame — and the inflate is one shared
/// context for the life of the connection, never one per frame.
public actor GatewaySocket {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Gateway")

    /// Where lifecycle tracing goes.
    ///
    /// A sink the app installs rather than a file this module opens: the network
    /// layer has no business deciding where diagnostics live, and a socket that
    /// never produces a READY is diagnosed by reading the ORDER of a handful of
    /// events alongside the app's own.
    ///
    /// Off by default and free when off — one optional check.
    nonisolated(unsafe) public static var traceSink: (@Sendable (String) -> Void)? = {
        guard ProcessInfo.processInfo.environment["WINGCORD_LIVE"] == "1" else { return nil }
        return { message in
            FileHandle.standardError.write(Data("[gateway] \(message)\n".utf8))
        }
    }()

    /// Whether a trace line would be written anywhere: the stderr sink a
    /// developer turns on, or the log while detailed logging is on.
    nonisolated static var isTracing: Bool { traceSink != nil || Log.isDetailed }

    /// A protocol-level line: every frame, every key list. **Detailed logging
    /// only** — it is a line per frame, which the always-on log must never be
    /// (docs/BUG-REPORTING.md §4); the connection's lifecycle is written with
    /// `Log.info` where it happens.
    nonisolated static func trace(_ message: @autoclosure () -> String) {
        guard isTracing else { return }
        let text = message()
        traceSink?(text)
        Log.debug(.gateway, .raw(text))
    }

    public enum Event: Sendable {
        case connecting
        case ready(ReadySnapshot)
        /// The rest of the bootstrap, a beat after `ready`. Its own event
        /// rather than a delayed field on the first: READY is what brings the
        /// window up, and holding it back until the second half arrives would
        /// trade a working sidebar for a filled one.
        case readySupplemental(ReadySupplementalSnapshot)
        case resumed
        case update(GatewayUpdate)
        case disconnected(reason: String, willRetry: Bool)
        /// The token is dead. The session must not retry — retrying a rejected
        /// credential forever is how an app burns battery going nowhere.
        case authenticationFailed
    }

    private let metadata: ClientMetadata
    private var token: String?
    private var session: URLSession
    private var task: URLSessionWebSocketTask?
    private var inflater: ZlibInflater?

    /// The order READY listed the account's guilds in. See the note where it is
    /// written; it is only ever read by `READY_SUPPLEMENTAL`, which follows.
    private var readyGuildIDs: [GuildID] = []

    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var sequence: Int?
    private var sessionID: String?
    private var resumeURL: String?
    /// Who we are, remembered from READY.
    ///
    /// **Two thread events are about us and say so only by omission.** The
    /// membership nested in `THREAD_CREATE`, and the one in a `THREAD_LIST_SYNC`
    /// row, leave `user_id` out because the account is implied — so converting
    /// either into a `ThreadMember` needs an id the payload does not carry.
    /// Held here rather than fabricated at the call site.
    private var currentUserID: UserID?

    /// The session READY named, for the one caller outside this socket that
    /// needs it.
    ///
    /// **An interaction names the session that will receive its response**, so
    /// launching an activity is impossible without this. Read rather than
    /// stored elsewhere because it changes on every resume that fails, and a
    /// copy kept by a view model is a copy that goes stale exactly when the
    /// socket reconnects. Nil between a disconnect and the next READY, which is
    /// a real state a launch has to refuse rather than paper over.
    public var currentSessionID: String? { sessionID }
    private var lastHeartbeatAcknowledged = true
    private var reconnectAttempt = 0
    /// How many times to retry before saying so. Ten attempts with the back-off
    /// below spans roughly five minutes, which is long enough to ride out a
    /// laptop lid or a Wi-Fi change and short enough that a broken client says
    /// something the same session.
    static let maximumReconnectAttempts = 10
    /// A one-way latch. Everything checks it, so nothing resumed after teardown
    /// writes into a session that is gone.
    private var isStopped = false

    private var continuation: AsyncStream<Event>.Continuation?
    public private(set) var events: AsyncStream<Event>!

    /// **`DiscordREST`'s, not a second one.** This was a byte-identical copy of
    /// that decoder — the same two-spelling date strategy, for the same reason —
    /// and two definitions of how Discord's timestamps are read is one more than
    /// can be kept in step. The socket and the REST client decode the same
    /// objects off the same API; a fix to one that missed the other would show
    /// up as a field that parses over HTTP and not over the socket.
    private var decoder: JSONDecoder { DiscordREST.decoder }

    public init(metadata: ClientMetadata = ClientMetadata()) {
        self.metadata = metadata
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        // The gateway gets its own connection pool. A REST timeout that stalls
        // one pool must never take the heartbeat down with it.
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)

        let (stream, continuation) = AsyncStream<Event>.makeStream(
            // A dropped presence update is nothing; a dropped MESSAGE_CREATE is
            // a message missing from a transcript. Unbounded, and the consumer
            // is fast enough that it never grows — the bound that matters is the
            // one on the socket's own read rate.
            bufferingPolicy: .unbounded
        )
        events = stream
        self.continuation = continuation
    }

    // MARK: Lifecycle

    public func connect(token: String) {
        self.token = token
        isStopped = false
        reconnectAttempt = 0
        sessionID = nil
        sequence = nil
        resumeURL = nil
        openSocket(resuming: false)
    }

    /// Closes everything and releases the stream.
    ///
    /// Idempotent, and complete: a socket left open holds a TCP connection, a
    /// heartbeat task left running wakes the CPU every forty seconds forever,
    /// and a continuation left unfinished keeps its consumer suspended.
    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        inflater = nil
        token = nil
        continuation?.finish()
        continuation = nil
    }

    private func openSocket(resuming: Bool) {
        // The token is not read here — IDENTIFY sends it — but a socket must
        // never be opened without one, or the connection comes up and then sits
        // silent waiting for an authentication that can never be sent.
        guard !isStopped, token != nil else { return }

        heartbeatTask?.cancel()
        receiveTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)

        // One inflater per connection. Reusing the previous one carries a
        // half-finished message across the reconnect and every frame after it
        // inflates to garbage.
        inflater = try? ZlibInflater()

        let base = (resuming ? resumeURL : nil) ?? "wss://gateway.discord.gg"
        var components = URLComponents(string: base)
        components?.queryItems = [
            URLQueryItem(name: "v", value: String(metadata.baseline.apiVersion)),
            URLQueryItem(name: "encoding", value: "json"),
            URLQueryItem(name: "compress", value: "zlib-stream"),
        ]
        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.setValue(metadata.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://discord.com", forHTTPHeaderField: "Origin")

        Self.trace("opening \(url.absoluteString)")
        Log.info(.gateway, "opening the gateway, attempt \(reconnectAttempt + 1)")
        let socket = session.webSocketTask(with: request)
        // **The default cap is 1 MB, and READY is bigger than that.**
        //
        // `URLSessionWebSocketTask` rejects any message larger than
        // `maximumMessageSize` by failing the *receive* with POSIX `EMSGSIZE`
        // (code 40, "Message too long") and tearing the socket down. The client
        // then reconnects, asks for the same READY, and fails identically —
        // which reads as an endless "Reconnecting…" with a perfectly healthy
        // network, and gets worse the more servers the account joins.
        //
        // This account's compressed READY sits right around the default, which
        // is why it connected for weeks and then stopped: it did not break, it
        // grew. The ceiling is generous because the failure is fatal and the
        // cost of headroom is nothing — the buffer is sized by what arrives, not
        // by this number.
        socket.maximumMessageSize = 16 * 1024 * 1024
        task = socket
        socket.resume()
        continuation?.yield(.connecting)
        startReceiving()
    }

    // MARK: Receiving

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while await !self.isStopped {
                do {
                    guard let message = try await self.receiveNext() else { break }
                    await self.handle(message)
                } catch {
                    GatewaySocket.trace("receive failed: \(error)")
                    await self.socketFailed(error)
                    return
                }
            }
        }
    }

    private func receiveNext() async throws -> URLSessionWebSocketTask.Message? {
        guard let task else { return nil }
        return try await task.receive()
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .data(let value):
            data = inflate(value)
        case .string(let text):
            // Only ever seen when compression is refused. Handled anyway,
            // because a connection that silently drops every frame is far worse
            // than one branch that is usually dead.
            data = Data(text.utf8)
        @unknown default:
            data = nil
        }
        guard let data, !data.isEmpty else {
            Self.trace("frame produced no payload")
            return
        }

        do {
            let frame = try decoder.decode(GatewayFrame.self, from: data)
            Self.trace(
                "op=\(frame.opcode) \(frame.name ?? "-") "
                + "seq=\(frame.sequence.map(String.init) ?? "-") bytes=\(data.count)"
            )
            // READY only, once per connection: name the keys Discord actually
            // sent. Discord has moved these before — `user_settings` for one —
            // and a missing key is silent, because every non-structural field
            // here is optional by design. Reading the key list off the wire is
            // the difference between knowing and guessing.
            if case .ready = frame.payload { Self.traceReadyShape(data) }
            // Every Go Live frame, verbatim. See `traceStreamFrame`.
            if let name = Self.streamEventName(of: frame) { Self.traceStreamFrame(name, data) }
            if frame.name == "SESSIONS_REPLACE" { Self.traceOwnSessions(data) }
            if let sequence = frame.sequence { self.sequence = sequence }
            process(frame)
        } catch {
            // **A swallowed decode failure is invisible and permanent.** If the
            // frame that failed was READY, the app sits at "Connecting…" for as
            // long as it is open, with a healthy socket and no error anywhere —
            // which is indistinguishable from a network problem and is the one
            // failure mode this whole layer must not have.
            //
            // So the envelope is re-read with a decoder that cannot fail, purely
            // to find out WHICH event was lost, and a lost bootstrap is
            // reported rather than logged.
            let envelope = try? JSONDecoder().decode(FrameEnvelope.self, from: data)
            let name = envelope?.t ?? "op \(envelope?.op ?? -1)"
            Self.trace("DECODE FAILED for \(name) (\(data.count) bytes): \(error)")
            Log.fault(.gateway, "could not decode \(public: name) (\(bytes: data.count)): \(error)")
            Self.log.error("gateway decode failed for \(name, privacy: .public): \(error)")

            if envelope?.t == "READY" {
                continuation?.yield(.disconnected(
                    reason: "Discord sent a bootstrap payload this client could not read.",
                    willRetry: false
                ))
                stop()
            }
        }
    }

    /// What kind of JSON value this is — for a trace that must name a shape
    /// without printing anybody's data.
    nonisolated private static func kind(of value: Any?) -> String {
        switch value {
        case nil, is NSNull: "null"
        case is String: "string"
        case let number as NSNumber: CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
        case is [Any]: "array"
        case is [String: Any]: "object"
        default: "other"
        }
    }

    /// What Discord holds for each of the account's own sessions — the one
    /// place it says back what this client published, as it stored it: the
    /// activity's name and lines, and the picture as resolved (`mp:` or an
    /// asset id). Diagnostic only, and gated on the trace sink.
    nonisolated private static func traceOwnSessions(_ data: Data) {
        guard traceSink != nil,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = root["d"] as? [[String: Any]]
        else { return }
        for session in sessions {
            let info = session["client_info"] as? [String: Any]
            let activities = (session["activities"] as? [[String: Any]] ?? []).map { activity in
                let assets = activity["assets"] as? [String: Any]
                return "\(activity["type"] ?? "?") \(activity["name"] ?? "?")"
                    + " | \(activity["details"] ?? "-") | \(activity["state"] ?? "-")"
                    + " | large=\(assets?["large_image"] ?? "-")"
                    + " | buttons=\((activity["buttons"] as? [Any])?.count ?? 0)"
            }
            // **The developer's stderr only, never the log**: these are the
            // reader's own activity lines — a game, a song, an editor's file
            // name — and a report must not carry them.
            traceSink?(
                "own session \(info?["client"] ?? "?")/\(info?["os"] ?? "?") \(session["status"] ?? "?"): "
                    + (activities.isEmpty ? "no activities" : activities.joined(separator: " ;; "))
            )
        }
    }

    /// Names the top-level keys of a READY payload, and the settings shape
    /// inside it. Diagnostic only, and gated on the trace sink being installed.
    nonisolated private static func traceReadyShape(_ data: Data) {
        guard isTracing else { return }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let body = root["d"] as? [String: Any]
        else { return }
        trace("READY keys: \(body.keys.sorted().joined(separator: ","))")
        // The reader's own applications as READY carries them — never captured,
        // and once decoded to nothing while Discord's rail showed one. Keys and
        // value kinds only.
        switch body["guild_join_requests"] {
        case let list as [Any]:
            let first = (list.first as? [String: Any]).map { entry in
                entry.keys.sorted().map { "\($0):\(Self.kind(of: entry[$0]))" }.joined(separator: ",")
            } ?? "-"
            trace("READY guild_join_requests: \(list.count) first={\(first)}")
        case nil:
            trace("READY guild_join_requests: absent")
        case let other?:
            trace("READY guild_join_requests: \(Self.kind(of: other))")
        }
        if let settings = body["user_settings"] as? [String: Any] {
            let folders = settings["guild_folders"] as? [Any]
            trace("READY user_settings keys: \(settings.keys.sorted().joined(separator: ","))")
            trace("READY guild_folders: \(folders?.count.description ?? "absent")")
        } else {
            trace("READY user_settings: ABSENT")
        }
        if let proto = body["user_settings_proto"] as? String {
            trace("READY user_settings_proto: \(proto.count) base64 chars")
        }
        // **The main gateway's session id, to compare against the voice one.**
        // Every voice IDENTIFY this client sends uses the session id off our
        // own `VOICE_STATE_UPDATE`, on the belief that it is this same string.
        // A Go Live stream identifying with it is refused `4006 Session is no
        // longer valid.`, and "the two are not the same string" is the first
        // thing that has to be ruled out — it cannot be, without both in one
        // log. It is already beside the voice one in the identify line.
        if let session = body["session_id"] as? String {
            trace("READY session_id: \(session)")
        }
    }

    /// The event name, for a frame this client wants written down whole.
    ///
    /// Read off the decoded payload rather than off the envelope, so the cost
    /// is a switch on an enum the frame already built rather than a second
    /// parse of every frame that arrives.
    nonisolated private static func streamEventName(of frame: GatewayFrame) -> String? {
        // Read off the name rather than the payload case, so an event this
        // client does not decode is written down too — the set of Go Live
        // events is not settled here, and a name in the trace is how the next
        // one gets found.
        guard let name = frame.name, name.hasPrefix("STREAM_") else { return nil }
        return name
    }

    /// Writes a Go Live frame's payload down **verbatim**, less the token.
    ///
    /// **Every wire fact this client has about Go Live is documentation rather
    /// than a capture**, and that is the one shape of knowledge this project
    /// has repeatedly found to be wrong — a stream's `rtc_server_id`, the key's
    /// grammar, which of these frames carries what. §"Print the frame, do not
    /// infer it": one raw READY line killed two hypotheses about the camera
    /// after three sessions of reading the code, and it had been arriving all
    /// along.
    ///
    /// These frames are small, there are four of them per share, and one of
    /// them arrives whenever anybody else in the channel starts sharing — so a
    /// capture costs nothing and does not need us to be the one sharing.
    ///
    /// **The token is replaced by its length.** `STREAM_SERVER_UPDATE` carries
    /// a media credential in the clear, and a trace line is a file, a screen
    /// share and a sysdiagnose. The key is kept: it is an identifier, it is how
    /// whose stream this is gets read, and its grammar is one of the things
    /// being captured.
    nonisolated private static func traceStreamFrame(_ name: String, _ data: Data) {
        guard isTracing else { return }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var body = root["d"] as? [String: Any]
        else {
            trace("\(name): payload is not an object")
            return
        }
        if let token = body["token"] as? String {
            body["token"] = "<\(token.count) chars>"
        }
        guard
            let redacted = try? JSONSerialization.data(
                withJSONObject: body, options: [.sortedKeys]
            ),
            let text = String(data: redacted, encoding: .utf8)
        else {
            trace("\(name) keys: \(body.keys.sorted().joined(separator: ","))")
            return
        }
        trace("\(name) \(text)")
    }

    private func inflate(_ frame: Data) -> Data? {
        guard let inflater else { return frame }
        do {
            let result = try inflater.push(frame)
            Self.trace("inflate \(frame.count) -> \(result.map { String($0.count) } ?? "partial")")
            return result
        } catch {
            Self.trace("inflate failed: \(error)")
            Log.fault(.gateway, "the compression stream failed: \(error)")
            Self.log.error("inflate failed: \(error)")
            // A corrupt stream cannot be recovered by continuing to read it —
            // the shared dictionary is now wrong for every following frame.
            scheduleReconnect(reason: "compression stream failed")
            return nil
        }
    }

    private func process(_ frame: GatewayFrame) {
        switch frame.payload {
        case .hello(let hello):
            Self.trace("hello, interval=\(hello.heartbeat_interval)ms")
            startHeartbeat(interval: hello.heartbeat_interval / 1000)
            if sessionID != nil, sequence != nil {
                sendResume()
            } else {
                sendIdentify()
            }

        case .heartbeatAck:
            lastHeartbeatAcknowledged = true

        case .reconnect:
            scheduleReconnect(reason: "server asked for a reconnect", resumable: true)

        case .invalidSession(let resumable):
            Log.info(.gateway, "session invalidated, resumable=\(resumable)")
            if !resumable { sessionID = nil; sequence = nil }
            scheduleReconnect(reason: "session invalidated", resumable: resumable)

        case .ready(let ready):
            Self.trace("READY guilds=\(ready.guilds?.count ?? 0) dms=\(ready.private_channels?.count ?? 0)")
            Log.info(.gateway, "READY guilds=\(ready.guilds?.count ?? 0) dms=\(ready.private_channels?.count ?? 0)")
            reconnectAttempt = 0
            sessionID = ready.session_id
            // A new session holds no subscriptions: every guild asks for its
            // threads again on its next subscribe.
            threadSubscribedGuilds.removeAll()
            resumeURL = ready.resume_gateway_url
            currentUserID = ready.user.id
            // **The order the merged arrays in `READY_SUPPLEMENTAL` are indexed
            // against.** Kept here rather than derived there, because that
            // payload's own guild list is a different array that happens to
            // agree — see `ReadySupplementalSnapshot`.
            readyGuildIDs = (ready.guilds ?? []).map(\.id)
            continuation?.yield(.ready(ReadySnapshot(payload: ready)))

        case .readySupplemental(let supplemental):
            let snapshot = ReadySupplementalSnapshot(
                payload: supplemental, guildOrder: readyGuildIDs
            )
            Self.trace(
                "READY_SUPPLEMENTAL voice=\(snapshot.voiceStates.count) "
                + "members=\(snapshot.membersByGuild.values.reduce(0) { $0 + $1.count }) "
                + "presences=\(snapshot.presences.count) "
                + "dms=\(snapshot.privateChannels.count)"
            )
            continuation?.yield(.readySupplemental(snapshot))

        case .resumed:
            Log.info(.gateway, "resumed")
            reconnectAttempt = 0
            continuation?.yield(.resumed)

        default:
            if let update = GatewayUpdate(frame.payload, currentUserID: currentUserID) {
                continuation?.yield(.update(update))
            }
        }
    }

    // MARK: Sending

    private func sendIdentify() {
        struct Identify: Encodable {
            var op = 2
            var d: Data

            struct Data: Encodable {
                var token: String
                var capabilities: Int
                var properties: [String: JSONScalar]
                var compress = false
                var presence: Presence

                struct Presence: Encodable {
                    var status = "online"
                    var since = 0
                    var activities: [String] = []
                    var afk = false
                }
            }
        }
        guard let token else { return }
        send(Identify(d: .init(
            token: token,
            // The capability bitfield the current web client sends. It tells the
            // gateway which payload shapes this client understands — an older
            // value gets an older READY shape, which decodes but is missing
            // fields this app reads.
            capabilities: 1_734_653,
            properties: metadata.identifyProperties,
            presence: .init()
        )))
    }

    private func sendResume() {
        struct Resume: Encodable {
            var op = 6
            var d: Data

            struct Data: Encodable {
                var token: String
                var session_id: String
                var seq: Int
            }
        }
        guard let token, let sessionID, let sequence else {
            sendIdentify()
            return
        }
        send(Resume(d: .init(token: token, session_id: sessionID, seq: sequence)))
    }

    /// Subscribes to a guild's member list.
    ///
    /// Asks for specific members by id — op 8, `REQUEST_GUILD_MEMBERS`.
    ///
    /// **The other half of op 14, not a replacement for it.** The subscription
    /// below answers for a *range of the roster*, which is what a member list
    /// needs; it says nothing about somebody who posted an hour ago and is
    /// three hundred rows down, or offline, or not in the list at all. Those
    /// people arrived at the transcript with a user record and no member
    /// record — so no roles, which is no name colour, no role icon and an empty
    /// Roles section on their profile, for the whole session. Every counter
    /// read healthy; the member simply was not there.
    ///
    /// `user_ids` is the addressed form and answers in one `GUILD_MEMBERS_CHUNK`
    /// per hundred ids. `presences: true` is what Discord's own client sends —
    /// the note below about op 8 answering without presences is true of the
    /// *query* form, and is why the roster is still built on op 14.
    ///
    /// The nonce comes back on the chunk. Nothing here reads it: the chunk
    /// merges into the same tables every other member source does, so there is
    /// no request to correlate it with.
    /// Who in a server goes by a name — Discord's `requestMembers` (op 8 with a
    /// `query`), what its own mention box and search ask. Twenty-five at most, the
    /// limit its callers use. The answer merges into the tables like any other chunk.
    public func queryGuildMembers(guildID: GuildID, query: String, limit: Int = 25) {
        guard !query.isEmpty else { return }
        struct Request: Encodable {
            var op = 8
            var d: Data

            struct Data: Encodable {
                var guild_id: String
                var query: String
                var limit: Int
                var presences = true
            }
        }
        send(Request(d: .init(guild_id: guildID.description, query: query, limit: limit)))
    }

    public func requestGuildMembers(guildID: GuildID, userIDs: [UserID]) {
        guard !userIDs.isEmpty else { return }
        struct Request: Encodable {
            var op = 8
            var d: Data

            struct Data: Encodable {
                var guild_id: String
                var user_ids: [String]
                var presences = true
                var limit = 0
            }
        }
        // Discord caps one request at a hundred ids and answers a longer one
        // with nothing at all.
        for chunk in stride(from: 0, to: userIDs.count, by: 100) {
            let slice = userIDs[chunk..<min(chunk + 100, userIDs.count)]
            send(Request(d: .init(
                guild_id: guildID.description,
                user_ids: slice.map(\.description)
            )))
        }
    }

    /// Asks for these servers' soundboards — Discord's op 31,
    /// `REQUEST_SOUNDBOARD_SOUNDS`, exactly as its client sends it when the
    /// picker opens: `requestSoundboardSounds(e){this.send(31,{guild_ids:e})}`,
    /// the ids as strings. Answered by one `SOUNDBOARD_SOUNDS` dispatch per
    /// server.
    public func requestForumUnreads(
        guildID: GuildID,
        channelID: ChannelID,
        threads: [(threadID: ChannelID, ackMessageID: MessageID)]
    ) {
        guard !threads.isEmpty else { return }
        Self.trace("request forum unreads for \(threads.count) posts in \(channelID)")
        send(ForumUnreadsRequest(guildID: guildID, channelID: channelID, threads: threads))
    }

    /// Asks for a private channel's call: Discord's op 13, `CALL_CONNECT`,
    /// exactly as its client sends it (`callConnect(e){this.send(13,
    /// {channel_id:e})}`). Answered with `CALL_CREATE`, the people already in
    /// the call included, when one is going; with nothing when none is.
    ///
    /// **Without it a call already running is invisible**: nothing else tells
    /// a client that just connected about a DM call started before it did
    /// (docs/ACTIVITIES-CALLS-PICKER.md, decision 9).
    public func callConnect(channelID: ChannelID) {
        struct Request: Encodable {
            var op = 13
            var d: Data

            struct Data: Encodable {
                var channel_id: String
            }
        }
        send(Request(d: .init(channel_id: channelID.description)))
    }

    public func requestSoundboardSounds(guildIDs: [GuildID]) {
        guard !guildIDs.isEmpty else { return }
        struct Request: Encodable {
            var op = 31
            var d: Data

            struct Data: Encodable {
                var guild_ids: [String]
            }
        }
        Self.trace("request soundboards for \(guildIDs.count) servers")
        send(Request(d: .init(guild_ids: guildIDs.map(\.description))))
    }

    /// The op-14 lazy subscription, which is the only route that answers with
    /// members **and their presences**. The documented op-8 request answers with
    /// members and no presence for them, so a roster built on it shows everyone
    /// offline.
    ///
    /// `ranges` are the pages of the channel's list to keep current, each a
    /// `[first, last]` pair — see `MemberList.pages(visible:margin:)`. Every
    /// page wanted, every time: Discord's own client never sends a difference.
    public func subscribeToMemberList(
        guildID: GuildID,
        channelID: ChannelID,
        ranges: [[Int]]
    ) {
        subscribeToMemberLists(guildID: guildID, channels: [channelID: ranges])
    }

    /// The same subscription for several of a server's channels at once —
    /// **Discord keeps its last five subscribed** (docs/BETA3.md D6), so a list
    /// the reader goes back to has stayed current and fills at once rather
    /// than waiting for a fresh `SYNC`.
    public func subscribeToMemberLists(
        guildID: GuildID,
        channels: [ChannelID: [[Int]]]
    ) {
        struct Subscribe: Encodable {
            var op = 14
            var d: Data

            struct Data: Encodable {
                var guild_id: String
                var typing = true
                /// Sent once per guild per session, as Discord's client does
                /// (`subscribeToGuild`): it is what makes Discord send each
                /// active thread's newest message (`THREAD_LIST_SYNC`) for the
                /// cards in its parent channel. Left out after, so repeating a
                /// member-list subscribe never asks for the sync again.
                var threads: Bool?
                var activities = true
                var channels: [String: [[Int]]]
            }
        }
        // **An empty range list is never sent**: Discord can't decode one, and
        // answers with 4002 and the end of the session (docs/BETA3.md §7, R2).
        var wire: [String: [[Int]]] = [:]
        for (channelID, ranges) in channels where !ranges.isEmpty { wire[channelID.description] = ranges }
        guard !wire.isEmpty else { return }
        let asksForThreads = threadSubscribedGuilds.insert(guildID).inserted
        send(Subscribe(d: .init(
            guild_id: guildID.description,
            threads: asksForThreads ? true : nil,
            channels: wire
        )))
    }

    /// The guilds subscribed with `threads` this session.
    private var threadSubscribedGuilds: Set<GuildID> = []

    /// Asks for the status line and session clock of every voice channel in a
    /// guild.
    ///
    /// **Opcode 43, and the only route to either fact for a guild the reader
    /// has been away from.** A status arrives on the READY guild's channel
    /// objects and then only as `VOICE_CHANNEL_STATUS_UPDATE`, which Discord
    /// sends for *subscribed* guilds — so a label somebody set in a server the
    /// reader had not opened this session is invisible until this is asked.
    /// The session clock has no other source at all: no channel object anywhere
    /// carries it.
    ///
    /// Opcode 36 does half of this and is deprecated in favour of it. The answer
    /// comes back as `CHANNEL_INFO`.
    public func requestChannelInfo(guildID: GuildID) {
        struct Request: Encodable {
            var op = 43
            var d: Data

            struct Data: Encodable {
                var guild_id: String
                /// **Both, always.** The answer is treated as authoritative for
                /// every field it was asked for — see `GatewayUpdate` — and
                /// asking for one would make it authoritative for one.
                var fields = ["status", "voice_start_time"]
            }
        }
        send(Request(d: .init(guild_id: guildID.description)))
    }

    /// Joins, moves between, or leaves a voice channel.
    ///
    /// **Op 4 over the socket, and there is no REST route for it.** This is the
    /// whole of joining a call: the server answers with our own
    /// `VOICE_STATE_UPDATE` — carrying the session id the media handshake
    /// identifies with — and a `VOICE_SERVER_UPDATE` carrying the endpoint and
    /// the token. The two arrive in **either order**.
    ///
    /// - Parameters:
    ///   - guildID: nil for a direct-message call, where the channel is the
    ///     whole address.
    ///   - channelID: nil to **leave**. Discord has no leave op; a null channel
    ///     is it.
    ///   - selfVideo: whether the camera is on. Sent with the join rather than
    ///     afterwards where possible — the media session is negotiated for
    ///     video or not at identify time.
    ///   - flags: what this client says about clips — `VoiceStateFlags`.
    public func updateVoiceState(
        guildID: GuildID?,
        channelID: ChannelID?,
        selfMute: Bool,
        selfDeaf: Bool,
        selfVideo: Bool = false,
        flags: VoiceStateFlags = []
    ) {
        struct Update: Encodable {
            var op = 4
            var d: Data

            /// **Six keys, and both ids are written even when they are
            /// absent.** Swift omits a nil optional, and this payload needs
            /// `guild_id: null` on the wire rather than no `guild_id` at all —
            /// that is how a direct-message call is distinguished from a
            /// malformed one, and how leaving is distinguished from a payload
            /// that forgot to say where.
            ///
            /// **`flags` is Discord's own, every time** — its `voiceStateUpdate`
            /// writes `{guild_id, channel_id, self_mute, self_deaf,
            /// self_video, flags}` with `flags` defaulting to 0 (web build
            /// 641803, read in docs/CLIPS-PRESENCE.md Phase 3). An earlier
            /// version sent it on a guess and was rightly reverted; this one
            /// is read off the client. `preferred_region` stays out: Discord
            /// sends it only behind a check this client has not read.
            struct Data: Encodable {
                var guild_id: String?
                var channel_id: String?
                var self_mute: Bool
                var self_deaf: Bool
                var self_video: Bool
                var flags: Int

                enum CodingKeys: String, CodingKey {
                    case guild_id, channel_id, self_mute, self_deaf, self_video, flags
                }

                func encode(to encoder: any Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(guild_id, forKey: .guild_id)
                    try container.encode(channel_id, forKey: .channel_id)
                    try container.encode(self_mute, forKey: .self_mute)
                    try container.encode(self_deaf, forKey: .self_deaf)
                    try container.encode(self_video, forKey: .self_video)
                    try container.encode(flags, forKey: .flags)
                }
            }
        }
        Self.trace("voice state -> guild=\(guildID?.description ?? "-") channel=\(channelID?.description ?? "-") flags=\(flags.rawValue)")
        send(Update(d: .init(
            guild_id: guildID.map { String($0.rawValue) },
            channel_id: channelID.map { String($0.rawValue) },
            self_mute: selfMute,
            self_deaf: selfDeaf,
            self_video: selfVideo,
            flags: flags.rawValue
        )))
    }

    /// Opens a Go Live stream, and asks the server for a media session to
    /// carry it.
    ///
    /// **Op 18, and it is not the camera.** Turning a camera on is a switch on
    /// the call's own media session — `self_video` at op 4. A screen share is a
    /// *second* media session with its own RTC server, its own endpoint, its
    /// own token and its own MLS group, and this is what asks for one. The
    /// server answers in two frames that arrive in **either order**, exactly as
    /// a call's credential does:
    ///
    /// - `STREAM_CREATE` — the stream key and the `rtc_server_id`
    /// - `STREAM_SERVER_UPDATE` — the endpoint and the token
    ///
    /// **This payload is documentation, not a capture.** Everything else this
    /// client sends was read off a wire first; these three fields were not, and
    /// §"Wire facts are captured, never assumed" says that is a difference
    /// worth writing down rather than leaving for a reader to assume. What the
    /// server sends back *is* captured — `traceStreamFrame` writes every Go
    /// Live frame down verbatim.
    ///
    /// - Parameters:
    ///   - guildID: nil for a direct-message call, which makes this a stream of
    ///     type `call` rather than `guild`. The two produce the two different
    ///     stream-key grammars — see `StreamEventDTO`.
    ///   - preferredRegion: the region the call is already in. Sent so the
    ///     stream's own server is allocated beside the call's rather than
    ///     across the world from it.
    public func createStream(
        guildID: GuildID?,
        channelID: ChannelID,
        preferredRegion: String?
    ) {
        struct Create: Encodable {
            var op = 18
            var d: Body

            /// **`guild_id` is written even when it is absent**, exactly as
            /// `updateVoiceState`'s body writes it. Swift omits a nil optional,
            /// and this payload needs `guild_id: null` on the wire rather than
            /// no `guild_id` at all — the same distinction that tells a
            /// direct-message call from a malformed one, one opcode over.
            struct Body: Encodable {
                var type: String
                var guild_id: String?
                var channel_id: String
                var preferred_region: String?

                enum CodingKeys: String, CodingKey {
                    case type, guild_id, channel_id, preferred_region
                }

                func encode(to encoder: any Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(type, forKey: .type)
                    try container.encode(guild_id, forKey: .guild_id)
                    try container.encode(channel_id, forKey: .channel_id)
                    // Omitted when absent rather than sent null: nothing has
                    // captured what the server does with an explicit null here,
                    // and the key is optional in every description of it.
                    try container.encodeIfPresent(
                        preferred_region, forKey: .preferred_region
                    )
                }
            }
        }
        Self.trace(
            "stream create -> guild=\(guildID?.description ?? "-") channel=\(channelID) "
            + "region=\(preferredRegion ?? "-")"
        )
        send(Create(d: .init(
            type: guildID == nil ? "call" : "guild",
            guild_id: guildID.map { String($0.rawValue) },
            channel_id: String(channelID.rawValue),
            preferred_region: preferredRegion
        )))
    }

    /// Asks to watch somebody else's Go Live stream.
    ///
    /// **Op 20, and it is what turns a badge into a picture.** A stream is a
    /// media session of its own: knowing that somebody is live — which comes
    /// from `self_stream` on their voice state, not from a stream event —
    /// carries no address, no key and no token. This asks for them, and the
    /// server answers with the same two frames a stream's owner gets:
    /// `STREAM_CREATE` with the RTC ids, and `STREAM_SERVER_UPDATE` with the
    /// endpoint and token, in **either order**.
    ///
    /// **The key is built, not received.** Nothing dispatches a stream event to
    /// somebody who is not already watching, so a viewer never sees the owner's
    /// `stream_key` before asking for it. Its grammar is captured — see
    /// `StreamEventDTO` — and `GoLiveKey` is the one place it is assembled.
    ///
    /// Like opcode 18, this payload is **documentation rather than capture**:
    /// what comes back is written down verbatim by `traceStreamFrame`, and that
    /// is what will correct it.
    public func watchStream(streamKey: String) {
        struct Watch: Encodable {
            var op = 20
            var d: Body
            struct Body: Encodable { var stream_key: String }
        }
        Self.trace("stream watch -> \(streamKey)")
        send(Watch(d: .init(stream_key: streamKey)))
    }

    /// Ends a Go Live stream.
    ///
    /// **Op 19, and it is addressed by key rather than by channel.** One
    /// account can hold a stream in more than one place, so the key is the only
    /// thing that names which — and it is the server's own string, echoed back
    /// exactly as `STREAM_CREATE` sent it rather than rebuilt from its parts.
    public func deleteStream(streamKey: String) {
        struct Delete: Encodable {
            var op = 19
            var d: Body
            struct Body: Encodable { var stream_key: String }
        }
        Self.trace("stream delete -> \(streamKey)")
        send(Delete(d: .init(stream_key: streamKey)))
    }

    /// Publishes the reader's own status and custom status.
    ///
    /// **Op 3, over the socket, and there is no REST equivalent that works.**
    /// The settings route stores a status but does not broadcast one, so an
    /// account that changed status there stays green to everyone else until it
    /// reconnects. This is the presence every other client sees.
    ///
    /// A custom status is an activity of kind 4 whose `state` is the text — the
    /// same shape it arrives in. Sent as an empty list when there is none,
    /// because omitting the key leaves the previous activity standing.
    /// Publishes the reader's presence.
    ///
    /// **`activities` is an ARRAY and the whole array is replaced.** A custom
    /// status is one entry (type 4), a running game is another (type 0) and an
    /// embedded activity is a third; sending any one alone erases the rest,
    /// which is why they all cross here together rather than through calls that
    /// would fight.
    public func updatePresence(
        status: String,
        customStatus: String?,
        customEmoji: EmojiRef?,
        activities richPresences: [RichPresenceActivity] = []
    ) {
        guard let frame = Self.presenceFrame(
            status: status, customStatus: customStatus, customEmoji: customEmoji, activities: richPresences
        ) else { return }
        send(encoded: frame)
    }

    /// Opcode 3's frame, encoded — apart from the socket so the wire it writes
    /// can be read back in a test.
    static func presenceFrame(
        status: String,
        customStatus: String?,
        customEmoji: EmojiRef?,
        activities richPresences: [RichPresenceActivity]
    ) -> Data? {
        struct Update: Encodable {
            var op = 3
            var d: Data

            struct Data: Encodable {
                var status: String
                var since = 0
                var afk = false
                var activities: [Activity]
            }

            /// One entry. A custom status fills `state` and `emoji`; a rich
            /// presence fills the rest. **Every nil field is omitted** — the
            /// encoder drops them — because an explicit null is not the same as
            /// an absent key to the gateway.
            struct Activity: Encodable {
                var name: String
                var type: Int
                var state: String?
                var details: String?
                var emoji: Emoji?
                var assets: Assets?
                var timestamps: Timestamps?
                var party: Party?
                var buttons: [String]?
                var application_id: String?
                /// A Spotify session's track, its `PLAY | SYNC` flags and what
                /// a listener needs to follow it — absent on everything else.
                var sync_id: String?
                var flags: Int?
                var metadata: Metadata?
                /// A Streaming activity's stream, and where the two lines link
                /// to — a custom presence's (DESIGN-NOTES §11).
                var url: String?
                var details_url: String?
                var state_url: String?
                /// Which line names it in a member list — a local app's
                /// `status_display_type`, passed through.
                var status_display_type: Int?
            }

            /// Spotify's, as Discord's `getActivity` writes it — `button_urls`
            /// included, empty — or a presence's buttons' links alone, as
            /// Vencord's CustomRPC writes them.
            struct Metadata: Encodable {
                var context_uri: String?
                var album_id: String?
                var artist_ids: [String]?
                var type: String?
                var button_urls: [String]
            }

            /// **`id` and `animated` as well as the name.** A custom emoji in a
            /// status is `{name, id, animated}`; this carried the name alone, so
            /// every custom one was broadcast as a literal shortcode and drew as
            /// text on everybody else's roster. Both extra keys are omitted for a
            /// Unicode emoji, which is what the encoder does with a nil.
            struct Emoji: Encodable {
                var name: String
                var id: String?
                var animated: Bool?
            }

            struct Assets: Encodable {
                var large_image: String?
                var large_text: String?
                var large_url: String?
                var small_image: String?
                var small_text: String?
                var small_url: String?
            }

            /// **Milliseconds.** Seconds would date the activity to 1970 and
            /// every elapsed clock would read as decades.
            struct Timestamps: Encodable {
                var start: Int?
                var end: Int?
            }

            struct Party: Encodable {
                var id: String?
                var size: [Int]?
            }
        }

        var activities: [Update.Activity] = []
        if customStatus?.isEmpty == false || customEmoji != nil {
            activities.append(Update.Activity(
                name: "Custom Status",
                type: 4,
                state: customStatus.flatMap { $0.isEmpty ? nil : $0 },
                emoji: customEmoji.map {
                    Update.Emoji(
                        name: $0.name,
                        id: $0.id.map { String($0.rawValue) },
                        // Sent only when it is true: an explicit `false` on a
                        // still emoji is a key Discord's own client does not
                        // send.
                        animated: $0.isAnimated ? true : nil
                    )
                }
            ))
        }
        for activity in richPresences {
            activities.append(Update.Activity(
                name: activity.name,
                type: activity.type,
                state: activity.state,
                details: activity.details,
                assets: activity.assets.map {
                    Update.Assets(
                        large_image: $0.largeImage,
                        large_text: $0.largeText,
                        large_url: $0.largeURL?.absoluteString,
                        small_image: $0.smallImage,
                        small_text: $0.smallText,
                        small_url: $0.smallURL?.absoluteString
                    )
                },
                timestamps: activity.timestamps.map {
                    Update.Timestamps(start: $0.start, end: $0.end)
                },
                // **An empty object is not the same as an absent one.** An
                // app that sends a party with nothing in it — Watch Together
                // sends only an id, and a non-string one is dropped — would
                // otherwise put `"party":{}` on the wire, which is a claim
                // about a party rather than silence about one.
                party: activity.party.flatMap {
                    $0.id == nil && $0.size == nil
                        ? nil : Update.Party(id: $0.id, size: $0.size)
                },
                // Empty is omitted, not sent as `[]`: an empty array is a claim
                // that there are no buttons, and Discord is happier with silence.
                buttons: activity.buttons.isEmpty ? nil : Array(activity.buttons.prefix(2)),
                application_id: activity.applicationID?.description,
                sync_id: activity.syncID,
                flags: activity.flags == 0 ? nil : activity.flags,
                metadata: activity.metadata.map {
                    Update.Metadata(
                        context_uri: $0.contextURI,
                        album_id: $0.albumID,
                        artist_ids: $0.artistIDs,
                        type: $0.type,
                        button_urls: []
                    )
                } ?? (activity.buttonURLs.isEmpty ? nil : Update.Metadata(
                    button_urls: activity.buttonURLs.prefix(2).map(\.absoluteString)
                )),
                url: activity.url?.absoluteString,
                details_url: activity.detailsURL?.absoluteString,
                state_url: activity.stateURL?.absoluteString,
                status_display_type: activity.statusDisplayType
            ))
        }
        return try? JSONEncoder().encode(Update(d: .init(status: status, activities: activities)))
    }

    private func send(_ value: some Encodable) {
        do {
            send(encoded: try JSONEncoder().encode(value))
        } catch {
            Self.log.error("gateway encode failed: \(error)")
        }
    }

    private func send(encoded data: Data) {
        guard let task, !isStopped else { return }
        // The payload is never logged. An IDENTIFY carries the account token in
        // the clear, and a log line is a file, a screen share and a sysdiagnose.
        Self.trace("send \(data.count) bytes")
        noteSend(data)
        task.send(.data(data)) { error in
            if let error {
                GatewaySocket.trace("send failed: \(error.localizedDescription)")
                Self.log.error("gateway send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The last few payloads sent, by op and size — **never their contents**
    /// (an IDENTIFY carries the token). Said beside any close Discord explains
    /// with a 4xxx code, so a payload it refused names itself: three of his
    /// "Reconnecting…" were a member-list resync's op 14, closed 4002 a sixth
    /// of a second later (docs/BETA3.md §7, R2).
    private var recentSends: [(op: Int, bytes: Int, at: ContinuousClock.Instant)] = []

    private func noteSend(_ data: Data) {
        recentSends.append((op: Self.opcode(in: data) ?? -1, bytes: data.count, at: .now))
        if recentSends.count > 6 { recentSends.removeFirst(recentSends.count - 6) }
    }

    /// The `op` of an encoded payload, read without decoding the rest.
    static func opcode(in data: Data) -> Int? {
        guard let key = data.range(of: Data("\"op\":".utf8)) else { return nil }
        var index = key.upperBound
        while index < data.endIndex, data[index] == 0x20 { index += 1 }
        var value = 0
        var digits = 0
        while index < data.endIndex, (0x30...0x39).contains(data[index]), digits < 4 {
            value = value * 10 + Int(data[index] - 0x30)
            digits += 1
            index += 1
        }
        return digits > 0 ? value : nil
    }

    /// "op 14 (365 B, 0.15 s before), …", newest first.
    private func recentSendsSummary() -> String {
        let now = ContinuousClock.now
        return recentSends.reversed().map { send in
            let seconds = Double((now - send.at).components.attoseconds) / 1e18
                + Double((now - send.at).components.seconds)
            return "op \(send.op) (\(send.bytes) B, \(String(format: "%.2f", seconds)) s before)"
        }
        .joined(separator: ", ")
    }

    // MARK: Heartbeat

    private func startHeartbeat(interval: Double) {
        heartbeatTask?.cancel()
        lastHeartbeatAcknowledged = true
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            // The first beat is jittered, which Discord's own protocol asks for:
            // without it every client that reconnects after an outage beats in
            // lockstep and hits the gateway in one wave.
            let jitter = Double.random(in: 0...1)
            try? await Task.sleep(for: .seconds(interval * jitter))
            while !Task.isCancelled, await !self.isStopped {
                await self.beat()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func beat() {
        /// **`d` is always written, as `null` before the first dispatch.** A
        /// synthesized `Encodable` leaves a nil optional out, so a beat that
        /// went before READY — the first beat is jittered, and can land a
        /// second after IDENTIFY while a 7 MB READY is still coming — was
        /// `{"op":1}`, which Discord can't decode: 4002, and the session gone
        /// (his log, 2026-11-19: "op 1 (8 B, 0.81 s before)").
        struct Heartbeat: Encodable {
            var op = 1
            var d: Int?

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(op, forKey: .op)
                try container.encode(d, forKey: .d)
            }

            private enum CodingKeys: String, CodingKey { case op, d }
        }
        // A missed acknowledgement means the connection is a zombie: the socket
        // is open, writes succeed, and nothing is arriving. Only the missing ACK
        // reveals it, which is the entire reason the protocol has one.
        guard lastHeartbeatAcknowledged else {
            scheduleReconnect(reason: "heartbeat was not acknowledged", resumable: true)
            return
        }
        lastHeartbeatAcknowledged = false
        send(Heartbeat(d: sequence))
    }

    // MARK: Failure and retry

    private func socketFailed(_ error: any Error) {
        guard !isStopped else { return }

        // **The close code is on the TASK, not in the error.** A gateway that
        // rejects an IDENTIFY closes the socket, and `receive()` then fails with
        // a generic `NSPOSIXErrorDomain 57 "Socket is not connected"` — the
        // 4004 that says *why* is only in `closeCode`.
        //
        // Reading the error instead is how a rejected token becomes an infinite
        // reconnect loop that reports "Connecting…" forever: the check for 4004
        // never matches, so every rejection looks like a transient network
        // failure worth retrying.
        let closeCode = task?.closeCode ?? .invalid
        let closeReason = task?.closeReason
            .flatMap { String(data: $0, encoding: .utf8) }
        let nsError = error as NSError
        Self.trace(
            "socket failed: close=\(closeCode.rawValue) reason=\(closeReason ?? "-") "
            + "domain=\(nsError.domain) code=\(nsError.code)"
        )
        // INVARIANTS §1.5: never a close code without its reason.
        Log.info(
            .gateway,
            "socket closed: code=\(closeCode.rawValue) reason=\(public: closeReason ?? "-") "
                + "error=\(public: nsError.domain) \(nsError.code)"
        )
        if (4000..<5000).contains(closeCode.rawValue), !recentSends.isEmpty {
            Log.info(.gateway, "sent before the close: \(public: recentSendsSummary())")
        }

        if let outcome = CloseOutcome(closeCode: closeCode.rawValue) {
            switch outcome {
            case .authentication:
                continuation?.yield(.authenticationFailed)
                stop()
                return
            case .fatal(let reason):
                continuation?.yield(.disconnected(reason: reason, willRetry: false))
                stop()
                return
            case .resumable:
                break
            case .freshSession:
                sessionID = nil
                sequence = nil
            }
        }

        scheduleReconnect(
            reason: closeReason ?? Self.describe(closeCode: closeCode.rawValue)
                ?? error.localizedDescription,
            resumable: sessionID != nil
        )
    }

    /// What a gateway close code means for the retry policy.
    ///
    /// Discord's codes divide into three groups and treating them alike is the
    /// difference between an app that recovers and one that loops: a token that
    /// will never work must not be retried, and a session that cannot be resumed
    /// must not be resumed.
    enum CloseOutcome {
        case authentication
        case fatal(String)
        case resumable
        case freshSession

        init?(closeCode: Int) {
            switch closeCode {
            case 4004:
                self = .authentication
            case 4010, 4011, 4013, 4014:
                self = .fatal(GatewaySocket.describe(closeCode: closeCode) ?? "Gateway refused this client.")
            case 4007, 4009:
                // The sequence or the session is gone; reconnecting is right but
                // resuming is not.
                self = .freshSession
            case 4000, 4001, 4002, 4003, 4005, 4008:
                self = .resumable
            default:
                return nil
            }
        }
    }

    nonisolated static func describe(closeCode: Int) -> String? {
        switch closeCode {
        case 4000: "The gateway reported an unknown error."
        case 4001: "The gateway rejected an opcode this client sent."
        case 4002: "The gateway could not decode a payload this client sent."
        case 4003: "The gateway received a payload before authentication."
        case 4004: "The session token was rejected."
        case 4005: "The gateway received a second authentication."
        case 4007: "The resume sequence was invalid."
        case 4008: "Too many payloads were sent too quickly."
        case 4009: "The session timed out."
        case 4010: "The shard this client asked for is invalid."
        case 4011: "This account needs sharding."
        case 4013: "The gateway rejected the requested intents."
        case 4014: "The gateway refused the requested privileged intents."
        default: nil
        }
    }

    private func scheduleReconnect(reason: String, resumable: Bool = true) {
        guard !isStopped, reconnectTask == nil else { return }
        heartbeatTask?.cancel()
        heartbeatTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil

        reconnectAttempt += 1
        // A client that retries forever without ever coming up reports
        // "Connecting…" indefinitely, which tells the reader nothing and costs a
        // connection attempt every few seconds for as long as the app is open.
        // After enough attempts it says so and stops.
        if reconnectAttempt > Self.maximumReconnectAttempts {
            Self.trace("giving up after \(reconnectAttempt) attempts")
            Log.fault(.gateway, "gave up after \(reconnectAttempt) attempts: \(public: reason)")
            continuation?.yield(.disconnected(
                reason: "Could not reach Discord after several attempts. \(reason)",
                willRetry: false
            ))
            stop()
            return
        }
        // Exponential back-off with a ceiling and jitter. Without the ceiling a
        // long outage ends with the client asleep for an hour; without the
        // jitter every client returns simultaneously.
        let base = min(pow(2, Double(min(reconnectAttempt, 6))), 60)
        let delay = base * Double.random(in: 0.8...1.2)
        Log.info(
            .gateway,
            "reconnecting in \(delay, digits: 1)s, attempt \(reconnectAttempt), resume=\(resumable): \(public: reason)"
        )
        continuation?.yield(.disconnected(reason: reason, willRetry: true))

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            await self.finishReconnect(resuming: resumable)
        }
    }

    private func finishReconnect(resuming: Bool) {
        reconnectTask = nil
        guard !isStopped else { return }
        openSocket(resuming: resuming && sessionID != nil)
    }
}

/// Just enough of a frame to name it.
///
/// Every field optional and nothing nested, so this decoder cannot itself fail —
/// which is the entire point: it exists to identify a payload that the real
/// decoder could not read.
struct FrameEnvelope: Decodable, Sendable {
    var op: Int?
    var t: String?
    var s: Int?
}

/// READY, converted to domain values.
///
/// **Converted here, off the main actor.** READY carries every guild, channel,
/// role and read state the account has; doing that conversion on the main thread
/// is a visible stall at exactly the moment the window is trying to appear.
public struct ReadySnapshot: Sendable {
    public var currentUser: User
    /// This gateway session's id: what a running activity's participant
    /// record names, so the client can tell its own session from the same
    /// account elsewhere.
    public var sessionID: String?
    /// The reader's tier and age status, off READY's own `user` — the one
    /// object in the payload that carries them — and **nil where it did not**,
    /// so they merge into `AccountEntitlements` rather than overwrite it. An
    /// absent tier and a tier of zero lock the same perks for different reasons,
    /// and the session trace prints which one READY sent.
    public var premiumType: Int?
    public var ageVerificationStatus: Int?
    /// The reader's perks, off READY's own `user`; nil where it did not say.
    public var perks: AccountPerks?
    /// Whether the reader has confirmed an e-mail and holds a phone — off
    /// READY's own `user`, nil where it did not say. See `AccountVerification`.
    public var accountVerification: AccountVerification?
    /// The reader's custom typing indicator, off READY's own `user`; nil for
    /// the plain one.
    public var typingIndicatorStyle: TypingIndicatorStyle?
    /// What READY says the account and its servers are in — see `Experiments`.
    public var experiments: ExperimentSnapshot
    /// What Discord holds back by age in the reader's region. Empty when READY
    /// gated nothing or did not say.
    public var ageGatedFeatures: AgeGatedFeatures
    public var guilds: [Guild]
    public var channelsByGuild: [GuildID: [Channel]]
    /// The threads the account follows, per guild.
    ///
    /// **A user account is sent only the threads it has joined**, so this is the
    /// followed set at launch and not the guild's active threads. Kept apart
    /// from `channelsByGuild` for the reason `guildAvailable` states: a thread's
    /// parent is a channel, not a category.
    public var threadsByGuild: [GuildID: [Channel]]
    public var rolesByGuild: [GuildID: [RoleID: Role]]
    /// A server's own emoji and stickers, for the expression picker. Kept beside
    /// the guilds rather than on them, the way roles and members already are:
    /// these are per-guild collections that most of the app never reads, and a
    /// `Guild` copied on every scalar change should not carry thousands of them.
    public var emojisByGuild: [GuildID: [EmojiRef]]
    public var stickersByGuild: [GuildID: [StickerRef]]
    public var membersByGuild: [GuildID: [UserID: Member]]
    public var privateChannels: [Channel]
    public var users: [UserID: User]
    public var presences: [UserID: Presence]
    public var readStates: [ChannelID: ReadState]
    /// Each server's scheduled-events cursor — the non-channel read state of
    /// type 1, keyed by the server.
    public var guildEventAcks: [GuildID: MessageID]
    /// The account's `notification_settings.flags`, nil where READY sent none.
    public var notificationFlags: Int?
    public var settings: ClientSettings
    public var mutedGuildIDs: Set<GuildID>
    public var mutedChannelIDs: Set<ChannelID>
    /// Everything the reader has said about being interrupted, as one value —
    /// see `NotificationPreferences`. It carries the two mute sets above as
    /// well, because the policy takes all of it or none.
    public var notificationPreferences: NotificationPreferences
    /// The reader's whole settings record for each server they are in.
    ///
    /// **Not a duplicate of `notificationPreferences`.** That one is the
    /// *decision's* input — read on every arriving message, off a hot path, in
    /// a shape built for membership tests. This is the *editor's*: the server
    /// menu opens on one of these and shows nine fields at once, four of which
    /// the policy has no use for and therefore never carried.
    public var guildUserSettings: [GuildID: GuildUserSettings]
    /// Channels and categories the reader has opted into — the checkboxes and
    /// the Follow switches in Browse Channels. See `ChannelSettingsFlags`.
    public var followedChannelIDs: Set<ChannelID>
    /// Conversations the reader pinned to the top of the direct-message list.
    ///
    /// The same overrides `followedChannelIDs` is read out of, carrying a
    /// different bit — `ChannelSettingsFlags.favorited`, which Discord's UI
    /// calls Pin. They arrive under the private-channel pseudo-guild, whose
    /// entry sends `guild_id: null`.
    public var pinnedChannelIDs: Set<ChannelID>
    /// People the account has blocked, and people it has ignored.
    ///
    /// **Two independent facts on one list.** A relationship's `type` says
    /// blocked; `is_spam_request` and the ignore flag are separate — and one is
    /// not implied by the other, because ignoring a friend is a real state. A
    /// reader that took `type == 2` as covering both would silently un-ignore
    /// everybody on every launch.
    public var blockedUserIDs: Set<UserID>
    public var ignoredUserIDs: Set<UserID>
    /// What the account is to each person it has any relationship with.
    /// Absent means `.none`, which is what an empty table already says.
    public var relationships: [UserID: Relationship]
    /// What the reader has decided to call somebody, privately.
    ///
    /// **Not a server nickname and not their display name.** It rides the
    /// relationship, travels with the account and is visible to nobody else —
    /// which is why it lives beside `notes` rather than on `User`, where a
    /// merge from a guild payload would overwrite it.
    public var friendNicknames: [UserID: String]
    /// When each outstanding request was made, and Discord's two flags on it.
    ///
    /// **Sparse on purpose.** Only relationships with something to say carry an
    /// entry — see `RelationshipFacts.isNoteworthy` — so an account with two
    /// thousand friends and one pending request stores one row rather than two
    /// thousand and one.
    public var relationshipFacts: [UserID: RelationshipFacts]
    /// The account's private notes about people. READY carries the whole set,
    /// which is why the profile card never has to fetch one.
    public var notes: [UserID: String]
    /// The reader's own applications, keyed by the server applied to — see
    /// `OwnJoinRequest`.
    public var joinRequests: [GuildID: OwnJoinRequest]
    /// Every stage that was live when this session connected, keyed by its
    /// channel. See `StageInstance` for why the channel is the key.
    public var stages: [ChannelID: StageInstance]
    /// Each server's scheduled events, as READY carried them.
    public var scheduledEvents: [GuildID: [ScheduledEvent]]
    /// Each server's soundboard, where READY carried one.
    public var soundboardsByGuild: [GuildID: [SoundboardSound]]
    /// Who is already in a voice channel, keyed by the person. One flat table
    /// rather than one per guild: a person can be in exactly one voice channel
    /// across the whole account, so the guild is a property of the row rather
    /// than a partition of it — and "am I in a call" is then one lookup instead
    /// of a sweep over ninety servers.
    public var voiceStates: [UserID: VoiceState]
    /// The label each voice channel is wearing, for the ones wearing any.
    ///
    /// **Harvested off the channel objects rather than mapped onto them.** The
    /// gateway's guild object is the only place `status` appears — no REST
    /// channel route answers with it — so putting it on `Channel` would mean the
    /// next plain channel object to arrive silently erased it. See
    /// `VoiceChannelInfo`.
    public var voiceChannelInfo: [ChannelID: VoiceChannelInfo]

    init(payload: ReadyPayload) {
        currentUser = payload.user.domain
        sessionID = payload.session_id
        premiumType = payload.user.premium_type
        typingIndicatorStyle = payload.user.typing_indicator_style.map(\.domain).flatMap { $0.isPlain ? nil : $0 }
        experiments = ExperimentWire.snapshot(
            experiments: payload.experiments, guild: payload.guild_experiments, apex: payload.apex_experiments
        )
        ageVerificationStatus = payload.user.age_verification_status
        perks = payload.user.perks?.domain
        accountVerification = payload.user.accountVerification
        ageGatedFeatures = AgeGatedFeatures(rawValue: payload.regional_feature_config?.ageGatedFeatures ?? 0)

        var guilds: [Guild] = []
        var channelsByGuild: [GuildID: [Channel]] = [:]
        var threadsByGuild: [GuildID: [Channel]] = [:]
        var rolesByGuild: [GuildID: [RoleID: Role]] = [:]
        var emojisByGuild: [GuildID: [EmojiRef]] = [:]
        var stickersByGuild: [GuildID: [StickerRef]] = [:]
        var stages: [ChannelID: StageInstance] = [:]
        var scheduledEvents: [GuildID: [ScheduledEvent]] = [:]
        var membersByGuild: [GuildID: [UserID: Member]] = [:]
        var users: [UserID: User] = [:]
        var presences: [UserID: Presence] = [:]
        var voiceStates: [UserID: VoiceState] = [:]
        var voiceChannelInfo: [ChannelID: VoiceChannelInfo] = [:]
        var soundboardsByGuild: [GuildID: [SoundboardSound]] = [:]

        for guildDTO in payload.guilds ?? [] {
            let guild = guildDTO.domain
            guilds.append(guild)

            if let channels = guildDTO.channels {
                channelsByGuild[guild.id] = channels.map { $0.domain(guildID: guild.id) }
                for channelDTO in channels {
                    guard let status = channelDTO.status, !status.isEmpty else { continue }
                    voiceChannelInfo[channelDTO.id] = VoiceChannelInfo(status: status)
                }
            }
            if let threads = guildDTO.threads, !threads.isEmpty {
                threadsByGuild[guild.id] = threads.map { $0.domain(guildID: guild.id) }
            }
            if let sounds = guildDTO.soundboard_sounds, !sounds.isEmpty {
                soundboardsByGuild[guild.id] = sounds.map(\.domain)
            }
            for stateDTO in guildDTO.voice_states ?? [] {
                guard var state = stateDTO.domain, state.channelID != nil else { continue }
                // READY's per-guild states omit the guild id, because the guild
                // they are nested in is the answer. Filling it here is what
                // stops every one of them looking like a direct-message call.
                state.guildID = state.guildID ?? guild.id
                voiceStates[state.userID] = state
            }
            if let roles = guildDTO.roles {
                var table: [RoleID: Role] = [:]
                table.reserveCapacity(roles.count)
                for role in roles { table[role.id] = role.domain }
                rolesByGuild[guild.id] = table
            }
            if let emojis = guildDTO.emojis {
                let usable = emojis.compactMap(\.catalogEntry)
                if !usable.isEmpty { emojisByGuild[guild.id] = usable }
            }
            if let stickers = guildDTO.stickers {
                let usable = stickers.compactMap(\.catalogEntry)
                if !usable.isEmpty { stickersByGuild[guild.id] = usable }
            }
            // The stages already running when we connected. Keyed by channel,
            // because that is how everything addresses a stage.
            for stage in (guildDTO.stage_instances ?? []).compactMap(\.domain) {
                stages[stage.channelID] = stage
            }
            let events = (guildDTO.guild_scheduled_events?.elements ?? []).compactMap {
                $0.domain(fallbackGuildID: guild.id)
            }
            if !events.isEmpty { scheduledEvents[guild.id] = events }
            if let members = guildDTO.members {
                var table: [UserID: Member] = [:]
                table.reserveCapacity(members.count)
                for memberDTO in members {
                    guard let userDTO = memberDTO.user else { continue }
                    users[userDTO.id] = userDTO.domain
                    table[userDTO.id] = memberDTO.domain(userID: userDTO.id)
                }
                membersByGuild[guild.id] = table
            }
            for presenceDTO in guildDTO.presences ?? [] {
                guard let presence = presenceDTO.domain else { continue }
                presences[presence.userID] = presence
            }
        }
        // The reader's own record in every server, positional against READY's
        // guild list and guarded on its count, as READY_SUPPLEMENTAL's merged
        // arrays are: a mismatch would file one server's roles under another.
        if let merged = payload.merged_members?.lists, !merged.isEmpty {
            if merged.count == guilds.count {
                for (offset, list) in merged.enumerated() where !list.isEmpty {
                    let guildID = guilds[offset].id
                    var table = membersByGuild[guildID] ?? [:]
                    for memberDTO in list {
                        guard let userID = memberDTO.user?.id ?? memberDTO.user_id else { continue }
                        if let userDTO = memberDTO.user { users[userID] = userDTO.domain }
                        table[userID] = memberDTO.domain(userID: userID)
                    }
                    membersByGuild[guildID] = table
                }
            } else {
                Log.fault(.gateway, "READY: merged members for \(merged.count) servers, READY named \(guilds.count); dropped")
            }
        }

        self.guilds = guilds
        self.channelsByGuild = channelsByGuild
        self.threadsByGuild = threadsByGuild
        self.rolesByGuild = rolesByGuild
        self.emojisByGuild = emojisByGuild
        self.stickersByGuild = stickersByGuild
        self.membersByGuild = membersByGuild

        var privateChannels: [Channel] = []
        for channelDTO in payload.private_channels ?? [] {
            privateChannels.append(channelDTO.domain())
            for recipient in channelDTO.recipients ?? [] {
                users[recipient.id] = recipient.domain
            }
        }
        self.privateChannels = privateChannels

        for userDTO in payload.users ?? [] { users[userDTO.id] = userDTO.domain }
        var blockedUserIDs: Set<UserID> = []
        var ignoredUserIDs: Set<UserID> = []
        var relationships: [UserID: Relationship] = [:]
        var friendNicknames: [UserID: String] = [:]
        var relationshipFacts: [UserID: RelationshipFacts] = [:]
        for relationship in payload.relationships ?? [] {
            if let userDTO = relationship.user { users[userDTO.id] = userDTO.domain }
            let kind = Relationship(rawValue: relationship.type ?? 0)
            if kind != .none { relationships[relationship.id] = kind }
            if let facts = relationship.facts { relationshipFacts[relationship.id] = facts }
            if let nickname = relationship.nickname, !nickname.isEmpty {
                friendNicknames[relationship.id] = nickname
            }
            // Blocked is a relationship *type*; ignoring is a flag beside it.
            // Reading either as the other is how a friend gets hidden or an
            // ignore is silently lifted on every launch.
            if kind == .blocked { blockedUserIDs.insert(relationship.id) }
            if relationship.user_ignored == true { ignoredUserIDs.insert(relationship.id) }
        }
        self.blockedUserIDs = blockedUserIDs
        self.ignoredUserIDs = ignoredUserIDs
        self.relationships = relationships
        self.friendNicknames = friendNicknames
        self.relationshipFacts = relationshipFacts
        // **A dictionary of ids to strings, straight off READY.** There is no
        // route this client needs for reading one: the whole set arrives with
        // the bootstrap, so a profile card opens with the note already in it.
        var notes: [UserID: String] = [:]
        for (key, note) in payload.notes ?? [:] {
            guard let userID = UserID(key), !note.isEmpty else { continue }
            notes[userID] = note
        }
        self.notes = notes
        // Every one of them is the reader's, so there is nobody to filter out —
        // Discord's `CONNECTION_OPEN` files them all.
        var joinRequests: [GuildID: OwnJoinRequest] = [:]
        for request in (payload.guild_join_requests?.requests ?? []).compactMap(\.domain) {
            joinRequests[request.guildID] = request
        }
        self.joinRequests = joinRequests
        self.voiceStates = voiceStates
        self.voiceChannelInfo = voiceChannelInfo
        self.soundboardsByGuild = soundboardsByGuild
        self.stages = stages
        self.scheduledEvents = scheduledEvents
        // **The reader's own object last, and merged.** Every array above
        // assigns whole, and any of them may carry the reader again as a thinner
        // copy — a member entry, a relationship's user. Written first, the full
        // object READY led with lost to whichever copy came after it.
        users[currentUser.id] = currentUser.merged(over: users[currentUser.id])
        self.users = users
        self.presences = presences

        var readStates: [ChannelID: ReadState] = [:]
        var guildEventAcks: [GuildID: MessageID] = [:]
        for entry in payload.read_state?.entries ?? [] {
            switch entry.read_state_type ?? 0 {
            case 0: break
            case 1:
                // A server's scheduled events, keyed by the server.
                if let acked = entry.last_acked_id ?? entry.last_message_id, acked.rawValue != 0 {
                    guildEventAcks[GuildID(rawValue: entry.id.rawValue)] = acked
                }
                continue
            default: continue
            }
            readStates[entry.id] = ReadState(
                // **A zero snowflake is not a message id; it is "never read".**
                // Discord sends `"last_message_id": "0"` for a channel the
                // reader has no position in, and carried through as a real
                // cursor it is the most dangerous value there is: every
                // comparison against it passes, so "everything after the
                // cursor" becomes the channel's entire history and the first
                // unread message is the first message ever posted there. The
                // inbox drew 2025 for channels that had been busy all week.
                lastAcknowledgedID: entry.last_message_id.flatMap {
                    $0.rawValue == 0 ? nil : $0
                },
                mentionCount: entry.mention_count ?? 0,
                isMuted: false
            )
        }

        var mutedGuildIDs: Set<GuildID> = []
        var mutedChannelIDs: Set<ChannelID> = []
        var followedChannelIDs: Set<ChannelID> = []
        var pinnedChannelIDs: Set<ChannelID> = []
        var guildLevels: [GuildID: MessageNotificationLevel] = [:]
        var channelLevels: [ChannelID: MessageNotificationLevel] = [:]
        var suppressEveryone: Set<GuildID> = []
        var suppressRoles: Set<GuildID> = []
        var guildUserSettings: [GuildID: GuildUserSettings] = [:]
        for entry in payload.user_guild_settings?.entries ?? [] {
            if let guildID = entry.guild_id {
                guildUserSettings[guildID] = entry.domain(guildID: guildID)
                if entry.muted == true { mutedGuildIDs.insert(guildID) }
                // **Stored even when it is `inherit`.** The policy distinguishes
                // "the reader chose the server's default" from "the reader chose
                // nothing", and collapsing them here would throw that away
                // before it ever reaches the decision.
                if let level = entry.message_notifications {
                    guildLevels[guildID] = MessageNotificationLevel(rawValue: level)
                }
                if entry.suppress_everyone == true { suppressEveryone.insert(guildID) }
                if entry.suppress_roles == true { suppressRoles.insert(guildID) }
            }
            for override in entry.channel_overrides ?? [] {
                guard let channelID = override.channel_id else { continue }
                // Three independent facts on one override, and a `guard` on the
                // first used to drop the others: a muted channel is not the only
                // kind that carries an opt-in bit or a level.
                if override.muted == true {
                    mutedChannelIDs.insert(channelID)
                    readStates[channelID]?.isMuted = true
                }
                let flags = override.flags ?? 0
                if flags & ChannelSettingsFlags.followed != 0 {
                    followedChannelIDs.insert(channelID)
                }
                // The pin. It rides the private-channel entry, whose `guild_id`
                // is null — so it is read here, inside the override loop that
                // runs for every entry, rather than in the `if let guildID`
                // above which that entry never enters.
                if flags & ChannelSettingsFlags.favorited != 0 {
                    pinnedChannelIDs.insert(channelID)
                }
                if let level = override.message_notifications {
                    channelLevels[channelID] = MessageNotificationLevel(rawValue: level)
                }
            }
        }
        self.readStates = readStates
        self.guildEventAcks = guildEventAcks
        notificationFlags = payload.notification_settings?.flags
        self.mutedGuildIDs = mutedGuildIDs
        self.mutedChannelIDs = mutedChannelIDs
        self.notificationPreferences = NotificationPreferences(
            mutedGuildIDs: mutedGuildIDs,
            mutedChannelIDs: mutedChannelIDs,
            guildLevels: guildLevels,
            channelLevels: channelLevels,
            suppressEveryoneGuildIDs: suppressEveryone,
            suppressRoleMentionGuildIDs: suppressRoles
        )
        self.guildUserSettings = guildUserSettings
        self.followedChannelIDs = followedChannelIDs
        self.pinnedChannelIDs = pinnedChannelIDs
        // The protobuf first, the JSON second, empty last.
        //
        // Discord moved the settings into `user_settings_proto` and stopped
        // sending `user_settings` — measured on a live READY — so the order is
        // not a preference: reading the JSON first would take an absent value
        // over a present one. The JSON branch stays because it costs nothing and
        // some sessions still answer with it.
        settings = payload.user_settings_proto.flatMap { UserSettingsProto.decode(base64: $0) }
            ?? payload.user_settings?.domain
            ?? ClientSettings(folders: [], status: .online, customStatus: nil)
    }
}

/// A live update, converted to domain values.
public enum GatewayUpdate: Sendable {
    /// - Parameter quotedAuthor: whoever the message quotes, when it is a reply
    ///   and the payload carried them. The reply header names and pictures that
    ///   person, and a live message is very often the first time this client
    ///   hears of them — see `MessageDTO.QuotedDTO`.
    /// An interaction this client sent was accepted. `id` is the interaction's
    /// snowflake; for an activity launch it is the instance.
    case interactionAcknowledged(id: String, nonce: String?)
    /// An interaction this client sent was refused, or the application let
    /// Discord's window close on it. Carries no reason — the dispatch is
    /// `{id, nonce}` and nothing more — so what the reader is told is that the
    /// command did not run, which is the only thing the wire actually said.
    case interactionFailed(nonce: String?)
    /// A running activity, as Discord now describes it. No participants means
    /// it ended. `members` are the ones its participants carried.
    case activityInstanceChanged(ActivityInstance, members: [UserID: Member])
    /// The account's experiment assignments, sent after READY: merged over
    /// READY's (`STATE_UPDATE`). Nil-free: an update with none isn't sent.
    case experimentsUpdated(reader: [UInt32: ApexAssignment], apex: [ApexAssignment])
    case messageCreated(
        Message, author: User, quotedAuthor: User?, member: Member?, guildID: GuildID?
    )
    case messageUpdated(Message)
    case messageDeleted(MessageID, channelID: ChannelID)
    /// One reaction of one kind. `colors` is the server's palette for a super
    /// reaction, the first three of `burst_colors`; empty for a plain one.
    case reactionAdded(
        MessageID, channelID: ChannelID, emoji: EmojiRef, userID: UserID,
        kind: ReactionKind, colors: [UInt32]
    )
    case reactionRemoved(
        MessageID, channelID: ChannelID, emoji: EmojiRef, userID: UserID, kind: ReactionKind
    )
    /// Several plain reactions at once, as `(emoji, users)` pairs.
    case reactionsAdded(MessageID, channelID: ChannelID, reactions: [(EmojiRef, [UserID])])
    /// A moderator cleared every reaction on a message.
    case reactionsCleared(MessageID, channelID: ChannelID)
    /// A moderator cleared one emoji — both kinds, everybody's.
    case reactionEmojiCleared(MessageID, channelID: ChannelID, emoji: EmojiRef)
    case guildAvailable(
        Guild,
        channels: [Channel],
        /// The labels those channels are wearing. **Only ever on this object** —
        /// see `ReadySnapshot.voiceChannelInfo`.
        voiceChannelInfo: [ChannelID: VoiceChannelInfo],
        /// The threads the account follows in this guild.
        ///
        /// Beside the channels rather than among them: a thread's `parentID` is
        /// a channel, not a category, so a builder that groups channels by
        /// parent would silently drop every one of them into a bucket it never
        /// emits. Kept separate so the sidebar has to say what it does with them.
        threads: [Channel],
        roles: [RoleID: Role],
        members: [UserID: Member],
        users: [UserID: User],
        presences: [UserID: Presence],
        emojis: [EmojiRef],
        stickers: [StickerRef],
        /// The stages that were **already live** when the server arrived. See
        /// `GuildDTO.stage_instances`.
        stages: [StageInstance],
        /// The activities already running in its channels.
        activityInstances: [ActivityInstance],
        scheduledEvents: [ScheduledEvent]
    )
    /// A scheduled event was created or changed.
    case scheduledEventChanged(ScheduledEvent)
    /// A scheduled event was deleted.
    case scheduledEventRemoved(GuildID, eventID: UInt64)
    /// Somebody's answer to an event arrived, or was taken back.
    case scheduledEventRSVPAdded(ScheduledEventRSVP)
    case scheduledEventRSVPRemoved(ScheduledEventRSVP)
    /// A date of a series changed; nil exception is that date's change gone,
    /// and a nil date as well is every date's.
    case scheduledEventExceptionChanged(eventID: UInt64, ScheduledEvent.Exception)
    case scheduledEventExceptionRemoved(eventID: UInt64, occurrence: UInt64?)
    /// The reader's activity feed is stale; ask again after this long.
    case activityInboxStale(refreshAfter: TimeInterval?)
    /// A server changed. `carriesTheme` is false when the payload left `theme`
    /// out, which keeps the theme already held — see `GuildDTO.carriesTheme`.
    case guildUpdated(Guild, carriesTheme: Bool)
    /// A stage went live, or its topic changed.
    case stageChanged(StageInstance)
    /// A stage ended. The channel and everybody in it stay; only the stage
    /// stops being one.
    case stageEnded(ChannelID)
    /// A server's emoji or sticker set was replaced. `nil` on either side means
    /// that half did not change — the two arrive on separate events, and
    /// treating a missing one as empty would empty the picker.
    case guildExpressionsUpdated(GuildID, emojis: [EmojiRef]?, stickers: [StickerRef]?)
    case guildRemoved(GuildID, wasLeft: Bool)
    case channelUpserted(Channel)
    case channelRemoved(ChannelID)
    /// A thread arrived or changed.
    ///
    /// `isNew` is Discord's `newly_created`, and it is the only way to tell a
    /// thread that has just been opened from one being re-announced because the
    /// account gained access to its parent — the event name is the same for
    /// both. `membership` is our own, present when the payload carried it.
    case threadUpserted(Channel, isNew: Bool, membership: ThreadMember?)
    case threadRemoved(ChannelID, parentID: ChannelID?)
    /// Every thread the account can see in `channelIDs`, replacing what was
    /// held for those parents.
    ///
    /// **A nil `channelIDs` covers the whole guild.** The caller must not read
    /// that as an empty list — see `ThreadListSyncDTO.channel_ids`.
    case threadListSynced(
        GuildID?,
        channelIDs: [ChannelID]?,
        threads: [Channel],
        memberships: [ThreadMember],
        newestMessages: [Message],
        newestAuthors: [User]
    )
    /// How many messages a board's posts have past the marks it asked about.
    case forumUnreads(ChannelID, counts: [ChannelID: Int])
    /// Our own membership of one thread moved: joined, left, muted, or the
    /// notification setting changed.
    case threadMembershipChanged(ThreadMember)
    /// Somebody else came or went. Only the count is acted on — a thread's
    /// member list is not something this client draws.
    case threadMemberCountChanged(ChannelID, count: Int?)
    case presenceUpdated(Presence)
    /// Somebody started typing — with their custom indicator, or nil for the
    /// plain one. **Every event says which**, so nil replaces what came before.
    case typingStarted(ChannelID, userID: UserID, at: Date, style: TypingIndicatorStyle?)
    case membersChunk(GuildID, members: [UserID: Member], users: [UserID: User], presences: [UserID: Presence])
    /// Somebody left the server, or was kicked or banned from it.
    case memberRemoved(GuildID, UserID)
    /// A bulk ban finished: who was banned and who could not be.
    case bulkBanFinished(GuildID, banned: [UserID], failed: [UserID])
    /// A join request was made or changed. `userID` is the applicant: a
    /// moderator is sent everybody's, and only the reader's own is theirs.
    case joinRequestChanged(OwnJoinRequest, userID: UserID?)
    /// A join request is gone — withdrawn, or settled.
    case joinRequestRemoved(GuildID, userID: UserID?)
    case memberListUpdated(MemberListUpdate)
    /// A read cursor moved in another session. `isManual` is a Mark Unread
    /// there, which may move it back; anything else only ever moves it on.
    case channelAcknowledged(ChannelID, messageID: MessageID?, mentionCount: Int, isManual: Bool)
    /// The reader's own account changed. The tier and the age status ride
    /// beside the user rather than on it — see `AccountEntitlements` — and are
    /// nil where this update did not carry them.
    case currentUserUpdated(
        User, premiumType: Int?, ageVerificationStatus: Int?, verification: AccountVerification?,
        perks: AccountPerks? = nil
    )
    /// A mention was acknowledged somewhere. The inbox drops the row.
    case recentMentionDeleted(MessageID)
    /// A message was bookmarked or a reminder set — here, or elsewhere.
    ///
    /// Carries the author because the saved message arrives whole, and a
    /// bookmark set on a phone points at a message this window may never have
    /// loaded: without the author the row draws "Unknown" over a grey circle.
    case savedMessageAdded(SavedMessage, author: User?)
    case savedMessageRemoved(channelID: ChannelID, messageID: MessageID)
    /// A relationship arrived or went. `kind` is `.none` for a removal, which is
    /// the same thing the table says by not holding an entry.
    case relationshipChanged(
        UserID, kind: Relationship, isIgnored: Bool, user: User?, facts: RelationshipFacts?
    )
    /// The reader renamed somebody, or cleared the name — here or elsewhere.
    ///
    /// **Its own case rather than a field on `relationshipChanged`.** A rename
    /// is not a relationship arriving, and folding it in would make every
    /// nickname change look like one to a store that reconciles on kind.
    case friendNicknameChanged(UserID, nickname: String?)
    /// A relationship as it now stands — `RELATIONSHIP_UPDATE`. The kind is
    /// nil where the event named none, and the relationship then keeps its own.
    case relationshipUpdated(
        UserID, kind: Relationship?, isIgnored: Bool, nickname: String?, facts: RelationshipFacts?
    )
    /// A pin, a mute or a notification level changed for one guild — or, when
    /// `guildID` is nil, for the direct-message list.
    ///
    /// **The sets are complete for that guild, not deltas.** An override with
    /// nothing left on it is dropped by the server, so what is absent from
    /// these is off rather than unmentioned.
    /// - Parameter settings: the reader's whole record for that server, when
    ///   the event was about one. **Nil for the private-channel entry**, whose
    ///   `guild_id` is null — that one carries the DM pins and mutes above and
    ///   is not a server's settings at all.
    case guildSettingsChanged(
        guildID: GuildID?,
        pinned: Set<ChannelID>,
        muted: Set<ChannelID>,
        settings: GuildUserSettings?
    )
    /// Another client changed the account's settings, or this one's write
    /// echoed back. A partial update leaves out what did not change, so the
    /// rail's folders are nil, and each synced preference nil, where it did
    /// not carry them.
    case userSettingsChanged(
        folders: GuildFolderSettings?,
        preferences: SyncedPreferences.Delta,
        audioContext: AudioContextSettings?
    )
    /// The frecency blob (type 2) moved — a star or a use in another client,
    /// or this one's own write echoed back.
    case frecencySettingsChanged
    /// An application answered an interaction with a form to fill in.
    case interactionModalCreated(InteractionModal)
    /// Somebody moved in, out of, or between voice channels. A state whose
    /// `channelID` is nil **is** the departure.
    case voiceStateChanged(VoiceState, member: Member?, user: User?)
    /// Where our media session lives. Half a credential — see `VoiceServer`.
    case voiceServerChanged(VoiceServer)
    case voiceEffect(VoiceChannelEffect)
    /// Somebody in the reader's call clipped a moment — Discord's
    /// distributed clips (docs/CLIPS-PRESENCE.md, Phase 7.3).
    case clipsRemoteTrigger(ClipsRemoteTrigger)
    /// A voice channel's own two facts moved: its status line, its session
    /// clock, or both. **One case for three events**, because all three answer
    /// the same question and a store that told them apart would be telling
    /// itself something it does not act on. A field left nil is one this event
    /// said nothing about — see `VoiceChannelPatch`.
    case voiceChannelInfoChanged(GuildID?, patches: [ChannelID: VoiceChannelPatch])
    /// One guild the client is not subscribed to, in a periodic delta.
    case passiveGuildUpdate(
        GuildID,
        voiceStates: [VoiceState],
        departedUserIDs: [UserID],
        members: [UserID: Member],
        users: [UserID: User],
        unreads: [(channelID: ChannelID, lastMessageID: MessageID?)]
    )
    /// A private channel's call, and the people already in it: `CALL_CREATE`
    /// carries their voice states, which are the only word a client that
    /// just connected gets about who's sitting in a call.
    case callChanged(DirectCall, voiceStates: [VoiceState])
    /// `CALL_DELETE`. `isUnavailable` is an outage, not an ending.
    case callEnded(ChannelID, isUnavailable: Bool)
    case soundboardSoundsChanged(GuildID?, sounds: [SoundboardSound])
    /// Who is watching one person's screen share, and — on the `STREAM_CREATE`
    /// that opens it — where its media session lives.
    ///
    /// `viewers` is the whole set, never a delta: the caller diffs it against
    /// what it held. `rtcServerID` is present only on the create, and only for
    /// **our own** stream; it is what a Go Live session's MLS group is keyed
    /// from, and it is `rtc_channel_id` rather than anything derived.
    case streamChanged(
        owner: UserID,
        channelID: ChannelID?,
        key: String,
        /// Present only on the `STREAM_CREATE` that opens a stream, and only
        /// for our own. `nil` on every viewer-count update.
        session: GoLiveSession?,
        viewers: Set<UserID>
    )
    case streamEnded(owner: UserID)
    /// The other half of a Go Live credential. Arrives in **either order**
    /// relative to `streamChanged`, exactly as a call's two halves do.
    case streamServerChanged(GoLiveServer)
    /// New or changed summaries for one channel, to be merged over the ones
    /// held. See `SummaryUpdatePayload`.
    case summariesUpdated(ChannelID, [ChannelSummary])

    /// - Parameter currentUserID: who we are, for the thread events whose
    ///   membership payload leaves `user_id` out because the account is
    ///   implied. Nil before READY, in which case those memberships are
    ///   dropped rather than attributed to nobody — a `ThreadMember` with a
    ///   zero user id would be indistinguishable from a real one.
    init?(_ payload: GatewayFrame.Payload, currentUserID: UserID? = nil) {
        switch payload {
        case .interactionSuccess(let ack):
            guard let id = ack.id else { return nil }
            self = .interactionAcknowledged(id: id, nonce: ack.nonce)

        case .interactionFailure(let ack):
            self = .interactionFailed(nonce: ack.nonce)

        case .embeddedActivityUpdate(let dto):
            guard let instance = dto.domain else { return nil }
            self = .activityInstanceChanged(instance, members: dto.members)

        case .messageCreate(let dto):
            guard let authorDTO = dto.author else { return nil }
            self = .messageCreated(
                dto.domain,
                author: authorDTO.domain,
                quotedAuthor: dto.quotedAuthor?.domain,
                member: nil,
                guildID: nil
            )
        case .messageUpdate(let dto):
            self = .messageUpdated(dto.domain)
        case .messageDelete(let payload):
            self = .messageDeleted(payload.id, channelID: payload.channel_id)
        case .messageReactionAdd(let payload):
            self = .reactionAdded(
                payload.message_id,
                channelID: payload.channel_id,
                emoji: payload.emoji.domain,
                userID: payload.user_id,
                kind: payload.kind,
                colors: ReactionDTO.palette(payload.burst_colors)
            )
        case .messageReactionRemove(let payload):
            self = .reactionRemoved(
                payload.message_id,
                channelID: payload.channel_id,
                emoji: payload.emoji.domain,
                userID: payload.user_id,
                kind: payload.kind
            )
        case .messageReactionAddMany(let payload):
            self = .reactionsAdded(
                payload.message_id,
                channelID: payload.channel_id,
                reactions: (payload.reactions ?? []).compactMap { entry in
                    guard let emoji = entry.emoji, let users = entry.users, !users.isEmpty
                    else { return nil }
                    return (emoji.domain, users)
                }
            )
        case .messageReactionRemoveAll(let payload):
            self = .reactionsCleared(payload.message_id, channelID: payload.channel_id)
        case .messageReactionRemoveEmoji(let payload):
            self = .reactionEmojiCleared(
                payload.message_id,
                channelID: payload.channel_id,
                emoji: payload.emoji.domain
            )
        case .guildCreate(let dto):
            let guild = dto.domain
            var roles: [RoleID: Role] = [:]
            for role in dto.roles ?? [] { roles[role.id] = role.domain }
            var members: [UserID: Member] = [:]
            var users: [UserID: User] = [:]
            for memberDTO in dto.members ?? [] {
                // A member may name its person by `user_id` alone
                // (`DEDUPE_USER_OBJECTS`) — the reader's own record on a join
                // among them, which says whether they're pending.
                guard let userID = memberDTO.user?.id ?? memberDTO.user_id else { continue }
                if let userDTO = memberDTO.user { users[userID] = userDTO.domain }
                members[userID] = memberDTO.domain(userID: userID)
            }
            var presences: [UserID: Presence] = [:]
            for presenceDTO in dto.presences ?? [] {
                guard let presence = presenceDTO.domain else { continue }
                presences[presence.userID] = presence
            }
            var voiceChannelInfo: [ChannelID: VoiceChannelInfo] = [:]
            for channelDTO in dto.channels ?? [] {
                guard let status = channelDTO.status, !status.isEmpty else { continue }
                voiceChannelInfo[channelDTO.id] = VoiceChannelInfo(status: status)
            }
            self = .guildAvailable(
                guild,
                channels: (dto.channels ?? []).map { $0.domain(guildID: guild.id) },
                voiceChannelInfo: voiceChannelInfo,
                threads: (dto.threads ?? []).map { $0.domain(guildID: guild.id) },
                roles: roles,
                members: members,
                users: users,
                presences: presences,
                emojis: (dto.emojis ?? []).compactMap(\.catalogEntry),
                stickers: (dto.stickers ?? []).compactMap(\.catalogEntry),
                stages: (dto.stage_instances ?? []).compactMap(\.domain),
                activityInstances: (dto.activity_instances?.elements ?? []).compactMap(\.domain),
                scheduledEvents: (dto.guild_scheduled_events?.elements ?? []).compactMap {
                    $0.domain(fallbackGuildID: guild.id)
                }
            )
        case .guildUpdate(let dto):
            self = .guildUpdated(dto.domain, carriesTheme: dto.carriesTheme)
        case .stageInstanceUpsert(let dto):
            guard let stage = dto.domain else { return nil }
            self = .stageChanged(stage)
        case .stageInstanceDelete(let dto):
            guard let channelID = dto.channel_id else { return nil }
            self = .stageEnded(channelID)
        case .scheduledEventUpsert(let dto):
            guard let guildID = dto.guild_id, let event = dto.domain(fallbackGuildID: guildID) else { return nil }
            self = .scheduledEventChanged(event)
        case .scheduledEventDelete(let dto):
            guard let guildID = dto.guild_id, let id = dto.id?.value else { return nil }
            self = .scheduledEventRemoved(guildID, eventID: id)
        case .scheduledEventUserAdd(let dto):
            guard let rsvp = dto.domain else { return nil }
            self = .scheduledEventRSVPAdded(rsvp)
        case .scheduledEventUserRemove(let dto):
            guard let rsvp = dto.domain else { return nil }
            self = .scheduledEventRSVPRemoved(rsvp)
        case .scheduledEventExceptionUpsert(let dto):
            guard let eventID = dto.event_id?.value, let exception = dto.domain else { return nil }
            self = .scheduledEventExceptionChanged(eventID: eventID, exception)
        case .scheduledEventExceptionDelete(let dto):
            guard let eventID = dto.event_id?.value, let id = dto.event_exception_id?.value else { return nil }
            self = .scheduledEventExceptionRemoved(eventID: eventID, occurrence: id)
        case .scheduledEventExceptionsDelete(let dto):
            guard let eventID = dto.event_id?.value else { return nil }
            self = .scheduledEventExceptionRemoved(eventID: eventID, occurrence: nil)
        case .activityInboxStale(let dto):
            self = .activityInboxStale(refreshAfter: dto.refresh_after_ms.map { $0 / 1000 })
        case .guildEmojisUpdate(let payload):
            self = .guildExpressionsUpdated(payload.guild_id, emojis: payload.catalog, stickers: nil)
        case .guildStickersUpdate(let payload):
            self = .guildExpressionsUpdated(payload.guild_id, emojis: nil, stickers: payload.catalog)
        case .guildDelete(let payload):
            // An unavailable guild is an outage, not a departure. Removing it
            // from the rail and putting it back reads as being kicked and
            // re-invited.
            self = .guildRemoved(payload.id, wasLeft: payload.unavailable != true)
        case .channelCreate(let dto), .channelUpdate(let dto):
            self = .channelUpserted(dto.domain())
        case .channelDelete(let dto):
            self = .channelRemoved(dto.id)

        case .threadCreate(let payload):
            let thread = payload.channel.domain()
            self = .threadUpserted(
                thread,
                isNew: payload.newly_created ?? false,
                membership: currentUserID.map {
                    payload.member?.domain(threadID: thread.id, userID: $0)
                } ?? nil
            )
        case .threadUpdate(let dto):
            // No `newly_created` on an update, and no membership: an edit to the
            // thread's own fields says nothing about whether we are in it.
            self = .threadUpserted(dto.domain(), isNew: false, membership: nil)
        case .threadDelete(let payload):
            self = .threadRemoved(payload.id, parentID: payload.parent_id)
        case .threadListSync(let payload):
            let memberships: [ThreadMember]
            if let currentUserID {
                memberships = (payload.members ?? []).compactMap { dto in
                    // A sync row names its thread and omits the user, which is
                    // the mirror of `THREAD_CREATE`'s nested member.
                    dto.id.map { dto.domain(threadID: $0, userID: currentUserID) }
                }
            } else {
                memberships = []
            }
            self = .threadListSynced(
                payload.guild_id,
                channelIDs: payload.channel_ids,
                threads: (payload.threads ?? []).map { $0.domain(guildID: payload.guild_id) },
                memberships: memberships,
                newestMessages: payload.most_recent_messages?.elements.map(\.domain) ?? [],
                newestAuthors: payload.most_recent_messages?.elements.compactMap { $0.author?.domain } ?? []
            )
        case .forumUnreads(let payload):
            guard payload.permission_denied != true else { return nil }
            var counts: [ChannelID: Int] = [:]
            for thread in payload.threads ?? [] {
                if let count = thread.count { counts[thread.thread_id] = count }
            }
            self = .forumUnreads(payload.channel_id, counts: counts)
        case .threadMemberUpdate(let payload):
            // This one *does* carry `user_id` — it is a full thread member
            // object — so the fallback is only reached before READY.
            guard let currentUserID,
                  let membership = payload.domain(userID: currentUserID)
            else { return nil }
            self = .threadMembershipChanged(membership)
        case .threadMembersUpdate(let payload):
            self = .threadMemberCountChanged(payload.id, count: payload.member_count)
        case .presenceUpdate(let dto):
            guard let presence = dto.domain else { return nil }
            self = .presenceUpdated(presence)
        case .typingStart(let payload):
            self = .typingStarted(
                payload.channel_id,
                userID: payload.user_id,
                at: payload.timestamp.map { Date(timeIntervalSince1970: $0) } ?? .now,
                style: payload.typing_indicator_style.map(\.domain).flatMap { $0.isPlain ? nil : $0 }
            )
        case .guildMembersChunk(let payload):
            var members: [UserID: Member] = [:]
            var users: [UserID: User] = [:]
            for memberDTO in payload.members ?? [] {
                guard let userDTO = memberDTO.user else { continue }
                users[userDTO.id] = userDTO.domain
                members[userDTO.id] = memberDTO.domain(userID: userDTO.id)
            }
            var presences: [UserID: Presence] = [:]
            for presenceDTO in payload.presences ?? [] {
                guard let presence = presenceDTO.domain else { continue }
                presences[presence.userID] = presence
            }
            self = .membersChunk(
                payload.guild_id,
                members: members,
                users: users,
                presences: presences
            )
        case .guildMemberUpsert(let payload):
            guard let user = payload.member.user else { return nil }
            self = .membersChunk(
                payload.guild_id,
                members: [user.id: payload.member.domain(userID: user.id)],
                users: [user.id: user.domain],
                presences: [:]
            )
        case .guildMemberRemove(let payload):
            self = .memberRemoved(payload.guild_id, payload.user.id)
        case .guildBulkBanUpdate(let payload):
            self = .bulkBanFinished(
                payload.guild_id,
                banned: payload.bulk_ban?.banned_users ?? [],
                failed: payload.bulk_ban?.failed_users ?? []
            )
        case .guildJoinRequestUpsert(let payload):
            // The request names its server too; the envelope's is the one
            // Discord files it under.
            guard let dto = payload.request,
                  let request = dto.domain(guildID: payload.guild_id)
            else { return nil }
            self = .joinRequestChanged(request, userID: dto.user_id)
        case .guildJoinRequestDelete(let payload):
            self = .joinRequestRemoved(payload.guild_id, userID: payload.user_id)
        case .guildMemberListUpdate(let payload):
            self = .memberListUpdated(MemberListUpdate(payload))
        case .messageAck(let payload):
            self = .channelAcknowledged(
                payload.channel_id,
                messageID: payload.message_id,
                mentionCount: payload.mention_count ?? 0,
                isManual: payload.manual ?? false
            )
        case .userUpdate(let dto):
            self = .currentUserUpdated(
                dto.domain,
                premiumType: dto.premium_type,
                ageVerificationStatus: dto.age_verification_status,
                verification: dto.accountVerification,
                perks: dto.perks?.domain
            )
        case .recentMentionDelete(let dto):
            self = .recentMentionDeleted(dto.message_id)
        case .savedMessageCreate(let dto):
            // A save whose `save_data` could not be read is dropped rather than
            // invented: without the channel there is nothing to address the
            // unsave route with, and a row that cannot be removed is worse than
            // a row that never appeared.
            guard let resolved = dto.domain() else { return nil }
            self = .savedMessageAdded(resolved.saved, author: resolved.author)
        case .savedMessageDelete(let dto):
            self = .savedMessageRemoved(channelID: dto.channel_id, messageID: dto.message_id)
        case .relationshipAdd(let dto):
            self = .relationshipChanged(
                dto.id,
                kind: Relationship(rawValue: dto.type ?? 0),
                isIgnored: dto.user_ignored ?? false,
                user: dto.user?.domain,
                facts: dto.facts
            )
        case .voiceStateUpdate(let dto):
            guard let state = dto.domain else { return nil }
            let user = dto.member?.user?.domain
            let member = dto.member.flatMap { entry -> Member? in
                guard let id = entry.user?.id else { return nil }
                return entry.domain(userID: id)
            }
            self = .voiceStateChanged(state, member: member, user: user)
        case .voiceServerUpdate(let dto):
            guard let server = dto.domain else { return nil }
            self = .voiceServerChanged(server)
        case .voiceChannelEffect(let dto):
            self = .voiceEffect(dto.domain)
        case .clipsRemoteTrigger(let dto):
            guard let trigger = dto.domain else { return nil }
            self = .clipsRemoteTrigger(trigger)
        case .voiceChannelStatusUpdate(let dto):
            self = .voiceChannelInfoChanged(
                dto.guild_id, patches: [dto.id: VoiceChannelPatch(status: .some(dto.status))]
            )
        case .voiceChannelStartTimeUpdate(let dto):
            self = .voiceChannelInfoChanged(
                dto.guild_id,
                patches: [dto.id: VoiceChannelPatch(sessionStartedAt: .some(dto.voice_start_time?.date))]
            )
        case .channelInfo(let payload):
            // **Authoritative for both fields, and only because both are always
            // asked for together.** Opcode 43 answers with the fields the
            // request named, so a channel listed here with no `status` key has
            // no status — not an unsaid one. Setting rather than merging is what
            // clears a label somebody took down while this client was away,
            // which no other event would ever tell it about.
            var patches: [ChannelID: VoiceChannelPatch] = [:]
            for entry in payload.channels ?? [] {
                patches[entry.id] = VoiceChannelPatch(
                    status: .some(entry.status),
                    sessionStartedAt: .some(entry.voice_start_time?.date)
                )
            }
            guard !patches.isEmpty else { return nil }
            self = .voiceChannelInfoChanged(payload.guild_id, patches: patches)
        case .passiveUpdate(let dto):
            var states: [VoiceState] = []
            var members: [UserID: Member] = [:]
            var users: [UserID: User] = [:]
            for stateDTO in dto.updated_voice_states ?? [] {
                guard var state = stateDTO.domain else { continue }
                state.guildID = state.guildID ?? dto.guild_id
                states.append(state)
            }
            for memberDTO in dto.updated_members ?? [] {
                guard let id = memberDTO.user?.id ?? memberDTO.user_id else { continue }
                members[id] = memberDTO.domain(userID: id)
                if let userDTO = memberDTO.user { users[id] = userDTO.domain }
            }
            let departed = dto.removed_voice_states ?? []
            let unreads = (dto.updated_channels ?? []).map {
                (channelID: $0.id, lastMessageID: $0.last_message_id)
            }
            guard !states.isEmpty || !departed.isEmpty || !unreads.isEmpty else { return nil }
            self = .passiveGuildUpdate(
                dto.guild_id,
                voiceStates: states,
                departedUserIDs: departed,
                members: members,
                users: users,
                unreads: unreads
            )
        case .callCreate(let dto), .callUpdate(let dto):
            let states = (dto.voice_states ?? []).compactMap { stateDTO -> VoiceState? in
                guard var state = stateDTO.domain else { return nil }
                state.channelID = state.channelID ?? dto.channel_id
                return state
            }
            self = .callChanged(dto.domain, voiceStates: states)
        case .callDelete(let dto):
            self = .callEnded(dto.channel_id, isUnavailable: dto.unavailable == true)
        case .guildSoundboardSounds(let payload):
            self = .soundboardSoundsChanged(payload.guild_id, sounds: payload.catalog)
        case .streamUpsert(let dto):
            guard let owner = dto.ownerID else { return nil }
            // Both ids or neither: a session named by only one of them is one
            // this client cannot open, and half of it is not worth carrying.
            let session: GoLiveSession? =
                if let server = dto.rtc_server_id, let channel = dto.rtc_channel_id {
                    GoLiveSession(
                        streamKey: dto.stream_key,
                        rtcServerID: server.rawValue,
                        rtcChannelID: channel.rawValue
                    )
                } else {
                    nil
                }
            self = .streamChanged(
                owner: owner,
                channelID: dto.channelID,
                key: dto.stream_key,
                session: session,
                viewers: Set(dto.viewer_ids ?? [])
            )
        case .streamDelete(let dto):
            guard let owner = dto.ownerID else { return nil }
            self = .streamEnded(owner: owner)
        case .streamServerUpdate(let dto):
            guard let server = dto.domain else { return nil }
            self = .streamServerChanged(server)
        case .stateUpdate(let payload):
            guard let tree = payload.apex_experiments else { return nil }
            let reader = Dictionary(
                ExperimentWire.readerApex(tree).map { ($0.hash, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let apex = ExperimentWire.apex(tree)
            guard !reader.isEmpty || !apex.isEmpty else { return nil }
            self = .experimentsUpdated(reader: reader, apex: apex)
        case .conversationSummaryUpdate(let payload):
            let summaries = (payload.summaries ?? []).compactMap(\.domain)
            guard !summaries.isEmpty else { return nil }
            self = .summariesUpdated(payload.channel_id, summaries)
        case .relationshipRemove(let dto):
            // A removal carries the type that *was*, not one to apply — so the
            // event is normalised to `.none` here rather than at the store,
            // where the distinction would have to be remembered.
            //
            // **The ignore is the one thing a removal can leave standing**:
            // Discord's store drops it only where the event does not say
            // `user_ignored` (`e.relationship.userIgnored || D(id)`), so an
            // unfriended person the reader ignores stays ignored.
            self = .relationshipChanged(
                dto.id, kind: .none, isIgnored: dto.user_ignored ?? false, user: nil, facts: nil
            )
        case .relationshipUpdate(let dto):
            // **Empty is cleared.** The route takes `null` to clear and the
            // event has been seen to echo either, so both are normalised to
            // nil here — a nickname of no characters is not a nickname.
            //
            // **An update is the whole relationship, not only its nickname.**
            // Discord's store takes the type and the ignore from it as well
            // (`v(t.id, t.type)`, `t.userIgnored ? y(id) : D(id)`), and it is
            // the event an ignore made on another device arrives as for
            // somebody who is already a friend.
            self = .relationshipUpdated(
                dto.id,
                kind: dto.type.map(Relationship.init(rawValue:)),
                isIgnored: dto.user_ignored ?? false,
                nickname: dto.nickname?.isEmpty == true ? nil : dto.nickname,
                facts: dto.facts
            )
        case .userGuildSettingsUpdate(let dto):
            self = .guildSettingsChanged(
                guildID: dto.guild_id,
                pinned: DiscordREST.pinned(in: dto),
                muted: DiscordREST.muted(in: dto),
                settings: dto.guild_id.map(dto.domain(guildID:))
            )
        case .userSettingsProtoUpdate(let dto) where dto.settings.type == 2:
            self = .frecencySettingsChanged
        case .userSettingsProtoUpdate(let dto):
            guard dto.settings.type == 1,
                  let data = Data(base64Encoded: dto.settings.proto, options: .ignoreUnknownCharacters)
            else { return nil }
            let folders = UserSettingsProto.guildFolders(in: data)
            let preferences = SyncedPreferencesProto.decode(data)
            let audioContext = AudioContextProto.decode(data)
            // An update about something else — the inbox's tab, a theme — has
            // nothing for the session.
            guard folders != nil || preferences != SyncedPreferences.Delta() || audioContext != nil
            else { return nil }
            self = .userSettingsChanged(
                folders: folders, preferences: preferences, audioContext: audioContext
            )
        case .interactionModalCreate(let dto):
            self = .interactionModalCreated(dto.domain)
        default:
            return nil
        }
    }
}
