import Foundation
import Network

// MARK: - Valve's Game State Integration, received
//
// docs/CLIPS-PRESENCE.md, Phase 3.4. Dota 2 and Counter-Strike 2 POST a JSON
// document to the `uri` their `gamestate_integration_*.cfg` names, every time
// their state changes. This is the smallest HTTP server that takes one: on
// 127.0.0.1 only, one request per connection, a `200` and the connection
// closed — the game opens another for the next.

@MainActor
final class GameStateServer {

    /// A document arrived. The body is the game's JSON, unread.
    var onDocument: ((Data) -> Void)?

    private(set) var port: UInt16
    private var listener: NWListener?
    private(set) var isListening = false

    /// The most a document may be — Dota's whole state with every component
    /// is a few tens of kilobytes; anything past this is not a game.
    static let largestDocument = 1 << 20

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        guard listener == nil, let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        // **Loopback only.** Nothing off this Mac has any business telling a
        // clip what happened in a game.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.isListening = true
                case .failed, .cancelled: self?.isListening = false
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isListening = false
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffered: Data())
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                var buffered = buffered
                if let data { buffered.append(data) }
                guard buffered.count <= Self.largestDocument, error == nil else { return connection.cancel() }
                if let body = Self.body(of: buffered) {
                    Self.respond(on: connection)
                    self.onDocument?(body)
                } else if isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffered: buffered)
                }
            }
        }
    }

    /// The request's body once the whole of it has arrived, by its
    /// `Content-Length`.
    nonisolated static func body(of request: Data) -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = request.range(of: separator) else { return nil }
        let head = String(decoding: request[..<end.lowerBound], as: UTF8.self)
        let length = head.split(separator: "\r\n").lazy.compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
            else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let body = request[end.upperBound...]
        guard body.count >= length else { return nil }
        return Data(body.prefix(length))
    }

    private static func respond(on connection: NWConnection) {
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
