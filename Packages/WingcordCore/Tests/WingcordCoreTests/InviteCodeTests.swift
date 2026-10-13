import Foundation
import Testing
@testable import WingcordCore

/// The invites a message links to, keyed as Discord keys them.
struct InviteCodeTests {

    @Test("A plain invite is its code, once")
    func plainCodes() {
        let text = "join discord.gg/wingcord or https://discord.com/invite/wingcord, also discord.gg/other"
        #expect(InviteCard.codes(in: text) == ["wingcord", "other"])
    }

    /// `21599`'s `fB`: the event rides on the key, so the same invite with an
    /// event on it is another card.
    @Test("An invite with an event on it is keyed with the event")
    func eventCodes() {
        let text = "https://discord.gg/wingcord?event=1323893975486496490 and discord.gg/wingcord"
        let codes = InviteCard.codes(in: text)
        #expect(codes == ["wingcord?event=1323893975486496490", "wingcord"])
        #expect(InviteCard.code(ofKey: codes[0]) == "wingcord")
        #expect(InviteCard.eventID(ofKey: codes[0]) == 1_323_893_975_484_369_279)
        #expect(InviteCard.code(ofKey: "wingcord") == "wingcord")
        #expect(InviteCard.eventID(ofKey: "wingcord") == nil)
    }

    @Test("A query without an event leaves the plain code")
    func otherQueries() {
        #expect(InviteCard.codes(in: "https://discord.gg/wingcord?utm=x&event=") == ["wingcord"])
        #expect(InviteCard.codes(in: "https://discord.gg/wingcord?ref=1&event=42") == ["wingcord?event=42"])
    }
}
