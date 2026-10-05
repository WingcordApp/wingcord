import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// A Twitch or YouTube sync's own settings, read and written as Discord's
/// `updateIntegration` writes them.
@Suite("Integration expiry on the wire")
struct IntegrationExpiryWireTests {

    private let guild = GuildID(rawValue: 1)

    @Test("A sync carries its expiry, count, last run and revocation")
    func reads() async throws {
        let body = """
        [{"id":"5","type":"twitch","name":"chan","enabled":true,"role_id":"9",
          "account":{"id":"a","name":"chan"},"expire_behavior":1,"expire_grace_period":7,
          "enable_emoticons":true,"subscriber_count":42,"synced_at":"2026-09-10T04:47:52.192000+00:00",
          "revoked":true},
         {"id":"6","type":"discord","name":"Bot","enabled":true}]
        """
        let (rest, _) = await RequestRecorder.client(body: body)
        let integrations = try await rest.guildIntegrations(in: guild)
        let twitch = try #require(integrations.first)
        #expect(twitch.expiry == GuildIntegration.Expiry(behavior: .kick, gracePeriod: 7, enablesEmoticons: true))
        #expect(twitch.subscriberCount == 42)
        #expect(twitch.syncedAt != nil)
        #expect(twitch.isRevoked)
        // An app has none of it.
        #expect(integrations[1].expiry == nil)
    }

    @Test("Saving sends all three fields")
    func writes() async throws {
        let (rest, token) = await RequestRecorder.client(status: 204, body: "")
        try await rest.updateIntegration(
            5, in: guild,
            expiry: GuildIntegration.Expiry(behavior: .removeRole, gracePeriod: 30, enablesEmoticons: false)
        )
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "PATCH")
        #expect(request.path == "/api/v9/guilds/1/integrations/5")
        #expect(request.json?["expire_behavior"] as? Int == 0)
        #expect(request.json?["expire_grace_period"] as? Int == 30)
        #expect(request.json?["enable_emoticons"] as? Bool == false)
    }
}
