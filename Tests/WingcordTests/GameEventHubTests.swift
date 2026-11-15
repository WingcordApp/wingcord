import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The listener Valve's games POST to, the token that gates it, and where the
/// games are looked for (docs/CLIPS-PRESENCE.md, Phase 3.4).
@MainActor
@Suite("Game event hub", .serialized)
struct GameEventHubTests {

    private func dotaDocument(kills: Int, token: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "provider": ["name": "Dota 2", "appid": 570, "steamid": "765"],
            "map": ["matchid": "1"],
            "player": ["steamid": "765", "kills": kills, "deaths": 0, "assists": 0],
            "auth": ["token": token],
        ])
    }

    @Test("The listener takes a POST over loopback and hands over its body")
    func serverReceives() async throws {
        let port = UInt16.random(in: 61_000...62_000)
        let server = GameStateServer(port: port)
        var received: [Data] = []
        server.onDocument = { received.append($0) }
        server.start()
        defer { server.stop() }
        // Up to twenty seconds, like the RPC suites: the listener reports ready
        // on the main thread, which the rest of the suite shares.
        for _ in 0..<1000 where !server.isListening { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.isListening)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"provider":{"appid":570}}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(received.count == 1)
        #expect(received.first.flatMap { String(data: $0, encoding: .utf8) } == #"{"provider":{"appid":570}}"#)
    }

    @Test("A request's body is complete only at its Content-Length")
    func bodyFraming() {
        let head = "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\n\r\n"
        #expect(GameStateServer.body(of: Data((head + "abc").utf8)) == nil)
        #expect(GameStateServer.body(of: Data((head + "abcde").utf8)) == Data("abcde".utf8))
        #expect(GameStateServer.body(of: Data("POST / HTTP/1.1\r\n".utf8)) == nil)
    }

    @Test("Only a document carrying the cfg file's token counts")
    func tokenGates() {
        let hub = GameEventHub()
        hub.receive(dotaDocument(kills: 0, token: GameEventSettings.token))
        hub.receive(dotaDocument(kills: 1, token: "somebody else"))
        #expect(hub.kept.isEmpty)
        hub.receive(dotaDocument(kills: 1, token: GameEventSettings.token))
        #expect(hub.kept.map(\.name) == ["Kill"])
        #expect(hub.lastEvent?.kind == .kill)
    }

    @Test("Steam's libraries, a Windows Steam's read inside its bottle")
    func libraries() throws {
        let vdf = """
        "libraryfolders"
        {
        \t"0"
        \t{
        \t\t"path"\t\t"C:\\\\Program Files (x86)\\\\Steam"
        \t\t"label"\t\t""
        \t}
        \t"1"
        \t{
        \t\t"path"\t\t"D:\\\\Games\\\\SteamLibrary"
        \t}
        }
        """
        #expect(GameInstalls.libraryPaths(inVDF: vdf) == [#"C:\\Program Files (x86)\\Steam"#, #"D:\\Games\\SteamLibrary"#])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let steam = root.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        try Data(vdf.utf8).write(to: steam.appendingPathComponent("steamapps/libraryfolders.vdf"))
        let libraries = GameInstalls.steamLibraries(root: steam, driveC: root.appendingPathComponent("drive_c"))
        #expect(libraries.first == steam)
        #expect(libraries.contains { $0.path.hasSuffix("drive_c/Program Files (x86)/Steam") })
    }
}
