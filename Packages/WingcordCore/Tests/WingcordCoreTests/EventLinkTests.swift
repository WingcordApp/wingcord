import Foundation
import Testing
@testable import WingcordCore

/// Event links, in the form Discord's Copy Event Link writes them.
struct EventLinkTests {

    @Test("An event link names the server and the event")
    func eventLink() throws {
        let link = try #require(EventLink.parse("https://discord.com/events/603970300668805120/1323893975486496490"))
        #expect(link.guildID == GuildID(rawValue: 603_970_300_668_805_120))
        #expect(link.eventID == 1_323_893_975_484_369_279)
        #expect(link.occurrence == nil)
    }

    @Test("One date of a series rides on the end")
    func occurrenceLink() throws {
        let link = try #require(EventLink.parse(
            "https://canary.discord.com/events/603970300668805120/1323893975486496490/1588436611891200000/"
        ))
        #expect(link.occurrence == 1_588_436_611_891_200_000)
    }

    @Test("Anything else stays a plain link")
    func rejects() {
        #expect(EventLink.parse("https://discord.com.evil.example/events/1/2") == nil)
        #expect(EventLink.parse("http://discord.com/events/1/2") == nil)
        #expect(EventLink.parse("https://discord.com/events/1") == nil)
        #expect(EventLink.parse("https://discord.com/events/1/two") == nil)
        #expect(EventLink.parse("https://discord.com/channels/1/2") == nil)
        #expect(EventLink.parse("https://discord.com/events/1/2/3/4") == nil)
    }
}
