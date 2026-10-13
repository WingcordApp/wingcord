import Foundation

// MARK: - Discord's local RPC server, the wire
//
// What a game's SDK sends over `discord-ipc-N`, and what a discord.com page
// sends to `ws://127.0.0.1:6463`. Read out of Discord's own server in its web
// bundle: `998921` the IPC transport, `289919` the server, `313731` a socket,
// `33006` the WebSocket transport, `546983`/`90924` the handshake. The codes,
// the words and the limits below are Discord's.

public enum LocalRPC {

    /// The only protocol version — Discord's `dL4`. A socket asking for any
    /// other is closed with `invalidVersion`.
    public static let version = 1

    /// The WebSocket server's first port, and how many it tries after a busy
    /// one — Discord's `xEi` and `sJq`: 6463 to 6472.
    public static let firstPort: UInt16 = 6463
    public static let portRange: UInt16 = 10

    /// The IPC socket's name in the temporary folder, `discord-ipc-0` to `-9`.
    public static func socketName(index: Int) -> String { "discord-ipc-\(index)" }

    /// The IPC opcodes (`998921`'s `f`).
    public enum Opcode: Int32, Sendable {
        case handshake = 0
        case frame = 1
        case close = 2
        case ping = 3
        case pong = 4
    }

    /// A command's failure — `{cmd, evt: "ERROR", data: {code, message}}`,
    /// Discord's `Lw6`, the codes this server can send.
    public enum ErrorCode: Int, Sendable {
        case invalidPayload = 4000
        case invalidCommand = 4002
        case invalidPermissions = 4006
        case invalidInvite = 4011
        case invalidActivitySecret = 5005
    }

    /// Why a socket is closed — Discord's `YI$`.
    public enum CloseCode: Int, Sendable {
        case normal = 1000
        case unsupported = 1003
        case abnormal = 1006
        case invalidClientID = 4000
        case invalidOrigin = 4001
        case invalidVersion = 4004
        case invalidEncoding = 4005
    }

    /// A failure that answers one request: Discord's `bH.A` with an error code.
    public struct CommandError: Error, Equatable, Sendable {
        public var code: ErrorCode
        public var message: String

        public init(_ code: ErrorCode, _ message: String) {
            self.code = code
            self.message = message
        }
    }

    /// Whether a page's origin is Discord's own — `90924`'s `IR`: `https://`,
    /// at most one lowercase label in front, then discord.com or
    /// discordapp.com, and never a staging host. Such a page needs no client
    /// id, and only such a page may open an invite or a link in the app.
    public static func isDiscordOrigin(_ origin: String?) -> Bool {
        guard let origin, !origin.contains("staging") else { return false }
        return origin.wholeMatch(of: discordOrigin) != nil
    }

    nonisolated(unsafe) private static let discordOrigin = /https:\/\/(?:[a-z]+\.)?(?:discordapp\.com|discord\.com)/

    // MARK: Messages

    /// A frame's payload — `289919`'s `dispatch`: `{cmd, data, evt, nonce}`,
    /// `evt` and `nonce` null where there are none. The nonce is the request's
    /// own, whatever its type; a request without a `cmd` is answered without
    /// one, as `JSON.stringify` drops an `undefined`.
    public static func message(cmd: String?, data: RPCValue, evt: String? = nil, nonce: RPCValue?) -> RPCValue {
        var fields: [String: RPCValue] = [
            "data": data,
            "evt": evt.map(RPCValue.string) ?? .null,
            "nonce": nonce ?? .null,
        ]
        if let cmd { fields["cmd"] = .string(cmd) }
        return .object(fields)
    }

    /// A command's failure, as `289919`'s `error` sends it.
    public static func errorMessage(cmd: String?, error: CommandError, nonce: RPCValue?) -> RPCValue {
        message(
            cmd: cmd,
            data: .object(["code": .number(Double(error.code.rawValue)), "message": .string(error.message)]),
            evt: "ERROR",
            nonce: nonce
        )
    }

    /// What a socket hears first — `289919`'s `handleConnect`: the version,
    /// where Discord's API and CDN are, and, over IPC only, who is signed in.
    public static func ready(user: RPCValue?) -> RPCValue {
        var data: [String: RPCValue] = [
            "v": .number(Double(version)),
            "config": .object([
                "cdn_host": .string("cdn.discordapp.com"),
                "api_endpoint": .string("//discord.com/api"),
                "environment": .string("production"),
            ]),
        ]
        if let user { data["user"] = user }
        return message(cmd: "DISPATCH", data: .object(data), evt: "READY", nonce: nil)
    }

    /// The reader as READY names them — `639621`: the user's public fields
    /// and nothing else.
    public static func user(
        id: String,
        username: String,
        discriminator: String,
        globalName: String?,
        avatar: String?,
        bot: Bool,
        flags: Int,
        premiumType: Int
    ) -> RPCValue {
        .object([
            "id": .string(id),
            "username": .string(username),
            "discriminator": .string(discriminator),
            "global_name": globalName.map(RPCValue.string) ?? .null,
            "avatar": avatar.map(RPCValue.string) ?? .null,
            "avatar_decoration_data": .null,
            "bot": .bool(bot),
            "flags": .number(Double(flags)),
            "premium_type": .number(Double(premiumType)),
        ])
    }
}

// MARK: - The IPC frame

/// One IPC frame: an opcode, then the JSON's length, both 32-bit
/// little-endian, then the JSON — `998921`'s `m`.
public enum LocalRPCFrame {

    public static func encode(_ opcode: LocalRPC.Opcode, _ payload: RPCValue) -> Data {
        let json = payload.jsonData
        var data = Data(capacity: 8 + json.count)
        withUnsafeBytes(of: opcode.rawValue.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(json.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(json)
        return data
    }
}

/// Reads frames out of a stream as they arrive, a header and then its body —
/// `998921`'s `read` and `processMessages`, with Discord's limits: 5 MiB held
/// at once, 3 MiB a frame, and an opcode that is one of the five.
public struct LocalRPCFrameReader: Sendable {
    public struct Frame: Equatable, Sendable {
        public var opcode: LocalRPC.Opcode
        public var payload: RPCValue
    }

    /// Why a stream was given up on — each of Discord's words, which become
    /// the reason the socket is closed with.
    public enum Failure: Error, Equatable, Sendable {
        case bufferExceeded
        case protocolError
        case messageTooLarge
        case notJSON

        public var message: String {
            switch self {
            case .bufferExceeded: "total buffer size exceeded"
            case .protocolError: "protocol error"
            case .messageTooLarge: "message too large"
            // Discord passes on V8's own parse error here; these are the
            // words its WebSocket transport closes with for the same thing.
            case .notJSON: "Payload not json"
            }
        }
    }

    public static let maximumBuffer = 5_242_880
    public static let maximumFrame = 3_145_728

    private var buffer = Data()
    private var header: (opcode: LocalRPC.Opcode, size: Int)?

    public init() {}

    /// Takes what arrived and answers with every frame now whole.
    public mutating func read(_ bytes: Data) throws(Failure) -> [Frame] {
        guard buffer.count + bytes.count <= Self.maximumBuffer else { throw .bufferExceeded }
        buffer.append(bytes)
        var frames: [Frame] = []
        while true {
            if header == nil {
                guard buffer.count >= 8 else { break }
                let raw = buffer.prefix(8).withUnsafeBytes { bytes in
                    (bytes.loadUnaligned(fromByteOffset: 0, as: Int32.self).littleEndian,
                     bytes.loadUnaligned(fromByteOffset: 4, as: Int32.self).littleEndian)
                }
                guard let opcode = LocalRPC.Opcode(rawValue: raw.0), raw.1 >= 0 else { throw .protocolError }
                guard raw.1 <= Self.maximumFrame else { throw .messageTooLarge }
                header = (opcode, Int(raw.1))
                buffer.removeFirst(8)
            }
            guard let current = header, buffer.count >= current.size else { break }
            let body = buffer.prefix(current.size)
            buffer.removeFirst(current.size)
            header = nil
            guard let payload = RPCValue(json: Data(body)) else { throw .notJSON }
            frames.append(Frame(opcode: current.opcode, payload: payload))
        }
        return frames
    }
}

// MARK: - JSON

/// A JSON value as the RPC server handles one: the protocol is untyped, and a
/// request is checked field by field against Discord's schema before anything
/// reads it — see `LocalRPCActivity`.
public enum RPCValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RPCValue])
    case object([String: RPCValue])

    /// Parses JSON — any top-level value, as `JSON.parse` does.
    public init?(json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed]) else {
            return nil
        }
        self.init(foundation: object)
    }

    private init?(foundation value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // A JSON `true` and a JSON `1` arrive as the same class; the
            // boolean is the one Core Foundation calls a boolean.
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            var values: [RPCValue] = []
            for element in array {
                guard let value = RPCValue(foundation: element) else { return nil }
                values.append(value)
            }
            self = .array(values)
        case let dictionary as [String: Any]:
            var values: [String: RPCValue] = [:]
            for (key, element) in dictionary {
                guard let value = RPCValue(foundation: element) else { return nil }
                values[key] = value
            }
            self = .object(values)
        default:
            return nil
        }
    }

    public var jsonData: Data {
        (try? JSONSerialization.data(withJSONObject: foundation, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            ?? Data("null".utf8)
    }

    private var foundation: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        // A whole number goes out without a fraction, as JavaScript writes it.
        case .number(let value):
            value.rounded() == value && abs(value) < 9_007_199_254_740_992 ? NSNumber(value: Int64(value)) : NSNumber(value: value)
        case .string(let value): value
        case .array(let values): values.map(\.foundation)
        case .object(let values): values.mapValues(\.foundation)
        }
    }

    public subscript(key: String) -> RPCValue? {
        if case .object(let values) = self { return values[key] }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var array: [RPCValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    public var isNull: Bool { self == .null }
}
