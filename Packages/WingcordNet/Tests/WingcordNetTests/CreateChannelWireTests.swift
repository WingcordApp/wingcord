import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Create Channel's body, and Duplicate Channel's two extra keys as Discord's
/// `createChannel` (module 755584) sends them.
@Suite("Creating a channel on the wire")
struct CreateChannelWireTests {

    private let guild = GuildID(rawValue: 10)
    private static let created = #"{"id":"30","type":2,"guild_id":"10","name":"lounge"}"#

    @Test("A plain create sends no bitrate and no limit")
    func plain() async throws {
        let (rest, token) = await RequestRecorder.client(body: Self.created)
        _ = try await rest.createChannel(in: guild, name: "lounge", kind: .voice)
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v9/guilds/10/channels")
        #expect(request.json?.keys.sorted() == ["name", "permission_overwrites", "type"])
    }

    @Test("A duplicate carries the bitrate and the limit it copied")
    func duplicate() async throws {
        let (rest, token) = await RequestRecorder.client(body: Self.created)
        _ = try await rest.createChannel(
            in: guild, name: "lounge", kind: .voice, parentID: ChannelID(rawValue: 5),
            bitrate: 96_000, userLimit: 8
        )
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.json?["bitrate"] as? Int == 96_000)
        #expect(request.json?["user_limit"] as? Int == 8)
        #expect(request.json?["parent_id"] as? String == "5")
    }

    /// Discord leaves out a default bitrate and an unlimited room.
    @Test("The default bitrate and no limit are left out")
    func defaultsLeftOut() async throws {
        let (rest, token) = await RequestRecorder.client(body: Self.created)
        _ = try await rest.createChannel(in: guild, name: "lounge", kind: .voice, bitrate: 64_000, userLimit: 0)
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.json?["bitrate"] == nil)
        #expect(request.json?["user_limit"] == nil)
    }
}
