import Foundation
import Network
import WingcordCore
import WingcordNet

/// One app's connection to the local RPC server — a game's SDK over
/// `discord-ipc-N`, or a discord.com page over the WebSocket — and what the
/// server knows about it: Discord's `313731` socket, with its transport.
///
/// **On the main queue, like everything it reports to.** A connection carries
/// a handshake and a presence or two a minute; Discord's own server runs on
/// its renderer's main thread for the same reason.
final class LocalRPCConnection {
    enum Transport {
        case ipc
        case webSocket
    }

    /// What a socket may do — Discord's pseudo-scopes. An IPC socket gets
    /// the one SET_ACTIVITY and DEEP_LINK accept (`hj`); a Discord page
    /// without a client id the two its browser commands accept (`LQ`, `kw`).
    enum Scope {
        case ipc
        case discordPage
    }

    let id: Int
    let transport: Transport
    private let connection: NWConnection

    /// The app's client id, as its handshake gave it.
    var clientID: String?
    /// The app the client id names, once Discord has said what it is.
    var application: RPCApplication?
    var scopes: Set<Scope> = []
    /// Through the handshake, the throttle and the app lookup, and READY sent:
    /// requests are heard from here on, and dropped before, as Discord's are.
    var isReady = false
    var didHandshake = false
    /// Whether this socket set an activity, which closing it clears.
    var hasActivity = false
    /// A page's origin, for the WebSocket.
    var origin: String?

    /// Each IPC frame; each WebSocket text message, parsed; the upgrade.
    var onFrame: ((LocalRPCFrameReader.Frame) -> Void)?
    var onMessage: ((RPCValue) -> Void)?
    var onUpgrade: ((LocalRPCUpgradeRequest) -> Void)?
    var onClosed: (() -> Void)?

    private var frameReader = LocalRPCFrameReader()
    private var messageReader = LocalRPCWebSocketReader()
    private var head = Data()
    private var isUpgraded = false
    private(set) var isClosed = false

    /// The HTTP head a page's upgrade may run to before it is refused.
    private static let maximumHead = 16_384

    init(id: Int, transport: Transport, connection: NWConnection) {
        self.id = id
        self.transport = transport
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                // A failed connection still has to be cancelled to let go.
                case .failed: self?.cancel()
                case .cancelled: self?.finish()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                if let data, !data.isEmpty { self.take(data) }
                if isComplete || error != nil {
                    self.cancel()
                } else if !self.isClosed {
                    self.receive()
                }
            }
        }
    }

    private func take(_ data: Data) {
        switch transport {
        case .ipc:
            do {
                for frame in try frameReader.read(data) where !isClosed { onFrame?(frame) }
            } catch {
                // `998921`: any read failure closes as unsupported, with its words.
                close(.unsupported, error.message)
            }
        case .webSocket:
            guard isUpgraded else { return takeHead(data) }
            do {
                for message in try messageReader.read(data) where !isClosed {
                    switch message {
                    case .text(let text):
                        guard let value = RPCValue(json: Data(text.utf8)) else {
                            return close(.unsupported, "Payload not json")
                        }
                        onMessage?(value)
                    case .ping(let payload):
                        send(raw: LocalRPCWebSocketFrame.pong(payload))
                    case .close:
                        close(.normal, "")
                    }
                }
            } catch {
                close(.unsupported, "Payload not json")
            }
        }
    }

    /// Gathers the HTTP head; an upgrade becomes a WebSocket, anything else is
    /// Discord's 404.
    private func takeHead(_ data: Data) {
        head.append(data)
        guard let end = head.range(of: Data("\r\n\r\n".utf8)) else {
            if head.count > Self.maximumHead { cancel() }
            return
        }
        guard let request = LocalRPCUpgradeRequest(head: String(decoding: head[..<end.lowerBound], as: UTF8.self)) else {
            return goodbye(LocalRPCUpgradeRequest.notFound)
        }
        let rest = head[end.upperBound...]
        head = Data()
        isUpgraded = true
        send(raw: request.response)
        onUpgrade?(request)
        if !rest.isEmpty, !isClosed { take(Data(rest)) }
    }

    // MARK: Sending

    /// One message: a FRAME over IPC, a text frame over the WebSocket.
    func send(_ payload: RPCValue) {
        guard !isClosed else { return }
        switch transport {
        case .ipc: send(raw: LocalRPCFrame.encode(.frame, payload))
        case .webSocket: send(raw: LocalRPCWebSocketFrame.text(payload))
        }
    }

    /// IPC's PONG, which echoes the PING.
    func pong(_ payload: RPCValue) {
        guard !isClosed else { return }
        send(raw: LocalRPCFrame.encode(.pong, payload))
    }

    private func send(raw data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Ends the socket the way its transport ends one — a CLOSE frame with
    /// `{code, message}` over IPC (`998921`'s `close`), a close frame over the
    /// WebSocket — and lets it go once that is written.
    func close(_ code: LocalRPC.CloseCode, _ message: String) {
        guard !isClosed else { return }
        let last = switch transport {
        case .ipc:
            LocalRPCFrame.encode(.close, .object([
                "code": .number(Double(code.rawValue)), "message": .string(message),
            ]))
        case .webSocket:
            LocalRPCWebSocketFrame.close(code.rawValue, reason: message)
        }
        goodbye(last)
    }

    /// Writes a last message and cancels the connection once it is out.
    ///
    /// **The completion holds the connection, not this object.** Finishing
    /// tells the server, which lets this object go at once — and a connection
    /// released mid-write loses the message and is never cancelled.
    private func goodbye(_ data: Data) {
        let connection = connection
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        finish()
    }

    private func cancel() {
        connection.cancel()
        finish()
    }

    /// Gone, by either side: reported once.
    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        onClosed?()
        onClosed = nil
        onFrame = nil
        onMessage = nil
        onUpgrade = nil
    }
}
