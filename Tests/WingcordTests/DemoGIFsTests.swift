import Foundation
import ImageIO
import Testing
import WingcordCore
@testable import Wingcord

/// `--demo`'s own GIFs — what Choose GIF and the composer's GIF tab offer
/// without a request.
@Suite("Demo GIFs")
struct DemoGIFsTests {

    @Test("Eight loops, every one a moving GIF on disk")
    func loops() throws {
        let gifs = DemoGIFs.all
        #expect(gifs.count == 8)
        for gif in gifs {
            let url = try #require(gif.previewURL)
            #expect(url.isFileURL)
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            #expect(CGImageSourceGetCount(source) > 1, "\(url.lastPathComponent) moves")
        }
    }

    @Test("The landing has a tile per loop, and a search never comes back empty")
    func landingAndSearch() {
        let landing = DemoGIFs.landing
        #expect(landing.categories.map(\.name).contains("hello"))
        #expect(landing.trending.count == 8)
        #expect(DemoGIFs.search("love").first?.previewURL?.lastPathComponent == "love.gif")
        #expect(DemoGIFs.search("nothing like it").count == 8)
    }

    @Test("A picked GIF reads back as a moving picture ready to crop")
    func pickedReadsBack() async throws {
        let url = try #require(DemoGIFs.all.first?.previewURL)
        let picked = try await PictureFile.download(url)
        #expect(picked.mimeType == "image/gif")
        #expect(PictureFile.isAnimated(picked))
        let crop = PictureCrop(shape: .avatar, imageSize: CGSize(width: 200, height: 150), viewport: CGSize(width: 240, height: 240))
        let cut = try #require(PictureFile.cropped(picked, to: crop))
        #expect(cut.mimeType == "image/gif")
        #expect(PictureFile.isAnimated(cut))
        let frame = try #require(PictureFile.firstFrame(cut))
        #expect(frame.width == 150 && frame.height == 150)
    }
}
