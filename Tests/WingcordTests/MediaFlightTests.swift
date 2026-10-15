import CoreGraphics
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The viewer's flights and gallery, as arithmetic: a picture grows out of its
/// thumbnail and lands back in it cropped as the cell crops it; a swipe pages
/// by where it is going; a gesture picks its axis after ten points.
@Suite("Media flights and paging")
struct MediaFlightTests {

    private let box = CGRect(x: 100, y: 200, width: 120, height: 120)
    /// A landscape picture, 3:2.
    private let picture = CGSize(width: 1500, height: 1000)
    private let stage = CGRect(x: 0, y: 0, width: 1200, height: 800)

    @Test("A mosaic cell crops the picture to fill it; a lone picture's box fits it")
    func home() {
        let cell = MediaFlight.home(box: box, cornerRadius: 8, pictureSize: picture, cropsToFill: true)
        #expect(cell.clip == box)
        #expect(cell.content.height == box.height)
        #expect(cell.content.width == 180)
        #expect(cell.content.midX == box.midX)
        #expect(cell.cornerRadius == 8)

        let lone = MediaFlight.home(box: CGRect(x: 0, y: 0, width: 300, height: 200), cornerRadius: 8, pictureSize: picture, cropsToFill: false)
        #expect(lone.content == lone.clip)
    }

    @Test("A flight is exactly its ends at 0 and 1")
    func ends() {
        let from = MediaFlight.home(box: box, cornerRadius: 8, pictureSize: picture, cropsToFill: true)
        let to = MediaFlight.stage(content: MediaFlight.aspectFit(picture, in: stage))
        let flight = MediaFlight(from: from, to: to)
        let start = flight.frame(progress: 0, contentCenter: CGPoint(x: from.content.midX, y: from.content.midY))
        let end = flight.frame(progress: 1, contentCenter: CGPoint(x: to.content.midX, y: to.content.midY))
        #expect(start == from)
        #expect(end == to)
        #expect(end.cornerRadius == 0)
        #expect(end.clip == end.content)
    }

    @Test("Halfway, the clip and the picture morph together")
    func middle() {
        let from = MediaFlight.home(box: box, cornerRadius: 8, pictureSize: picture, cropsToFill: true)
        let to = MediaFlight.stage(content: MediaFlight.aspectFit(picture, in: stage))
        let flight = MediaFlight(from: from, to: to)
        let center = CGPoint(x: 500, y: 450)
        let middle = flight.frame(progress: 0.5, contentCenter: center)
        #expect(middle.content.midX == center.x)
        #expect(middle.content.midY == center.y)
        #expect(middle.cornerRadius == 4)
        // The clip is still narrower than the picture — the crop is opening.
        #expect(middle.clip.width < middle.content.width)
        #expect(middle.content.width > from.content.width)
        #expect(middle.content.width < to.content.width)
    }

    @Test("With nowhere to fly, the picture materialises in place")
    func dissolve() {
        let content = MediaFlight.aspectFit(picture, in: stage)
        let gone = MediaFlight.dissolve(content: content)
        #expect(gone.alpha == 0)
        #expect(gone.content.midX == content.midX)
        #expect(gone.content.width < content.width)
    }

    @Test("Presence follows the flight both ways")
    func presence() {
        #expect(MediaFlight.presence(progress: 0, isOpening: true) == 0)
        #expect(MediaFlight.presence(progress: 1, isOpening: true) == 1)
        #expect(MediaFlight.presence(progress: 1, isOpening: false) == 0)
        #expect(MediaFlight.presence(progress: 1.04, isOpening: false) == 0)
    }

    @Test("Ten points before a direction is chosen, then the dominant axis")
    func axis() {
        #expect(GestureAxis.resolve(CGPoint(x: 6, y: 5)) == .undecided)
        #expect(GestureAxis.resolve(CGPoint(x: 12, y: 3)) == .paging)
        #expect(GestureAxis.resolve(CGPoint(x: -3, y: -14)) == .dismissing)
    }

    @Test("A page turns by where the swipe is going")
    func paging() {
        let width: CGFloat = 1232
        // A short fast flick turns it…
        #expect(MediaPaging.landing(offset: -80, velocity: -1400, pageWidth: width, canPage: true) == 1)
        // …a long slow drag that came back does not…
        #expect(MediaPaging.landing(offset: -500, velocity: 600, pageWidth: width, canPage: true) == 0)
        // …past halfway with no speed it does, either way.
        #expect(MediaPaging.landing(offset: 700, velocity: 0, pageWidth: width, canPage: true) == -1)
        // And nothing to page to is nothing to page to.
        #expect(MediaPaging.landing(offset: -900, velocity: -2000, pageWidth: width, canPage: false) == 0)
    }

    @Test("Velocity comes from the last stretch of samples, not the last event")
    func velocity() {
        var tracker = GestureVelocity()
        tracker.add(.zero, at: 0)
        tracker.add(CGPoint(x: 10, y: 0), at: 0.01)
        tracker.add(CGPoint(x: 20, y: 0), at: 0.02)
        tracker.add(CGPoint(x: 30, y: -5), at: 0.03)
        let speed = tracker.velocity
        #expect(abs(speed.x - 1000) < 1)
        #expect(abs(speed.y + 166.7) < 1)
        // An old sample falls out of the window.
        tracker.add(CGPoint(x: 31, y: -5), at: 0.5)
        tracker.add(CGPoint(x: 32, y: -5), at: 0.51)
        #expect(abs(tracker.velocity.x - 100) < 1)
    }

    @Test("A gallery's neighbours wrap, as Discord's carousel does")
    func neighbours() {
        func item(_ id: UInt64) -> MediaItem {
            MediaItem(
                Attachment(
                    id: AttachmentID(rawValue: id), filename: "\(id).png",
                    url: "https://cdn.discordapp.com/attachments/1/\(id)/\(id).png",
                    proxyURL: "https://media.discordapp.net/attachments/1/\(id)/\(id).png",
                    contentType: "image/png", size: 10, width: 10, height: 10
                ),
                posterWidth: 100,
                attachmentIndex: Int(id)
            )!
        }
        var request = MediaViewerRequest(
            items: [item(1), item(2), item(3)], index: 0,
            messageID: MessageID(rawValue: 9 << 22), authorName: "Ada", sentAt: .now
        )
        #expect(request.item(offsetBy: -1)?.id == AttachmentID(rawValue: 3))
        #expect(request.item(offsetBy: 1)?.id == AttachmentID(rawValue: 2))
        #expect(request.sourceKey == MediaSources.Key(messageID: MessageID(rawValue: 9 << 22), attachmentIndex: 1))
        request.index = 2
        #expect(request.item(offsetBy: 1)?.id == AttachmentID(rawValue: 1))
        let single = MediaViewerRequest(items: [item(1)], index: 0, authorName: "Ada", sentAt: .now)
        #expect(single.item(offsetBy: 1) == nil)
    }
}
