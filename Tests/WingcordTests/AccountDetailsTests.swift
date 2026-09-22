import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The signed-in account's own details.
///
/// **Masking is the thing worth pinning.** It is the one piece of logic on the
/// page, it runs on two secrets, and both ways of getting it wrong are quiet:
/// a mask that covers too little prints an address somebody can read over a
/// shoulder, and one that covers too much leaves the reader unable to tell which
/// account they are signed in as — which is the whole reason the page exists.
@Suite("Account details")
struct AccountDetailsTests {

    @Test("An e-mail keeps its domain and loses its local part")
    func emailKeepsTheDomain() {
        let details = AccountDetails(email: "someone@example.com")
        #expect(details.maskedEmail == "•••••••@example.com")
        // As many dots as there were characters: a fixed-length mask leaks
        // nothing but also tells the reader nothing, and a variable one at
        // least reads as the right shape.
        #expect(details.maskedEmail?.count == details.email?.count)
    }

    @Test("A phone keeps its last four digits")
    func phoneKeepsItsTail() {
        let details = AccountDetails(phone: "+40712345015")
        #expect(details.maskedPhone?.hasSuffix("5015") == true)
        #expect(details.maskedPhone?.contains("0712") == false)
    }

    @Test("Something too short to mask is left alone rather than mangled")
    func shortValuesAreNotMangled() {
        // The arithmetic underneath subtracts four; a four-character number
        // would produce a negative repeat count and trap.
        #expect(AccountDetails(phone: "5015").maskedPhone == "5015")
        #expect(AccountDetails(phone: "15").maskedPhone == "15")
        // An address with no `@` in it is not an address this client should be
        // inventing a shape for.
        #expect(AccountDetails(email: "not-an-address").maskedEmail == "not-an-address")
    }

    @Test("Nothing to mask stays nothing")
    func absentStaysAbsent() {
        // Nil is a real state — an account made through a phone number may have
        // no e-mail at all — and a mask of an absent value would be a row of
        // dots claiming there is something behind them.
        let empty = AccountDetails()
        #expect(empty.maskedEmail == nil)
        #expect(empty.maskedPhone == nil)
        #expect(!empty.hasMFA)
        #expect(!empty.isEmailVerified)
    }

    @Test("A platform names a shape, and an unknown one still names something")
    func sessionsAlwaysHaveAGlyph() {
        // A row with no symbol is a row with a hole in it, and the route is not
        // one this tree has watched — so every answer, including the ones it has
        // never seen, has to land somewhere.
        for platform in ["macOS", "Windows", "Linux", "iOS", "Android", "Chrome OS", nil] {
            let session = AuthSession(id: "x", platform: platform)
            #expect(!session.symbolName.isEmpty, "\(platform ?? "nil")")
        }
        #expect(AuthSession(id: "x", platform: "iOS").symbolName == "iphone")
        #expect(AuthSession(id: "x", platform: "macOS").symbolName == "desktopcomputer")
    }

    @Test("A session's title is whichever halves the route gave")
    func titleTakesWhatItHas() {
        #expect(AuthSession(id: "x", platform: "macOS", client: "Safari").title
            == "macOS · Safari")
        #expect(AuthSession(id: "x", platform: "macOS").title == "macOS")
        #expect(AuthSession(id: "x").title.isEmpty)
    }
}
