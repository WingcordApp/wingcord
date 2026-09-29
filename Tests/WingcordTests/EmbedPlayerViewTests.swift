import AppKit
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// A site's own player over a video card, and what fullscreen does to it.
@MainActor
@Suite("Embed player")
struct EmbedPlayerViewTests {

    /// A blank page rather than a site, so nothing here reaches the network.
    private func player() throws -> EmbedPlayerView {
        EmbedPlayerView(messageID: MessageID(rawValue: 1), video: .player(try #require(URL(string: "about:blank"))))
    }

    @Test("The player fills the card it plays over, as the card moves and resizes")
    func fillsItsCard() throws {
        let view = try player()
        defer { view.stop() }
        view.frame = CGRect(x: 40, y: 900, width: 400, height: 225)
        let web = try #require(view.subviews.first)
        #expect(web.frame == view.bounds)
        view.setFrameSize(CGSize(width: 320, height: 180))
        #expect(web.frame == view.bounds)
    }

    /// **The report**: fullscreen drew the video at the card's size in the
    /// bottom-left corner of a black screen. WebKit moves the web view into a
    /// window of its own and leaves a placeholder in the card, so the card's
    /// next layout pass must leave a web view that has gone alone.
    @Test("A layout pass does not shrink a web view that went fullscreen")
    func fullscreenKeepsItsSize() throws {
        let view = try player()
        defer { view.stop() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 225)
        let web = try #require(view.subviews.first)

        let screen = NSView(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        web.removeFromSuperview()
        screen.addSubview(web)
        web.frame = screen.bounds
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()

        #expect(web.frame == screen.bounds)
    }
}
