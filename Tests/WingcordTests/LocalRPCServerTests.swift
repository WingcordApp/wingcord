import Foundation
import Testing
@testable import Wingcord
import WingcordCore
import WingcordNet

/// The local RPC server driven end to end, as a game's SDK drives it: a real
/// Unix socket in a private folder, frames written and read off the main
/// thread while the server answers on it.
@MainActor
@Suite("Local RPC server", .serialized)
struct LocalRPCServerTests {

    /// What the server told the app.
    final class Recorder {
        var activities: [(socket: Int, activity: RichPresenceActivity?)] = []
        var deepLinks: [String] = []
    }

    private func server(_ recorder: Recorder, clientName: String = "Test App") -> LocalRPCServer {
        LocalRPCServer(host: LocalRPCServer.Host(
            currentUser: { LocalRPC.user(
                id: "1", username: "reader", discriminator: "0", globalName: "Reader",
                avatar: nil, bot: false, flags: 0, premiumType: 0
            ) },
            application: { id in RPCApplication(id: id, name: clientName) },
            resolveAssets: { _, large, _ in (large.map { "asset-\($0)" }, nil) },
            partyPrivacy: { (true, true) },
            setActivity: { socket, activity in recorder.activities.append((socket, activity)) },
            openInvite: { code in .object(["code": .string(code)]) },
            openDeepLink: { type, _ in recorder.deepLinks.append(type) }
        ))
    }

    /// A folder short enough for a socket path (104 bytes at most).
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "rpc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Two minutes, because the server answers on the main thread and the
    /// whole suite shares it: twenty seconds was too few in a full run here
    /// once the settings tests took turns (2026-11-15). A broken server only
    /// costs the wait.
    private func waitForSocket(_ server: LocalRPCServer) async throws -> String {
        for _ in 0..<6000 {
            if let path = server.socketPath { return path }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }

    @Test("Handshake, READY, an activity, an unknown command, and the activity gone with the socket")
    func endToEnd() async throws {
        let recorder = Recorder()
        let server = server(recorder)
        let directory = try folder()
        server.start(directory: directory, firstPort: nil)
        defer { server.stop() }
        let path = try await waitForSocket(server)
        #expect(path.hasSuffix("discord-ipc-0"))

        let client = try RPCTestClient(path: path)
        client.send(.handshake, .object(["v": .number(1), "client_id": .string("42")]))
        let ready = try #require(await client.frame())
        #expect(ready.payload["evt"] == .string("READY"))
        #expect(ready.payload["data"]?["user"]?["username"] == .string("reader"))

        client.send(.frame, .object([
            "cmd": .string("SET_ACTIVITY"),
            "nonce": .string("n1"),
            "args": .object([
                "pid": .number(7),
                "activity": .object([
                    "state": .string("In a match"),
                    "assets": .object(["large_image": .string("map")]),
                ]),
            ]),
        ]))
        let reply = try #require(await client.frame())
        #expect(reply.payload["cmd"] == .string("SET_ACTIVITY"))
        #expect(reply.payload["nonce"] == .string("n1"))
        #expect(reply.payload["data"]?["name"] == .string("Test App"))
        #expect(reply.payload["data"]?["assets"]?["large_image"] == .string("asset-map"))
        #expect(recorder.activities.last?.activity?.state == "In a match")

        client.send(.frame, .object(["cmd": .string("AUTHORIZE"), "nonce": .number(2)]))
        let refused = try #require(await client.frame())
        #expect(refused.payload["evt"] == .string("ERROR"))
        #expect(refused.payload["data"]?["code"] == .number(4002))
        #expect(refused.payload["data"]?["message"] == .string("Invalid command: AUTHORIZE"))
        #expect(refused.payload["nonce"] == .number(2))

        client.close()
        for _ in 0..<6000 where recorder.activities.last?.activity != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(recorder.activities.last?.activity == nil)
    }

    /// Discord's words, on a CLOSE frame.
    @Test("A wrong version and a missing client id are closed with Discord's reasons")
    func refusals() async throws {
        let server = server(Recorder())
        server.start(directory: try folder(), firstPort: nil)
        defer { server.stop() }
        let path = try await waitForSocket(server)

        let wrongVersion = try RPCTestClient(path: path)
        wrongVersion.send(.handshake, .object(["v": .number(2), "client_id": .string("42")]))
        let closed = try #require(await wrongVersion.frame())
        #expect(closed.opcode == .close)
        #expect(closed.payload["code"] == .number(1003))
        #expect(closed.payload["message"] == .string("Invalid Version: 2"))

        let anonymous = try RPCTestClient(path: path)
        anonymous.send(.handshake, .object(["v": .number(1)]))
        let refused = try #require(await anonymous.frame())
        #expect(refused.payload["code"] == .number(4000))
        #expect(refused.payload["message"] == .string("No Client ID Specified"))
    }

    /// `getAvailableSocket`: a live server keeps its slot; a dead one's file
    /// is taken over.
    @Test("A live server keeps discord-ipc-0; a stale file is taken over")
    func slots() async throws {
        let directory = try folder()
        let first = server(Recorder())
        first.start(directory: directory, firstPort: nil)
        defer { first.stop() }
        #expect(try await waitForSocket(first).hasSuffix("discord-ipc-0"))

        let second = server(Recorder())
        second.start(directory: directory, firstPort: nil)
        defer { second.stop() }
        #expect(try await waitForSocket(second).hasSuffix("discord-ipc-1"))

        // A socket file nobody listens on any more.
        let stale = try folder()
        let path = stale.appending(path: "discord-ipc-0").path(percentEncoded: false)
        try RPCTestClient.leaveStaleSocket(at: path)
        let third = server(Recorder())
        third.start(directory: stale, firstPort: nil)
        defer { third.stop() }
        #expect(try await waitForSocket(third) == path)
    }
}

/// What a discord.com page does: the upgrade with its origin, READY, a command.
@MainActor
@Suite("Local RPC WebSocket", .serialized)
struct LocalRPCWebSocketServerTests {

    @Test("A Discord page is admitted without a client id, and may deep-link")
    func discordPage() async throws {
        var links: [String] = []
        let server = LocalRPCServer(host: LocalRPCServer.Host(
            currentUser: { nil },
            application: { id in RPCApplication(id: id, name: "x") },
            resolveAssets: { _, _, _ in (nil, nil) },
            partyPrivacy: { (true, true) },
            setActivity: { _, _ in },
            openInvite: { code in .object(["code": .string(code)]) },
            openDeepLink: { type, _ in links.append(type) }
        ))
        // A port away from Discord's own, so a running Discord is no matter.
        let port = UInt16.random(in: 47_000..<48_000)
        server.start(directory: FileManager.default.temporaryDirectory.appending(path: "rpc-ws"), firstPort: port)
        defer { server.stop() }
        for _ in 0..<6000 where server.webPort == nil { try await Task.sleep(for: .milliseconds(20)) }
        let open = try #require(server.webPort)

        let page = try WebSocketTestClient(port: open)
        let answer = await page.upgrade(origin: "https://discord.com")
        #expect(answer.hasPrefix("HTTP/1.1 101"))
        let ready = try #require(await page.message())
        #expect(ready["evt"] == .string("READY"))
        // A page is not told who is signed in.
        #expect(ready["data"]?["user"] == nil)

        page.send(.object([
            "cmd": .string("DEEP_LINK"),
            "nonce": .string("d1"),
            "args": .object(["type": .string("CHANNEL"), "params": .object([:])]),
        ]))
        let reply = try #require(await page.message())
        #expect(reply["cmd"] == .string("DEEP_LINK"))
        #expect(reply["evt"] == .null)
        #expect(links == ["CHANNEL"])

        // A page may not set an activity: that is an app's.
        page.send(.object(["cmd": .string("SET_ACTIVITY"), "nonce": .string("s1"), "args": .object([:])]))
        let refused = try #require(await page.message())
        #expect(refused["data"]?["message"] == .string("Not authenticated or invalid scope"))
    }
}

/// A page's side of the WebSocket: a raw TCP socket, its frames masked as a
/// browser's are.
nonisolated final class WebSocketTestClient: @unchecked Sendable {
    private let fd: Int32
    private var pending = Data()

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { Darwin.close(fd) }

    /// Sends the upgrade and answers with the response's head.
    func upgrade(origin: String) async -> String {
        let request = "GET /?v=1&encoding=json HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\n"
            + "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            + "Sec-WebSocket-Version: 13\r\nOrigin: \(origin)\r\n\r\n"
        write(Data(request.utf8))
        return await background {
            while self.pending.range(of: Data("\r\n\r\n".utf8)) == nil {
                guard self.readMore() else { return "" }
            }
            let end = self.pending.range(of: Data("\r\n\r\n".utf8))!
            let head = String(decoding: self.pending[..<end.lowerBound], as: UTF8.self)
            self.pending.removeSubrange(..<end.upperBound)
            return head
        }
    }

    func send(_ message: RPCValue) {
        let payload = [UInt8](message.jsonData)
        let mask: [UInt8] = [7, 1, 9, 3]
        var frame: [UInt8] = [0x81]
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else {
            frame += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        }
        frame += mask
        frame += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        write(Data(frame))
    }

    /// The next text message the server sent, parsed.
    func message() async -> RPCValue? {
        await background {
            while true {
                if let message = self.takeMessage() { return message }
                guard self.readMore() else { return nil }
            }
        }
    }

    private func takeMessage() -> RPCValue? {
        let bytes = [UInt8](pending)
        guard bytes.count >= 2 else { return nil }
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        }
        guard bytes.count >= offset + length else { return nil }
        pending.removeFirst(offset + length)
        return RPCValue(json: Data(bytes[offset..<(offset + length)]))
    }

    private func readMore() -> Bool {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return false }
        pending.append(contentsOf: buffer.prefix(count))
        return true
    }

    private func write(_ data: Data) {
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
    }

    private func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: work()) }
        }
    }
}

/// A game's side of the socket: blocking POSIX reads and writes, kept off the
/// main thread the server answers on.
nonisolated final class RPCTestClient: @unchecked Sendable {
    private let fd: Int32
    private var reader = LocalRPCFrameReader()

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = Self.address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { Darwin.close(fd) }

    func send(_ opcode: LocalRPC.Opcode, _ payload: RPCValue) {
        let data = LocalRPCFrame.encode(opcode, payload)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    }

    /// The next whole frame, or nil after two minutes of silence.
    func frame() async -> LocalRPCFrameReader.Frame? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.readFrame())
            }
        }
    }

    private func readFrame() -> LocalRPCFrameReader.Frame? {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { return nil }
            guard let frames = try? reader.read(Data(buffer.prefix(count))) else { return nil }
            if let first = frames.first { return first }
        }
    }

    func close() {
        shutdown(fd, SHUT_RDWR)
    }

    /// Binds a socket at `path` and closes it without unlinking: the file a
    /// crashed server leaves behind.
    static func leaveStaleSocket(at path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        Darwin.close(fd)
        guard result == 0 else { throw POSIXError(.EADDRINUSE) }
    }

    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in path.utf8.enumerated() where index < raw.count - 1 { raw[index] = byte }
        }
        return address
    }
}

/// What the reader publishes while apps are connected: their activities first,
/// and the detected game only where no app already said it.
@MainActor
@Suite("Local RPC activities")
struct LocalRPCActivityPublishingTests {

    private func game(_ name: String, id: UInt64) -> DetectedGame {
        DetectedGame(
            id: ApplicationID(rawValue: id), name: name, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            isLauncher: false, isTranslated: false, processIdentifier: 1
        )
    }

    @Test("Apps' activities come first, in the order they first spoke")
    func order() {
        let model = AppModel()
        model.setLocalRPCActivity(RichPresenceActivity(type: 0, name: "Editor"), socket: 2)
        model.setLocalRPCActivity(RichPresenceActivity(type: 0, name: "Game"), socket: 1)
        model.setLocalRPCActivity(RichPresenceActivity(type: 0, name: "Editor 2"), socket: 2)
        #expect(model.localRPCActivities.map(\.activity.name) == ["Editor 2", "Game"])
        model.setLocalRPCActivity(nil, socket: 2)
        #expect(model.localRPCActivities.map(\.socket) == [1])
    }

    /// Discord's `480595`: a game whose app speaks for itself is not said
    /// twice — by its name, or by its app.
    @Test("The detected game gives way to its own app's activity")
    func dedupe() {
        let model = AppModel()
        model.detectedGame = game("Roblox", id: 363445589251008817)
        #expect(model.publishedActivities.map(\.name) == ["Roblox"])
        model.setLocalRPCActivity(RichPresenceActivity(type: 0, name: "Roblox", state: "In a game"), socket: 1)
        #expect(model.publishedActivities.map(\.name) == ["Roblox"])
        #expect(model.publishedActivities.first?.state == "In a game")

        var other = RichPresenceActivity(type: 0, name: "Different name")
        other.applicationID = ApplicationID(rawValue: 363445589251008817)
        model.setLocalRPCActivity(other, socket: 1)
        #expect(model.publishedActivities.map(\.name) == ["Different name"])

        model.setLocalRPCActivity(RichPresenceActivity(type: 0, name: "Editor"), socket: 1)
        #expect(model.publishedActivities.map(\.name) == ["Editor", "Roblox"])
    }
}
