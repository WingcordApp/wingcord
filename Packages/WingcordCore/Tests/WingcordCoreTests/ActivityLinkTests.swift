import Testing
@testable import WingcordCore

/// Activity links: Discord's hosts only, the app's id, and the ids after it.
struct ActivityLinkTests {
    @Test func readsTheAppAndItsIDs() throws {
        let text = "come play https://discord.com/activities/1000000000000000001?referrer_id=1000000000000000002&custom_id=abc"
        let link = try #require(ActivityLink.links(in: text).first)
        #expect(link.applicationID == ApplicationID(rawValue: 1_000_000_000_000_000_001))
        #expect(link.referrerID == UserID(rawValue: 1_000_000_000_000_000_002))
        #expect(link.customID == "abc")
    }

    @Test func onlyDiscordsHosts() {
        #expect(ActivityLink.links(in: "https://example.com/activities/1000000000000000001").isEmpty)
        #expect(ActivityLink.links(in: "https://ptb.discord.com/activities/1000000000000000001").count == 1)
    }

    @Test func eachAppOnce() {
        let id = "1000000000000000001"
        #expect(ActivityLink.links(in: "https://discord.com/activities/\(id) https://discord.com/activities/\(id)").count == 1)
    }
}
