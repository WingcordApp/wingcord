import CoreGraphics
import Foundation
import Testing
import WingcordCore

/// What a picture is asked of Discord's media proxy for (docs/BETA3.md §1.4).
///
/// **The proxy crops to the box it is given and refuses a side past 4096**
/// (measured 2026-11-18 on the Beta 2 banner, 1672×941: `808×3232` came back a
/// 1:4 slice, `1616×6464` a 400). A box invented as four widths was the
/// zoomed banner and every blurred card.
@Suite("Media proxy boxes")
struct ProxyBoxTests {
    private static let proxy = "https://media.discordapp.net/attachments/1/2/banner.png?ex=a&is=b&hm=c"
    private static let banner = CGSize(width: 1672, height: 941)

    private func box(_ url: URL?) -> (width: Int?, height: Int?) {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return (
            items.first { $0.name == "width" }?.value.flatMap(Int.init),
            items.first { $0.name == "height" }?.value.flatMap(Int.init)
        )
    }

    @Test("The banner in a card 404 points wide is asked for in its own shape")
    func bannerKeepsItsShape() {
        let url = CDN.resizedAttachment(proxyURL: Self.proxy, width: 404, sourceSize: Self.banner)
        let asked = box(url)
        #expect(asked.width == 808)
        #expect(asked.height == 455)
    }

    @Test("Never four widths: no shape known is the original, untouched")
    func noShapeIsTheOriginal() throws {
        let url = try #require(CDN.resizedAttachment(proxyURL: Self.proxy, width: 404))
        let asked = box(url)
        #expect(asked.width == nil)
        #expect(asked.height == nil)
        // The signed parameters stay: without them the CDN refuses.
        #expect(url.absoluteString.contains("hm=c"))
    }

    @Test("A box the caller draws into is kept: a square thumbnail crops by design")
    func callersBoxIsKept() {
        let asked = box(CDN.resizedAttachment(proxyURL: Self.proxy, width: 85, height: 85, sourceSize: Self.banner))
        #expect(asked.width == 170)
        #expect(asked.height == 170)
    }

    @Test("Never larger than the file: the proxy would only enlarge it")
    func neverPastTheSource() {
        let asked = box(CDN.resizedAttachment(proxyURL: Self.proxy, width: 1000, sourceSize: Self.banner))
        #expect(asked.width == 1672)
        #expect(asked.height == 941)
        let square = box(CDN.resizedAttachment(proxyURL: Self.proxy, width: 3000, height: 3000, sourceSize: Self.banner))
        #expect(square.width == 941)
        #expect(square.height == 941)
    }

    @Test("Neither side past 4096, the shape kept")
    func neverPastTheLimit() {
        let tall = CGSize(width: 1000, height: 8000)
        let asked = box(CDN.resizedAttachment(proxyURL: Self.proxy, width: 3000, sourceSize: tall))
        #expect(asked.height == CDN.proxyLimit)
        #expect(asked.width == 512)
        let wide = box(CDN.resizedAttachment(proxyURL: Self.proxy, width: 4096, height: 1024, scale: 2))
        #expect(wide.width == CDN.proxyLimit)
        #expect(wide.height == 1024)
    }

    @Test("A video's poster follows the same rule and stays a WebP")
    func posterFollowsTheRule() throws {
        let url = try #require(CDN.videoPoster(proxyURL: Self.proxy, width: 404, sourceSize: Self.banner))
        let asked = box(url)
        #expect(asked.width == 808)
        #expect(asked.height == 455)
        #expect(url.absoluteString.contains("format=webp"))
        let bare = try #require(CDN.videoPoster(proxyURL: Self.proxy, width: 404))
        #expect(box(bare).width == nil)
    }
}
