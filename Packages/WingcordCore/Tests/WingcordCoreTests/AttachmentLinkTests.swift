import Foundation
import Testing
@testable import WingcordCore

/// Discord's rule for a signed upload link that has run out (module `679164`).
@Suite("Attachment links")
struct AttachmentLinkTests {

    /// `ex` is hex seconds: 0x68E5F000 is 2025-10-08 05:31:12 UTC.
    private let cdn = URL(string: "https://cdn.discordapp.com/attachments/1/2/a.png?ex=68e5f000&is=68e49e80&hm=abc&")!
    private let proxy = URL(string: "https://media.discordapp.net/attachments/1/2/a.png?ex=68e5f000&is=68e49e80&hm=abc&width=640&height=2560")!
    private var expiry: Date { Date(timeIntervalSince1970: 0x68E5_F000) }

    @Test("The expiry is read as hex seconds")
    func expiryIsHex() {
        #expect(AttachmentLink.expiry(of: cdn) == expiry)
    }

    @Test("A link is due an hour before it runs out, and after")
    func refreshMargin() {
        #expect(!AttachmentLink.needsRefresh(cdn, now: expiry.addingTimeInterval(-2 * 3600)))
        #expect(AttachmentLink.needsRefresh(cdn, now: expiry.addingTimeInterval(-30 * 60)))
        #expect(AttachmentLink.needsRefresh(cdn, now: expiry.addingTimeInterval(60)))
    }

    @Test("A signed upload with no expiry is due; anything else never is")
    func whatIsSigned() {
        #expect(AttachmentLink.needsRefresh(URL(string: "https://cdn.discordapp.com/attachments/1/2/a.png")!))
        #expect(!AttachmentLink.needsRefresh(URL(string: "https://cdn.discordapp.com/avatars/1/a.png")!))
        #expect(!AttachmentLink.needsRefresh(URL(string: "https://media.tenor.com/x.gif")!))
        #expect(AttachmentLink.isSigned(URL(string: "https://cdn.discordapp.com/ephemeral-attachments/1/2/a.png?ex=1")!))
    }

    @Test("Any rendition asks the route about the CDN link with only its signature")
    func canonicalForm() throws {
        let canonical = try #require(AttachmentLink.canonical(proxy))
        #expect(canonical.host == "cdn.discordapp.com")
        #expect(canonical.path == "/attachments/1/2/a.png")
        let names = URLComponents(url: canonical, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name)
        #expect(names == ["ex", "is", "hm"])
    }

    @Test("A fresh signature replaces the old one and keeps the rendition's own query")
    func resigning() {
        let fresh = URL(string: "https://cdn.discordapp.com/attachments/1/2/a.png?ex=68e74180&is=68e5f000&hm=def&")!
        let resigned = AttachmentLink.resigned(proxy, with: fresh)
        let items = URLComponents(url: resigned, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(resigned.host == "media.discordapp.net")
        #expect(items.first { $0.name == "ex" }?.value == "68e74180")
        #expect(items.first { $0.name == "hm" }?.value == "def")
        #expect(items.first { $0.name == "width" }?.value == "640")
        #expect(items.filter { $0.name == "ex" }.count == 1)
    }
}
