import Foundation
import OSLog

/// What somebody looking at the QR code sees happen.
public enum RemoteAuthEvent: Sendable, Equatable {
    /// A new key and a new socket; the code isn't drawn yet.
    case connecting
    /// The code, ready to scan.
    case ready(url: URL, fingerprint: String)
    /// Somebody scanned it; their phone is asking them.
    case scanned(RemoteAuthUser)
    /// They said yes and the token's being fetched.
    case loggingIn
    /// Signed in. The stream ends after this.
    case token(String)
    /// The socket went away. Another key follows after a pause — the code on
    /// screen is dead until then.
    case interrupted
    /// The phone said yes and the login still didn't finish — Discord refused
    /// the ticket, or asked for a human check that wasn't passed. Said once,
    /// for the screen to show, before a new code.
    case failed(AuthRefusal?)
}

/// The QR code's socket, around `RemoteAuthHandshake`.
///
/// **One key per code, and every restart is a new one** — Discord's own client
/// makes a fresh pair each time it connects, so a code that was on somebody's
/// screen a minute ago can't be scanned after the gateway has let it go.
///
/// The web client's rules, kept: heartbeats after a random part of the interval
/// and then on it, a missed acknowledgement closes the socket; a phone that says
/// no starts over at once; anything else that ends the socket waits 1.5 seconds,
/// doubling to 30, before the next key (`new Backoff(1500, 3e4)`), and a code
/// that reached the screen resets the wait.
///
/// Runs only while somebody's iterating `events()`: the login screen's task.
public actor RemoteAuthSession {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "RemoteAuth")

    public static let endpoint = URL(string: "wss://remote-auth-gateway.discord.gg/?v=2")!

    private let rest: DiscordREST
    private let userAgent: String
    private let session: URLSession
    /// Which socket a heartbeat belongs to, so one left over from a closed
    /// socket stops instead of closing the next.
    private var generation = 0
    private var acknowledged = true

    public init(rest: DiscordREST) {
        self.rest = rest
        userAgent = rest.metadata.userAgent
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    /// The code's life, from the first key to a token. Cancelling the
    /// iteration closes the socket.
    public nonisolated func events() -> AsyncStream<RemoteAuthEvent> {
        AsyncStream { continuation in
            let task = Task { await self.run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum Ending {
        case token(String)
        case startOver
        case failed(String)
        /// After the phone's yes: worth telling somebody, not only retrying.
        case failedAfterApproval(AuthRefusal?, String)
    }

    private func run(_ continuation: AsyncStream<RemoteAuthEvent>.Continuation) async {
        var delay: Double = 1.5
        while !Task.isCancelled {
            continuation.yield(.connecting)
            switch await attempt(continuation, onReady: { delay = 1.5 }) {
            case .token(let token):
                continuation.yield(.token(token))
                continuation.finish()
                return
            case .startOver:
                delay = 1.5
            case .failedAfterApproval(let refusal, let reason):
                Self.log.error("remote auth login failed after approval: \(reason, privacy: .public)")
                continuation.yield(.failed(refusal))
                delay = 1.5
            case .failed(let reason):
                Self.log.info("remote auth ended: \(reason, privacy: .public)")
                continuation.yield(.interrupted)
                try? await Task.sleep(for: .seconds(delay))
                delay = min(30, delay * 2)
            }
        }
        continuation.finish()
    }

    private func attempt(
        _ continuation: AsyncStream<RemoteAuthEvent>.Continuation,
        onReady: () -> Void
    ) async -> Ending {
        let handshake: RemoteAuthHandshake
        do {
            handshake = RemoteAuthHandshake(key: try RemoteAuthKey.generate())
        } catch {
            return .failed("key: \(error)")
        }

        var request = URLRequest(url: Self.endpoint)
        // The gateway is Discord's web client's, and answers that origin.
        request.setValue("https://discord.com", forHTTPHeaderField: "Origin")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let socket = session.webSocketTask(with: request)
        generation += 1
        let mine = generation
        acknowledged = true
        socket.resume()
        var heartbeat: Task<Void, Never>?
        /// Set once the phone has said yes: a failure after it is the login's,
        /// not the socket's.
        var approved = false
        defer {
            heartbeat?.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
        }

        do {
            for output in handshake.opened() { try await perform(output, on: socket) }
            while !Task.isCancelled {
                let frame = try await socket.receive()
                let text: String
                switch frame {
                case .string(let value): text = value
                case .data(let value): text = String(decoding: value, as: UTF8.self)
                @unknown default: continue
                }
                for output in try handshake.receive(text) {
                    switch output {
                    case .send:
                        try await perform(output, on: socket)
                    case .startHeartbeat(let interval):
                        heartbeat?.cancel()
                        heartbeat = Task { await self.beat(socket, every: interval, generation: mine) }
                    case .heartbeatAcknowledged:
                        acknowledged = true
                    case .ready(let url, let fingerprint):
                        onReady()
                        continuation.yield(.ready(url: url, fingerprint: fingerprint))
                    case .scanned(let user):
                        continuation.yield(.scanned(user))
                    case .cancelled:
                        return .startOver
                    case .ticket(let ticket):
                        approved = true
                        continuation.yield(.loggingIn)
                        let encrypted = try await rest.exchangeRemoteAuthTicket(ticket)
                        return .token(try handshake.decryptToken(encrypted))
                    }
                }
            }
            return .failed("cancelled")
        } catch {
            let code = socket.closeCode.rawValue
            if approved { return .failedAfterApproval(error as? AuthRefusal, "\(error)") }
            return .failed("\(error) (close \(code))")
        }
    }

    private func perform(_ output: RemoteAuthOutput, on socket: URLSessionWebSocketTask) async throws {
        guard case .send(let text) = output else { return }
        try await socket.send(.string(text))
    }

    /// The web client's heartbeat: a random part of the interval first, then on
    /// it; an unanswered one closes the socket, which `attempt` reads as an end.
    private func beat(_ socket: URLSessionWebSocketTask, every interval: Duration, generation mine: Int) async {
        let first = Double.random(in: 0...1) * Double(interval.components.seconds)
        try? await Task.sleep(for: .seconds(first))
        while !Task.isCancelled, generation == mine {
            guard acknowledged else {
                Self.log.info("heartbeat unanswered, closing")
                socket.cancel(with: .goingAway, reason: nil)
                return
            }
            acknowledged = false
            try? await socket.send(.string(RemoteAuthHandshake.heartbeatFrame))
            try? await Task.sleep(for: interval)
        }
    }
}
