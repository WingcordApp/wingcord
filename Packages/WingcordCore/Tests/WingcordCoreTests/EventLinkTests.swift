import Foundation
import Testing
@testable import WingcordCore

/// Event links, in the form Discord's Copy Event Link writes them.
struct EventLinkTests {

    @Test("An event link names the server and the event")
    func eventLink() throws {
        let link = try #require(EventLink.parse("https://discord.com/events/603970300668805120/1323893975484369279"))
        #expect(link.guildID == GuildID(rawValue: 603_970_300_668_805_120))
        #expect(link.eventID == 1_323_893_975_484_369_279)
        #expect(link.occurrence == nil)
    }

    @Test("One date of a series rides on the end")
    func occurrenceLink() throws {
        let link = try #require(EventLink.parse(
            "https://canary.discord.com/events/603970300668805120/1323893975484369279/1588436611891200000/"
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
    @Test("A message's event links, in order, each once, with their dates")
    func linksInText() {
        let text = """
        tonight https://discord.com/events/603970300668805120/1323893975484369279 and \
        (discord.com/events/603970300668805120/1323893975487238721/1588436611891200000), \
        again https://ptb.discord.com/events/603970300668805120/1323893975484369279/
        """
        #expect(EventLink.links(in: text) == [
            EventLink(guildID: GuildID(rawValue: 603_970_300_668_805_120), eventID: 1_323_893_975_484_369_279),
            EventLink(
                guildID: GuildID(rawValue: 603_970_300_668_805_120),
                eventID: 1_323_893_975_487_238_721,
                occurrence: 1_588_436_611_891_200_000
            ),
        ])
    }

    @Test("Another host's page, or a path that goes on, draws no card")
    func linksElsewhere() {
        #expect(EventLink.links(in: "https://example.com/events/603970300668805120/1323893975484369279").isEmpty)
        #expect(EventLink.links(in: "https://discord.com/events/603970300668805120/1323893975484369279/more").isEmpty)
    }

    @Test("Ten a message, as every code link")
    func linksCapped() {
        let text = (0..<12)
            .map { "https://discord.com/events/603970300668805120/13238939754864964\(10 + $0)" }
            .joined(separator: " ")
        #expect(EventLink.links(in: text).count == 10)
    }
}
