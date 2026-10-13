import Foundation
import Testing
@testable import WingcordNet

/// The local RPC server's wire: IPC frames, the WebSocket upgrade and frames,
/// and which pages count as Discord's own.
@Suite("Local RPC wire")
struct LocalRPCWireTests {

    // MARK: IPC

    @Test("A frame is its opcode and length, little-endian, then the JSON")
    func encodeFrame() throws {
        let data = LocalRPCFrame.encode(.frame, .object(["cmd": .string("DISPATCH")]))
        #expect(Array(data.prefix(4)) == [1, 0, 0, 0])
        let length = Int(data[4]) | Int(data[5]) << 8 | Int(data[6]) << 16 | Int(data[7]) << 24
        #expect(length == data.count - 8)
        #expect(RPCValue(json: data.dropFirst(8)) == .object(["cmd": .string("DISPATCH")]))
    }

    @Test("Frames are read across arbitrary chunks")
    func readAcrossChunks() throws {
        let handshake = LocalRPCFrame.encode(.handshake, .object(["v": .number(1), "client_id": .string("42")]))
        let ping = LocalRPCFrame.encode(.ping, .string("x"))
        let stream = handshake + ping
        var reader = LocalRPCFrameReader()
        var frames: [LocalRPCFrameReader.Frame] = []
        for chunk in stride(from: 0, to: stream.count, by: 5) {
            frames += try reader.read(stream.subdata(in: chunk..<min(chunk + 5, stream.count)))
        }
        #expect(frames.map(\.opcode) == [.handshake, .ping])
        #expect(frames.first?.payload["client_id"] == .string("42"))
    }

    /// Discord's own words close the socket — `998921`'s checks.
    @Test("An unknown opcode, an oversized frame and bad JSON are refused")
    func refusals() {
        var unknown = LocalRPCFrameReader()
        #expect(throws: LocalRPCFrameReader.Failure.protocolError) {
            try unknown.read(Data([9, 0, 0, 0, 0, 0, 0, 0]))
        }
        var huge = LocalRPCFrameReader()
        var header = Data([1, 0, 0, 0])
        withUnsafeBytes(of: Int32(LocalRPCFrameReader.maximumFrame + 1).littleEndian) { header.append(contentsOf: $0) }
        #expect(throws: LocalRPCFrameReader.Failure.messageTooLarge) { try huge.read(header) }
        var broken = LocalRPCFrameReader()
        #expect(throws: LocalRPCFrameReader.Failure.notJSON) {
            try broken.read(Data([1, 0, 0, 0, 3, 0, 0, 0]) + Data("{x}".utf8))
        }
        #expect(LocalRPCFrameReader.Failure.protocolError.message == "protocol error")
    }

    @Test("A boolean stays a boolean and a number a number")
    func jsonKinds() {
        #expect(RPCValue(json: Data("[true,1,1.5,null]".utf8)) == .array([.bool(true), .number(1), .number(1.5), .null]))
        #expect(String(decoding: RPCValue.object(["v": .number(1)]).jsonData, as: UTF8.self) == #"{"v":1}"#)
    }

    @Test("READY carries the config and, where given, the user")
    func ready() {
        let ready = LocalRPC.ready(user: .object(["id": .string("1")]))
        #expect(ready["cmd"] == .string("DISPATCH"))
        #expect(ready["evt"] == .string("READY"))
        #expect(ready["nonce"] == .null)
        #expect(ready["data"]?["v"] == .number(1))
        #expect(ready["data"]?["config"]?["cdn_host"] == .string("cdn.discordapp.com"))
        #expect(ready["data"]?["user"]?["id"] == .string("1"))
        #expect(LocalRPC.ready(user: nil)["data"]?["user"] == nil)
    }

    @Test("An error answers with ERROR, its code and its words")
    func errorMessage() {
        let message = LocalRPC.errorMessage(
            cmd: "AUTHORIZE",
            error: LocalRPC.CommandError(.invalidCommand, "Invalid command: AUTHORIZE"),
            nonce: .string("n1")
        )
        #expect(message["evt"] == .string("ERROR"))
        #expect(message["data"]?["code"] == .number(4002))
        #expect(message["data"]?["message"] == .string("Invalid command: AUTHORIZE"))
        #expect(message["nonce"] == .string("n1"))
    }

    // MARK: Origins

    @Test("Discord's own pages, and nothing that merely looks like them")
    func origins() {
        #expect(LocalRPC.isDiscordOrigin("https://discord.com"))
        #expect(LocalRPC.isDiscordOrigin("https://ptb.discord.com"))
        #expect(LocalRPC.isDiscordOrigin("https://canary.discordapp.com"))
        #expect(!LocalRPC.isDiscordOrigin("http://discord.com"))
        #expect(!LocalRPC.isDiscordOrigin("https://discord.com.evil.example"))
        #expect(!LocalRPC.isDiscordOrigin("https://a.b.discord.com"))
        #expect(!LocalRPC.isDiscordOrigin("https://staging.discord.com"))
        #expect(!LocalRPC.isDiscordOrigin(nil))
    }

    // MARK: WebSocket

    /// RFC 6455 §1.3's own example.
    @Test("The accept value is RFC 6455's")
    func acceptValue() {
        #expect(LocalRPCUpgradeRequest.acceptValue(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test("The upgrade gives the query and the origin; anything else is not one")
    func upgrade() throws {
        let request = try #require(LocalRPCUpgradeRequest(head: """
        GET /?v=1&encoding=json HTTP/1.1\r
        Host: 127.0.0.1:6463\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
        Sec-WebSocket-Version: 13\r
        Origin: https://discord.com
        """))
        #expect(request.query == ["v": "1", "encoding": "json"])
        #expect(request.origin == "https://discord.com")
        #expect(String(decoding: request.response, as: UTF8.self).contains("s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
        #expect(LocalRPCUpgradeRequest(head: "GET /rpc?v=1 HTTP/1.1\r\nHost: x") == nil)
    }

    private func masked(_ opcode: UInt8, _ payload: [UInt8], final: Bool = true) -> Data {
        let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        var data = Data([(final ? 0x80 : 0) | opcode, 0x80 | UInt8(payload.count)])
        data.append(contentsOf: mask)
        data.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return data
    }

    @Test("A client's masked, fragmented text is put back together")
    func readFrames() throws {
        var reader = LocalRPCWebSocketReader()
        let first = masked(0x1, Array("{\"cmd\":".utf8), final: false)
        let second = masked(0x0, Array("\"X\"}".utf8))
        let ping = masked(0x9, [1, 2])
        let stream = first + second + ping
        var messages: [LocalRPCWebSocketReader.Message] = []
        for byte in stream { messages += try reader.read(Data([byte])) }
        #expect(messages == [.text("{\"cmd\":\"X\"}"), .ping(Data([1, 2]))])
    }

    @Test("An unmasked client frame is a protocol error")
    func unmasked() {
        var reader = LocalRPCWebSocketReader()
        #expect(throws: LocalRPCWebSocketReader.Failure.protocolError) { try reader.read(Data([0x81, 0x01, 0x41])) }
    }

    @Test("A server frame's length takes one, three or nine bytes")
    func serverLengths() {
        #expect(LocalRPCWebSocketFrame.pong(Data(count: 125))[1] == 125)
        #expect(LocalRPCWebSocketFrame.pong(Data(count: 126))[1] == 126)
        #expect(LocalRPCWebSocketFrame.pong(Data(count: 65_536))[1] == 127)
        let close = LocalRPCWebSocketFrame.close(4000, reason: "No Client ID Specified")
        #expect(Array(close.prefix(4)) == [0x88, 24, 0x0F, 0xA0])
    }
}
