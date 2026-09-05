import Foundation
import Testing
@testable import WingcordCore

/// A pasted picture link, and the two shapes it actually arrives in.
///
/// **Both were being drawn as link-preview cards** — a short empty box with the
/// picture squeezed into the 80-point thumbnail well beside it — because the
/// client looked for the media in `image`, and neither of them puts it there.
@Suite("Bare image embeds")
struct BareImageEmbedTests {

    private func media(_ url: String, _ width: Int = 400, _ height: Int = 300) -> Embed.Media {
        Embed.Media(url: url, proxyURL: url, width: width, height: height)
    }

    /// **Captured**, `threads.har`: a `type: "image"` embed has no `image` field
    /// at all. This is the one that made a direct `.gif` link draw an empty card.
    @Test("An image embed carries its picture in thumbnail")
    func imageTypeUsesThumbnail() {
        let embed = Embed(
            kind: "image",
            url: "https://cdn.discordapp.com/attachments/1/2/HappyDays.gif",
            thumbnail: media("https://cdn.discordapp.com/attachments/1/2/HappyDays.gif")
        )
        #expect(embed.isBareImage)
        #expect(embed.bareMedia?.width == 400)
    }

    /// A GIF provider's unfurl carries a title, a provider and a page URL, and
    /// Discord draws none of them. The **type** decides, not the emptiness test.
    @Test("A gifv is bare even though it has a title")
    func gifvIgnoresItsTitle() {
        let embed = Embed(
            title: "Hugs Big Hugs GIF - Hugs Big hugs - Discover & Share GIFs",
            kind: "gifv",
            url: "https://tenor.com/view/hugs-big-hugs-gif-2881900892435551369",
            thumbnail: media("https://media.tenor.com/abc/hugs.gif", 498, 498),
            video: media("https://media.tenor.com/abc/hugs.mp4", 498, 498),
            providerName: "Tenor"
        )
        #expect(embed.isBareImage)
        // The thumbnail, not the video: an MP4 has no inline player here.
        #expect(embed.bareMedia?.url.hasSuffix(".gif") == true)
    }

    /// The guard that keeps every ordinary link preview a card. A thumbnail
    /// beside a title and a description is the 80-point well, which is what it
    /// is for.
    @Test("A link preview with a thumbnail is still a card")
    func linkPreviewStaysACard() {
        let embed = Embed(
            title: "Some article",
            description: "A paragraph about it.",
            url: "https://example.com/article",
            thumbnail: media("https://example.com/hero.png")
        )
        #expect(!embed.isBareImage)
    }
}

/// What a message draws when the message is only a link.
@Suite("Suppressed link text")
struct SuppressedLinkTextTests {

    private func message(_ content: String, embeds: [Embed]) -> Message {
        Message(
            id: MessageID(rawValue: 1),
            channelID: ChannelID(rawValue: 2),
            authorID: UserID(rawValue: 3),
            content: content,
            payload: MessagePayload(embeds: embeds)
        )
    }

    private var gif: Embed {
        Embed(
            kind: "image",
            url: "https://cdn.discordapp.com/attachments/1/2/HappyDays.gif",
            thumbnail: Embed.Media(
                url: "https://cdn.discordapp.com/attachments/1/2/HappyDays.gif",
                width: 400, height: 300
            )
        )
    }

    @Test("A message that is only the link draws no text")
    func onlyTheLink() {
        let value = message("https://cdn.discordapp.com/attachments/1/2/HappyDays.gif", embeds: [gif])
        #expect(value.displayedContent.isEmpty)
        // Display only. Copy, search and the accessibility label still get the
        // words the message actually carries.
        #expect(!value.content.isEmpty)
    }

    /// **The sentence is not the link.** Dropping the words here would lose
    /// what somebody wrote.
    @Test("A link with words around it keeps the words")
    func linkWithWords() {
        let value = message(
            "look at this https://cdn.discordapp.com/attachments/1/2/HappyDays.gif",
            embeds: [gif]
        )
        #expect(value.displayedContent == value.content)
    }

    /// One of two links unfurled. Dropping the text would take the other one
    /// with it, and it is the only place that one appears.
    @Test("A second link that did not unfurl keeps the text")
    func secondLinkSurvives() {
        let value = message(
            "https://cdn.discordapp.com/attachments/1/2/HappyDays.gif https://example.com",
            embeds: [gif]
        )
        #expect(value.displayedContent == value.content)
    }

    /// A card is not a picture: an article preview says nothing the link text
    /// does, so the link stays.
    @Test("A link that unfurled into a card keeps its text")
    func cardKeepsItsLink() {
        let card = Embed(
            title: "Some article",
            description: "A paragraph.",
            url: "https://example.com/article"
        )
        let value = message("https://example.com/article", embeds: [card])
        #expect(value.displayedContent == value.content)
    }
}
