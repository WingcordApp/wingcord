import CoreGraphics
import Testing
@testable import WingcordCore

@Suite("Picture crop")
struct PictureCropTests {

    @Test("A wide picture, unzoomed, keeps its centre square")
    func centredSquare() {
        let crop = PictureCrop(shape: .avatar, imageSize: CGSize(width: 2000, height: 1000), viewport: CGSize(width: 240, height: 240))
        #expect(crop.cropRect == CGRect(x: 500, y: 0, width: 1000, height: 1000))
        #expect(crop.outputSize == CGSize(width: 1000, height: 1000))
    }

    @Test("Dragging right shows more of the left")
    func dragging() {
        let crop = PictureCrop(
            shape: .avatar, imageSize: CGSize(width: 2000, height: 1000),
            viewport: CGSize(width: 240, height: 240), offset: CGSize(width: 60, height: 0)
        )
        // 240 points over 1000 pixels: 60 points is 250 pixels.
        #expect(crop.cropRect.minX == 250)
    }

    @Test("No edge can be dragged into view")
    func clamping() {
        let crop = PictureCrop(
            shape: .avatar, imageSize: CGSize(width: 2000, height: 1000),
            viewport: CGSize(width: 240, height: 240), offset: CGSize(width: 9_999, height: 9_999)
        )
        #expect(crop.offset == CGSize(width: 120, height: 0))
        #expect(crop.cropRect.minX == 0)
    }

    @Test("Zooming takes a smaller part, scaled to the output ceiling")
    func zooming() {
        let crop = PictureCrop(
            shape: .banner, imageSize: CGSize(width: 4000, height: 3000),
            viewport: CGSize(width: 340, height: 120), zoom: 2
        )
        let rect = crop.cropRect
        #expect(abs(rect.width / rect.height - PictureCrop.Shape.banner.aspect) < 0.02)
        #expect(crop.outputSize.width <= 1360)
        #expect(!crop.isIdentity)
    }

    @Test("A picture already the shape is left alone")
    func identity() {
        let crop = PictureCrop(shape: .avatar, imageSize: CGSize(width: 512, height: 512), viewport: CGSize(width: 240, height: 240))
        #expect(crop.isIdentity)
    }
}
