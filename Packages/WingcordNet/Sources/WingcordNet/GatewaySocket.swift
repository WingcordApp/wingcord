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

    nonisolated static func trace(_ message: @autoclosure () -> String) {
        guard let traceSink else { return }
        traceSink(message())
    }

    public enum Event: Sendable {
        case connecting
        case ready(ReadySnapshot)
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

    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var sequence: Int?
    private var sessionID: String?
    private var resumeURL: String?
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

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = ISO8601DateFormatter.withFraction.date(from: text) { return date }
            if let date = ISO8601DateFormatter.plain.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unrecognised timestamp: \(text)"
            )
        }
        return decoder
    }()

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
            Self.trace("op=\(frame.opcode) seq=\(frame.sequence.map(String.init) ?? "-") bytes=\(data.count)")
            // READY only, once per connection: name the keys Discord actually
            // sent. Discord has moved these before — `user_settings` for one —
            // and a missing key is silent, because every non-structural field
            // here is optional by design. Reading the key list off the wire is
            // the difference between knowing and guessing.
            if case .ready = frame.payload { Self.traceReadyShape(data) }
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

    /// Names the top-level keys of a READY payload, and the settings shape
    /// inside it. Diagnostic only, and gated on the trace sink being installed.
    nonisolated private static func traceReadyShape(_ data: Data) {
        guard traceSink != nil else { return }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let body = root["d"] as? [String: Any]
        else { return }
        trace("READY keys: \(body.keys.sorted().joined(separator: ","))")
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
    }

    private func inflate(_ frame: Data) -> Data? {
        guard let inflater else { return frame }
        do {
            let result = try inflater.push(frame)
            Self.trace("inflate \(frame.count) -> \(result.map { String($0.count) } ?? "partial")")
            return result
        } catch {
            Self.trace("inflate failed: \(error)")
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
            if !resumable { sessionID = nil; sequence = nil }
            scheduleReconnect(reason: "session invalidated", resumable: resumable)

        case .ready(let ready):
            Self.trace("READY guilds=\(ready.guilds?.count ?? 0) dms=\(ready.private_channels?.count ?? 0)")
            reconnectAttempt = 0
            sessionID = ready.session_id
            resumeURL = ready.resume_gateway_url
            continuation?.yield(.ready(ReadySnapshot(payload: ready)))

        case .resumed:
            reconnectAttempt = 0
            continuation?.yield(.resumed)

        default:
            if let update = GatewayUpdate(frame.payload) {
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
    /// The op-14 lazy subscription, which is the only route that answers with
    /// members **and their presences**. The documented op-8 request answers with
    /// members and no presence for them, so a roster built on it shows everyone
    /// offline.
    public func subscribeToMemberList(
        guildID: GuildID,
        channelID: ChannelID,
        ranges: [[Int]] = [[0, 99]]
    ) {
        struct Subscribe: Encodable {
            var op = 14
            var d: Data

            struct Data: Encodable {
                var guild_id: String
                var typing = true
                var threads = false
                var activities = true
                var channels: [String: [[Int]]]
            }
        }
        send(Subscribe(d: .init(
            guild_id: guildID.description,
            channels: [channelID.description: ranges]
        )))
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
    public func updatePresence(status: String, customStatus: String?, customEmoji: String?) {
        struct Update: Encodable {
            var op = 3
            var d: Data

            struct Data: Encodable {
                var status: String
                var since = 0
                var afk = false
                var activities: [Activity]
            }

            struct Activity: Encodable {
                var name = "Custom Status"
                var type = 4
                var state: String?
                var emoji: Emoji?
            }

            struct Emoji: Encodable {
                var name: String
            }
        }

        var activities: [Update.Activity] = []
        if customStatus?.isEmpty == false || customEmoji?.isEmpty == false {
            activities.append(Update.Activity(
                state: customStatus.flatMap { $0.isEmpty ? nil : $0 },
                emoji: customEmoji.flatMap { $0.isEmpty ? nil : Update.Emoji(name: $0) }
            ))
        }
        send(Update(d: .init(status: status, activities: activities)))
    }

    private func send(_ value: some Encodable) {
        guard let task, !isStopped else { return }
        do {
            let data = try JSONEncoder().encode(value)
            // The payload is never logged. An IDENTIFY carries the account token
            // in the clear, and a log line is a file, a screen share and a
            // sysdiagnose.
            Self.trace("send \(data.count) bytes")
            task.send(.data(data)) { error in
                if let error {
                    GatewaySocket.trace("send failed: \(error.localizedDescription)")
                    Self.log.error("gateway send failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            Self.log.error("gateway encode failed: \(error)")
        }
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
        struct Heartbeat: Encodable {
            var op = 1
            var d: Int?
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
    public var guilds: [Guild]
    public var channelsByGuild: [GuildID: [Channel]]
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
    public var settings: ClientSettings
    public var mutedGuildIDs: Set<GuildID>
    public var mutedChannelIDs: Set<ChannelID>
    /// Channels and categories the reader has opted into — the checkboxes and
    /// the Follow switches in Browse Channels. See `ChannelSettingsFlags`.
    public var followedChannelIDs: Set<ChannelID>
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
    /// The account's private notes about people. READY carries the whole set,
    /// which is why the profile card never has to fetch one.
    public var notes: [UserID: String]

    init(payload: ReadyPayload) {
        currentUser = payload.user.domain

        var guilds: [Guild] = []
        var channelsByGuild: [GuildID: [Channel]] = [:]
        var rolesByGuild: [GuildID: [RoleID: Role]] = [:]
        var emojisByGuild: [GuildID: [EmojiRef]] = [:]
        var stickersByGuild: [GuildID: [StickerRef]] = [:]
        var membersByGuild: [GuildID: [UserID: Member]] = [:]
        var users: [UserID: User] = [:]
        var presences: [UserID: Presence] = [:]

        users[currentUser.id] = currentUser

        for guildDTO in payload.guilds ?? [] {
            let guild = guildDTO.domain
            guilds.append(guild)

            if let channels = guildDTO.channels {
                channelsByGuild[guild.id] = channels.map { $0.domain(guildID: guild.id) }
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
        self.guilds = guilds
        self.channelsByGuild = channelsByGuild
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
        for relationship in payload.relationships ?? [] {
            if let userDTO = relationship.user { users[userDTO.id] = userDTO.domain }
            let kind = Relationship(rawValue: relationship.type ?? 0)
            if kind != .none { relationships[relationship.id] = kind }
            // Blocked is a relationship *type*; ignoring is a flag beside it.
            // Reading either as the other is how a friend gets hidden or an
            // ignore is silently lifted on every launch.
            if kind == .blocked { blockedUserIDs.insert(relationship.id) }
            if relationship.is_ignored == true { ignoredUserIDs.insert(relationship.id) }
        }
        self.blockedUserIDs = blockedUserIDs
        self.ignoredUserIDs = ignoredUserIDs
        self.relationships = relationships
        // **A dictionary of ids to strings, straight off READY.** There is no
        // route this client needs for reading one: the whole set arrives with
        // the bootstrap, so a profile card opens with the note already in it.
        var notes: [UserID: String] = [:]
        for (key, note) in payload.notes ?? [:] {
            guard let userID = UserID(key), !note.isEmpty else { continue }
            notes[userID] = note
        }
        self.notes = notes
        self.users = users
        self.presences = presences

        var readStates: [ChannelID: ReadState] = [:]
        for entry in payload.read_state?.entries ?? [] {
            readStates[entry.id] = ReadState(
                lastAcknowledgedID: entry.last_message_id,
                mentionCount: entry.mention_count ?? 0,
                isMuted: false
            )
        }

        var mutedGuildIDs: Set<GuildID> = []
        var mutedChannelIDs: Set<ChannelID> = []
        var followedChannelIDs: Set<ChannelID> = []
        for entry in payload.user_guild_settings?.entries ?? [] {
            if entry.muted == true, let guildID = entry.guild_id {
                mutedGuildIDs.insert(guildID)
            }
            for override in entry.channel_overrides ?? [] {
                guard let channelID = override.channel_id else { continue }
                // Two independent facts on one override, and a `guard` on the
                // first used to drop the second: a muted channel is not the only
                // kind that carries an opt-in bit.
                if override.muted == true {
                    mutedChannelIDs.insert(channelID)
                    readStates[channelID]?.isMuted = true
                }
                if (override.flags ?? 0) & ChannelSettingsFlags.followed != 0 {
                    followedChannelIDs.insert(channelID)
                }
            }
        }
        self.readStates = readStates
        self.mutedGuildIDs = mutedGuildIDs
        self.mutedChannelIDs = mutedChannelIDs
        self.followedChannelIDs = followedChannelIDs
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
    case messageCreated(
        Message, author: User, quotedAuthor: User?, member: Member?, guildID: GuildID?
    )
    case messageUpdated(Message)
    case messageDeleted(MessageID, channelID: ChannelID)
    case reactionAdded(MessageID, channelID: ChannelID, emoji: EmojiRef, userID: UserID)
    case reactionRemoved(MessageID, channelID: ChannelID, emoji: EmojiRef, userID: UserID)
    case guildAvailable(
        Guild,
        channels: [Channel],
        roles: [RoleID: Role],
        members: [UserID: Member],
        users: [UserID: User],
        presences: [UserID: Presence],
        emojis: [EmojiRef],
        stickers: [StickerRef]
    )
    case guildUpdated(Guild)
    /// A server's emoji or sticker set was replaced. `nil` on either side means
    /// that half did not change — the two arrive on separate events, and
    /// treating a missing one as empty would empty the picker.
    case guildExpressionsUpdated(GuildID, emojis: [EmojiRef]?, stickers: [StickerRef]?)
    case guildRemoved(GuildID, wasLeft: Bool)
    case channelUpserted(Channel)
    case channelRemoved(ChannelID)
    case presenceUpdated(Presence)
    case typingStarted(ChannelID, userID: UserID, at: Date)
    case membersChunk(GuildID, members: [UserID: Member], users: [UserID: User], presences: [UserID: Presence])
    case memberListUpdated(GuildID, members: [UserID: Member], users: [UserID: User], presences: [UserID: Presence])
    case channelAcknowledged(ChannelID, messageID: MessageID?, mentionCount: Int)
    case currentUserUpdated(User)
    /// A relationship arrived or went. `kind` is `.none` for a removal, which is
    /// the same thing the table says by not holding an entry.
    case relationshipChanged(
        UserID, kind: Relationship, isIgnored: Bool, user: User?
    )

    init?(_ payload: GatewayFrame.Payload) {
        switch payload {
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
                userID: payload.user_id
            )
        case .messageReactionRemove(let payload):
            self = .reactionRemoved(
                payload.message_id,
                channelID: payload.channel_id,
                emoji: payload.emoji.domain,
                userID: payload.user_id
            )
        case .guildCreate(let dto):
            let guild = dto.domain
            var roles: [RoleID: Role] = [:]
            for role in dto.roles ?? [] { roles[role.id] = role.domain }
            var members: [UserID: Member] = [:]
            var users: [UserID: User] = [:]
            for memberDTO in dto.members ?? [] {
                guard let userDTO = memberDTO.user else { continue }
                users[userDTO.id] = userDTO.domain
                members[userDTO.id] = memberDTO.domain(userID: userDTO.id)
            }
            var presences: [UserID: Presence] = [:]
            for presenceDTO in dto.presences ?? [] {
                guard let presence = presenceDTO.domain else { continue }
                presences[presence.userID] = presence
            }
            self = .guildAvailable(
                guild,
                channels: (dto.channels ?? []).map { $0.domain(guildID: guild.id) },
                roles: roles,
                members: members,
                users: users,
                presences: presences,
                emojis: (dto.emojis ?? []).compactMap(\.catalogEntry),
                stickers: (dto.stickers ?? []).compactMap(\.catalogEntry)
            )
        case .guildUpdate(let dto):
            self = .guildUpdated(dto.domain)
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
        case .presenceUpdate(let dto):
            guard let presence = dto.domain else { return nil }
            self = .presenceUpdated(presence)
        case .typingStart(let payload):
            self = .typingStarted(
                payload.channel_id,
                userID: payload.user_id,
                at: payload.timestamp.map { Date(timeIntervalSince1970: $0) } ?? .now
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
        case .guildMemberListUpdate(let payload):
            var members: [UserID: Member] = [:]
            var users: [UserID: User] = [:]
            var presences: [UserID: Presence] = [:]
            for operation in payload.ops ?? [] {
                let entries = (operation.items ?? []) + (operation.item.map { [$0] } ?? [])
                for entry in entries {
                    guard let memberEntry = entry.member, let userDTO = memberEntry.user else {
                        continue
                    }
                    users[userDTO.id] = userDTO.domain
                    members[userDTO.id] = Member(
                        userID: userDTO.id,
                        nickname: memberEntry.nick,
                        avatarHash: memberEntry.avatar,
                        roleIDs: memberEntry.roles ?? [],
                        joinedAt: memberEntry.joined_at,
                        premiumSince: memberEntry.premium_since
                    )
                    if let presence = memberEntry.presence?.domain {
                        presences[userDTO.id] = presence
                    } else {
                        // The subscription answers with a presence for everyone
                        // it lists; an entry without one is genuinely offline
                        // rather than unknown, and defaulting it to unknown
                        // leaves the roster's offline group empty.
                        presences[userDTO.id] = Presence(userID: userDTO.id, status: .offline)
                    }
                }
            }
            self = .memberListUpdated(
                payload.guild_id,
                members: members,
                users: users,
                presences: presences
            )
        case .messageAck(let payload):
            self = .channelAcknowledged(
                payload.channel_id,
                messageID: payload.message_id,
                mentionCount: payload.mention_count ?? 0
            )
        case .userUpdate(let dto):
            self = .currentUserUpdated(dto.domain)
        case .relationshipAdd(let dto):
            self = .relationshipChanged(
                dto.id,
                kind: Relationship(rawValue: dto.type ?? 0),
                isIgnored: dto.is_ignored ?? false,
                user: dto.user?.domain
            )
        case .relationshipRemove(let dto):
            // A removal carries the type that *was*, not one to apply — so the
            // event is normalised to `.none` here rather than at the store,
            // where the distinction would have to be remembered.
            self = .relationshipChanged(
                dto.id, kind: .none, isIgnored: false, user: nil
            )
        default:
            return nil
        }
    }
}
