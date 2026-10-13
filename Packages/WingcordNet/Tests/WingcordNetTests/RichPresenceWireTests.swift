import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The Rich Presence builder on the wire: opcode 3 as Vencord's CustomRPC
/// fills it, and Discord's two image routes (`fetchAssetIds`).
@Suite("Rich Presence on the wire")
struct RichPresenceWireTests {

    private func frame(_ activity: RichPresenceActivity) throws -> [String: Any] {
        let data = try #require(GatewaySocket.presenceFrame(
            status: "online", customStatus: nil, customEmoji: nil, activities: [activity]
        ))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let d = try #require(json["d"] as? [String: Any])
        let activities = try #require(d["activities"] as? [[String: Any]])
        return try #require(activities.first)
    }

    @Test("A custom presence carries its stream, its lines' links and its buttons' links")
    func customPresence() throws {
        var activity = RichPresenceActivity(
            type: 1, name: "Live", details: "Ranked", state: "Valorant",
            buttons: ["Wiki"], applicationID: ApplicationID(rawValue: 0), flags: 1
        )
        activity.url = URL(string: "https://www.twitch.tv/somebody")
        activity.detailsURL = URL(string: "https://example.com/d")
        activity.buttonURLs = [URL(string: "https://example.com/w")!]
        let sent = try frame(activity)
        #expect(sent["url"] as? String == "https://www.twitch.tv/somebody")
        #expect(sent["details_url"] as? String == "https://example.com/d")
        #expect(sent["state_url"] == nil)
        #expect(sent["application_id"] as? String == "0")
        #expect(sent["flags"] as? Int == 1)
        #expect(sent["buttons"] as? [String] == ["Wiki"])
        let metadata = try #require(sent["metadata"] as? [String: Any])
        #expect(metadata.keys.sorted() == ["button_urls"])
        #expect(metadata["button_urls"] as? [String] == ["https://example.com/w"])
    }

    @Test("A presence with no buttons sends no metadata at all")
    func noMetadata() throws {
        let sent = try frame(RichPresenceActivity(type: 0, name: "Plain"))
        #expect(sent["metadata"] == nil)
        #expect(sent["url"] == nil)
    }

    /// Spotify's own shape is unchanged — `button_urls` present and empty.
    @Test("Spotify's metadata keeps its shape")
    func spotify() throws {
        let sent = try frame(RichPresenceActivity(
            type: 2, name: "Spotify",
            metadata: .init(contextURI: nil, albumID: "album", artistIDs: ["artist"], type: "track")
        ))
        let metadata = try #require(sent["metadata"] as? [String: Any])
        #expect(metadata["album_id"] as? String == "album")
        #expect(metadata["button_urls"] as? [String] == [])
    }

    @Test("Links become mp: ids through the application's external assets")
    func externalAssets() async throws {
        let (rest, token) = await RequestRecorder.client(
            body: #"[{"url":"https://i.imgur.com/a.png","external_asset_path":"external/abc/https/i.imgur.com/a.png"}]"#
        )
        let ids = try await rest.externalAssetIDs(
            application: ApplicationID(rawValue: 42), urls: ["https://i.imgur.com/a.png"]
        )
        #expect(ids == ["https://i.imgur.com/a.png": "mp:external/abc/https/i.imgur.com/a.png"])
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v9/applications/42/external-assets")
        #expect(request.json?["urls"] as? [String] == ["https://i.imgur.com/a.png"])
    }

    @Test("A key is the application's own asset, by name")
    func applicationAssets() async throws {
        let (rest, token) = await RequestRecorder.client(
            body: #"[{"id":"999","name":"badge","type":1},{"id":"1000","name":"logo","type":1}]"#
        )
        let ids = try await rest.applicationAssetIDs(application: ApplicationID(rawValue: 42))
        #expect(ids == ["badge": "999", "logo": "1000"])
        #expect(RequestRecorder.requests(for: token).first?.path == "/api/v9/oauth2/applications/42/assets")
    }
}
