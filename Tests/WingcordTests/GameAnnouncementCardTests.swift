import AppKit
import Foundation
import SwiftUI
import Testing
import WingcordCore
@testable import Wingcord

/// Announcements on a game's profile, digested as Discord digests them
/// (`pp`, `05ea9e44…`) and drawn as its cards are.
@MainActor
@Suite("Game announcement cards")
struct GameAnnouncementCardTests {

    private func message(
        content: String = "",
        attachments: [WingcordCore.Attachment] = [],
        embeds: [Embed] = []
    ) -> Message {
        Message(
            id: MessageID(rawValue: 77),
            channelID: ChannelID(rawValue: 3),
            authorID: UserID(rawValue: 5),
            content: content,
            payload: MessagePayload(attachments: attachments, embeds: embeds)
        )
    }

    @Test("A post opening with a heading is titled by it, and the rest stays markdown")
    func headingIsTheTitle() throws {
        let card = try #require(AppModel.announcementCard(message(
            content: "## Grand Theft Auto VI pre-loading is now available\nIf you still have yet to **pre-order**, see [the store](https://rockstargames.com)."
        )))
        #expect(card.title == "Grand Theft Auto VI pre-loading is now available")
        #expect(card.body == "If you still have yet to **pre-order**, see [the store](https://rockstargames.com).")
    }

    @Test("A post with no heading has no title, and all of it is the body")
    func noHeading() throws {
        let card = try #require(AppModel.announcementCard(message(content: "\"Blood In Your Eyes\" by Tove Lo")))
        #expect(card.title == nil)
        #expect(card.body == "\"Blood In Your Eyes\" by Tove Lo")
    }

    @Test("A video attachment's first frame is the picture, asked of the media proxy as WebP")
    func videoFrame() throws {
        let video = WingcordCore.Attachment(
            id: AttachmentID(rawValue: 9),
            filename: "preload.mp4",
            url: "https://cdn.discordapp.com/attachments/1/2/preload.mp4",
            proxyURL: "https://media.discordapp.net/attachments/1/2/preload.mp4?ex=1&is=2&hm=3",
            contentType: "video/mp4",
            width: 1920,
            height: 1080
        )
        let card = try #require(AppModel.announcementCard(message(content: "Out now", attachments: [video])))
        let media = try #require(card.media)
        let parts = try #require(URLComponents(url: media.url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(parts.host == "media.discordapp.net")
        #expect(query["format"] == "webp")
        #expect(query["width"] == "728")
        #expect(query["height"] == "410")
        // The signature the proxy checks is kept.
        #expect(query["hm"] == "3")
        #expect(abs(media.aspect - 16.0 / 9) < 0.001)
    }

    @Test("A post that is only a link takes its words from the link's embed, and says where they came from")
    func loneLinkUsesTheEmbed() throws {
        let embed = Embed(
            title: "Watch the trailer",
            description: "Grand Theft Auto VI, November 19.",
            url: "https://www.youtube.com/watch?v=abc"
        )
        let card = try #require(AppModel.announcementCard(message(
            content: "https://www.youtube.com/watch?v=abc", embeds: [embed]
        )))
        #expect(card.title == "Watch the trailer")
        #expect(card.body == "Grand Theft Auto VI, November 19.")
        #expect(card.source?.url == "https://www.youtube.com/watch?v=abc")
    }

    @Test("Drawn — written out with WINGCORD_RENDER_DIR set")
    func drawn() throws {
        let cards = [
            GameAnnouncementCard(
                id: MessageID(rawValue: 1),
                title: "Grand Theft Auto VI pre-loading is now available for everyone who has pre-ordered",
                body: "If you still have yet to pre-order, now's the time to make sure you're prepared for **November 19**. Trailer: [rockstargames.com/VI](https://rockstargames.com/VI)",
                media: nil,
                postedAt: Date(timeIntervalSince1970: 1_794_000_000),
                reactionCount: 6_071,
                poll: nil,
                source: nil,
                spokenText: "Pre-loading"
            ),
            GameAnnouncementCard(
                id: MessageID(rawValue: 2),
                title: nil,
                body: "\"Blood In Your Eyes\" by Tove Lo — featured in today's Pre-Load Now video and also on **GTAVI: The Album**\nAvailable now on all major music streaming services: https://gtavi-thealbum.lnk.to/bloodinyoureyes",
                media: nil,
                postedAt: Date(timeIntervalSince1970: 1_794_000_000),
                reactionCount: 3_550,
                poll: nil,
                source: nil,
                spokenText: "Blood"
            ),
        ]
        let shelf = GameAnnouncementsShelf(announcements: cards, openChannel: {}, openMessage: { _ in })
            .environment(\.colorScheme, .dark)
        let result = try SurfaceRender.render(shelf, named: "game-announcements", width: 760)
        #expect(result.ink > 0.05)
    }
}
