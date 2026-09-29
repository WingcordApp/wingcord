import AppKit
import CoreGraphics
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Link embeds as Discord's normaliser and stylesheet set them (module
/// `659674`, stylesheet `198496`). Each fixture is a capture's own fields —
/// `blip embed.har`, `usevia qwertykeys.har`.
@MainActor
@Suite("Link embeds")
struct LinkEmbedTests {

    private func layout(_ embed: Embed, width: CGFloat = 520) -> EmbedSlot {
        EmbedLayoutEngine.layout(
            embed,
            origin: .zero,
            availableWidth: width,
            style: MessageTextStyle.current(),
            mentions: MentionContext(),
            parser: MarkdownParser()
        )
    }

    private func texts(_ slot: EmbedSlot) -> [String] {
        slot.texts.map { $0.block.text.attributed.string }
    }

    private let blip = Embed(
        title: "Blip is the fastest way to send files",
        kind: "article",
        description: "Send big files with no size limits, at full quality, across platforms,\n\t\t\t\t\t\t\t\t directly to other people and devices",
        url: "https://blip.net/",
        colorValue: 7_674_869,
        thumbnail: Embed.Media(
            url: "https://blip.net/og_image.jpg",
            proxyURL: "https://images-ext-1.discordapp.net/external/5GRnOCVv6KKi10AD06zjPARso7xO1jrKe9bCB6kocOo/https/blip.net/og_image.jpg",
            width: 1200, height: 630
        ),
        video: Embed.Media(
            url: "https://blip.net/videos/overview-640kbps.mp4",
            proxyURL: "https://images-ext-1.discordapp.net/external/jiCj2FCZ-Tg0wtlEHktNwtxIDYbSQdQg6u3a6BYd4fU/https/blip.net/videos/overview-640kbps.mp4",
            width: 1920, height: 1080
        ),
        providerName: "Blip"
    )

    /// **The report**: Blip's card was a title, a description broken by a
    /// wide gap, and a corner picture — where Discord plays its video.
    @Test("An article's video file plays in the card, behind a still of itself")
    func blipVideo() throws {
        let slot = layout(blip)
        let media = try #require(slot.images.first { $0.controls != nil })
        guard case .file(let file) = media.video else {
            Issue.record("the card's media should be the video file")
            return
        }
        #expect(file.absoluteString.hasSuffix("overview-640kbps.mp4"))
        // The proxy's still of the file, not the og image.
        #expect(media.url?.query()?.contains("format=jpg") == true)
        #expect(abs(media.rect.width / media.rect.height - 16.0 / 9.0) < 0.02)
        #expect(media.rect.width <= 400)
        // No corner thumbnail beside the media.
        #expect(slot.images.count == 1)
    }

    @Test("The site's name leads the card, and a description is set as pre-line")
    func providerAndWhitespace() {
        let lines = texts(layout(blip))
        #expect(lines.first == "Blip")
        #expect(lines.contains("Send big files with no size limits, at full quality, across platforms,\ndirectly to other people and devices"))
        #expect(EmbedLayoutEngine.preLine("a  \t b\n\t\t c\n```\n  kept\n```") == "a b\nc\n```\n  kept\n```")
    }

    @Test("An article's thumbnail is its picture, drawn large")
    func qwertykeys() throws {
        let slot = layout(Embed(
            title: "Firmware and Software",
            kind: "article",
            description: "All-in-one download site for Owlab and Qwertykeys firmware and software.",
            url: "https://www.qwertykeys.com/pages/fw",
            colorValue: 1_513_239,
            thumbnail: Embed.Media(
                url: "http://www.qwertykeys.com/cdn/shop/files/color_logo_png_45a844cc-e882-4981-b9fe-93749e0aff52.png?v=1661514169",
                proxyURL: "https://images-ext-1.discordapp.net/external/e8T4i3rhBIQqcDcq7PyL0CfJNYDDfT13wIDjLmzxQj0/%3Fv%3D1661514169/http/www.qwertykeys.com/cdn/shop/files/color_logo_png_45a844cc-e882-4981-b9fe-93749e0aff52.png",
                width: 2570, height: 1290
            ),
            providerName: "Qwertykeys"
        ))
        let picture = try #require(slot.images.first)
        #expect(picture.rect.width == 400)
        #expect(abs(picture.rect.width / picture.rect.height - 2570.0 / 1290.0) < 0.02)
        #expect(texts(slot).first == "Qwertykeys")
    }

    /// A link keeps its thumbnail in the corner, and the card is as wide as
    /// what is in it — Discord's `max-width: max-content`.
    @Test("A link's card fits its content, its thumbnail in the corner")
    func via() throws {
        let slot = layout(Embed(
            title: "VIA",
            kind: "link",
            description: "Your keyboard's best friend",
            url: "https://usevia.app/",
            colorValue: 14_342_874,
            thumbnail: Embed.Media(
                url: "https://usevia.app/images/chippy.png",
                proxyURL: "https://images-ext-1.discordapp.net/external/fSf42b2Tt2vtYkL1m7qRgm6aS669IjXfAyKSGg9eAss/https/usevia.app/images/chippy.png",
                width: 1024, height: 1024
            )
        ))
        let thumbnail = try #require(slot.images.first)
        #expect(thumbnail.rect.width == EmbedLayoutEngine.thumbnailSide)
        #expect(slot.rect.width < Metrics.embedMaxWidth - 60)
        // Still inside its card, against its trailing edge.
        #expect(thumbnail.rect.maxX == slot.rect.maxX - EmbedLayoutEngine.padding)
        #expect(slot.isLinkCard)
    }

    @Test("Embeds that share a link are one card with a gallery")
    func gallery() {
        func post(_ image: String) -> Embed {
            Embed(
                title: "A post", kind: "rich", url: "https://x.test/status/1",
                image: Embed.Media(url: "https://x.test/\(image).jpg", width: 1200, height: 800)
            )
        }
        let merged = Embed.mergingGalleries([post("a"), post("b"), post("c")])
        #expect(merged.count == 1)
        #expect(merged.first?.galleryImages.count == 2)
        let slot = layout(merged[0])
        #expect(slot.images.count == 3)
        #expect(slot.images.allSatisfy { $0.cropsToFill })
        #expect(slot.images.allSatisfy { slot.rect.contains($0.rect) })
    }
}
