import Testing
@testable import WingcordCore

/// Discord's profile links: a whole `/users/<id>` path on one of its hosts.
struct UserLinkTests {

    @Test("Profile links on every Discord host, in order and each once")
    func finds() {
        let text = """
        https://discord.com/users/732280746023186586 and \
        canary.discord.com/users/247088618114848105/ and again \
        https://discordapp.com/users/732280746023186586
        """
        #expect(UserLink.userIDs(in: text).map(\.rawValue) == [732_280_746_023_186_586, 247_088_618_114_848_105])
    }

    /// A path that goes on past the id is a different page.
    @Test("A deeper path is not a profile link")
    func deeperPath() {
        #expect(UserLink.userIDs(in: "https://discord.com/users/732280746023186586/settings").isEmpty)
        #expect(UserLink.userIDs(in: "https://example.com/users/732280746023186586").isEmpty)
    }

    @Test("An unfurled link is recognised whole")
    func embedURL() {
        #expect(UserLink.userID(inURL: "https://discord.com/users/732280746023186586")?.rawValue
            == 732_280_746_023_186_586)
        #expect(UserLink.userID(inURL: "https://discord.com/channels/1/2") == nil)
    }
}
