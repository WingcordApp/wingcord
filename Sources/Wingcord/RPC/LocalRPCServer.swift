import AppKit
import Foundation
import Network
import WingcordCore
import WingcordNet

/// Discord's local RPC server: what a game's SDK finds at
/// `$TMPDIR/discord-ipc-N`, and what a discord.com page finds at
/// `ws://127.0.0.1:6463` — so a game's Rich Presence shows on the reader's
/// profile, and "Open in app" on an invite page opens it here.
///
/// **Discord's server, rule for rule** (DESIGN-NOTES §11 decisions 4–7): the
/// transport (`998921`), the handshake and its throttle (`546983`, `90924`),
/// READY and the request pipeline (`289919`), and three commands —
/// SET_ACTIVITY, INVITE_BROWSER and DEEP_LINK. Every other command gets
/// Discord's own "Invalid command" frame.
final class LocalRPCServer {

    /// What the server asks of the app.
    struct Host {
        /// READY's user, nil while signed out — an IPC socket is then closed.
        var currentUser: () -> RPCValue?
        /// The app a client id names: `GET /oauth2/applications/{id}/rpc`.
        var application: (ApplicationID) async throws -> RPCApplication
        /// Discord's `fetchAssetIds` for an activity's two pictures.
        var resolveAssets: (ApplicationID, String?, String?) async -> (large: String?, small: String?)
        /// The reader's "who may join" switches, which a public party carries.
        var partyPrivacy: () -> (friends: Bool, voiceChannel: Bool)
        /// An activity set or cleared, by socket.
        var setActivity: (_ socket: Int, _ activity: RichPresenceActivity?) -> Void
        /// INVITE_BROWSER: the invite, opened — or Discord's INVALID_INVITE.
        var openInvite: (_ code: String) async throws(LocalRPC.CommandError) -> RPCValue
        /// DEEP_LINK.
        var openDeepLink: (_ type: String, _ params: RPCValue?) -> Void
    }

    private let host: Host
    private var ipcListener: NWListener?
    private var webListener: NWListener?
    private var connections: [Int: LocalRPCConnection] = [:]
    private var nextID = 0
    private var throttles: [String: Throttle] = [:]
    private var applications: [ApplicationID: RPCApplication] = [:]
    private var webAttempt = 0
    private(set) var socketPath: String?
    /// The socket file this server bound, for `stop()` to remove: `socketPath`
    /// is only published once the listener is ready, and a stop can come first.
    private var boundPath: String?
    private(set) var webPort: UInt16?
    private var isStopped = false

    /// Discord's ceiling on IPC connections, and its handshake's patience.
    static let maximumConnections = 100
    static let handshakeTimeout: Duration = .seconds(10)

    init(host: Host) {
        self.host = host
    }

    /// Opens the IPC socket in `directory` — the first of `discord-ipc-0…9`
    /// free — and, given a first port, the WebSocket there or after it.
    func start(directory: URL, firstPort: UInt16?) {
        isStopped = false
        Task { await openIPC(in: directory) }
        if let firstPort { openWebSocket(firstPort: firstPort) }
    }

    /// Closes every socket — signed out — and takes the listeners down.
    func stop() {
        isStopped = true
        for connection in connections.values { connection.close(.normal, "User logged out") }
        connections.removeAll()
        ipcListener?.cancel()
        ipcListener = nil
        webListener?.cancel()
        webListener = nil
        if let path = boundPath ?? socketPath { unlink(path) }
        boundPath = nil
        socketPath = nil
        webPort = nil
    }

    // MARK: The IPC socket

    /// Takes the first slot nobody answers on — Discord's
    /// `getAvailableSocket` with its test (`998921`'s `T`): a path is free
    /// when connecting to it fails, and in use when something PONGs, or says
    /// nothing for a second.
    private func openIPC(in directory: URL) async {
        for index in 0..<10 {
            let path = directory.appending(path: LocalRPC.socketName(index: index)).path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: path) {
                guard await Self.isStale(path) else { continue }
                unlink(path)
            }
            guard !isStopped else { return }
            if listenIPC(at: path) { return }
        }
        Self.trace("no free discord-ipc slot")
    }

    private func listenIPC(at path: String) -> Bool {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        guard let listener = try? NWListener(using: parameters) else { return false }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.acceptIPC(connection) }
        }
        // The path is published once the listener is READY, not when it is
        // started: a client that read it earlier could be refused, as a test
        // that connected straight away was on a busy main thread.
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    guard !self.isStopped else { return }
                    self.socketPath = path
                    Self.trace("listening at \(path)")
                case .failed(let error):
                    Self.trace("discord-ipc listener failed: \(error)")
                    self.ipcListener?.cancel()
                    self.ipcListener = nil
                    self.socketPath = nil
                default:
                    break
                }
            }
        }
        listener.start(queue: .main)
        ipcListener = listener
        boundPath = path
        return true
    }

    /// Whether a socket file is left over: connecting fails, where a live
    /// server would answer a PING.
    private static func isStale(_ path: String) async -> Bool {
        await withCheckedContinuation { continuation in
            StaleProbe(path: path, continuation: continuation).start()
        }
    }

    private func acceptIPC(_ raw: NWConnection) {
        let connection = LocalRPCConnection(id: nextConnectionID(), transport: .ipc, connection: raw)
        let open = connections.values.count { $0.transport == .ipc }
        connection.start()
        guard open < Self.maximumConnections else {
            return connection.close(.abnormal, "Server at capacity")
        }
        track(connection)
        connection.onFrame = { [weak self, weak connection] frame in
            guard let self, let connection else { return }
            handle(frame, on: connection)
        }
        Task { [weak connection] in
            try? await Task.sleep(for: Self.handshakeTimeout)
            guard let connection, !connection.didHandshake, !connection.isClosed else { return }
            connection.close(.abnormal, "Handshake timeout")
        }
    }

    /// `998921`'s `dispatchMessage`. A version, handshake or order error
    /// closes as unsupported, with Discord's words.
    private func handle(_ frame: LocalRPCFrameReader.Frame, on connection: LocalRPCConnection) {
        switch frame.opcode {
        case .ping:
            connection.pong(frame.payload)
        case .pong:
            break
        case .handshake:
            guard !connection.didHandshake else { return connection.close(.unsupported, "already did handshake") }
            connection.clientID = Self.javaScriptString(frame.payload["client_id"])
            let version = Self.javaScriptNumber(frame.payload["v"])
            guard version == Double(LocalRPC.version) else {
                return connection.close(.unsupported, "Invalid Version: \(Self.written(version))")
            }
            connection.didHandshake = true
            // `sq`: a socket with no origin is an IPC one.
            connection.scopes = [.ipc]
            Task { await admit(connection) }
        case .frame:
            guard connection.didHandshake else { return connection.close(.unsupported, "did not handshake") }
            guard connection.isReady else { return }
            Task { await request(frame.payload, from: connection) }
        case .close:
            connection.close(.normal, "client disconnect")
        }
    }

    // MARK: The WebSocket

    /// 127.0.0.1 from `firstPort`, the next port a second after a busy one,
    /// round the ten — Discord's `N`.
    private func openWebSocket(firstPort: UInt16) {
        let port = firstPort + UInt16(webAttempt) % LocalRPC.portRange
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, !self.isStopped else { return }
                switch state {
                case .ready:
                    self.webPort = port
                    Self.trace("websocket on \(port)")
                case .failed:
                    self.webListener?.cancel()
                    self.webListener = nil
                    self.webAttempt += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self, !self.isStopped else { return }
                        self.openWebSocket(firstPort: firstPort)
                    }
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.acceptWebSocket(connection) }
        }
        listener.start(queue: .main)
        webListener = listener
    }

    private func acceptWebSocket(_ raw: NWConnection) {
        let connection = LocalRPCConnection(id: nextConnectionID(), transport: .webSocket, connection: raw)
        track(connection)
        connection.onUpgrade = { [weak self, weak connection] request in
            guard let self, let connection else { return }
            upgrade(connection, request)
        }
        connection.onMessage = { [weak self, weak connection] message in
            guard let self, let connection, connection.isReady else { return }
            Task { await self.request(message, from: connection) }
        }
        connection.start()
    }

    /// `33006`'s `handleConnection`: the socket's version and encoding, then
    /// the same admission an IPC handshake gets.
    private func upgrade(_ connection: LocalRPCConnection, _ request: LocalRPCUpgradeRequest) {
        let version = request.query["v"].flatMap(Double.init) ?? 0
        guard version == Double(LocalRPC.version) else {
            return connection.close(.invalidVersion, "Invalid Version: \(Self.written(version))")
        }
        let encoding = request.query["encoding"] ?? "json"
        guard encoding == "json" else {
            return encoding == "etf"
                ? connection.close(.invalidEncoding, "Erlpack cannot be used on this client")
                : connection.close(.invalidEncoding, "Invalid Encoding: \(encoding)")
        }
        connection.origin = request.origin ?? ""
        connection.clientID = request.query["client_id"]
        Task { await admit(connection) }
    }

    // MARK: Admission

    /// `546983`'s `j7`: a Discord page needs no client id; anything else must
    /// name one, wait its turn in the app's throttle, and be an app Discord
    /// knows — whose `rpc_origins` must hold a page's origin. Then READY.
    private func admit(_ connection: LocalRPCConnection) async {
        let clientID = connection.clientID ?? ""
        if clientID.isEmpty, connection.transport == .webSocket, LocalRPC.isDiscordOrigin(connection.origin) {
            connection.scopes = [.discordPage]
            return ready(connection)
        }
        guard !clientID.isEmpty else { return connection.close(.invalidClientID, "No Client ID Specified") }
        await throttle(for: clientID).wait { [weak connection] in connection?.isClosed == false }
        guard !connection.isClosed else { return }
        guard let id = UInt64(clientID).map(ApplicationID.init(rawValue:)),
              let application = await application(id, refetch: connection.transport == .webSocket)
        else { return connection.close(.invalidClientID, "Invalid Client ID") }
        if connection.transport == .webSocket, !application.rpcOrigins.contains(connection.origin ?? "") {
            return connection.close(.invalidOrigin, "Invalid Origin")
        }
        guard !connection.isClosed else { return }
        connection.application = application
        ready(connection)
    }

    /// A page's app is asked about afresh, for its origins; an IPC one is
    /// taken from what this session already knows where it can.
    private func application(_ id: ApplicationID, refetch: Bool) async -> RPCApplication? {
        if !refetch, let known = applications[id] { return known }
        guard let fetched = try? await host.application(id) else { return nil }
        applications[id] = fetched
        return fetched
    }

    /// `289919`'s `handleConnect`.
    private func ready(_ connection: LocalRPCConnection) {
        var user: RPCValue?
        if connection.transport == .ipc {
            guard let current = host.currentUser() else { return connection.close(.normal, "User logged out") }
            user = current
        }
        connection.isReady = true
        connection.send(LocalRPC.ready(user: user))
        Self.trace("socket \(connection.id) ready for \(connection.clientID ?? "a Discord page")")
    }

    private func throttle(for clientID: String) -> Throttle {
        if let existing = throttles[clientID] { return existing }
        // Discord's own allowlisted app gets sixty a minute; everyone else two.
        let throttle = Throttle(capacity: clientID == "207646673902501888" ? 60 : 2, period: .seconds(60))
        throttles[clientID] = throttle
        return throttle
    }

    // MARK: Requests

    /// `289919`'s `handleRequest`: a nonce, a command this server knows, the
    /// scope for it, its schema — then the command, answered with its result
    /// or with Discord's error frame.
    private func request(_ payload: RPCValue, from connection: LocalRPCConnection) async {
        // Echoed as they came, whatever their type — and an absent `cmd` is
        // JavaScript's `undefined`, which leaves the key out of the answer.
        let command = payload["cmd"]?.string
        let nonce = payload["nonce"]
        do throws(LocalRPC.CommandError) {
            guard let nonce, !nonce.isNull, nonce != .string("") else {
                throw LocalRPC.CommandError(.invalidPayload, "Payload requires a nonce")
            }
            let result = try await perform(command ?? "undefined", args: payload["args"], on: connection)
            guard !connection.isClosed else { return }
            connection.send(LocalRPC.message(cmd: command, data: result, nonce: nonce))
        } catch {
            connection.send(LocalRPC.errorMessage(cmd: command, error: error, nonce: nonce))
        }
    }

    private func perform(
        _ command: String,
        args: RPCValue?,
        on connection: LocalRPCConnection
    ) async throws(LocalRPC.CommandError) -> RPCValue {
        switch command {
        case "SET_ACTIVITY":
            try requireScope(connection.scopes.contains(.ipc))
            return try await setActivity(args, on: connection)
        case "INVITE_BROWSER":
            try requireScope(connection.scopes.contains(.discordPage))
            guard let code = args?["code"]?.string else {
                throw LocalRPC.CommandError(.invalidInvite, "Invalid invite id: undefined")
            }
            let invite = try await host.openInvite(code)
            return .object(["invite": invite, "code": .string(code)])
        case "DEEP_LINK":
            try requireScope(!connection.scopes.isEmpty)
            host.openDeepLink(args?["type"]?.string ?? "", args?["params"])
            return .null
        default:
            throw LocalRPC.CommandError(.invalidCommand, "Invalid command: \(command)")
        }
    }

    private func requireScope(_ isAllowed: Bool) throws(LocalRPC.CommandError) {
        guard isAllowed else {
            throw LocalRPC.CommandError(.invalidPermissions, "Not authenticated or invalid scope")
        }
    }

    /// Discord's SET_ACTIVITY handler: checked and shaped by
    /// `LocalRPCActivityRequest`, its pictures resolved, then published —
    /// unless the socket left while they were.
    private func setActivity(_ args: RPCValue?, on connection: LocalRPCConnection) async throws(LocalRPC.CommandError) -> RPCValue {
        guard let application = connection.application else {
            throw LocalRPC.CommandError(.invalidPermissions, "Not authenticated or invalid scope")
        }
        let request = try LocalRPCActivityRequest(
            args: args,
            application: (application.id, application.name),
            requiresPID: connection.transport == .ipc,
            partyPrivacy: host.partyPrivacy()
        )
        guard request.activity != nil else {
            host.setActivity(connection.id, nil)
            connection.hasActivity = false
            return .null
        }
        let pictures = request.largeImage == nil && request.smallImage == nil
            ? (large: nil, small: nil)
            : await host.resolveAssets(application.id, request.largeImage, request.smallImage)
        guard !connection.isClosed, let activity = request.resolvingAssets(large: pictures.large, small: pictures.small)
        else { return .null }
        host.setActivity(connection.id, activity)
        connection.hasActivity = true
        return Self.reply(for: activity)
    }

    /// The activity as SET_ACTIVITY answers with it — the shaped object
    /// Discord's handler returns.
    static func reply(for activity: RichPresenceActivity) -> RPCValue {
        var fields: [String: RPCValue] = [
            "name": .string(activity.name),
            "type": .number(Double(activity.type)),
            "application_id": activity.applicationID.map { .string(String($0.rawValue)) } ?? .null,
            "platform": .string("desktop"),
            "metadata": .object(activity.buttonURLs.isEmpty ? [:] : [
                "button_urls": .array(activity.buttonURLs.map { .string($0.absoluteString) }),
            ]),
        ]
        if let details = activity.details { fields["details"] = .string(details) }
        if let state = activity.state { fields["state"] = .string(state) }
        if let url = activity.detailsURL { fields["details_url"] = .string(url.absoluteString) }
        if let url = activity.stateURL { fields["state_url"] = .string(url.absoluteString) }
        if !activity.buttons.isEmpty { fields["buttons"] = .array(activity.buttons.map(RPCValue.string)) }
        if activity.flags > 0 { fields["flags"] = .number(Double(activity.flags)) }
        if let type = activity.statusDisplayType { fields["status_display_type"] = .number(Double(type)) }
        if let timestamps = activity.timestamps {
            var stamps: [String: RPCValue] = [:]
            if let start = timestamps.start { stamps["start"] = .number(Double(start)) }
            if let end = timestamps.end { stamps["end"] = .number(Double(end)) }
            fields["timestamps"] = .object(stamps)
        }
        if let assets = activity.assets {
            var pictures: [String: RPCValue] = [:]
            if let value = assets.largeImage { pictures["large_image"] = .string(value) }
            if let value = assets.largeText { pictures["large_text"] = .string(value) }
            if let value = assets.largeURL { pictures["large_url"] = .string(value.absoluteString) }
            if let value = assets.smallImage { pictures["small_image"] = .string(value) }
            if let value = assets.smallText { pictures["small_text"] = .string(value) }
            if let value = assets.smallURL { pictures["small_url"] = .string(value.absoluteString) }
            fields["assets"] = .object(pictures)
        }
        if let party = activity.party {
            var values: [String: RPCValue] = [:]
            if let id = party.id { values["id"] = .string(id) }
            if let size = party.size { values["size"] = .array(size.map { .number(Double($0)) }) }
            fields["party"] = .object(values)
        }
        return .object(fields)
    }

    // MARK: Bookkeeping

    private func nextConnectionID() -> Int {
        nextID += 1
        return nextID
    }

    /// Kept until it closes — and then its activity goes with it, Discord's
    /// `RPC_APP_DISCONNECTED`.
    private func track(_ connection: LocalRPCConnection) {
        connections[connection.id] = connection
        connection.onClosed = { [weak self, weak connection] in
            guard let self, let connection else { return }
            connections[connection.id] = nil
            if connection.hasActivity { host.setActivity(connection.id, nil) }
        }
    }

    /// A handshake's `client_id` as JavaScript reads it into a URL: a string
    /// as it is, a number as it is written.
    private static func javaScriptString(_ value: RPCValue?) -> String? {
        switch value {
        case .string(let text): text
        case .number(let number): written(number)
        default: nil
        }
    }

    /// `+e.v`: a number, a numeric string, or NaN.
    private static func javaScriptNumber(_ value: RPCValue?) -> Double {
        switch value {
        case .number(let number): number
        case .string(let text): Double(text.trimmingCharacters(in: .whitespaces)) ?? .nan
        case .bool(let flag): flag ? 1 : 0
        default: .nan
        }
    }

    private static func written(_ number: Double) -> String {
        if number.isNaN { return "NaN" }
        return number.rounded() == number ? String(Int64(number)) : number.description
    }

    nonisolated static func trace(_ message: @autoclosure () -> String) {
        SessionController.trace("rpc: \(message())")
    }
}

/// Discord's handshake throttle (`898467`): a bucket of `capacity` tokens, one
/// back every `period / capacity`, and a queue that waits for them rather
/// than being refused.
final class Throttle {
    private let capacity: Int
    private let interval: Duration
    private var tokens: Int
    private var waiting: [(isLive: () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []
    private var refill: Task<Void, Never>?

    init(capacity: Int, period: Duration) {
        self.capacity = capacity
        self.interval = period / capacity
        self.tokens = capacity
    }

    /// Returns when a token is free — or as soon as `isLive` says the socket
    /// waiting for it has gone, which takes no token (Discord's waiter is
    /// taken out of the queue when its socket aborts).
    func wait(while isLive: @escaping () -> Bool) async {
        if tokens > 0, waiting.isEmpty {
            take()
            return
        }
        await withCheckedContinuation { waiting.append((isLive, $0)) }
    }

    private func take() {
        tokens -= 1
        guard refill == nil else { return }
        refill = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: self.interval)
                self.tokens = min(self.capacity, self.tokens + 1)
                while self.tokens > 0, !self.waiting.isEmpty {
                    let waiter = self.waiting.removeFirst()
                    if waiter.isLive() { self.tokens -= 1 }
                    waiter.continuation.resume()
                }
                if self.tokens >= self.capacity, self.waiting.isEmpty {
                    self.refill = nil
                    return
                }
            }
        }
    }
}

/// One look at a socket file: a connection that fails means nobody is there;
/// one that answers a PING, or says nothing for a second, means somebody is.
private final class StaleProbe {
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Bool, Never>?

    init(path: String, continuation: CheckedContinuation<Bool, Never>) {
        connection = NWConnection(to: .unix(path: path), using: .tcp)
        self.continuation = continuation
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    connection.send(
                        content: LocalRPCFrame.encode(.ping, .string("wingcord")),
                        completion: .contentProcessed { _ in }
                    )
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] _, _, _, _ in
                        MainActor.assumeIsolated { answer(stale: false) }
                    }
                case .waiting, .failed:
                    answer(stale: true)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in answer(stale: false) }
    }

    private func answer(stale: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: stale)
    }
}
