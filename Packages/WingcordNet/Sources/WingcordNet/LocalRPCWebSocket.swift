import CryptoKit
import Foundation

// MARK: - The WebSocket half
//
// What a discord.com page opens to `ws://127.0.0.1:6463/?v=1&encoding=json`
// when it hands an invite or a link to the app — RFC 6455 as far as such a page
// needs it: the upgrade, text messages, close, ping. Discord's transport is the
// `ws` package behind `33006`; this is its wire, not its code.

/// The request a page's WebSocket opens with. Any path upgrades, as on
/// Discord's own port.
public struct LocalRPCUpgradeRequest: Equatable, Sendable {
    public var query: [String: String]
    /// The page's origin — what decides whether it may speak without a
    /// client id (`LocalRPC.isDiscordOrigin`).
    public var origin: String?
    public var key: String

    /// Parses an HTTP request's head, or nil for anything that is not a
    /// WebSocket upgrade — which the server answers 404, as Discord's does.
    public init?(head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count == 3, requestLine[0] == "GET", requestLine[2].hasPrefix("HTTP/1.1") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard headers["upgrade"]?.lowercased() == "websocket",
              headers["connection"]?.lowercased().contains("upgrade") == true,
              headers["sec-websocket-version"] == "13",
              let key = headers["sec-websocket-key"], !key.isEmpty
        else { return nil }
        let target = URLComponents(string: String(requestLine[1]))
        query = Dictionary(
            (target?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        origin = headers["origin"]
        self.key = key
    }

    /// RFC 6455's accept value: the key and the protocol's GUID, SHA-1'd.
    public static func acceptValue(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    /// The 101 that turns the connection into a WebSocket.
    public var response: Data {
        Data((
            "HTTP/1.1 101 Switching Protocols\r\n"
                + "Upgrade: websocket\r\n"
                + "Connection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(Self.acceptValue(for: key))\r\n\r\n"
        ).utf8)
    }

    /// Discord's answer to anything else on its port — `33006`'s `T(…, 404,
    /// "Not Found")`.
    public static let notFound: Data = {
        let body = #"{"code":0,"message":"Not Found"}"#
        return Data((
            "HTTP/1.1 404 Not Found\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(body.utf8.count)\r\n"
                + "Connection: close\r\n\r\n"
                + body
        ).utf8)
    }()
}

/// WebSocket frames both ways.
public enum LocalRPCWebSocketFrame {
    /// A text message, unmasked as a server's must be.
    public static func text(_ payload: RPCValue) -> Data {
        frame(opcode: 0x1, payload: payload.jsonData)
    }

    /// A close with a code and Discord's reason.
    public static func close(_ code: Int, reason: String) -> Data {
        var payload = Data([UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)])
        payload.append(Data(reason.utf8.prefix(123)))
        return frame(opcode: 0x8, payload: payload)
    }

    public static func pong(_ payload: Data) -> Data {
        frame(opcode: 0xA, payload: payload)
    }

    private static func frame(opcode: UInt8, payload: Data) -> Data {
        var data = Data([0x80 | opcode])
        switch payload.count {
        case ..<126:
            data.append(UInt8(payload.count))
        case ..<65_536:
            data.append(126)
            data.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        default:
            data.append(127)
            withUnsafeBytes(of: UInt64(payload.count).bigEndian) { data.append(contentsOf: $0) }
        }
        data.append(payload)
        return data
    }
}

/// Reads a client's frames as they arrive, putting fragmented messages back
/// together.
public struct LocalRPCWebSocketReader: Sendable {
    public enum Message: Equatable, Sendable {
        case text(String)
        case close
        case ping(Data)
    }

    public enum Failure: Error, Equatable, Sendable {
        /// A client frame without a mask, or a control frame that is not
        /// whole — RFC 6455's protocol errors.
        case protocolError
        case tooLarge
        /// Binary is ETF, which Discord's own client takes only where it has
        /// erlpack; this server, like the web, takes JSON.
        case binary
    }

    /// What one message may hold: the IPC transport's 5 MiB.
    public static let maximumMessage = 5_242_880

    private var buffer = Data()
    private var fragments = Data()

    public init() {}

    public mutating func read(_ bytes: Data) throws(Failure) -> [Message] {
        buffer.append(bytes)
        guard buffer.count <= Self.maximumMessage + 14 else { throw .tooLarge }
        var messages: [Message] = []
        while let frame = try nextFrame() {
            switch frame.opcode {
            case 0x0, 0x1:
                fragments.append(frame.payload)
                guard fragments.count <= Self.maximumMessage else { throw .tooLarge }
                if frame.isFinal {
                    messages.append(.text(String(decoding: fragments, as: UTF8.self)))
                    fragments = Data()
                }
            case 0x2:
                throw .binary
            case 0x8:
                messages.append(.close)
            case 0x9:
                messages.append(.ping(frame.payload))
            case 0xA:
                continue
            default:
                throw .protocolError
            }
        }
        return messages
    }

    private mutating func nextFrame() throws(Failure) -> (isFinal: Bool, opcode: UInt8, payload: Data)? {
        let bytes = [UInt8](buffer.prefix(14))
        guard bytes.count >= 2 else { return nil }
        let isFinal = bytes[0] & 0x80 != 0
        let opcode = bytes[0] & 0x0F
        guard bytes[1] & 0x80 != 0 else { throw .protocolError }
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            var value: UInt64 = 0
            for byte in bytes[2..<10] { value = value << 8 | UInt64(byte) }
            guard value <= UInt64(Self.maximumMessage) else { throw .tooLarge }
            length = Int(value)
            offset = 10
        }
        // Control frames are short and whole (RFC 6455 §5.5).
        if opcode >= 0x8, !isFinal || length > 125 { throw .protocolError }
        guard buffer.count >= offset + 4 + length else { return nil }
        let mask = [UInt8](buffer.dropFirst(offset).prefix(4))
        var payload = [UInt8](buffer.dropFirst(offset + 4).prefix(length))
        for index in payload.indices { payload[index] ^= mask[index % 4] }
        buffer.removeFirst(offset + 4 + length)
        return (isFinal, opcode, Data(payload))
    }
}
