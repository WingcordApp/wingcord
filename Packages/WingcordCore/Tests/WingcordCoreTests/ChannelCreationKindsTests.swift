import Testing
@testable import WingcordCore

/// The types Create Channel offers — Discord's option list in `410380` and
/// `canCreateMediaChannel` (`219444.V`).
@Suite("Create Channel's types")
struct ChannelCreationKindsTests {

    @Test("An ordinary server: Text, Voice and Forum")
    func ordinary() {
        #expect(ChannelCreation.kinds(features: []) == [.text, .voice, .forum])
    }

    @Test("A Community server without subscriptions: no Media, but Announcement and Stage")
    func communityWithoutMedia() {
        #expect(ChannelCreation.kinds(features: ["COMMUNITY", "NEWS"]) == [.text, .voice, .forum, .announcement, .stage])
        #expect(!ChannelCreation.offersMedia(features: ["COMMUNITY"]))
    }

    @Test("Media needs a Community server that sells subscriptions, in Discord's order")
    func mediaWithSubscriptions() {
        #expect(ChannelCreation.kinds(features: ["COMMUNITY", "CREATOR_MONETIZABLE"])
            == [.text, .voice, .forum, .media, .announcement, .stage])
        #expect(ChannelCreation.offersMedia(features: ["COMMUNITY", "CREATOR_MONETIZABLE_PROVISIONAL"]))
        // Subscriptions alone are not enough.
        #expect(!ChannelCreation.offersMedia(features: ["CREATOR_MONETIZABLE"]))
    }

    @Test("Discord's staff servers always have it")
    func staff() {
        #expect(ChannelCreation.offersMedia(features: ["INTERNAL_EMPLOYEE_ONLY"]))
    }
}
