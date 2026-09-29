import Foundation
import Testing
import WingcordCore

/// Which pictures move — Discord's `LazyImage.isAnimated`, and the proxy
/// parameter that keeps a moving WebP's frames.
@Suite("Plays as animated")
struct PlaysAsAnimatedTests {

    /// Discord's three regexes are `\.gif($|\?|#)`, `\.webp($|\?|#)` and
    /// `\.avif($|\?|#)`, case-insensitive; a GIF moves on its extension alone,
    /// the other two only with the mark.
    @Test("A GIF always, a WebP or AVIF only when marked, nothing else", arguments: [
        ("https://cdn.discordapp.com/attachments/1/2/a.gif?ex=6ab5&is=6ab3&hm=03cf&", false, true),
        ("https://cdn.discordapp.com/attachments/1/2/SHOUT.GIF", false, true),
        ("https://x.test/a.gif#frag", false, true),
        ("https://x.test/a.webp?size=160", true, true),
        ("https://x.test/a.webp", false, false),
        ("https://x.test/a.avif", true, true),
        ("https://x.test/a.png", true, false),
        ("https://x.test/a.gifv", false, false),
        ("https://x.test/gif/a.jpg", false, false),
    ])
    func rule(url: String, marked: Bool, moves: Bool) {
        #expect(CDN.playsAsAnimated(url, isMarkedAnimated: marked) == moves)
    }

    @Test("A moving picture asks the proxy for every frame; a still does not")
    func animatedParameter() throws {
        let proxy = "https://media.discordapp.net/attachments/1/2/a.webp?ex=6ab5&is=6ab3&hm=03cf"
        let moving = try #require(CDN.resizedAttachment(proxyURL: proxy, width: 100, height: 80, animated: true))
        let still = try #require(CDN.resizedAttachment(proxyURL: proxy, width: 100, height: 80))
        #expect(moving.query()?.contains("animated=true") == true)
        #expect(still.query()?.contains("animated") == false)
        // Asked again, it is replaced rather than repeated.
        let again = try #require(CDN.resizedAttachment(proxyURL: moving.absoluteString, width: 100, animated: true))
        #expect(again.query()?.components(separatedBy: "animated=").count == 2)
    }
}
